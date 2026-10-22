package com.feiniu.music.track_change

import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.animation.LinearInterpolator
import android.animation.ValueAnimator
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView

/**
 * 切歌通知·悬浮窗（单一渲染器）。
 *
 * TYPE_APPLICATION_OVERLAY 系统级悬浮窗：前台盖在应用上（原应用内弹窗效果），
 * 后台盖在系统上。不抢焦点、卡片外触摸穿透到下层；展示 durationMs 后自动移除。
 *
 * 卡片视觉对齐原 Flutter TrackChangeToastView（手机端精确数值）：
 *   - 圆角 16dp、边框、悬浮阴影
 *   - 封面 44dp 圆角 + 「正在播放」caption(accent) + 歌名 15sp 粗体 + 歌手 12sp 次级色
 *   - 音浪条（3 根 accent 竖条，ValueAnimator 循环动画）+ 关闭按钮「×」
 *   - 卡片宽度内容自适应（wrap_content），长歌名由文本列 maxWidth + ellipsize 兜底
 *
 * 背景 / 文字 / accent 全部来自 Dart 计算的 payload 配色（[show] 参数），不硬编码。
 * 所有 WindowManager 操作 try/catch：权限被撤销 / Activity 销毁时不崩溃。
 */
class OverlayTrackChange(private val context: Context) {

    companion object {
        private const val TAG = "OverlayTrackChange"
    }

    private val windowManager =
        context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val handler = Handler(Looper.getMainLooper())
    private val dismissRunnable = Runnable { hide() }
    private var overlayView: View? = null
    private var coverView: ImageView? = null

    // 音浪条动画（3 根竖条），show 时启动 / hide 时停止
    private var barsAnimator: ValueAnimator? = null
    private val barViews = ArrayList<View>(3)

    fun hasOverlayPermission(): Boolean = Settings.canDrawOverlays(context)

