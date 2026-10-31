// ignore_for_file: avoid_print
// 码率探针验证：dart run tool/bitrate_probe.dart <m3u8 地址>
// 不带参数时用一条已知的公开测试流（Apple 多码率示例的最高档）。
import 'package:hotshow/services/bitrate_probe.dart';
import 'package:hotshow/services/remote_ua.dart';

Future<void> main(List<String> args) async {
  final url = args.isNotEmpty
      ? args.first
      : 'https://devstreaming-cdn.apple.com/videos/streaming/examples/'
          'bipbop_16x9/gear5/prog_index.m3u8';
  final headers = <String, String>{
    'User-Agent': kBrowserUserAgent,
    if (Uri.tryParse(url)?.hasAuthority ?? false)
      'Referer': '${Uri.parse(url).scheme}://${Uri.parse(url).authority}/',
  };
  final sw = Stopwatch()..start();
  final e = await BitrateProbe.instance.probe(url, headers: headers);
  print('probe ${url.substring(0, url.length.clamp(0, 90))}');
  print('  ${sw.elapsedMilliseconds}ms -> '
      '${e == null ? '无法探测' : '${e.label} · ${e.grade}（采样 ${e.bytes ~/ 1024}KB）'}');
}
