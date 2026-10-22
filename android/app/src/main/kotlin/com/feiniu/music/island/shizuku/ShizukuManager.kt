package com.feiniu.music.island.shizuku

import android.content.AttributionSource
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.PackageManager
import android.os.Build
import android.os.IBinder
import android.util.Log
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.first
import rikka.shizuku.Shizuku
import rikka.shizuku.ShizukuBinderWrapper
import rikka.shizuku.SystemServiceHelper
import rikka.sui.Sui
import java.lang.reflect.InvocationTargetException
import java.util.concurrent.ConcurrentHashMap

/**
 * Shizuku 焦点通知白名单绕过管理。
 *
 * 澎湃 OS 对焦点通知有应用白名单限制（未在名单内的应用发送的焦点通知会被
 * 系统拦截）。绕过思路（完整移植自 HyperNotification 的 ShizukuManager，
 * Apache-2.0）：借助 Shizuku 的高权限，在发送焦点通知的前后短暂拦截 XMSF
 * （com.xiaomi.xmsf，即小米推送/焦点通知服务）的网络——网络被掐断时系统
 * 无法向小米服务端校验白名单，本地焦点通知得以渲染。
 *
 * 注意：`setXmsfNetworkingEnabled` 在 Shizuku 未授权/离线时返回 false（这是
 * 一种安全降级）。调用方不应依赖「返回 false → 自动关闭绕过开关」的行为，
 * 而应在需要绕过时自行校验授权（见 [hasBypassPermission]）。
 */
object ShizukuManager {
    private const val TAG = "ShizukuManager"
    private const val XMSF_PACKAGE = "com.xiaomi.xmsf"
    private const val OEM_DENY_CHAIN = "oem_deny"

    private val hookedServiceCache = ConcurrentHashMap<String, Any>()

    private data class ServiceBackend(
        val label: String,
        val stubClassName: String,
        val systemServiceName: String
    )

    private val serviceBackends = listOf(
        ServiceBackend("Connectivity", "android.net.IConnectivityManager\$Stub", Context.CONNECTIVITY_SERVICE),
        ServiceBackend("NetworkManagement", "android.os.INetworkManagementService\$Stub", "network_management")
    )

