import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/player_service.dart';

void main() {
  test('手动强制转码优先于原始完整缓存', () {
    expect(
      shouldTryForcedTranscodeBeforeOriginalCache(
        isForcedTranscode: true,
        forceDirect: false,
        transcodeFailed: false,
      ),
      isTrue,
    );
  });

  test('非手动转码不改变原始完整缓存优先级', () {
    expect(
      shouldTryForcedTranscodeBeforeOriginalCache(
        isForcedTranscode: false,
        forceDirect: false,
        transcodeFailed: false,
      ),
      isFalse,
    );
  });

  test('已选直连或转码已失败时不再抢在原始缓存前重试', () {
    expect(
      shouldTryForcedTranscodeBeforeOriginalCache(
        isForcedTranscode: true,
        forceDirect: true,
        transcodeFailed: false,
      ),
      isFalse,
    );
    expect(
      shouldTryForcedTranscodeBeforeOriginalCache(
        isForcedTranscode: true,
        forceDirect: false,
        transcodeFailed: true,
      ),
      isFalse,
    );
  });
}
