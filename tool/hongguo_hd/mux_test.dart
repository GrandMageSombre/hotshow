import 'dart:io';
import 'package:hotshow/services/hongguo_mux.dart';

/// 临时验证：node 抓到的 video/audio fMP4 → HongguoMux.mux → 输出 mp4。
/// 用法：dart run tool/hongguo_hd/mux_test.dart <video.m4s> <audio.m4s> <out.mp4>
Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln('用法: dart run tool/hongguo_hd/mux_test.dart <video.m4s> <audio.m4s> <out.mp4>');
    exit(1);
  }
  final v = await File(args[0]).readAsBytes();
  final a = await File(args[1]).readAsBytes();
  final sw = Stopwatch()..start();
  final out = HongguoMux.mux(v, a);
  sw.stop();
  await File(args[2]).writeAsBytes(out);
  stdout.writeln('mux 完成: ${out.length} bytes, 耗时 ${sw.elapsedMilliseconds}ms -> ${args[2]}');
}
