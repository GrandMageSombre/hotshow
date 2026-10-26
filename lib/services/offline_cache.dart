import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'm3u8.dart';
import 'remote_ua.dart';

/// 一条已缓存到本地的剧集
class CachedMedia {
  final String key;
  final String title;
  final String episodeName;

  /// 本地播放列表文件绝对路径（index.m3u8）
  final String localFile;
  final int segments;
  final int bytes;
  final int updatedAt;

  const CachedMedia({
    required this.key,
    required this.title,
    required this.episodeName,
    required this.localFile,
    required this.segments,
    required this.bytes,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'key': key,
        'title': title,
        'episodeName': episodeName,
        'localFile': localFile,
        'segments': segments,
        'bytes': bytes,
        'updatedAt': updatedAt,
      };

  factory CachedMedia.fromJson(Map<String, dynamic> j) => CachedMedia(
        key: j['key']?.toString() ?? '',
        title: j['title']?.toString() ?? '',
        episodeName: j['episodeName']?.toString() ?? '',
        localFile: j['localFile']?.toString() ?? '',
        segments: (j['segments'] as num?)?.toInt() ?? 0,
        bytes: (j['bytes'] as num?)?.toInt() ?? 0,
        updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
      );
}

/// 缓存进度
class DownloadProgress {
  final int done;
  final int total;
  final int bytes;
  final String phase;

  const DownloadProgress({
    this.done = 0,
    this.total = 0,
    this.bytes = 0,
    this.phase = '',
  });

  double get ratio => total <= 0 ? 0 : (done / total).clamp(0, 1);

