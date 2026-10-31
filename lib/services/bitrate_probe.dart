import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'm3u8.dart';

/// 一条流的码率估算结果（用前几段分片「字节数 ÷ 时长」算，不解码）
class BitrateEstimate {
  /// 估算码率（kbps）
  final int kbps;

  /// 实际采样到的分片时长
  final Duration sampled;

  /// 实际采样到的字节数
  final int bytes;

  /// 分片超过单段读取上限时，真实码率只会更高——此时按已读字节算的是**下限**
  final bool lowerBound;

  const BitrateEstimate({
    required this.kbps,
    required this.sampled,
    required this.bytes,
    this.lowerBound = false,
  });

  /// `1.3 Mbps` / `≥4.2 Mbps` / `820 kbps`
  String get label {
    final base = kbps >= 1000
        ? '${(kbps / 1000).toStringAsFixed(1)} Mbps'
        : '$kbps kbps';
    return lowerBound ? '≥$base' : base;
  }

  /// 粗略分级。阈值按 H.264 常见编码水平定，只用来横向比较片源，不是绝对画质。
  String get grade {
    if (kbps >= 4000) return '高清';
    if (kbps >= 2000) return '较清晰';
    if (kbps >= 1200) return '一般';
    return '偏低';
  }

  /// 从采样字节数与时长算码率（单独抽出来便于单测）
  static BitrateEstimate? fromSamples({
    required int bytes,
    required Duration sampled,
    bool lowerBound = false,
  }) {
    if (bytes <= 0 || sampled.inMilliseconds <= 0) return null;
    final kbps = (bytes * 8 / (sampled.inMilliseconds / 1000) / 1000).round();
    return BitrateEstimate(
      kbps: kbps,
      sampled: sampled,
      bytes: bytes,
      lowerBound: lowerBound,
    );
  }
}

/// 片源码率探测器：抓一次 m3u8 + 头两段分片，估算码率。
///
/// 为什么这么做：采集站的 m3u8 基本是单码率，没有 `RESOLUTION` 可读，
/// 而只靠线路名（「蓝光」「高清」）完全不可信——实测就见过标着 HD 只有 0.5 Mbps 的。
/// 「下两段、算比特率」是唯一不需要解码就能横向比较的办法。
class BitrateProbe {
  static final BitrateProbe instance = BitrateProbe._();
  BitrateProbe._();

  /// 取 2 段：只测 1 段时万一碰上转场/黑场，码率会偏差好几倍
  static const int defaultSegments = 2;

  /// 单段最多读这么多字节就掐断（防止被大分片拖死）；被掐断的结果按「下限」展示
  static const int maxSegmentBytes = 2 * 1024 * 1024;

  /// 缓存上限（片源地址很多，别让 Map 无限涨）
  static const int maxCacheEntries = 64;

