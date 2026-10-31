import 'package:flutter_test/flutter_test.dart';
import 'package:hotshow/services/quality_service.dart';

const _master = '''#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=640x360
360/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720
720/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
1080/index.m3u8
''';

void main() {
  var hits = 0;
  var body = _master;

  setUp(() {
    qualityService.clearCache();
    hits = 0;
    body = _master;
    // 用注入的抓取函数代替真实网络：只验证缓存/合并/校验逻辑
    qualityService.debugFetchOverride = (url, headers) async {
      hits++;
      return body;
    };
  });

  tearDown(() {
    qualityService.debugFetchOverride = null;
    qualityService.clearCache();
  });

  const url = 'https://cdn.example.com/hls/master.m3u8';

  test('同一地址第二次探测直接命中缓存，不再抓取', () async {
    final first = await qualityService.probe(url);
    expect(first.map((o) => o.label).toList(), ['自动', '1080P', '720P', '360P']);
    expect(hits, 1);
    expect(qualityService.isCached(url), isTrue);

    final second = await qualityService.probe(url);
    expect(second.length, first.length);
    expect(hits, 1, reason: '第二次必须走缓存');
    expect(qualityService.cacheHits, greaterThan(0));
  });

  test('并发探测同一地址只抓一次（快速换集不会堆请求）', () async {
    final results = await Future.wait([
      qualityService.probe(url),
      qualityService.probe(url),
      qualityService.probe(url),
    ]);
    expect(hits, 1);
    expect(results.every((r) => r.length == 4), isTrue);
  });

  test('useCache=false 时强制重新抓', () async {
    await qualityService.probe(url);
    await qualityService.probe(url, useCache: false);
    expect(hits, 2);
  });

  test('URL 带 Referer 时与不带的分开缓存（不同站点鉴权）', () async {
    await qualityService.probe(url);
    await qualityService.probe(url, headers: {'Referer': 'https://a.com/'});
    expect(hits, 2);
    expect(qualityService.isCached(url, headers: {'Referer': 'https://a.com/'}),
        isTrue);
    expect(qualityService.isCached(url), isTrue);
  });

  test('mp4 这类明确不是播放列表的地址不发请求', () async {
    final options =
        await qualityService.probe('https://cdn.example.com/movie.mp4');
    expect(options, isEmpty);
    expect(hits, 0);
  });

  test('返回内容不是 #EXTM3U 时不算清晰度（避免把 JSON 当播放列表）', () async {
    body = '{"code":1,"list":[]}';
    final options =
        await qualityService.probe('https://cdn.example.com/api.php');
    expect(options, isEmpty);
    // 没被当成可用结果缓存，下次还会再试
    expect(qualityService.isCached('https://cdn.example.com/api.php'), isTrue,
        reason: '空结果也缓存，避免反复打接口');
  });

  test('抓取抛异常时静默降级为空，不影响播放', () async {
    qualityService.debugFetchOverride = (url, headers) async {
      throw const SocketExceptionLike();
    };
    final options = await qualityService.probe(url);
    expect(options, isEmpty);
  });
}

/// 模拟网络异常（不引 dart:io，测试里够用）
class SocketExceptionLike implements Exception {
  const SocketExceptionLike();
}
