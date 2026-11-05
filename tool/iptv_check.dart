/// IPTV 源命令行自检：把内置源挨个拉一遍，打印频道数、分组、可播率抽样。
///
/// ```bash
/// dart run tool/iptv_check.dart          # 全部源
/// dart run tool/iptv_check.dart vbskycn  # 只测一个
/// ```
import 'dart:io';

import 'package:hotshow/models/iptv_channel.dart';
import 'package:hotshow/services/iptv_service.dart';

Future<void> main(List<String> args) async {
  final only = args.isEmpty ? null : args.first;
  final service = IptvService.withClient(HttpClient()
    ..connectionTimeout = const Duration(seconds: 12)
    ..autoUncompress = true);

  for (final src in kIptvSources) {
    if (only != null && src.id != only) continue;
    final sw = Stopwatch()..start();
    try {
      final p = await service.load(src.id, force: true);
      sw.stop();
      final hd = p.channels.where((c) => c.isHd).length;
      final fourK = p.channels.where((c) => c.is4K).length;
      final dead = p.channels.where((c) => !c.playable).length;
      final needUa = p.channels.where((c) => c.playHeaders != null).length;
      final sports = p.channels.where((c) => c.isSports).length;
      final top = p.groups.take(4).join(' / ');
      stdout.writeln('${src.id.padRight(18)} '
          '${p.length.toString().padLeft(4)} 频道  '
          'HD $hd  4K $fourK  体育 $sports  需UA $needUa  组播 $dead  '
          '${sw.elapsedMilliseconds}ms  [$top]');
    } catch (e) {
      sw.stop();
      stdout.writeln('${src.id.padRight(18)} FAIL ${sw.elapsedMilliseconds}ms  $e');
    }
  }
  service.close();
}
