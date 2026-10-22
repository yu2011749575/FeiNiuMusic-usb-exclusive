package com.feiniu.music.island

/**
 * 焦点通知渲染所需的 UI 状态。由 Dart 层通过 MethodChannel 传入。
 */
data class IslandUiState(
    val title: String,                      // 大岛右侧主文本：当前歌词帧右半
    val islandTitleLeft: String,            // 大岛左侧文本：当前歌词帧左半
    val fullLyric: String,                  // 完整当前歌词帧（息屏 aodTitle / 通知标题用）
    val notificationTitleLeft: String,      // 通知标题 / 歌名
    val notificationTitleRight: String,     // 通知内容：当前歌词帧右半
    val songInfo: String,                   // 歌曲信息（歌名 - 歌手）
    val color: Int = 0,                     // 强调色（专辑主色，0=默认蓝）
    val colorEnd: Int = 0,
    val progress: Int = 0,                  // 播放进度 0-100
    val isPlaying: Boolean = true,
    val highlightColorEnabled: Boolean = false,
    val songInfoHighlightColorEnabled: Boolean = false,
    val progressColorEnabled: Boolean = true,
    val showProgress: Boolean = true,
    val hasCover: Boolean = false,
    val aodLyrics: Boolean = false,
    val focusShowNotification: Boolean = true
)