    /**
     * 校验 Shizuku 授权：服务运行且已授予权限。未授权时尝试弹出授权申请。
     *
     * @param packageName 当前应用实际安装包名，用于 Sui 初始化。
     */
    suspend fun checkShizukuPermission(packageName: String): Boolean {
        return try {
            if (!isShizukuServiceRunning(packageName)) return false
            if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) return true

            callbackFlow {
                val listener = Shizuku.OnRequestPermissionResultListener { _, grantResult ->
                    trySend(grantResult == PackageManager.PERMISSION_GRANTED)
                }
                Shizuku.addRequestPermissionResultListener(listener)
                Shizuku.requestPermission(1001)
                awaitClose { Shizuku.removeRequestPermissionResultListener(listener) }
            }.catch { emit(false) }.first()
        } catch (e: Throwable) {
            Log.e(TAG, "Shizuku 权限检查异常: ${e.message}", e)
            false
        }
    }

    /**
     * 判断 Shizuku 服务当前是否运行（含 Sui/root 兼容初始化）。
     *
     * @param packageName 当前应用实际安装包名，用于 Sui 初始化。
     */
    fun isShizukuServiceRunning(packageName: String): Boolean {
        return try {
            Sui.init(packageName)
            Shizuku.pingBinder()
        } catch (_: Throwable) {
            false
        }
    }

    /**
     * 判断当前是否具备「绕过焦点通知白名单」的完整授权（服务运行 + 权限已授予）。
     */
    fun hasBypassPermission(packageName: String): Boolean {
        return try {
            isShizukuServiceRunning(packageName) &&
                Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
        } catch (_: Throwable) {
            false
        }
    }

    /**
     * 拦截 / 恢复 XMSF 网络。enabled=true 恢复网络，false 拦截网络。
     *
     * 未授权 / 服务离线时返回 false（安全降级，不做任何网络变更）。
     */
    suspend fun setXmsfNetworkingEnabled(context: Context, enabled: Boolean): Boolean {
        try {
            if (!isShizukuServiceRunning(context.packageName)) {
                Log.w(TAG, "Shizuku 服务未运行，跳过网络操作 enabled=$enabled")
                return false
            }
            if (Shizuku.checkSelfPermission() != PackageManager.PERMISSION_GRANTED) {
                Log.w(TAG, "Shizuku 未授权，跳过网络操作 enabled=$enabled")
                return false
            }
        } catch (e: Throwable) {
            Log.e(TAG, "Shizuku 检查异常 (服务可能未启动或 binder 未接收): ${e.message}", e)
            return false
        }

        val pm = context.packageManager
        val uid = try {
            pm.getPackageUid(XMSF_PACKAGE, 0)
        } catch (_: Exception) {
            Log.w(TAG, "未找到 XMSF 包名 (UID 查询失败)")
            return false
        }

        Log.v(TAG, "setXmsfNetworkingEnabled 被调用: enabled=$enabled, UID=$uid")

        // 1. 优先尝试使用具有高权限的 Shizuku User Service 进行跨进程调用以完美绕过系统对于 callingUid 的强校验
        try {
            Log.v(TAG, "正在尝试使用 Shizuku UserService...")
            val service = ShizukuServiceConnection.getPrivilegedService(context.packageName)
            Log.v(TAG, "成功获取特权 Service, 正在调用 setPackageNetworkingEnabled...")
            val success = service.setPackageNetworkingEnabled(uid, enabled)
            if (success) {
                Log.d(TAG, "通过特权 Service 成功设置 XMSF 网络状态为 $enabled")
                return true
            } else {
                Log.w(TAG, "特权 Service 返回失败, UID=$uid, 正在退回到本地 Hook 模式")
            }
        } catch (e: Exception) {
            Log.w(TAG, "特权 Service 调用失败: ${e.message}, 正在退回到本地 Hook 模式")
        }

        // 2. 本地 Hook 备用方案（当 User Service 无法正常工作或尚未就绪时的降级路径）
        val rule = if (enabled) 0 else 2 // 0 = ALLOW, 2 = DENY
        val failures = mutableListOf<String>()

        for (backend in serviceBackends) {
            try {
                val service = getHookedService(backend)
                Log.d(TAG, "正在尝试 ${backend.label} 后端: UID=$uid, enabled=$enabled (本地 Hook)")

                if (!enabled) {
                    callMethodResilient(
                        service,
                        listOf("setFirewallChainEnabled"),
                        OEM_DENY_CHAIN,
                        true
                    )
                    Log.d(TAG, "在拦截 UID=$uid 之前, 已通过 ${backend.label} 启用防火墙链 $OEM_DENY_CHAIN (本地 Hook)")
                }

                val methodUsed = callMethodResilient(
                    service,
                    listOf("setUidFirewallRule", "setFirewallUidRule"),
                    OEM_DENY_CHAIN,
                    uid,
                    rule
                )
                Log.d(
                    TAG,
                    "已通过 ${backend.label}.$methodUsed 成功${if (enabled) "恢复" else "拦截"} UID=$uid 的网络连接 (本地 Hook)"
                )
                return true
            } catch (t: Throwable) {
                val detail = "${backend.label} 失败: ${t.message}"
                failures += detail
                Log.w(TAG, detail, t)
            }
        }

        Log.e(TAG, "所有防火墙后端均失败: ${failures.joinToString(" || ")}")
        return false
    }

    private fun getHookedService(backend: ServiceBackend): Any {
        hookedServiceCache[backend.stubClassName]?.let { return it }

        return synchronized(this) {
            hookedServiceCache[backend.stubClassName]?.let { return@synchronized it }

            val originalBinder = SystemServiceHelper.getSystemService(backend.systemServiceName)
            val wrapper = ShizukuBinderWrapper(originalBinder)

            val stubClass = Class.forName(backend.stubClassName)
            val asInterfaceMethod = stubClass.getMethod("asInterface", IBinder::class.java)
            val service = asInterfaceMethod.invoke(null, wrapper)
                ?: throw RuntimeException("无法通过 asInterface 转换服务 Binder: ${backend.stubClassName}")

            hookedServiceCache[backend.stubClassName] = service
            service
        }
    }

    private fun callMethodResilient(obj: Any, methodNames: List<String>, vararg args: Any): String {
        val clazz = obj.javaClass
        val methods = clazz.methods

        for (methodName in methodNames) {
            val targetMethod = methods.find { it.name == methodName && it.parameterCount == args.size }
            if (targetMethod != null) {
                targetMethod.isAccessible = true
                val finalArgs = Array(args.size) { i ->
                    val paramType = targetMethod.parameterTypes[i]
                    val arg = args[i]
                    when {
                        paramType == Int::class.javaPrimitiveType && arg is Int -> arg
                        paramType == Boolean::class.javaPrimitiveType && arg is Boolean -> arg
                        paramType == Boolean::class.javaPrimitiveType && arg is Number -> arg.toInt() != 0
                        paramType == Int::class.javaPrimitiveType && arg is Boolean -> if (arg) 1 else 0
                        else -> arg
                    }
                }
                try {
                    targetMethod.invoke(obj, *finalArgs)
                    return methodName
                } catch (e: InvocationTargetException) {
                    throw e.targetException ?: e
                }
            }
        }
        throw NoSuchMethodException("Could not find any matching method in $methodNames with ${args.size} params on ${clazz.name}")
    }
}

/**
 * Shizuku 调用上下文：伪装为 com.android.shell（shell UID），使隐藏系统接口
 * 接受本次调用。完整移植自 HyperNotification 的 ShizukuContext（GPL-3.0）。
 */
class ShizukuContext(base: Context) : ContextWrapper(base) {
    override fun getOpPackageName(): String = "com.android.shell"

    override fun getAttributionSource(): AttributionSource {
        val shellUid = try {
            Shizuku.getUid()
        } catch (_: Throwable) {
            2000
        }
        val builder = AttributionSource.Builder(shellUid)
            .setPackageName("com.android.shell")
        if (Build.VERSION.SDK_INT >= 34) {
            Api34Impl.setPid(builder)
        }
        return builder.build()
    }

    private object Api34Impl {
        @androidx.annotation.RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
        fun setPid(builder: AttributionSource.Builder) {
            builder.setPid(-1)
        }
    }
}
