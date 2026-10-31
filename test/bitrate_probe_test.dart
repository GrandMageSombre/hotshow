import 'package:flutter_test/flutter_test.dart';
import 'package:hotshow/services/bitrate_probe.dart';

const _media = '''#EXTM3U
#EXT-X-TARGETDURATION:4
#EXTINF:4.0,
seg0.ts
#EXTINF:4.0,
seg1.ts
#EXT-X-ENDLIST
''';

const _master = '''#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=640x360
low/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
high/index.m3u8
''';

void main() {
  group('码率换算', () {
    test('字节数 ÷ 时长 → kbps', () {
      final e = BitrateEstimate.fromSamples(
        bytes: 1300000,
        sampled: const Duration(seconds: 8),
      );
      expect(e, isNotNull);
      expect(e!.kbps, 1300);
      expect(e.label, '1.3 Mbps');
      expect(e.grade, '一般');
    });

    test('样本无效时返回 null', () {
      expect(
        BitrateEstimate.fromSamples(bytes: 0, sampled: const Duration(seconds: 8)),
        isNull,
      );
      expect(
        BitrateEstimate.fromSamples(bytes: 1000, sampled: Duration.zero),
        isNull,
      );
    });

    test('分级按常见编码水平分四档', () {
      BitrateEstimate g(int kbps) => BitrateEstimate(
            kbps: kbps,
            sampled: const Duration(seconds: 4),
            bytes: 1,
          );
      expect(g(4500).grade, '高清');
      expect(g(2500).grade, '较清晰');
      expect(g(1500).grade, '一般');
      expect(g(900).grade, '偏低');
      expect(g(900).label, '900 kbps');
    });


    test('分片被读取上限截断时，码率标成下限', () {
      final e = BitrateEstimate.fromSamples(
        bytes: 1000000,
        sampled: const Duration(seconds: 2),
        lowerBound: true,
      );
      expect(e!.label.startsWith('≥'), isTrue, reason: '真实码率只会更高');
      expect(e.lowerBound, isTrue);
    });
    test('排序：码率高在前，未测的排最后', () {
      final high = BitrateEstimate.fromSamples(
          bytes: 2000000, sampled: const Duration(seconds: 4));
      final low = BitrateEstimate.fromSamples(
          bytes: 500000, sampled: const Duration(seconds: 4));
      final list = [null, low, high];
      list.sort(BitrateProbe.compare);
      expect(list.first!.kbps, 4000);
      expect(list.last, isNull);
    });
  });

  group('探测流程', () {
    setUp(() {
      BitrateProbe.instance.clearCache();
    });

    tearDown(() {
      BitrateProbe.instance.debugPlaylistOverride = null;
      BitrateProbe.instance.debugSegmentOverride = null;
    });

    test('分片列表：按采样的字节数算码率，并缓存结果', () async {
      var segCalls = 0;
      BitrateProbe.instance.debugPlaylistOverride =
          (url, headers) async => _media;
      BitrateProbe.instance.debugSegmentOverride = (url, headers) async {
        segCalls++;
        return 1000000; // 每段 1MB / 4 秒 → 2000 kbps
      };

      final e = await BitrateProbe.instance.probe('https://a.com/x.m3u8');
      expect(e, isNotNull);
      expect(e!.kbps, 2000);
      expect(segCalls, 2);

      // 第二次走缓存，不再抓分片
      final again = await BitrateProbe.instance.probe('https://a.com/x.m3u8');
      expect(again!.kbps, 2000);
      expect(segCalls, 2);
    });

    test('master playlist 跟随最高码率变体', () async {
      final asked = <String>[];
      BitrateProbe.instance.debugPlaylistOverride = (url, headers) async {
        asked.add(url);
        return url.contains('high') ? _media : _master;
      };
      BitrateProbe.instance.debugSegmentOverride =
          (url, headers) async => 1000000;

      final e = await BitrateProbe.instance.probe('https://a.com/master.m3u8');
      expect(e!.kbps, 2000);
      expect(asked.last, 'https://a.com/high/index.m3u8');
    });

    test('不是播放列表 / 抓取失败时返回 null，不抛异常', () async {
      BitrateProbe.instance.debugPlaylistOverride =
          (url, headers) async => '{"code":1}';
      expect(await BitrateProbe.instance.probe('https://a.com/api.php'), isNull);

      BitrateProbe.instance.debugPlaylistOverride = (url, headers) async => null;
      expect(await BitrateProbe.instance.probe('https://a.com/x.m3u8'), isNull);
    });

    test('分片一个都拿不到时返回 null', () async {
      BitrateProbe.instance.debugPlaylistOverride =
          (url, headers) async => _media;
      BitrateProbe.instance.debugSegmentOverride = (url, headers) async => null;
      expect(await BitrateProbe.instance.probe('https://a.com/x.m3u8'), isNull);
    });

    test('并发请求同一地址只抓一次分片', () async {
      var segCalls = 0;
      BitrateProbe.instance.debugPlaylistOverride =
          (url, headers) async => _media;
      BitrateProbe.instance.debugSegmentOverride = (url, headers) async {
        segCalls++;
        return 800000;
      };
      final results = await Future.wait([
        BitrateProbe.instance.probe('https://a.com/y.m3u8'),
        BitrateProbe.instance.probe('https://a.com/y.m3u8'),
      ]);
      expect(results.every((e) => e != null), isTrue);
      expect(segCalls, 2);
    });
  });
}