    fun openOverlaySettings(): Boolean = try {
        val intent = Intent(
            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            Uri.parse("package:${context.packageName}")
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
        true
    } catch (e: Exception) {
        android.util.Log.w(TAG, "打开悬浮窗权限设置失败", e)
        false
    }

    /** 悬浮窗权限缺失时的一次性提示（前台/后台均可见，不静默失败）。 */
    fun showPermissionToast() {
        try {
            android.widget.Toast.makeText(
                context,
                "未开启悬浮窗权限，无法显示切歌弹窗",
                android.widget.Toast.LENGTH_LONG
            ).show()
        } catch (e: Exception) {
            android.util.Log.w(TAG, "悬浮窗权限提示失败", e)
        }
    }

    fun show(
        title: String,
        artist: String,
        coverPath: String?,
        durationMs: Long,
        isLarge: Boolean,
        scale: Double,
        isDark: Boolean,
        cardColor: Int,
        textColor: Int,
        secondaryColor: Int,
        accentColor: Int
    ) {
        if (!hasOverlayPermission()) {
            android.util.Log.w(TAG, "无悬浮窗权限，忽略 show")
            return
        }
        hide() // 幂等：先移除旧窗口 + 取消旧回调
        handler.removeCallbacks(dismissRunnable)

        val view = buildCardView(
            title, artist, coverPath, isLarge, scale,
            isDark, cardColor, textColor, secondaryColor, accentColor
        )
        overlayView = view
        // 固定尺寸：手机 280×80dp，平板/TV 320×96dp × scale。
        // 窗口 LayoutParams 即固定像素，卡片绝不随歌曲信息伸缩 —— 任何歌同一长宽比。
        val density = context.resources.displayMetrics.density
        val baseW = if (isLarge) 320 else 280
        val baseH = if (isLarge) 96 else 80
        val fixedW = (((baseW * scale).toInt())).dp(density)
        val fixedH = (((baseH * scale).toInt())).dp(density)
        val wmParams = WindowManager.LayoutParams(
            fixedW,
            fixedH,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else
                WindowManager.LayoutParams.TYPE_PHONE,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            android.graphics.PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            y = statusBarHeight() + 12.dpToPx(context)
        }
        try {
            windowManager.addView(view, wmParams)
            handler.postDelayed(dismissRunnable, durationMs)
        } catch (e: Exception) {
            android.util.Log.w(TAG, "悬浮窗 addView 失败", e)
            overlayView = null
            stopBars()
        }
    }

    fun hide() {
        handler.removeCallbacks(dismissRunnable)
        stopBars()
        val view = overlayView ?: return
        overlayView = null
        coverView = null
        try {
            windowManager.removeView(view)
        } catch (e: Exception) {
            android.util.Log.w(TAG, "悬浮窗 removeView 失败", e)
        }
    }

    /**
     * 就地刷新封面：仅更新卡片上的 ImageView，不移除窗口、不重置 dismiss 计时器。
     * 窗口不存在或封面视图缺失时忽略；[coverPath] 为 null 时清空封面。
     */
    fun updateCover(coverPath: String?) {
        if (overlayView == null) return
        val cv = coverView ?: return
        try {
            cv.setImageBitmap(
                if (coverPath == null) null else BitmapFactory.decodeFile(coverPath)
            )
        } catch (e: Exception) {
            android.util.Log.w(TAG, "悬浮窗更新封面失败", e)
        }
    }

    // ---- 卡片构建 ----

    private fun buildCardView(
        title: String,
        artist: String,
        coverPath: String?,
        isLarge: Boolean,
        scale: Double,
        isDark: Boolean,
        cardColor: Int,
        textColor: Int,
        secondaryColor: Int,
        accentColor: Int
    ): View {
        val density = context.resources.displayMetrics.density
        val s = scale.toFloat()

        // ---- 尺寸。View 尺寸/圆角/间距用 dp（乘 density 得 px），文字用 sp（不乘）。
        //      全部按「卡片 280×80（手机）/ 320×96（平板）×scale」紧凑排布，
        //      封面/文字/音浪/关闭都在固定卡片内，标题恒可见。----
        val padH = (if (isLarge) 18 else 12).dp(density)             // px
        val padV = (if (isLarge) 14 else 10).dp(density)             // px
        val radius = (if (isLarge) 24 else 16).dp(density).toFloat() // 卡片圆角 px
        val coverSize = (if (isLarge) 60 else 48).dp(density) * s    // px
        val coverRadius = (coverSize * 0.18f).toInt()                // 封面圆角 px
        val gapArt = (if (isLarge) 14 else 10).dp(density)           // px
        val gapBars = (if (isLarge) 14 else 10).dp(density)          // px
        val gapClose = (if (isLarge) 10 else 6).dp(density)          // px
        val titleSp = (if (isLarge) 17 else 15).toFloat() * s        // sp
        val artistSp = (if (isLarge) 13 else 12).toFloat() * s       // sp
        val captionSp = (if (isLarge) 12 else 11).toFloat() * s      // sp
        val closeSp = (if (isLarge) 28 else 20).toFloat() * s        // sp

        // 边框色：深色白 12%，浅色黑 8%（对应原卡片 border）
        val borderColor = if (isDark) 0x1FFFFFFF.toInt() else 0x14000000.toInt()
        // 渐变背景（适配深色）：左上稍亮 → 右下稍暗，形成柔和层次。
        // 深色用暗灰渐变，浅色用近白渐变，均中性不抢主题色。
        val gradientTop = if (isDark) 0xFF2E333B.toInt() else 0xFFFFFFFF.toInt()
        val gradientBottom = if (isDark) 0xFF22262C.toInt() else 0xFFF2F4F6.toInt()

        // 卡片根：横向单行，内容自适应，圆角 + 渐变背景 + 边框 + 悬浮阴影
        val root = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(padH, padV, padH, padV)
            background = GradientDrawable(
                GradientDrawable.Orientation.TL_BR,
                intArrayOf(gradientTop, gradientBottom)
            ).apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = radius
                setStroke(((if (isLarge) 1.6f else 0.8f) * density).toInt(), borderColor)
            }
            elevation = (if (isLarge) 22 else 12).dp(density).toFloat()
        }

