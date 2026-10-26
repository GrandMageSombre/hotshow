import 'dart:convert';
import 'dart:typed_data';

import 'package:charset/charset.dart';

/// 字幕文本工具：编码识别、格式判断、时间轴偏移。
///
/// 在线字幕常见三种编码：UTF-8（多数）、GBK（国内站点/老字幕组）、
/// 以及少量 UTF-16 BOM。libmpv 默认只按 UTF-8 解析，直接把 GBK 文件丢给它
/// 会显示成乱码，所以下载后统一解码、再以 UTF-8 落盘。

/// 把任意编码的字幕字节解码成字符串。
String decodeSubtitleBytes(List<int> bytes) {
  if (bytes.isEmpty) return '';
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

  // UTF-8 BOM
  if (data.length >= 3 &&
      data[0] == 0xEF &&
      data[1] == 0xBB &&
      data[2] == 0xBF) {
    return utf8.decode(data.sublist(3), allowMalformed: true);
  }
  // UTF-16 BOM
  if (data.length >= 2 && data[0] == 0xFF && data[1] == 0xFE) {
    return _decodeUtf16(data.sublist(2), littleEndian: true);
  }
  if (data.length >= 2 && data[0] == 0xFE && data[1] == 0xFF) {
    return _decodeUtf16(data.sublist(2), littleEndian: false);
  }

  try {
    // 严格解码：能过就是 UTF-8
    return utf8.decode(data);
  } on FormatException {
    // 交给下面的 GBK 兜底
  }

  try {
    final decoded = gbk.decode(data, allowMalformed: true);
    // 纯西文文件用 GBK 解也会「成功」，但会解出满屏汉字乱码，
    // 因此只有确实出现足量汉字时才认为它是 GBK。
    // 阈值取 0.12：正常中文字幕的汉字占比远高于此，而西文文件接近 0。
    if (_cjkRatio(decoded) >= 0.12) return decoded;
  } catch (_) {
    // 继续兜底
  }

  // 最后按 Latin-1 处理（西欧字幕常见），至少不会抛异常
  return latin1.decode(data);
}

String _decodeUtf16(List<int> bytes, {required bool littleEndian}) {
  final units = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    units.add(littleEndian
        ? bytes[i] | (bytes[i + 1] << 8)
        : (bytes[i] << 8) | bytes[i + 1]);
  }
  // 跳过可能的 BOM 残留
  while (units.isNotEmpty && units.first == 0xFEFF) {
    units.removeAt(0);
  }
  try {
    return String.fromCharCodes(units);
  } catch (_) {
    return '';
  }
}

double _cjkRatio(String text) {
  var cjk = 0;
  var total = 0;
  for (final rune in text.runes) {
    if (rune <= 0x20) continue;
    total++;
    final isCjk = (rune >= 0x4E00 && rune <= 0x9FFF) ||
        (rune >= 0x3400 && rune <= 0x4DBF) ||
        (rune >= 0xF900 && rune <= 0xFAFF);
    if (isCjk) cjk++;
  }
  if (total == 0) return 0;
  return cjk / total;
}

/// 判断字幕格式，返回可直接当作文件扩展名的值（srt / ass / vtt）。
String detectSubtitleFormat({required String fileName, required String text}) {
  final lower = fileName.toLowerCase();
  if (lower.endsWith('.ass') || lower.endsWith('.ssa')) return 'ass';
  if (lower.endsWith('.vtt')) return 'vtt';
  if (lower.endsWith('.srt')) return 'srt';

  final head = text.trimLeft();
  if (head.toUpperCase().startsWith('WEBVTT')) return 'vtt';
  if (head.contains('[Script Info]') || head.contains('[V4+ Styles]')) {
    return 'ass';
  }
  return 'srt';
}

/// 时间轴整体偏移 [deltaMs]（正数延后、负数提前），返回新的字幕文本。
///
/// 支持 SRT / WebVTT（`00:00:06,000 --> 00:00:12,074`）与 ASS/SSA
/// （`Dialogue: 0,0:00:06.00,0:00:12.07,...`）。偏移后小于 0 的时间点会被夹到 0。
String shiftSubtitleText(String text, String format, int deltaMs) {
  if (deltaMs == 0) return text;
  if (format == 'ass') return _shiftAss(text, deltaMs);
  return _shiftArrowStyle(text, deltaMs);
}

