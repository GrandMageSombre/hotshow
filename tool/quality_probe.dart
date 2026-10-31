// ignore_for_file: avoid_print
// 清晰度探测探针：用一条公开的 master playlist 验证「抓取 → 解析 → 菜单项」链路。
// 也可以把自己的片源地址传进来：dart run tool/quality_probe.dart <m3u8 地址>
import 'package:hotshow/services/quality_service.dart';

Future<void> main(List<String> args) async {
  final targets = args.isEmpty
      ? const [
          // Apple 官方示例：一个典型的多码率 master playlist
          'https://devstreaming-cdn.apple.com/videos/streaming/examples/'
              'bipbop_16x9/bipbop_16x9_variant.m3u8',
          // 其中一路单码率分片列表：应该探不出可切换项（返回 0 项）
          'https://devstreaming-cdn.apple.com/videos/streaming/examples/'
              'bipbop_16x9/gear5/prog_index.m3u8',
        ]
      : args;

  for (final url in targets) {
    final options = await qualityService.probe(url);
    print('probe ${url.substring(0, url.length.clamp(0, 72))} -> ${options.length} 项');
    for (final o in options) {
      print('   ${o.label.padRight(8)} ${o.detail}  ${o.isAuto ? '(auto)' : o.url}');
    }
  }
}
