// m3u8 解析与离线缓存单元测试：本地假 HLS 服务，不访问外网。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotshow/services/m3u8.dart';
import 'package:hotshow/services/offline_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _mediaPlaylist = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:4
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:4.000,
seg0.ts
#EXTINF:4.000,
seg1.ts
#EXTINF:4.000,
seg2.ts
#EXT-X-ENDLIST
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // flutter_test 默认把 HttpClient 替换成「一律 400」的桩，这里恢复真实实现，
    // 以便请求本地假 HLS 服务。
    HttpOverrides.global = null;
  });

  group('parseM3u8', () {
    test('解析媒体播放列表', () {
      final p = parseM3u8(
        _mediaPlaylist,
        Uri.parse('https://cdn.example.com/a/b/index.m3u8'),
      );
      expect(p.isMaster, isFalse);
      expect(p.segments.length, 3);
      expect(p.totalDuration, 12.0);
      expect(p.endList, isTrue);
      expect(p.hasByteRange, isFalse);
      // 相对地址按播放列表地址补全
      expect(p.segments[0].uri.toString(), 'https://cdn.example.com/a/b/seg0.ts');
    });

    test('解析 master 播放列表并挑最高码率', () {
      final p = parseM3u8(
        '#EXTM3U\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360\n'
        'low/index.m3u8\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720\n'
        'high/index.m3u8\n',
        Uri.parse('https://cdn.example.com/v/index.m3u8'),
      );
      expect(p.isMaster, isTrue);
      expect(p.variants.length, 2);
      expect(p.bestVariant!.uri.toString(),
          'https://cdn.example.com/v/high/index.m3u8');
    });

    test('记录加密密钥与初始化段', () {
      final p = parseM3u8(
        '#EXTM3U\n'
        '#EXT-X-MAP:URI="init.mp4"\n'
        '#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x1234\n'
        '#EXTINF:4.0,\n'
        'seg0.ts\n'
        '#EXT-X-ENDLIST\n',
        Uri.parse('https://cdn.example.com/v/index.m3u8'),
      );
      expect(p.isEncrypted, isTrue);
      expect(p.initMap.toString(), 'https://cdn.example.com/v/init.mp4');
      expect(p.segments.first.key!.uri.toString(),
          'https://cdn.example.com/v/key.bin');
      expect(p.segments.first.key!.iv, '0x1234');
    });

    test('识别 BYTERANGE 与未结束的直播流', () {
      final p = parseM3u8(
        '#EXTM3U\n#EXT-X-BYTERANGE:1000@0\n#EXTINF:4.0,\nseg0.ts\n',
        Uri.parse('https://cdn.example.com/v/index.m3u8'),
      );
      expect(p.hasByteRange, isTrue);
      expect(p.endList, isFalse);
    });
  });

  group('buildLocalPlaylist', () {
    test('指向本地分片并保留时长', () {
      final p = parseM3u8(
        _mediaPlaylist,
        Uri.parse('https://cdn.example.com/v/index.m3u8'),
      );
      final text = buildLocalPlaylist(
        segments: p.segments,
        localNames: const ['seg_00001.ts', 'seg_00002.ts', 'seg_00003.ts'],
        keyFiles: const {},
        localInitMap: null,
        mediaSequence: p.mediaSequence,
        version: p.version,
      );
      expect(text, contains('seg_00001.ts'));
      expect(text, contains('#EXTINF:4.000,'));
      expect(text, contains('#EXT-X-ENDLIST'));
      expect(text, isNot(contains('cdn.example.com')));
    });
  });

  group('OfflineCache', () {
    late HttpServer server;
    late Directory root;

    /// 起一个假 HLS 服务：/index.m3u8 给出分片列表，/segN.ts 给出二进制内容
    Future<void> startServer({String? playlist, bool live = false}) async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final path = req.uri.path;
        if (path.endsWith('.m3u8')) {
          final body = playlist ??
              (live
                  ? _mediaPlaylist.replaceAll('#EXT-X-ENDLIST', '')
                  : _mediaPlaylist);
          req.response
            ..headers.contentType =
                ContentType('application', 'vnd.apple.mpegurl')
            ..write(body);
        } else if (RegExp(r'/seg\d+\.ts$').hasMatch(path)) {
          req.response.add(utf8.encode('ts-content-$path'));
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });
    }

    setUp(() async {
      root = await Directory.systemTemp.createTemp('hotshow_cache_test');
    });

    tearDown(() async {
      await server.close(force: true);
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('完整抓取分片并重写为可离线播放的列表', () async {
      await startServer();
      final cache = OfflineCache()..debugSetRoot(root);
      final key = cacheKeyOf('s1', '100', 0, 0);

      final media = await cache.download(
        key: key,
        title: '测试剧',
        episodeName: '第01集',
        m3u8Url: 'http://127.0.0.1:${server.port}/index.m3u8',
      );

      expect(media.segments, 3);
      expect(cache.byKey(key), isNotNull);
      expect(cache.countFor('s1', '100'), 1);

      final local = File(media.localFile);
      expect(await local.exists(), isTrue);
      final text = await local.readAsString();
      expect(text, contains('seg_00001.ts'));
      expect(text, contains('seg_00003.ts'));
      expect(text, contains('#EXT-X-ENDLIST'));
      // 本地列表里不应再残留网络地址
      expect(text, isNot(contains('http://')));

      final seg2 = File('${local.parent.path}/seg_00002.ts');
      expect(await seg2.exists(), isTrue);
      expect(await seg2.readAsString(), contains('ts-content'));
    });

    test('已缓存时重复调用直接复用，不再请求网络', () async {
      await startServer();
      final cache = OfflineCache()..debugSetRoot(root);
      final key = cacheKeyOf('s2', '200', 0, 0);
      final url = 'http://127.0.0.1:${server.port}/index.m3u8';

      final first = await cache.download(
          key: key,
          title: 't',
          episodeName: 'e',
          m3u8Url: url);
      await server.close(force: true);

      final second = await cache.download(
          key: key,
          title: 't',
          episodeName: 'e',
          m3u8Url: url);
      expect(second.localFile, first.localFile);
    });

    test('直播流（无结束标记）被拒绝且不留下半成品', () async {
      await startServer(live: true);
      final cache = OfflineCache()..debugSetRoot(root);
      final key = cacheKeyOf('s3', '300', 0, 0);

      await expectLater(
        cache.download(
          key: key,
          title: 't',
          episodeName: 'e',
          m3u8Url: 'http://127.0.0.1:${server.port}/live.m3u8',
        ),
        throwsA(isA<OfflineCacheException>()),
      );
      expect(cache.byKey(key), isNull);
      expect(Directory('${root.path}/$key').existsSync(), isFalse);
    });

    test('分片缺失时报错并清理', () async {
      await startServer(playlist: '''
#EXTM3U
#EXT-X-TARGETDURATION:4
#EXTINF:4.0,
missing.ts
#EXT-X-ENDLIST
''');
      final cache = OfflineCache()..debugSetRoot(root);
      final key = cacheKeyOf('s4', '400', 0, 0);

      await expectLater(
        cache.download(
          key: key,
          title: 't',
          episodeName: 'e',
          m3u8Url: 'http://127.0.0.1:${server.port}/index.m3u8',
        ),
        throwsA(isA<OfflineCacheException>()),
      );
      expect(Directory('${root.path}/$key').existsSync(), isFalse);
    });
  });
}
