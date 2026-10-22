import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../app/services/player_service.dart';
import '../../../app/state/song_state.dart';
import '../../../app/utils/song_audio_spec.dart';

class PlayerAudioSpec extends StatelessWidget {
  final ValueListenable<SongEntity?> songListenable;
  final ValueListenable<String?>? playbackCodecListenable;

  /// 外层留白。默认值按整行铺开的样式设计；夹在其他控件中间时传更小的
  /// 横向留白（例如 [EdgeInsets.zero]），让文字在可用空间里居中。
  final EdgeInsetsGeometry padding;

  const PlayerAudioSpec({
    super.key,
    required this.songListenable,
    this.playbackCodecListenable,
    this.padding = const EdgeInsets.fromLTRB(20, 4, 20, 0),
  });

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    final codecListenable = playbackCodecListenable ??
        PlayerService.instance.playbackTranscodeCodec;
    return AnimatedBuilder(
      animation: Listenable.merge([songListenable, codecListenable]),
      builder: (context, _) {
        final text = formatPlayerAudioSpec(
          songListenable.value,
          playbackCodec: codecListenable.value,
        );
        if (text.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: padding,
          child: Tooltip(
            message: '实际播放音频信息',
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: color),
              semanticsLabel: '音频信息：${text.replaceAll('\n', '，')}',
            ),
          ),
        );
      },
    );
  }
}