/// SRT / VTT：只改含 `-->` 的时间轴行（VTT 允许省略小时）
String _shiftArrowStyle(String text, int deltaMs) {
  final re = RegExp(r'(?:(\d{1,2}):)?(\d{1,2}):(\d{2})([,.])(\d{1,3})');
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    // 只处理时间轴行：台词正文里的「12:34」不参与偏移
    if (!lines[i].contains('-->')) continue;
    lines[i] = lines[i].splitMapJoin(
      re,
      onMatch: (m) {
        final hasHours = m.group(1) != null;
        final h = hasHours ? int.parse(m.group(1)!) : 0;
        final mnt = int.parse(m.group(2)!);
        final s = int.parse(m.group(3)!);
        final sep = m.group(4)!;
        final fracRaw = m.group(5)!;
        // 小数位可能是 1~3 位（VTT 常见 3 位，个别文件 1~2 位）
        final frac = int.parse(fracRaw.padRight(3, '0'));
        var total = ((h * 60 + mnt) * 60 + s) * 1000 + frac;
        total += deltaMs;
        if (total < 0) total = 0;
        final ms = total % 1000;
        final totalSeconds = total ~/ 1000;
        final hh = totalSeconds ~/ 3600;
        final mm = (totalSeconds % 3600) ~/ 60;
        final ss = totalSeconds % 60;
        final digits = fracRaw.length;
        final fracText = ms.toString().padLeft(3, '0').substring(0, digits);
        final body = '${mm.toString().padLeft(2, '0')}:'
            '${ss.toString().padLeft(2, '0')}';
        final tail = '$sep$fracText';
        if (hasHours || hh > 0) {
          return '${hh.toString().padLeft(2, '0')}:$body$tail';
        }
        return '$body$tail';
      },
      onNonMatch: (s) => s,
    );
  }
  return lines.join('\n');
}

/// ASS/SSA：按 `Format:` 行的列定义找到 Start / End，只改这两列
String _shiftAss(String text, int deltaMs) {
  final lines = text.split('\n');
  var startColumn = 1;
  var endColumn = 2;
  for (final line in lines) {
    final trimmed = line.trimLeft().toLowerCase();
    if (!trimmed.startsWith('format:')) continue;
    final fields = line.substring(line.indexOf(':') + 1).split(',');
    final start = fields.indexWhere((f) => f.trim().toLowerCase() == 'start');
    final end = fields.indexWhere((f) => f.trim().toLowerCase() == 'end');
    if (start >= 0 && end >= 0) {
      startColumn = start;
      endColumn = end;
      break;
    }
  }

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final trimmed = line.trimLeft();
    if (!trimmed.toLowerCase().startsWith('dialogue:')) continue;
    final prefixLen = line.length - trimmed.length;
    final colon = trimmed.indexOf(':');
    if (colon < 0) continue;
    final body = trimmed.substring(colon + 1);
    final fields = body.split(',');
    if (fields.length <= startColumn || fields.length <= endColumn) continue;
    fields[startColumn] = _shiftAssTime(fields[startColumn], deltaMs);
    fields[endColumn] = _shiftAssTime(fields[endColumn], deltaMs);
    lines[i] = line.substring(0, prefixLen + colon + 1) + fields.join(',');
  }
  return lines.join('\n');
}

String _shiftAssTime(String raw, int deltaMs) {
  final m = RegExp(r'^\s*(\d{1,2}):(\d{2}):(\d{2})[.:](\d{1,3})\s*$')
      .firstMatch(raw);
  if (m == null) return raw;
  final h = int.parse(m.group(1)!);
  final mnt = int.parse(m.group(2)!);
  final s = int.parse(m.group(3)!);
  final csRaw = m.group(4)!;
  final cs = int.parse(csRaw.padRight(2, '0').substring(0, 2));
  var total = ((h * 60 + mnt) * 60 + s) * 1000 + cs * 10;
  total += deltaMs;
  if (total < 0) total = 0;
  final totalSeconds = total ~/ 1000;
  final hh = totalSeconds ~/ 3600;
  final mm = (totalSeconds % 3600) ~/ 60;
  final ss = totalSeconds % 60;
  final csOut = ((total % 1000) ~/ 10).toString().padLeft(2, '0');
  return '${hh.toString().padLeft(1, '0')}:'
      '${mm.toString().padLeft(2, '0')}:'
      '${ss.toString().padLeft(2, '0')}.$csOut';
}

/// 去掉 BOM、统一换行，落盘前调用
String normalizeSubtitleText(String text) {
  var result = text;
  if (result.startsWith('\uFEFF')) result = result.substring(1);
  return result.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
}