  /// playlist 文本上限
  static const int _maxPlaylistBytes = 512 * 1024;

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8)
    ..autoUncompress = true;

  final Map<String, BitrateEstimate> _cache = {};
  final Map<String, Future<BitrateEstimate?>> _inflight = {};

  /// 仅供测试注入：返回分片字节数；null 表示抓取失败
  Future<int?> Function(String url, Map<String, String> headers)?
      debugSegmentOverride;
  Future<String?> Function(String url, Map<String, String> headers)?
      debugPlaylistOverride;

  BitrateEstimate? cached(String m3u8Url) => _cache[m3u8Url];

  Future<BitrateEstimate?> probe(
    String m3u8Url, {
    Map<String, String> headers = const {},
    int segments = defaultSegments,
    Duration timeout = const Duration(seconds: 8),
  }) {
    final hit = _cache[m3u8Url];
    if (hit != null) return Future.value(hit);
    final running = _inflight[m3u8Url];
    if (running != null) return running;

    final future = _probe(m3u8Url, headers, segments, timeout)
        .then((estimate) {
          if (estimate != null) {
            if (_cache.length >= maxCacheEntries) {
              // 插入序即先后序，先扔最早的
              _cache.remove(_cache.keys.first);
            }
            _cache[m3u8Url] = estimate;
          }
          return estimate;
        })
        .whenComplete(() {
          // 注意别写成 `=> _inflight.remove(...)`：返回的是这个 Future 本身，会死锁
          _inflight.remove(m3u8Url);
        });
    _inflight[m3u8Url] = future;
    return future;
  }

  void clearCache() => _cache.clear();

  Future<BitrateEstimate?> _probe(
    String url,
    Map<String, String> headers,
    int segments,
    Duration timeout,
  ) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    try {
      final text = await _fetchPlaylist(uri, headers, timeout);
      if (text == null) return null;
      var playlist = parseM3u8(text, uri);
      // master：挑码率最高的那一路再算（与播放器的自适应目标一致）
      if (playlist.isMaster) {
        final best = playlist.bestVariant;
        if (best == null) return null;
        final inner = await _fetchPlaylist(best.uri, headers, timeout);
        if (inner == null) return null;
        playlist = parseM3u8(inner, best.uri);
      }
      if (playlist.segments.isEmpty) return null;

      var bytes = 0;
      var sampled = Duration.zero;
      var ok = 0;
      var capped = false;
      for (final seg in playlist.segments.take(segments)) {
        final sample = await _fetchSegment(seg.uri, headers, timeout);
        if (sample == null || sample.bytes <= 0) continue;
        bytes += sample.bytes;
        if (sample.capped) capped = true;
        sampled += Duration(
          milliseconds: (seg.duration * 1000).round(),
        );
        ok++;
      }
      if (ok == 0) return null;
      return BitrateEstimate.fromSamples(
        bytes: bytes,
        sampled: sampled,
        lowerBound: capped,
      );
    } catch (_) {
      // 探测失败只是「不知道码率」，绝不能影响播放
      return null;
    }
  }

  Future<String?> _fetchPlaylist(
    Uri uri,
    Map<String, String> headers,
    Duration timeout,
  ) async {
    final override = debugPlaylistOverride;
    if (override != null) return override(uri.toString(), headers);
    try {
      final req = await _http.getUrl(uri);
      headers.forEach((k, v) => req.headers.set(k, v));
      final resp = await req.close().timeout(timeout);
      if (resp.statusCode != 200) return null;
      final bytes = await _readCapped(resp, _maxPlaylistBytes, timeout);
      if (bytes == null || bytes.isEmpty) return null;
      final text = utf8.decode(bytes, allowMalformed: true);
      if (!text.trimLeft().startsWith('#EXTM3U')) return null;
      return text;
    } catch (_) {
      return null;
    }
  }

  Future<_SegSample?> _fetchSegment(
    Uri uri,
    Map<String, String> headers,
    Duration timeout,
  ) async {
    final override = debugSegmentOverride;
    if (override != null) {
      final size = await override(uri.toString(), headers);
      return size == null ? null : _SegSample(size, false);
    }
    try {
      final req = await _http.getUrl(uri);
      headers.forEach((k, v) => req.headers.set(k, v));
      final resp = await req.close().timeout(timeout);
      if (resp.statusCode != 200) return null;
      final contentLength = resp.contentLength;
      final bytes = await _readCapped(resp, maxSegmentBytes, timeout);
      if (bytes == null) return null;
      // 读满上限且原文件更大 → 码率只能给下限
      final capped = bytes.length >= maxSegmentBytes &&
          contentLength > maxSegmentBytes;
      return _SegSample(bytes.length, capped);
    } catch (_) {
      return null;
    }
  }

  /// 读到上限就主动退订，避免为了估码率把整段拖下来
  Future<List<int>?> _readCapped(
    HttpClientResponse resp,
    int cap,
    Duration timeout,
  ) {
    final completer = Completer<List<int>?>();
    final buf = <int>[];
    late StreamSubscription<List<int>> sub;
    late Timer timer;

    void finish(List<int>? value) {
      if (completer.isCompleted) return;
      timer.cancel();
      sub.cancel();
      completer.complete(value);
    }

    timer = Timer(timeout, () => finish(null));
    sub = resp.listen(
      (chunk) {
        buf.addAll(chunk);
        if (buf.length >= cap) finish(buf.sublist(0, cap));
      },
      onError: (_) => finish(null),
      onDone: () => finish(buf),
      cancelOnError: true,
    );
    return completer.future;
  }

  /// 给列表排序用：越大越清晰，未测排在最后
  static int compare(BitrateEstimate? a, BitrateEstimate? b) {
    final ka = a?.kbps ?? -1;
    final kb = b?.kbps ?? -1;
    return kb.compareTo(ka);
  }

  /// 四舍五入到 0.1 Mbps，便于展示
  static double mbps(int kbps) => math.max(0, kbps) / 1000;
}

class _SegSample {
  final int bytes;
  final bool capped;
  const _SegSample(this.bytes, this.capped);
}
