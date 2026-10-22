import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/feiniu/api_client.dart';
import 'package:feiniu_music/app/services/feiniu/api_models.dart';
import 'package:feiniu_music/app/services/feiniu/cue_service.dart';
import 'package:feiniu_music/app/state/song_state.dart';

/// 构造一个用拦截器短路返回指定响应体的 Dio（不真正发网络请求）。
Dio _mockDio(
  dynamic Function(RequestOptions options) respond, {
  DioException Function(RequestOptions options)? error,
}) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        final e = error?.call(options);
        if (e != null) {
          handler.reject(e, true);
          return;
        }
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: respond(options),
          ),
        );
      },
    ),
  );
  return dio;
}

FeiNiuAlbum _album(String guid) => FeiNiuAlbum(guid: guid, name: 'Album $guid');

FeiNiuTrack _track(
  String guid, {
  String title = 't',
  int? trackNo,
  int? discNo,
  int? duration,
  bool isCue = true,
  String albumGuid = 'alb-1',
  String? path = '/vol3/CDImage.flac',
}) {
  return FeiNiuTrack(
    guid: guid,
    title: title,
    discNo: discNo,
    trackNo: trackNo,
    duration: duration,
    isCue: isCue,
    createdAt: 0,
    updatedAt: 0,
    album: _album(albumGuid),
    artists: const [],
    audioSpec: path != null ? FeiNiuAudioSpec(path: path) : null,
  );
}

