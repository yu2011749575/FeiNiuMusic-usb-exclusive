import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/feiniu/api_models.dart';

void main() {
  group('FeiNiuTrack.accessStatus → 失效标记', () {
    test('accessStatus=3（音频文件失效/缺失）标记为失效', () {
      final track = FeiNiuTrack.fromJson({
        'guid': 'de6bbfd9cdfe4eb2ba20bcc9c9a19837',
        'title': '天下 (Live)',
        'accessStatus': 3,
      });
      expect(track.isAudioFileDeleted, isTrue);
    });

    test('accessStatus=0（正常可播放）不标记失效', () {
      final track = FeiNiuTrack.fromJson({
        'guid': '7d30a55feb874b849d46b6a475de213f',
        'title': '一点一滴 (Live)',
        'accessStatus': 0,
      });
      expect(track.isAudioFileDeleted, isFalse);
    });

    test('accessStatus 为字符串 "3" 同样识别为失效', () {
      final track = FeiNiuTrack.fromJson({
        'guid': 'x',
        'title': 'y',
        'accessStatus': '3',
      });
      expect(track.isAudioFileDeleted, isTrue);
    });

    test('旧删除标记字段仍生效（兼容个别接口）', () {
      final track = FeiNiuTrack.fromJson({
        'guid': 'x',
        'title': 'y',
        'isAudioFileDeleted': 1,
      });
      expect(track.isAudioFileDeleted, isTrue);
    });
  });
}
