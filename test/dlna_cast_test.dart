import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/cast/media_stream_proxy.dart';
import 'package:feiniu_music/app/services/feiniu/api_client.dart';
import 'package:feiniu_music/app/services/feiniu/transcode_service.dart';
import 'package:feiniu_music/app/state/settings_cast_state.dart';
import 'package:feiniu_music/app/state/settings_transcode_state.dart';
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

SongEntity _song(String id, {String? format, String? title, int? durationMs}) {
  return SongEntity(
    id: id,
    title: title ?? 't',
    artist: '[{"name":"a"}]',
    album: '{"name":"al"}',
    format: format,
    durationMs: durationMs,
  );
}

void main() {
  setUp(() {
    FeiNiuTranscodeService.instance.resetForTest();
    FeiNiuApiClient.instance.setDioForTest(
      _mockDio((o) => {
        'code': 0,
        'data': {
          'audioSpec': {'format': 'dsf'},
          'track': {
            'audioSpec': {'format': 'dsf'},
          },
          'url': '/music/api/v1/track/hls/id-1/preset.m3u8',
        },
      }),
    );
    DlnaCastSettings.resetForTest();
    AppTranscodeSettings.resetForTest();
    MediaStreamProxy.forceLoopbackBase = true;
  });

  tearDown(() async {
    MediaStreamProxy.forceLoopbackBase = false;
    await MediaStreamProxy.instance.stop();
  });

  group('MediaStreamProxy HLS 改写', () {
    test('普通分片行改写成经代理的绝对地址', () async {
      final base = await MediaStreamProxy.instance.start();
      expect(base, isNotNull);
      final proxyUrl = await MediaStreamProxy.instance.registerMedia(
        'http://nas/music/api/v1/track/hls/a.m3u8',
        headers: {'Cookie': 'music-token=xyz'},
      );
      expect(proxyUrl, isNotNull);

      // 直接测内部改写（用 Dart 的反射不可行，改为通过真实 HTTP 拉取：
      // 起一个本地上游服务返回 m3u8，走完整代理链路验证改写结果）。
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final upstreamPort = upstream.port;
      upstream.listen((request) {
        request.response.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl');
        request.response.write('''
#EXTM3U
#EXT-X-MAP:URI="init.mp4"
#EXTINF:4.0,
seg0.m4s
#EXTINF:4.0,
seg1.m4s
''');
        request.response.close();
      });

      try {
        final registered = await MediaStreamProxy.instance.registerMedia(
          'http://127.0.0.1:$upstreamPort/playlist.m3u8',
          headers: {'Cookie': 'music-token=xyz'},
        );
        expect(registered, isNotNull);

        final client = HttpClient();
        try {
          final req = await client.getUrl(Uri.parse(registered!));
          final resp = await req.close();
          final body = await resp.transform(utf8.decoder).join();
          expect(resp.statusCode, 200);
          // 分片与 init 段都必须改写成经代理的绝对地址
          expect(body, contains('/m/${MediaStreamProxy.instance.token}'));
          expect(body, contains('seg0.m4s'));
          expect(body, contains('seg1.m4s'));
          expect(body, contains('init.mp4'));
          // 相对分片不得原样保留
          expect(body.split('\n').any((l) => l.trim() == 'seg0.m4s'), isFalse);
        } finally {
          client.close(force: true);
        }
      } finally {
        await upstream.close(force: true);
      }
    });

    test('非 m3u8 媒体流透传内容', () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final upstreamPort = upstream.port;
      upstream.listen((request) {
        request.response.headers.contentType =
            ContentType('audio', 'mpeg');
        request.response.add(utf8.encode('fake-mp3-bytes'));
        request.response.close();
      });

      try {
        final registered = await MediaStreamProxy.instance.registerMedia(
          'http://127.0.0.1:$upstreamPort/track.mp3',
          headers: {'Cookie': 'music-token=xyz'},
          fileExtension: 'mp3',
        );
        expect(registered, endsWith('/media.mp3'));
        final client = HttpClient();
        try {
          final req = await client.getUrl(Uri.parse(registered!));
          final resp = await req.close();
          final bytes = await resp.fold<List<int>>(
            <int>[],
            (acc, chunk) => acc..addAll(chunk),
          );
          expect(resp.statusCode, 200);
          expect(utf8.decode(bytes), 'fake-mp3-bytes');
        } finally {
          client.close(force: true);
        }
      } finally {
        await upstream.close(force: true);
      }
    });

    test('媒体代理 URL 保留音频格式后缀', () async {
      final registered = await MediaStreamProxy.instance.registerMedia(
        'http://nas/music/api/v1/track/stream?guid=flac-id',
        fileExtension: 'flac',
      );

      expect(registered, endsWith('/media.flac'));
    });

    test('封面资源经 /r/<token> 匿名代理', () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final upstreamPort = upstream.port;
      upstream.listen((request) {
        request.response.headers.contentType = ContentType('image', 'jpeg');
        request.response.add(utf8.encode('fake-cover-bytes'));
        request.response.close();
      });

      try {
        final resUrl = await MediaStreamProxy.instance.registerResource(
          'http://127.0.0.1:$upstreamPort/cover.jpg',
          headers: {'Cookie': 'music-token=xyz'},
        );
        expect(resUrl, isNotNull);
        expect(resUrl, contains('/r/'));

        final client = HttpClient();
        try {
          final req = await client.getUrl(Uri.parse(resUrl!));
          final resp = await req.close();
          final bytes = await resp.fold<List<int>>(
            <int>[],
            (acc, chunk) => acc..addAll(chunk),
          );
          expect(resp.statusCode, 200);
          expect(utf8.decode(bytes), 'fake-cover-bytes');
        } finally {
          client.close(force: true);
        }
      } finally {
        await upstream.close(force: true);
      }
    });
  });

  group('DlnaCastService URL 解析', () {
    test('无损格式走转码 MP3 分支', () async {
      final song = _song('id-1', format: 'dsf', durationMs: 200000);
      // 用 transcodeMp3UrlFor 验证转码 URL 解析（dsf → 应转码）
      final hls = await FeiNiuTranscodeService.instance.transcodeMp3UrlFor(
        song,
      );
      expect(hls, isNotNull);
      expect(hls, contains('preset.m3u8'));
    });

    test('MP3 格式走直连流', () async {
      final song = _song('id-2', format: 'mp3');
      // 直连流 URL 构造
      final stream = FeiNiuApiClient.instance.streamUrl(song.id);
      expect(stream, contains('/track/stream?guid=id-2'));
    });
  });
}