SongEntity _song(String id, {required bool isCue, String albumGuid = 'alb-1'}) {
  return SongEntity(
    id: id,
    title: 't',
    artist: '[{"guid":"a1","name":"a"}]',
    album: jsonEncode({'guid': albumGuid, 'name': 'Album $albumGuid'}),
    isCue: isCue,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FeiNiuCueService.instance.resetForTest();
    FeiNiuApiClient.instance.setBaseUrl('https://nas.example.com');
  });

  group('computeOffsets', () {
    test('同镜像按 trackNo 顺序累计前序 duration（Kreisler 样本结构）', () {
      final tracks = [
        _track('g1', title: 'Liebesleid', trackNo: 2, duration: 201413),
        _track('g2', title: 'Tambourin', trackNo: 3, duration: 204013),
        _track('g3', title: 'Caprice', trackNo: 4, duration: 192840),
        _track('g4', title: 'Chanson', trackNo: 5, duration: 213520),
      ];
      final offsets = FeiNiuCueService.computeOffsets(tracks);
      expect(offsets['g1'], 0);
      expect(offsets['g2'], 201413);
      expect(offsets['g3'], 201413 + 204013);
      expect(offsets['g4'], 201413 + 204013 + 192840);
    });

    test('同组内乱序输入仍按 trackNo 排序累计', () {
      final tracks = [
        _track('g3', trackNo: 3, duration: 1000),
        _track('g1', trackNo: 1, duration: 500),
        _track('g2', trackNo: 2, duration: 750),
      ];
      final offsets = FeiNiuCueService.computeOffsets(tracks);
      expect(offsets['g1'], 0);
      expect(offsets['g2'], 500);
      expect(offsets['g3'], 1250);
    });

    test('trackNo 缺失回退到数组原始顺序', () {
      final tracks = [
        _track('g1', trackNo: null, duration: 300),
        _track('g2', trackNo: null, duration: 400),
        _track('g3', trackNo: null, duration: 500),
      ];
      final offsets = FeiNiuCueService.computeOffsets(tracks);
      expect(offsets['g1'], 0);
      expect(offsets['g2'], 300);
      expect(offsets['g3'], 700);
    });

    test('多碟专辑：不同 audioSpec.path 各自从头累计', () {
      final tracks = [
        _track(
          'd1a',
          discNo: 1,
          trackNo: 1,
          duration: 1000,
          path: '/vol3/Disc1/CDImage.flac',
        ),
        _track(
          'd1b',
          discNo: 1,
          trackNo: 2,
          duration: 1000,
          path: '/vol3/Disc1/CDImage.flac',
        ),
        _track(
          'd2a',
          discNo: 2,
          trackNo: 1,
          duration: 1000,
          path: '/vol3/Disc2/CDImage.flac',
        ),
        _track(
          'd2b',
          discNo: 2,
          trackNo: 2,
          duration: 1000,
          path: '/vol3/Disc2/CDImage.flac',
        ),
      ];
      final offsets = FeiNiuCueService.computeOffsets(tracks);
      expect(offsets['d1a'], 0);
      expect(offsets['d1b'], 1000);
      // 第 2 碟是另一物理文件 → 从头累计
      expect(offsets['d2a'], 0);
      expect(offsets['d2b'], 1000);
    });

    test('同 path 内 discNo 缺失与 1 混合仍连续累计（Kreisler 样本）', () {
      final tracks = [
        _track('g1', discNo: 1, trackNo: 1, duration: 1000),
        _track('g2', discNo: null, trackNo: 2, duration: 1000),
        _track('g3', discNo: 1, trackNo: 3, duration: 1000),
      ];
      final offsets = FeiNiuCueService.computeOffsets(tracks);
      expect(offsets['g1'], 0);
      expect(offsets['g2'], 1000);
      expect(offsets['g3'], 2000);
    });

    test('不同 audioSpec.path 分组独立累计', () {
      final tracks = [
        _track('p1', trackNo: 1, duration: 1000, path: '/a/CDImage.flac'),
        _track('p2', trackNo: 2, duration: 1000, path: '/a/CDImage.flac'),
        _track('q1', trackNo: 1, duration: 500, path: '/b/CDImage.flac'),
      ];
      final offsets = FeiNiuCueService.computeOffsets(tracks);
      expect(offsets['p1'], 0);
      expect(offsets['p2'], 1000);
      expect(offsets['q1'], 0);
    });

    test('非 CUE 曲目不参与累计', () {
      final tracks = [
        _track('c1', trackNo: 1, duration: 1000),
        _track('c2', trackNo: 2, duration: 1000),
        _track('normal', trackNo: 3, duration: 9999, isCue: false),
      ];
      final offsets = FeiNiuCueService.computeOffsets(tracks);
      expect(offsets['c1'], 0);
      expect(offsets['c2'], 1000);
      expect(offsets.containsKey('normal'), isFalse);
    });

    test('无 audioSpec.path 的 CUE 曲目跳过（不参与、不崩溃）', () {
      final tracks = [
        _track('c1', trackNo: 1, duration: 1000),
        _track('noPath', trackNo: 2, duration: 1000, path: null),
      ];
      final offsets = FeiNiuCueService.computeOffsets(tracks);
      expect(offsets['c1'], 0);
      expect(offsets.containsKey('noPath'), isFalse);
    });

    test('重复 trackNo 不崩溃，偏移仍正确累计', () {
      final tracks = [
        _track('g1', trackNo: 1, duration: 1000),
        _track('g2', trackNo: 1, duration: 1000),
        _track('g3', trackNo: 2, duration: 1000),
      ];
      final offsets = FeiNiuCueService.computeOffsets(tracks);
      expect(offsets['g1'], 0);
      expect(offsets['g2'], 1000);
      expect(offsets['g3'], 2000);
    });

    test('空列表 / 全非 CUE → 空 Map', () {
      expect(FeiNiuCueService.computeOffsets(const []), isEmpty);
      expect(
        FeiNiuCueService.computeOffsets([_track('normal', isCue: false)]),
        isEmpty,
      );
    });
  });

  group('offsetMsFor', () {
    test('非 CUE 曲直接返回 null，不发网络请求', () async {
      var apiCalls = 0;
      FeiNiuApiClient.instance.setDioForTest(
        _mockDio((o) {
          apiCalls++;
          return {};
        }),
      );
      final result = await FeiNiuCueService.instance.offsetMsFor(
        _song('s1', isCue: false),
      );
      expect(result, isNull);
      expect(apiCalls, 0);
    });

    test('已 stamp 偏移直接返回，不发网络请求', () async {
      var apiCalls = 0;
      FeiNiuApiClient.instance.setDioForTest(
        _mockDio((o) {
          apiCalls++;
          return {};
        }),
      );
      final song = _song('s1', isCue: true).copyWith(cueOffsetMs: 123456);
      final result = await FeiNiuCueService.instance.offsetMsFor(song);
      expect(result, 123456);
      expect(apiCalls, 0);
    });

    test('未 stamp → 拉专辑曲目计算偏移并返回', () async {
      FeiNiuApiClient.instance.setDioForTest(
        _mockDio(
          (o) => {
            'code': 0,
            'data': {
              'list': [
                {
                  'guid': 'g1',
                  'title': 'a',
                  'isCue': true,
                  'trackNo': 1,
                  'duration': 201413,
                  'album': {'guid': 'alb-1', 'name': 'A'},
                  'artists': [],
                  'createdAt': 0,
                  'updatedAt': 0,
                  'audioSpec': {'path': '/vol3/CDImage.flac'},
                },
                {
                  'guid': 'g2',
                  'title': 'b',
                  'isCue': true,
                  'trackNo': 2,
                  'duration': 141440,
                  'album': {'guid': 'alb-1', 'name': 'A'},
                  'artists': [],
                  'createdAt': 0,
                  'updatedAt': 0,
                  'audioSpec': {'path': '/vol3/CDImage.flac'},
                },
              ],
              'total': 2,
            },
          },
        ),
      );
      final result = await FeiNiuCueService.instance.offsetMsFor(
        _song('g2', isCue: true),
      );
      expect(result, 201413);
    });

    test('同一专辑并发请求去重（仅一次网络往返）', () async {
      var apiCalls = 0;
      FeiNiuApiClient.instance.setDioForTest(
        _mockDio((o) {
          apiCalls++;
          return {
            'code': 0,
            'data': {
              'list': [
                {
                  'guid': 'g1',
                  'title': 'a',
                  'isCue': true,
                  'trackNo': 1,
                  'duration': 1000,
                  'album': {'guid': 'alb-1', 'name': 'A'},
                  'artists': [],
                  'createdAt': 0,
                  'updatedAt': 0,
                  'audioSpec': {'path': '/v/CDImage.flac'},
                },
                {
                  'guid': 'g2',
                  'title': 'b',
                  'isCue': true,
                  'trackNo': 2,
                  'duration': 1000,
                  'album': {'guid': 'alb-1', 'name': 'A'},
                  'artists': [],
                  'createdAt': 0,
                  'updatedAt': 0,
                  'audioSpec': {'path': '/v/CDImage.flac'},
                },
              ],
              'total': 2,
            },
          };
        }),
      );
      final results = await Future.wait([
        FeiNiuCueService.instance.offsetMsFor(_song('g2', isCue: true)),
        FeiNiuCueService.instance.offsetMsFor(_song('g1', isCue: true)),
      ]);
      expect(results, [1000, 0]);
      expect(apiCalls, 1, reason: '并发调用应复用同一个在途请求');
    });

    test('网络失败返回 null（不阻塞播放）', () async {
      FeiNiuApiClient.instance.setDioForTest(
        _mockDio(
          (o) => {},
          error: (o) => DioException(
            requestOptions: o,
            type: DioExceptionType.connectionError,
          ),
        ),
      );
      final result = await FeiNiuCueService.instance.offsetMsFor(
        _song('g2', isCue: true),
      );
      expect(result, isNull);
    });

    test('缓存命中：第二次同一专辑不再请求', () async {
      var apiCalls = 0;
      FeiNiuApiClient.instance.setDioForTest(
        _mockDio((o) {
          apiCalls++;
          return {
            'code': 0,
            'data': {
              'list': [
                {
                  'guid': 'g1',
                  'title': 'a',
                  'isCue': true,
                  'trackNo': 1,
                  'duration': 1000,
                  'album': {'guid': 'alb-1', 'name': 'A'},
                  'artists': [],
                  'createdAt': 0,
                  'updatedAt': 0,
                  'audioSpec': {'path': '/v/CDImage.flac'},
                },
                {
                  'guid': 'g2',
                  'title': 'b',
                  'isCue': true,
                  'trackNo': 2,
                  'duration': 1000,
                  'album': {'guid': 'alb-1', 'name': 'A'},
                  'artists': [],
                  'createdAt': 0,
                  'updatedAt': 0,
                  'audioSpec': {'path': '/v/CDImage.flac'},
                },
              ],
              'total': 2,
            },
          };
        }),
      );
      await FeiNiuCueService.instance.offsetMsFor(_song('g1', isCue: true));
      await FeiNiuCueService.instance.offsetMsFor(_song('g2', isCue: true));
      expect(apiCalls, 1, reason: '第二次应命中 TTL 缓存');
    });
  });

  group('withCueOffsets', () {
    test('命中镜像的 CUE 曲目被 stamp isCue + cueOffsetMs', () {
      final tracks = [
        _track('g1', trackNo: 1, duration: 1000),
        _track('g2', trackNo: 2, duration: 1000),
      ];
      final songs = [
        _song('g1', isCue: false),
        _song('g2', isCue: false),
        _song('other', isCue: false),
      ];
      final stamped = FeiNiuCueService.instance.withCueOffsets(songs, tracks);
      expect(stamped[0].isCue, isTrue);
      expect(stamped[0].cueOffsetMs, 0);
      expect(stamped[1].isCue, isTrue);
      expect(stamped[1].cueOffsetMs, 1000);
      // 不在镜像里的曲目原样保留
      expect(stamped[2].isCue, isFalse);
      expect(stamped[2].cueOffsetMs, isNull);
    });

    test('tracks 为 null/空时原样返回', () {
      final songs = [_song('g1', isCue: true)];
      expect(
        identical(FeiNiuCueService.instance.withCueOffsets(songs, null), songs),
        isTrue,
      );
      expect(
        identical(
          FeiNiuCueService.instance.withCueOffsets(songs, const []),
          songs,
        ),
        isTrue,
      );
    });
  });
}
