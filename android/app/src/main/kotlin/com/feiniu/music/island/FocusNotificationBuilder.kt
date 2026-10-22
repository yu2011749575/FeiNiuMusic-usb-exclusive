package com.feiniu.music.island

import org.json.JSONObject

/**
 * 构建 MIUI/HyperOS「焦点通知」所需的 param_v2 JSON。
 *
 * 移植自 HyperLyric 的 FocusNotificationBuilder（GPL-3.0）。HyperOS 依据这段
 * JSON 在系统灵动岛渲染歌词卡片。无需 root / Shizuku —— 焦点通知通过普通
 * NotificationManager.notify() 即可发送，HyperOS 识别 mFocusNotification +
 * miui.focus.param 后在灵动岛展示。
 *
 * `outEffectSrc = "outer_glow"` 外发光光圈效果，参考 InstallerX-Revived
 * MiIslandNotificationBuilder（GPL-3.0）与 HyperIsland（GPL-3.0）的
 * injectIslandAppearance。三处注入：param_v2 顶层（悬浮特效）、param_island
 * 内（大岛光效）、通知 extras 的 miui.effect.src / miui.bigIsland.effect.src
 * （见 IslandLyricNotification.notifyFocus）。该字段为未公开参数，能否渲染
 * 取决于具体 HyperOS 版本。
 */
class FocusNotificationBuilder(
    private val uiState: IslandUiState,
    private val showProgress: Boolean
) {

    /** 构建焦点通知 JSON 字符串 (param_v2)。 */
    fun build(): String {
        val root = JSONObject()
        val paramV2 = JSONObject()

        // 基础配置
        paramV2.put("islandFirstFloat", false)
        paramV2.put("updatable", true)
        paramV2.put("reopen", "reopen")
        paramV2.put("isShowNotification", uiState.focusShowNotification)
        // 外发光光圈效果（参考 InstallerX-Revived MiIslandNotificationBuilder 与
        // HyperIsland injectIslandAppearance）：param_v2 顶层 outEffectSrc 控制
        // 悬浮特效。大岛光效在 param_island 内另有 outEffectSrc，通知 extras
        // 另有 miui.effect.src / miui.bigIsland.effect.src（见 notifyFocus）。
        paramV2.put("outEffectSrc", "outer_glow")

        // 1. 灵动岛区域 (param_island)
        paramV2.put("param_island", buildParamIsland())

        // 2. 基础展示区域 (baseInfo)
        paramV2.put("baseInfo", buildBaseInfo())

        // 3. 播放进度 (multiProgressInfo, OS3 标准模式)
        if (showProgress) {
            paramV2.put("multiProgressInfo", buildOS3MultiProgressInfo())
        }

        // 4. AOD / 状态栏
        // 息屏歌词开关为反向语义：
        // 开（aodLyrics=true）→ aodTitle = 歌名（息屏显示歌曲名）；
        // 关（aodLyrics=false，默认）→ aodTitle = 完整歌词帧（息屏显示歌词）。
        paramV2.put(
            "aodTitle",
            if (uiState.aodLyrics) uiState.notificationTitleLeft else uiState.fullLyric
        )
        paramV2.put("aodPic", "miui.focus.pic_album")

        root.put("param_v2", paramV2)
        return root.toString()
    }

    private fun buildParamIsland(): JSONObject {
        val json = JSONObject()
        if (uiState.highlightColorEnabled) {
            json.put("highlightColor", getColorHex(uiState.color))
        }
        // 大岛外发光光圈：param_island 内也注入 outEffectSrc（参考 HyperIsland
        // injectIslandAppearance，与 param_v2 顶层的悬浮特效叠加）。
        json.put("outEffectSrc", "outer_glow")
        json.put("bigIslandArea", buildBigIslandArea())
        json.put("smallIslandArea", buildSmallIslandArea())
        return json
    }

    private fun buildBigIslandArea(): JSONObject {
        val json = JSONObject()

        // 大岛左侧内容：封面图（picInfo）+ 歌词前半段（textInfo）组合
        val imageTextLeft = JSONObject()
        imageTextLeft.put("type", 1)

        if (uiState.hasCover) {
            // 封面 + 文本
            imageTextLeft.put("picInfo", buildPicInfo(1, "miui.focus.pic_album"))
            val textInfoLeft = JSONObject()
            textInfoLeft.put("title", uiState.islandTitleLeft)
            textInfoLeft.put("showHighlightColor", uiState.highlightColorEnabled)
            imageTextLeft.put("textInfo", textInfoLeft)
        } else {
            // 纯文本模式（无封面）：左侧只放歌词前半段
            val textInfoLeft = JSONObject()
            textInfoLeft.put("title", uiState.islandTitleLeft)
            textInfoLeft.put("showHighlightColor", uiState.highlightColorEnabled)
            imageTextLeft.put("textInfo", textInfoLeft)
        }
        json.put("imageTextInfoLeft", imageTextLeft)

        // 大岛主文本区（右侧）：当前歌词后半段
        val islandTitleText = JSONObject()
        islandTitleText.put("title", uiState.title)
        islandTitleText.put("showHighlightColor", uiState.highlightColorEnabled)
        json.put("textInfo", islandTitleText)

        return json
    }

    private fun buildSmallIslandArea(): JSONObject {
        val json = JSONObject()
        // 小岛胶囊：无封面图（首版精简），仅进度环
        val combinePicInfo = JSONObject()
        if (showProgress) {
            val progressInfo = JSONObject()
            progressInfo.put("progress", uiState.progress)
            progressInfo.put("colorReach", getColorHex(uiState.colorEnd))
            progressInfo.put("isCCW", true)
            combinePicInfo.put("progressInfo", progressInfo)
        }
        json.put("combinePicInfo", combinePicInfo)
        return json
    }

    /** 图片引用：type + pic key（指向 miui.focus.pics 里的资源）。 */
    private fun buildPicInfo(type: Int, picKey: String): JSONObject {
        val json = JSONObject()
        json.put("type", type)
        json.put("pic", picKey)
        return json
    }

    private fun buildBaseInfo(): JSONObject {
        val json = JSONObject()
        json.put("type", 2)
        json.put("title", uiState.notificationTitleLeft)
        // OS3 使用 notificationTitleRight 作为 content（当前歌词行）
        json.put("content", uiState.notificationTitleRight)

        if (uiState.songInfoHighlightColorEnabled) {
            val hex = getColorHex(uiState.color)
            json.put("colorTitle", hex)
            json.put("colorTitleDark", hex)
            json.put("colorContent", hex)
            json.put("colorContentDark", hex)
        }
        return json
    }

    private fun buildOS3MultiProgressInfo(): JSONObject {
        val json = JSONObject()
        json.put("title", uiState.songInfo)
        json.put("progress", uiState.progress)
        if (uiState.progressColorEnabled) {
            json.put("color", getColorHex(uiState.color))
        }

        if (uiState.songInfoHighlightColorEnabled) {
            val hex = getColorHex(uiState.color)
            json.put("colorTitle", hex)
            json.put("colorTitleDark", hex)
            json.put("colorContent", hex)
            json.put("colorContentDark", hex)
        }
        return json
    }

    private fun getColorHex(color: Int): String {
        return if (color != 0) {
            // 返回 8 位颜色格式 (#FFRRGGBB)
            String.format("#FF%06X", 0xFFFFFF and color)
        } else {
            "#3482FF"
        }
    }
}
