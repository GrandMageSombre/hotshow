// ignore_for_file: avoid_print
// 字幕源连通性验证：不需要设备与 Flutter 运行时，直接跑
//   dart run tool/subtitle_check.dart <片名> [语言,逗号分隔]
//   dart run tool/subtitle_check.dart --legacy <legacy_subtitle_id>
//
// 例：
//   dart run tool/subtitle_check.dart Inception zh-cn,zh-tw
//   dart run tool/subtitle_check.dart --legacy 8142102
//
// 第一种走完整的「搜索 → 免 Key 下载 → 解包 → 编码识别」链路；
// 第二种只验证下载链路（搜索接口被匿名限流时用）。
import 'package:hotshow/models/subtitle.dart';
import 'package:hotshow/services/subtitle/open_subtitles.dart';
import 'package:hotshow/services/subtitle/subtitle_text.dart';
import 'package:hotshow/services/subtitle/zip_reader.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    print('用法: dart run tool/subtitle_check.dart <片名> [语言]');
    print('  或: dart run tool/subtitle_check.dart --legacy <字幕ID>');
    print('例:   dart run tool/subtitle_check.dart Inception zh-cn,zh-tw');
    return;
  }

  final source = OpenSubtitlesSource();
  try {
    if (args.first == '--legacy') {
      await _checkLegacy(source, args.length > 1 ? args[1] : '');
      return;
    }
    await _checkSearch(source, args);
  } catch (e) {
    print('[FAIL] $e');
  } finally {
    source.close();
  }
}

Future<void> _checkSearch(OpenSubtitlesSource source, List<String> args) async {
  final query = args.first.trim();
  final languages = (args.length > 1 ? args[1] : 'zh-cn,zh-tw,en')
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  print('搜索「$query」 语言=${languages.join(",")}');
  final list = await source.search(query: query, languages: languages);
  if (list.isEmpty) {
    print('[WARN] 没有命中，换英文名再试');
    return;
  }
  print('[ OK ] 命中 ${list.length} 条：');
  for (final c in list.take(5)) {
    print('   - [${c.languageLabel}] ${c.title}');
    print('     下载 ${c.downloads} 次 · legacyId=${c.legacyId} · '
        'fileId=${c.fileId} · 免Key=${c.freeDownloadable}');
  }

  final target =
      list.firstWhere((c) => c.freeDownloadable, orElse: () => list.first);
  print('下载：${target.title}');
  await _dump(await source.download(target));
}

Future<void> _checkLegacy(OpenSubtitlesSource source, String rawId) async {
  final id = int.tryParse(rawId);
  if (id == null) {
    print('[FAIL] 需要数字字幕 ID，例如 8142102');
    return;
  }
  final candidate = SubtitleCandidate(
    source: OpenSubtitlesSource.id,
    id: 'legacy',
    title: 'legacy $id',
    language: '',
    legacyId: id,
  );
  print('下载 legacy id=$id');
  await _dump(await source.download(candidate));
}

Future<void> _dump(List<int> bytes) async {
  print('下载 ${bytes.length} 字节，magic=${bytes.take(4).toList()}');
  final archive = unpackSubtitleBytes(bytes);
  print('解包 ${archive.name} → ${archive.bytes.length} 字节');
  final text = normalizeSubtitleText(decodeSubtitleBytes(archive.bytes));
  print('[ OK ] 解码 ${text.length} 字符，开头内容：');
  print(text.split('\n').take(6).join('\n'));
}