  String get text {
    if (total <= 0) return phase;
    return '$phase $done/$total 分片';
  }
}

String _safeKey(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');

/// 一条剧集的缓存键（同时用作磁盘目录名，因此只保留安全字符）
String cacheKeyOf(
  String siteId,
  String vodId,
  int groupIndex,
  int episodeIndex,
) =>
    '${_safeKey(siteId)}_${_safeKey(vodId)}_g${groupIndex}_e$episodeIndex';

String cachePrefixOf(String siteId, String vodId) =>
    '${_safeKey(siteId)}_${_safeKey(vodId)}_g';

class OfflineCacheException implements Exception {
  final String message;
  OfflineCacheException(this.message);

  @override
  String toString() => message;
}

/// m3u8 分片离线缓存：把播放列表与全部分片抓到本地目录，
/// 重写为指向本地文件的 index.m3u8，从而支持断网播放。
class OfflineCache extends ChangeNotifier {
  static const _kIndex = 'offline_index';
  static const _concurrency = 4;
  static const _ua = kBrowserUserAgent;

  static final OfflineCache instance = OfflineCache();

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12)
    ..autoUncompress = true;

  final Map<String, CachedMedia> _items = {};
  final Map<String, DownloadProgress> _progress = {};
  final Set<String> _busy = {};
  final Set<String> _cancelled = {};

  Directory? _root;
  bool _loaded = false;

  /// 公开构造：测试可创建独立实例（应用内统一用 [instance]）
  OfflineCache();

  /// 仅在测试中使用：直接指定缓存根目录，跳过 path_provider
  @visibleForTesting
  void debugSetRoot(Directory dir) => _root = dir;

  List<CachedMedia> get items {
    final list = _items.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  int get totalBytes =>
      _items.values.fold<int>(0, (a, m) => a + m.bytes);

  CachedMedia? byKey(String key) => _items[key];

  /// 某个资源已缓存多少集
  int countFor(String siteId, String vodId) {
    final prefix = cachePrefixOf(siteId, vodId);
    return _items.keys.where((k) => k.startsWith(prefix)).length;
  }

  bool isCaching(String key) => _busy.contains(key);

  DownloadProgress? progressOf(String key) => _progress[key];

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final sp = await SharedPreferences.getInstance();
    for (final s in sp.getStringList(_kIndex) ?? const <String>[]) {
      try {
        final m = CachedMedia.fromJson(
            jsonDecode(s) as Map<String, dynamic>);
        _items[m.key] = m;
      } catch (_) {
        // 忽略损坏的索引项
      }
    }
    notifyListeners();
  }

  Future<Directory> ensureRoot() async {
    if (_root != null) return _root!;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/offline');
    if (!await dir.exists()) await dir.create(recursive: true);
    _root = dir;
    return dir;
  }

  Future<void> _persist() async {
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(
      _kIndex,
      _items.values.map((m) => jsonEncode(m.toJson())).toList(),
    );
  }

  void cancel(String key) => _cancelled.add(key);

  /// 下载整条 m3u8（全部线路分片）到本地；已完成则直接返回。
  Future<CachedMedia> download({
    required String key,
    required String title,
    required String episodeName,
    required String m3u8Url,
    Map<String, String>? headers,
  }) async {
    final existing = _items[key];
    if (existing != null && File(existing.localFile).existsSync()) {
      return existing;
    }
    if (_busy.contains(key)) {
      throw OfflineCacheException('该剧集正在缓存中');
    }
    _busy.add(key);
    _cancelled.remove(key);
    _progress[key] = const DownloadProgress(phase: '解析播放列表');
    notifyListeners();

    final root = await ensureRoot();
    final dir = Directory('${root.path}/$key');
    final reqHeaders = {
      'User-Agent': _ua,
      ...?headers,
    };

    try {
      if (await dir.exists()) await dir.delete(recursive: true);
      await dir.create(recursive: true);

      final uri = Uri.parse(m3u8Url);
      var playlist = parseM3u8(await _getText(uri, reqHeaders), uri);

      if (playlist.isMaster) {
        final best = playlist.bestVariant;
        if (best == null) throw OfflineCacheException('播放列表里没有可用码流');
        playlist = parseM3u8(await _getText(best.uri, reqHeaders), best.uri);
      }
      if (playlist.segments.isEmpty) {
        throw OfflineCacheException('该地址不含分片列表，无法离线缓存');
      }
      if (playlist.hasByteRange) {
        throw OfflineCacheException('该流使用 BYTERANGE 分段，暂不支持离线缓存');
      }
      if (!playlist.endList) {
        throw OfflineCacheException('该流可能是直播源（无结束标记），暂不支持离线缓存');
      }
      _throwIfCancelled(key);

      // 加密密钥：按原始 URI 去重后落盘
      final keyFiles = <String, String>{};
      var keyIndex = 0;
      for (final seg in playlist.segments) {
        final k = seg.key;
        if (k == null || !k.isEncrypted) continue;
        final ku = k.uri!.toString();
        if (keyFiles.containsKey(ku)) continue;
        _throwIfCancelled(key);
        final name = 'key_${keyIndex++}.bin';
        await File('${dir.path}/$name')
            .writeAsBytes(await _getBytes(k.uri!, reqHeaders));
        keyFiles[ku] = name;
      }

      // fMP4 初始化段
      String? initName;
      if (playlist.initMap != null) {
        _throwIfCancelled(key);
        initName = 'init.mp4';
        await File('${dir.path}/$initName')
            .writeAsBytes(await _getBytes(playlist.initMap!, reqHeaders));
      }

      final total = playlist.segments.length;
      final names = List<String>.filled(total, '');
      var done = 0;
      var bytes = 0;
      var cursor = 0;

      Future<void> worker() async {
        while (true) {
          final i = cursor++;
          if (i >= total) return;
          _throwIfCancelled(key);
          final name = 'seg_${(i + 1).toString().padLeft(5, '0')}.ts';
          final data = await _getBytes(playlist.segments[i].uri, reqHeaders);
          await File('${dir.path}/$name').writeAsBytes(data);
          names[i] = name;
          done++;
          bytes += data.length;
          _progress[key] = DownloadProgress(
            done: done,
            total: total,
            bytes: bytes,
            phase: '缓存中',
          );
          // 分片数可能上百，节流通知避免频繁重建
          if (done % 3 == 0 || done == total) notifyListeners();
        }
      }

      // 不使用 eagerError：等所有 worker 退出，避免失败后仍有写入在跑
      await Future.wait(List.generate(_concurrency, (_) => worker()));
      _throwIfCancelled(key);

      final local = buildLocalPlaylist(
        segments: playlist.segments,
        localNames: names,
        keyFiles: keyFiles,
        localInitMap: initName,
        mediaSequence: playlist.mediaSequence,
        version: playlist.version,
      );
      final indexFile = File('${dir.path}/index.m3u8');
      await indexFile.writeAsString(local);

      final media = CachedMedia(
        key: key,
        title: title,
        episodeName: episodeName,
        localFile: indexFile.path,
        segments: total,
        bytes: bytes,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
      _items[key] = media;
      await _persist();
      return media;
    } catch (e) {
      // 失败（含取消）后清理半成品目录
      try {
        if (await dir.exists()) await dir.delete(recursive: true);
      } catch (_) {
        // 忽略清理失败
      }
      if (e is _Cancelled) throw OfflineCacheException('已取消缓存');
      rethrow;
    } finally {
      _busy.remove(key);
      _cancelled.remove(key);
      _progress.remove(key);
      notifyListeners();
    }
  }

  Future<void> remove(String key) async {
    _items.remove(key);
    await _persist();
    try {
      final root = await ensureRoot();
      final dir = Directory('${root.path}/$key');
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // 目录可能已被系统清理
    }
  }

  Future<void> clear() async {
    _items.clear();
    await _persist();
    try {
      final root = await ensureRoot();
      if (await root.exists()) await root.delete(recursive: true);
    } catch (_) {
      // 忽略
    }
  }

  void _throwIfCancelled(String key) {
    if (_cancelled.contains(key)) throw _Cancelled();
  }

  Future<String> _getText(Uri uri, Map<String, String> headers) async {
    final bytes = await _getBytes(uri, headers);
    return utf8.decode(bytes, allowMalformed: true);
  }

  Future<List<int>> _getBytes(
      Uri uri, Map<String, String> headers) async {
    Object? last;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final req =
            await _http.getUrl(uri).timeout(const Duration(seconds: 15));
        headers.forEach((k, v) => req.headers.set(k, v));
        final resp = await req.close().timeout(const Duration(seconds: 30));
        final data =
            await resp.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
        if (resp.statusCode == 200) return data;
        final err = OfflineCacheException('下载失败（HTTP ${resp.statusCode}）');
        // 4xx 重试没有意义，直接放弃
        if (resp.statusCode >= 400 && resp.statusCode < 500) throw err;
        last = err;
      } on _Cancelled {
        rethrow;
      } on OfflineCacheException catch (e) {
        last = e;
        if (e.message.startsWith('下载失败')) rethrow;
      } catch (e) {
        last = e;
      }
      await Future<void>.delayed(Duration(milliseconds: 300 * (attempt + 1)));
    }
    throw OfflineCacheException('分片下载失败：$last');
  }
}

class _Cancelled implements Exception {}

final offlineCache = OfflineCache.instance;
