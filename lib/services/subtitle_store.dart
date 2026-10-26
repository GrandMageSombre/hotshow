import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/subtitle.dart';

/// 字幕文件的本地管理：
/// * 文件落在 `<应用支持目录>/subtitles/<剧集键>/` 下，按剧集分目录；
/// * 记住每部剧选中的字幕（下次进播放页自动挂上）；
/// * 记住语言筛选与 OpenSubtitles API Key。
class SubtitleStore extends ChangeNotifier {
  static const _kFiles = 'subtitle_files_v1';
  static const _kSelected = 'subtitle_selected_v1';
  static const _kApiKey = 'subtitle_api_key';
  static const _kLanguages = 'subtitle_languages_v1';

  /// 每部剧最多保留几条字幕，超出后清理最旧的
  static const _maxPerShow = 8;

  final Map<String, List<SubtitleFile>> _files = {};
  final Map<String, SubtitleFile> _selected = {};

  String apiKey = '';

  /// 搜索时默认勾选的语言
  List<String> languages = const ['zh-cn', 'zh-tw', 'en'];

  Directory? _root;
  bool _loaded = false;

  static String _safeKey(String s) =>
      s.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');

  /// 目录名：可读前缀 + 稳定短 hash。
  /// 只用 [_safeKey] 会把 `site#1_2` 和 `site_1#2` 归一到同一个目录。
  static String _dirName(String key) {
    final safe = _safeKey(key);
    final prefix = safe.length > 32 ? safe.substring(0, 32) : safe;
    var hash = 0x811c9dc5;
    for (final unit in key.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return '${prefix}_${hash.toRadixString(36)}';
  }

  Future<void> load() async {
    if (_loaded) return;
    final sp = await SharedPreferences.getInstance();
    apiKey = sp.getString(_kApiKey) ?? '';
    final langs = sp.getStringList(_kLanguages);
    if (langs != null && langs.isNotEmpty) languages = langs;

    for (final raw in sp.getStringList(_kFiles) ?? const <String>[]) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map) continue;
        final file =
            SubtitleFile.fromJson(Map<String, dynamic>.from(decoded));
        if (file.showKey.isEmpty || file.path.isEmpty) continue;
        (_files[file.showKey] ??= []).add(file);
      } catch (_) {
        // 忽略损坏的索引项
      }
    }
    for (final raw in sp.getStringList(_kSelected) ?? const <String>[]) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map) continue;
        final file =
            SubtitleFile.fromJson(Map<String, dynamic>.from(decoded));
        if (file.showKey.isEmpty) continue;
        _selected[file.showKey] = file;
      } catch (_) {
        // 忽略损坏的索引项
      }
    }
    _loaded = true;
    notifyListeners();
  }

  /// 测试用：跳过 path_provider 指定根目录
  @visibleForTesting
  void debugSetRoot(Directory dir) => _root = dir;

  Future<Directory> ensureRoot() async {
    if (_root != null) return _root!;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/subtitles');
    if (!await dir.exists()) await dir.create(recursive: true);
    _root = dir;
    return dir;
  }

  SubtitleFile? selectedFor(String showKey) => _selected[showKey];

  List<SubtitleFile> filesFor(String showKey) {
    final list = [...?_files[showKey]]
      ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    return list;
  }

  /// 已存在磁盘上的字幕（用于「本剧字幕」列表，过滤掉被系统清理的条目）
  List<SubtitleFile> existingFilesFor(String showKey) =>
      filesFor(showKey).where((f) => File(f.path).existsSync()).toList();

  /// 把解码后的字幕文本以 UTF-8 落盘，返回记录
  Future<SubtitleFile> addBytes({
    required String showKey,
    required String label,
    required String language,
    required String source,
    required List<int> utf8Bytes,
    required String ext,
  }) async {
    final dir = Directory('${(await ensureRoot()).path}/${_dirName(showKey)}');
    if (!await dir.exists()) await dir.create(recursive: true);

    final stamp = DateTime.now().millisecondsSinceEpoch;
    final safeLabel = _safeKey(label).replaceAll(RegExp(r'_{2,}'), '_');
    final shortLabel =
        safeLabel.length > 40 ? safeLabel.substring(0, 40) : safeLabel;
    final base = File('${dir.path}/${stamp}_$shortLabel.$ext');
    await base.writeAsBytes(utf8Bytes, flush: true);

    final file = SubtitleFile(
      showKey: showKey,
      basePath: base.path,
      path: base.path,
      label: label.trim().isEmpty ? '字幕' : label.trim(),
      language: language,
      source: source,
      addedAt: stamp,
    );
    final list = _files.putIfAbsent(showKey, () => [])..add(file);
    // 超出上限时删掉最旧的（含其偏移副本）；如果删的正是当前选中项，
    // 连选中记录一起清掉，否则播放页会指向一个已经不存在文件。
    while (list.length > _maxPerShow) {
      final old = list.removeAt(0);
      if (_selected[showKey]?.path == old.path) {
        _selected.remove(showKey);
      }
      await _deleteRelated(old);
    }
    await _persist();
    return file;
  }

  Future<void> select(String showKey, SubtitleFile? file) async {
    final current = _selected[showKey];
    if (current?.path == file?.path && current?.delayMs == file?.delayMs) {
      return;
    }
    if (file == null) {
      _selected.remove(showKey);
    } else {
      _selected[showKey] = file;
    }
    await _persist();
  }

  /// 调整时间轴后替换记录（保留在列表里，选中项同步更新）
  Future<void> replaceFile(
      String showKey, SubtitleFile oldFile, SubtitleFile newFile) async {
    final list = _files[showKey];
    if (list != null) {
      final i = list.indexWhere((f) => f.path == oldFile.path);
      if (i >= 0) {
        list[i] = newFile;
      } else {
        list.add(newFile);
      }
    }
    if (_selected[showKey]?.path == oldFile.path) {
      _selected[showKey] = newFile;
    }
    if (oldFile.path != newFile.path && oldFile.path != oldFile.basePath) {
      try {
        final f = File(oldFile.path);
        if (await f.exists()) await f.delete();
      } catch (_) {
        // 忽略
      }
    }
    await _persist();
  }

  Future<void> removeFile(SubtitleFile file) async {
    _files[file.showKey]?.removeWhere((f) => f.path == file.path);
    if (_selected[file.showKey]?.path == file.path) {
      _selected.remove(file.showKey);
    }
    await _deleteRelated(file);
    await _persist();
  }

  Future<void> _deleteRelated(SubtitleFile file) async {
    Future<void> del(String path) async {
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {
        // 文件可能已被清理
      }
    }

    await del(file.path);
    await del(file.basePath);
    // 时间轴偏移副本：<basePath 去扩展名>@<xxx>ms.<ext>
    final dir = File(file.basePath).parent;
    final name = file.basePath.split(RegExp(r'[/\\]')).last;
    final dot = name.lastIndexOf('.');
    final stem = dot < 0 ? name : name.substring(0, dot);
    try {
      if (await dir.exists()) {
        await for (final entity in dir.list()) {
          final fileName = entity.path.split(RegExp(r'[/\\]')).last;
          if (fileName.startsWith('$stem@') && entity is File) {
            await del(entity.path);
          }
        }
      }
    } catch (_) {
      // 忽略
    }
  }

  Future<void> setApiKey(String value) async {
    apiKey = value.trim();
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kApiKey, apiKey);
    notifyListeners();
  }

  Future<void> setLanguages(List<String> values) async {
    if (values.isEmpty) return;
    languages = List<String>.from(values);
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(_kLanguages, languages);
    notifyListeners();
  }

  Future<void> _persist() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(
      _kFiles,
      [
        for (final list in _files.values)
          for (final f in list) jsonEncode(f.toJson()),
      ],
    );
    await sp.setStringList(
      _kSelected,
      _selected.values.map((f) => jsonEncode(f.toJson())).toList(),
    );
    notifyListeners();
  }
}

final subtitleStore = SubtitleStore();
