import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/cover_local_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CoverLocalCache.contentUriForPath', () {
    test('exposes generated cover files through a content URI', () async {
      final uri = await CoverLocalCache.contentUriForPath(
        '/cache/covers_v2/0123456789abcdef0123456789abcdef01234567.img',
      );

      expect(uri, isNotNull);
      expect(uri!.scheme, 'content');
      expect(uri.authority, endsWith('.coverart'));
      expect(uri.pathSegments, <String>[
        '0123456789abcdef0123456789abcdef01234567.img',
      ]);
    });

    test('does not expose files outside the generated cover cache', () async {
      final uri = await CoverLocalCache.contentUriForPath(
        '/cache/private/notes.txt',
      );

      expect(uri, isNull);
    });
  });
}