        // 封面：圆角 ImageView。无封面时显示中性占位底色。
        val cover = ImageView(context).apply {
            coverView = this
            val bmp = coverPath?.let { BitmapFactory.decodeFile(it) }
            setImageBitmap(bmp)
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = coverRadius.toFloat()
                setColor(if (bmp == null) 0x22000000.toInt() else cardColor)
            }
            setClipToOutline(true)
        }
        root.addView(
            cover,
            LinearLayout.LayoutParams(coverSize.toInt(), coverSize.toInt()).apply {
                setMargins(0, 0, gapArt, 0)
            }
        )

        // 文本列：「正在播放」caption + 歌名（粗体）+ 歌手（次级色）
        val textColumn = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
        }
        val captionView = TextView(context).apply {
            text = "正在播放"
            setTextColor(accentColor)
            textSize = captionSp
            setSingleLine(true)
        }
        val titleView = TextView(context).apply {
            text = title
            setTextColor(textColor)
            textSize = titleSp
            setTypeface(null, Typeface.BOLD)
            setSingleLine(true)
            setEllipsize(TextUtils.TruncateAt.END)
        }
        val artistView = TextView(context).apply {
            text = artist
            setTextColor(secondaryColor)
            textSize = artistSp
            setSingleLine(true)
            setEllipsize(TextUtils.TruncateAt.END)
        }
        textColumn.addView(captionView)
        textColumn.addView(titleView)
        textColumn.addView(artistView)
        root.addView(
            textColumn,
            LinearLayout.LayoutParams(
                0,
                WindowManager.LayoutParams.WRAP_CONTENT,
                1f  // weight=1：撑开占满窗口固定宽度，歌名/歌手用省略号填充
            )
        )

        // 音浪条：3 根 accent 竖条，ValueAnimator 循环动画
        root.addView(
            buildBars(accentColor, isLarge, scale, density),
            LinearLayout.LayoutParams(
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.WRAP_CONTENT
            ).apply {
                setMargins(gapBars, 0, 0, 0)
            }
        )

        // 关闭按钮：「×」（次级色），点击隐藏。热区放大。
        val closeBtn = TextView(context).apply {
            text = "×"
            setTextColor(secondaryColor)
            textSize = closeSp
            gravity = Gravity.CENTER
            setPadding(
                (if (isLarge) 14 else 6).dp(density),
                (if (isLarge) 14 else 6).dp(density),
                (if (isLarge) 14 else 6).dp(density),
                (if (isLarge) 14 else 6).dp(density)
            )
            setOnClickListener { hide() }
        }
        root.addView(
            closeBtn,
            LinearLayout.LayoutParams(
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.WRAP_CONTENT
            ).apply {
                setMargins(gapClose, 0, 0, 0)
            }
        )

        return root
    }

    /**
     * 3 根竖条音浪（对应原 Flutter PlayingBars）。容器固定高度（避免动画时窗口
     * resize 抖动），条形在内部向上生长。尺寸按紧凑卡片（14dp 高）排布。
     */
    private fun buildBars(
        accentColor: Int,
        isLarge: Boolean,
        scale: Double,
        density: Float
    ): View {
        val barWidth = (if (isLarge) 3 else 3).dp(density)
        val barMaxHeight = (if (isLarge) 16 else 14).dp(density) * scale.toFloat()
        val gap = (if (isLarge) 3 else 2).dp(density)

        val container = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.BOTTOM
        }

        barViews.clear()
        for (i in 0 until 3) {
            val bar = View(context).apply {
                background = GradientDrawable().apply {
                    shape = GradientDrawable.RECTANGLE
                    cornerRadius = (barWidth / 2).toFloat()
                    setColor(accentColor)
                }
            }
            // 初始高度：中间高、两侧低（像音浪）
            val initH = (barMaxHeight * (if (i == 1) 1.0f else 0.55f)).toInt()
            container.addView(
                bar,
                LinearLayout.LayoutParams(barWidth, initH).apply {
                    setMargins(if (i == 0) 0 else gap, 0, 0, 0)
                }
            )
            barViews.add(bar)
        }

        // 固定容器高度，防止窗口随动画 resize
        container.layoutParams = LinearLayout.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            barMaxHeight.toInt()
        )

        barsAnimator?.cancel()
        barsAnimator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 820
            repeatCount = ValueAnimator.INFINITE
            interpolator = LinearInterpolator()
            addUpdateListener { anim ->
                val v = anim.animatedValue as Float
                for ((idx, bar) in barViews.withIndex()) {
                    val lp = bar.layoutParams as LinearLayout.LayoutParams
                    val phase = (v + idx * 0.33f) % 1.0f
                    // 高度在 0.45–1.0 之间起伏（不同步，像真音浪）
                    lp.height = (barMaxHeight * (0.45f + 0.55f * phase)).toInt()
                    bar.layoutParams = lp
                }
            }
            start()
        }
        return container
    }

    private fun stopBars() {
        barsAnimator?.cancel()
        barsAnimator = null
        barViews.clear()
    }

    private fun Int.dp(density: Float) = (this * density).toInt()

    private fun Int.dpToPx(context: Context): Int =
        (this * context.resources.displayMetrics.density).toInt()

    /** 系统状态栏高度（px）；资源不存在（如非系统 UI / 自定义 ROM）时回退 0。 */
    private fun statusBarHeight(): Int {
        val res = context.resources
        val id = res.getIdentifier("status_bar_height", "dimen", "android")
        return if (id > 0) res.getDimensionPixelSize(id) else 0
    }
}
