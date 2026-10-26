import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 在线字幕的常见打包方式解包：ZIP（OpenSubtitles 下载的是 zip）、
/// GZIP 单文件、以及直接给出的 .srt / .ass 文本。
///
/// 这里只实现「读中央目录 + stored/deflate」这一最小子集——字幕包都是
/// 普通 zip，没有 zip64 / 加密，足够用且不引入额外依赖。
class SubtitleArchive {
  /// 包内文件名（已去掉目录），用于判断格式
  final String name;
  final List<int> bytes;

  const SubtitleArchive({required this.name, required this.bytes});
}

const int _sigEocd = 0x06054b50;
const int _sigCentral = 0x02014b50;
const int _sigLocal = 0x04034b50;

const List<String> _subtitleExts = ['.srt', '.ass', '.ssa', '.vtt'];

/// 解包字幕字节流，返回其中第一个字幕文件。
///
/// 无法识别或数据损坏时抛 [FormatException]，由上层转成用户可读提示。
SubtitleArchive unpackSubtitleBytes(List<int> bytes, {String? name}) {
  if (bytes.isEmpty) {
    throw const FormatException('字幕文件是空的');
  }
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

  try {
    // GZIP
    if (data.length >= 2 && data[0] == 0x1F && data[1] == 0x8B) {
      final out = gzip.decode(data);
      return unpackSubtitleBytes(out, name: name);
    }
    // ZIP
    if (data.length >= 4 &&
        data[0] == 0x50 &&
        data[1] == 0x4B &&
        data[2] == 0x03 &&
        data[3] == 0x04) {
      final entry = _extractFromZip(data);
      if (entry == null) {
        throw const FormatException('压缩包里没有找到 .srt / .ass / .vtt 字幕');
      }
      return entry;
    }
    return SubtitleArchive(name: name ?? 'subtitle.srt', bytes: data);
  } on FormatException {
    rethrow;
  } catch (_) {
    // 压缩数据损坏（Filter error / RangeError 等）统一转成可读提示
    throw const FormatException('字幕压缩包已损坏，换一条或重新下载试试');
  }
}

SubtitleArchive? _extractFromZip(Uint8List data) {
  final bd = ByteData.sublistView(data);
  final eocd = _findEocd(data, bd);
  if (eocd < 0) return null;

  final count = bd.getUint16(eocd + 10, Endian.little);
  var offset = bd.getUint32(eocd + 16, Endian.little);
  SubtitleArchive? fallback;

  for (var i = 0; i < count; i++) {
    if (offset + 46 > data.length) break;
    if (bd.getUint32(offset, Endian.little) != _sigCentral) break;

    final flags = bd.getUint16(offset + 8, Endian.little);
    final method = bd.getUint16(offset + 10, Endian.little);
    final compSize = bd.getUint32(offset + 20, Endian.little);
    final nameLen = bd.getUint16(offset + 28, Endian.little);
    final extraLen = bd.getUint16(offset + 30, Endian.little);
    final commentLen = bd.getUint16(offset + 32, Endian.little);
    final localOffset = bd.getUint32(offset + 42, Endian.little);
    final nameEnd = offset + 46 + nameLen;
    if (nameEnd > data.length) break;
    final entryName =
        utf8.decode(data.sublist(offset + 46, nameEnd), allowMalformed: true);
    offset = nameEnd + extraLen + commentLen;

    final lower = entryName.toLowerCase();
    if (lower.endsWith('/') || lower.endsWith('\\')) continue;
    if (!_subtitleExts.any(lower.endsWith)) continue;
    if ((flags & 0x1) != 0) continue; // 加密条目

    final content =
        _readEntry(data, bd, localOffset, method, compSize);
    if (content == null) continue;

    final item = SubtitleArchive(
      name: entryName.split(RegExp(r'[/\\]')).last,
      bytes: content,
    );
    // srt / ass 更常见，优先返回；其它格式先记下来兜底
    if (lower.endsWith('.srt') || lower.endsWith('.ass')) return item;
    fallback ??= item;
  }
  return fallback;
}

Uint8List? _readEntry(
  Uint8List data,
  ByteData bd,
  int localOffset,
  int method,
  int compSize,
) {
  if (localOffset + 30 > data.length) return null;
  if (bd.getUint32(localOffset, Endian.little) != _sigLocal) return null;
  final nameLen = bd.getUint16(localOffset + 26, Endian.little);
  final extraLen = bd.getUint16(localOffset + 28, Endian.little);
  final start = localOffset + 30 + nameLen + extraLen;
  if (start + compSize > data.length || compSize <= 0) return null;
  final raw = data.sublist(start, start + compSize);
  switch (method) {
    case 0: // stored
      return Uint8List.fromList(raw);
    case 8: // deflate
      try {
        return Uint8List.fromList(ZLibDecoder(raw: true).convert(raw));
      } catch (_) {
        return null;
      }
    default:
      return null;
  }
}

int _findEocd(Uint8List data, ByteData bd) {
  final minPos = data.length - 22 - 65535;
  final start = minPos < 0 ? 0 : minPos;
  for (var i = data.length - 22; i >= start; i--) {
    if (bd.getUint32(i, Endian.little) != _sigEocd) continue;
    // 必须满足「记录 + 注释」正好到文件末尾，避免命中注释里的假签名
    final commentLen = bd.getUint16(i + 20, Endian.little);
    if (i + 22 + commentLen == data.length) return i;
  }
  return -1;
}
