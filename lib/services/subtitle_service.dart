import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/subtitle.dart';
import 'remote_ua.dart';
import 'subtitle/open_subtitles.dart';
import 'subtitle/subtitle_exception.dart';
import 'subtitle/subtitle_text.dart';
import 'subtitle/zip_reader.dart';
import 'subtitle_store.dart';

/// 字幕业务层：搜索 → 下载 → 解包 → 统一转 UTF-8 → 落盘 → 记住选择。
///
/// 页面只跟这个 facade 打交道（`subtitleService`），存储细节在 [store] 里；
/// [SubtitleStore] 允许注入，方便单测。
class SubtitleService {
  static final SubtitleService instance = SubtitleService();

  SubtitleService({SubtitleStore? store}) : store = store ?? subtitleStore;

  final SubtitleStore store;

  final OpenSubtitlesSource openSubtitles = OpenSubtitlesSource();

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12)
    ..autoUncompress = true;

  /// 匿名接口有频率限制，同一关键词短时间内重复搜索直接走缓存
  final Map<String, _CachedSearch> _cache = {};
  static const _cacheTtl = Duration(minutes: 10);
  static const _maxCacheEntries = 40;

  /// 同一时刻只允许一次下载同一候选，避免连点
  final Set<String> _inFlight = {};

  static const int _maxBytes = 30 * 1024 * 1024;

  Future<List<SubtitleCandidate>> search({
    required String query,
    String? year,
    List<String>? languages,
    String? apiKey,
    int page = 1,
    bool force = false,
  }) async {
    final langs = languages ?? store.languages;
    final key = apiKey ?? store.apiKey;
    final cacheKey = '${query.trim().toLowerCase()}|${langs.join(',')}|'
        '${year ?? ''}|$page|${key.isEmpty ? 'anon' : 'key'}';

    final cached = _cache[cacheKey];
    if (!force &&
        cached != null &&
        DateTime.now().difference(cached.at) < _cacheTtl) {
      return cached.items;
    }

    final list = await openSubtitles.search(
      query: query,
      year: year,
      languages: langs,
      apiKey: key,
      page: page,
    );
    _cache[cacheKey] = _CachedSearch(list, DateTime.now());
    _pruneCache();
    return list;
  }

  void _pruneCache() {
    if (_cache.length <= _maxCacheEntries) return;
    final entries = _cache.entries.toList()
      ..sort((a, b) => a.value.at.compareTo(b.value.at));
    for (final e in entries.take(_cache.length - _maxCacheEntries)) {
      _cache.remove(e.key);
    }
  }

  /// 下载候选字幕、落盘并记住为本剧选中项
  Future<SubtitleFile> downloadAndSave({
    required SubtitleCandidate candidate,
    required String showKey,
    String? apiKey,
  }) async {
    final id = '${candidate.source}:${candidate.id}';
    if (!_inFlight.add(id)) {
      throw SubtitleException('这条字幕正在下载中，请稍候');
    }
    try {
      final raw = await openSubtitles.download(
        candidate,
        apiKey: apiKey ?? store.apiKey,
      );
      final file = await _saveArchive(
        raw,
        showKey: showKey,
        label: candidate.title,
        language: candidate.language,
        source: candidate.source,
        fallbackName: 'subtitle.${candidate.format}',
      );
      await store.select(showKey, file);
      return file;
    } finally {
      _inFlight.remove(id);
    }
  }

  /// 从直链导入（.srt / .ass / .vtt / .zip / .gz）
  Future<SubtitleFile> importFromUrl({
    required String url,
    required String showKey,
    String? label,
  }) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
      throw SubtitleException('链接格式不对，需要 http(s) 开头的字幕地址');
    }
    final bytes = await _download(uri);
    final name = _fileNameOf(uri);
    final file = await _saveArchive(
      bytes,
      showKey: showKey,
      label: (label == null || label.trim().isEmpty) ? name : label,
      language: '',
      source: 'url',
      fallbackName: name,
    );
    await store.select(showKey, file);
    return file;
  }

  /// 只更新记录里的偏移量（播放器用 mpv 的 `sub-delay` 实时生效，不重写文件）
  Future<SubtitleFile> updateDelay(SubtitleFile file, int delayMs) async {
    final updated = file.copyWith(delayMs: delayMs);
    await store.replaceFile(file.showKey, file, updated);
    return updated;
  }

  /// 兜底方案：把偏移写死进字幕文件（播放器不支持 `sub-delay` 时用）。
  /// 始终以原文件为基准，反复调整不会累积误差。
  Future<SubtitleFile> bakeDelay(SubtitleFile file, int delayMs) async {
    final base = File(file.basePath);
    if (!await base.exists()) {
      throw SubtitleException('原字幕文件已不存在，请重新下载');
    }
    final text = normalizeSubtitleText(
      decodeSubtitleBytes(await base.readAsBytes()),
    );
    final format = detectSubtitleFormat(fileName: file.basePath, text: text);
    final shifted = shiftSubtitleText(text, format, delayMs);

    final dot = file.basePath.lastIndexOf('.');
    final stem = dot < 0 ? file.basePath : file.basePath.substring(0, dot);
    final ext = dot < 0 ? format : file.basePath.substring(dot + 1);
    final target = File('$stem@${delayMs}ms.$ext');
    await target.writeAsBytes(utf8.encode(shifted), flush: true);

    final updated = file.copyWith(path: target.path, delayMs: delayMs);
    await store.replaceFile(file.showKey, file, updated);
    return updated;
  }

  Future<SubtitleFile> _saveArchive(
    List<int> raw, {
    required String showKey,
    required String label,
    required String language,
    required String source,
    required String fallbackName,
  }) async {
    SubtitleArchive archive;
    try {
      archive = unpackSubtitleBytes(raw, name: fallbackName);
    } on FormatException catch (e) {
      throw SubtitleException(e.message);
    }

    final text = normalizeSubtitleText(decodeSubtitleBytes(archive.bytes));
    if (text.trim().isEmpty) {
      throw SubtitleException('这条字幕内容为空，换一条试试');
    }
    if (!_looksLikeSubtitle(text)) {
      throw SubtitleException('下载到的内容不是字幕文件（可能被站点拦截或返回了网页），换一条试试');
    }
    final format = detectSubtitleFormat(fileName: archive.name, text: text);
    return store.addBytes(
      showKey: showKey,
      label: label,
      language: language.trim().isEmpty ? _guessLanguage(text) : language,
      source: source,
      utf8Bytes: utf8.encode(text),
      ext: format,
    );
  }

  /// 粗判内容确实是字幕：SRT/VTT 的 `-->`、ASS 的段头、MicroDVD 的 `{n}{n}`
  bool _looksLikeSubtitle(String text) {
    final head = text.trimLeft();
    // HTML 注释里的 `<!-- -->` 也含 `-->`，先按开头把它排掉
    if (head.startsWith('<')) return false;
    if (text.contains('-->')) return true;
    if (text.contains('[Script Info]') ||
        text.contains('[Events]') ||
        text.contains('[V4+ Styles]')) {
      return true;
    }
    if (text.toUpperCase().contains('WEBVTT')) return true;
    if (RegExp(r'\{\d+\}\{\d+\}').hasMatch(text)) return true;
    return false;
  }

  Future<List<int>> _download(Uri uri) async {
    HttpClientRequest? req;
    try {
      req = await _http.getUrl(uri);
      req.headers.set('User-Agent', kBrowserUserAgent);
      req.headers.set('Referer', '${uri.scheme}://${uri.authority}/');
      req.headers.set('Accept', '*/*');
      final resp = await req.close().timeout(const Duration(seconds: 30));
      final readFuture = resp.fold<List<int>>(<int>[], (a, b) {
        a.addAll(b);
        if (a.length > _maxBytes) {
          throw SubtitleException('字幕文件过大（超过 30MB），已中止下载');
        }
        return a;
      });
      // Future.timeout 只完成 Future、不取消底层流：abort 之后的报错要吞掉
      unawaited(readFuture.catchError((Object _) => <int>[]));
      final bytes = await readFuture.timeout(const Duration(seconds: 60));
      if (resp.statusCode != 200) {
        throw SubtitleException('字幕下载失败（HTTP ${resp.statusCode}）');
      }
      if (bytes.isEmpty) throw SubtitleException('下载到的字幕是空的');
      final type = resp.headers.contentType?.mimeType ?? '';
      if (type.contains('html') || _startsWithHtml(bytes)) {
        throw SubtitleException('这个链接返回的是网页，不是字幕文件直链');
      }
      return bytes;
    } on SubtitleException {
      req?.abort();
      rethrow;
    } on TimeoutException {
      req?.abort();
      throw SubtitleException('字幕下载超时，请检查网络');
    } on SocketException {
      throw SubtitleException('连不上字幕文件所在服务器');
    } on HttpException {
      throw SubtitleException('字幕下载失败，请稍后重试');
    }
  }

  bool _startsWithHtml(List<int> bytes) {
    for (final byte in bytes) {
      if (byte == 0x20 || byte == 0x0D || byte == 0x0A || byte == 0x09) continue;
      return byte == 0x3C;
    }
    return false;
  }

  String _fileNameOf(Uri uri) {
    if (uri.pathSegments.isEmpty) return 'subtitle.srt';
    final raw = uri.pathSegments.last;
    if (raw.isEmpty) return 'subtitle.srt';
    try {
      return Uri.decodeComponent(raw);
    } catch (_) {
      return raw;
    }
  }

  /// 直链导入时猜一下语言：中文占比高就算简体，否则留空
  String _guessLanguage(String text) {
    var cjk = 0;
    var total = 0;
    for (final rune in text.runes) {
      if (rune <= 0x20) continue;
      total++;
      if (rune >= 0x4E00 && rune <= 0x9FFF) cjk++;
    }
    if (total == 0) return '';
    return cjk / total >= 0.1 ? 'zh-cn' : '';
  }

  void dispose() {
    _http.close();
    openSubtitles.close();
  }
}

final subtitleService = SubtitleService.instance;

class _CachedSearch {
  final List<SubtitleCandidate> items;
  final DateTime at;

  const _CachedSearch(this.items, this.at);
}
