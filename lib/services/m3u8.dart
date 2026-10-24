/// 极简 M3U8 / HLS 播放列表解析器（纯 Dart，无第三方依赖，便于单测）。
///
/// 支持：master playlist（多码率）、媒体分片列表、`EXT-X-KEY`（逐分片记录）、
/// `EXT-X-MAP`（fMP4 初始化段）、`EXT-X-BYTERANGE` 标记（不支持下片）。
library;

class M3u8Key {
  final String method; // AES-128 / SAMPLE-AES / NONE
  final Uri? uri;
  final String? iv;

  const M3u8Key({required this.method, this.uri, this.iv});

  bool get isEncrypted => method != 'NONE' && uri != null;

  @override
  String toString() => 'M3u8Key($method, $uri)';
}

class M3u8Segment {
  final Uri uri;
  final double duration;
  final String title;

  /// 该分片生效的加密密钥（可为空）
  final M3u8Key? key;

  const M3u8Segment({
    required this.uri,
    this.duration = 0,
    this.title = '',
    this.key,
  });

  @override
  String toString() => 'M3u8Segment($uri, ${duration}s)';
}

class M3u8Variant {
  final Uri uri;
  final int bandwidth;
  final String resolution;

  const M3u8Variant({
    required this.uri,
    this.bandwidth = 0,
    this.resolution = '',
  });

  @override
  String toString() => 'M3u8Variant($uri, $bandwidth, $resolution)';
}

class M3u8Playlist {
  final bool isMaster;
  final List<M3u8Variant> variants;
  final List<M3u8Segment> segments;
  final Uri? initMap;
  final int mediaSequence;
  final double targetDuration;
  final int version;
  final bool endList;
  final bool hasByteRange;

  const M3u8Playlist({
    this.isMaster = false,
    this.variants = const [],
    this.segments = const [],
    this.initMap,
    this.mediaSequence = 0,
    this.targetDuration = 0,
    this.version = 3,
    this.endList = true,
    this.hasByteRange = false,
  });

  double get totalDuration =>
      segments.fold<double>(0, (a, s) => a + s.duration);

  bool get isEncrypted => segments.any((s) => s.key?.isEncrypted ?? false);

  /// 码率最高的变体；无变体时返回 null
  M3u8Variant? get bestVariant {
    if (variants.isEmpty) return null;
    return variants.reduce((a, b) => b.bandwidth >= a.bandwidth ? b : a);
  }
}

/// 解析播放列表文本；[base] 用于把相对地址补全为绝对地址。
M3u8Playlist parseM3u8(String content, Uri base) {
  final variants = <M3u8Variant>[];
  final segments = <M3u8Segment>[];
  M3u8Key? currentKey;
  Uri? initMap;
  var mediaSequence = 0;
  var version = 3;
  var targetDuration = 0.0;
  var endList = false;
  var hasByteRange = false;
  var isMaster = false;

  double? pendingDuration;
  var pendingTitle = '';
  var pendingIsVariant = false;
  var pendingBandwidth = 0;
  var pendingResolution = '';

  for (final raw in content.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;

    if (line.startsWith('#')) {
      if (line.startsWith('#EXT-X-STREAM-INF')) {
        isMaster = true;
        final attrs = _parseAttributes(_afterColon(line));
        pendingIsVariant = true;
        pendingBandwidth = int.tryParse(attrs['BANDWIDTH'] ?? '') ?? 0;
        pendingResolution = attrs['RESOLUTION'] ?? '';
      } else if (line.startsWith('#EXTINF')) {
        final v = _afterColon(line);
        final comma = v.indexOf(',');
        final dur = comma < 0 ? v : v.substring(0, comma);
        pendingDuration = double.tryParse(dur.trim()) ?? 0;
        pendingTitle = comma < 0 ? '' : v.substring(comma + 1).trim();
      } else if (line.startsWith('#EXT-X-KEY')) {
        final attrs = _parseAttributes(_afterColon(line));
        final method = (attrs['METHOD'] ?? 'NONE').toUpperCase();
        if (method == 'NONE') {
          currentKey = null;
        } else {
          final u = attrs['URI'];
          currentKey = M3u8Key(
            method: method,
            uri: u == null ? null : base.resolve(u),
            iv: attrs['IV'],
          );
        }
      } else if (line.startsWith('#EXT-X-MAP')) {
        final attrs = _parseAttributes(_afterColon(line));
        final u = attrs['URI'];
        if (u != null) initMap = base.resolve(u);
        if (attrs['BYTERANGE'] != null) hasByteRange = true;
      } else if (line.startsWith('#EXT-X-MEDIA-SEQUENCE')) {
        mediaSequence = int.tryParse(_afterColon(line).trim()) ?? 0;
      } else if (line.startsWith('#EXT-X-TARGETDURATION')) {
        targetDuration = double.tryParse(_afterColon(line).trim()) ?? 0;
      } else if (line.startsWith('#EXT-X-VERSION')) {
        version = int.tryParse(_afterColon(line).trim()) ?? 3;
      } else if (line.startsWith('#EXT-X-BYTERANGE')) {
        hasByteRange = true;
      } else if (line.startsWith('#EXT-X-ENDLIST')) {
        endList = true;
      }
      continue;
    }

    final uri = base.resolve(line);
    if (pendingIsVariant) {
      variants.add(M3u8Variant(
        uri: uri,
        bandwidth: pendingBandwidth,
        resolution: pendingResolution,
      ));
      pendingIsVariant = false;
    } else if (pendingDuration != null) {
      segments.add(M3u8Segment(
        uri: uri,
        duration: pendingDuration,
        title: pendingTitle,
        key: currentKey,
      ));
      pendingDuration = null;
      pendingTitle = '';
    }
  }

  return M3u8Playlist(
    isMaster: isMaster && segments.isEmpty,
    variants: variants,
    segments: segments,
    initMap: initMap,
    mediaSequence: mediaSequence,
    targetDuration: targetDuration,
    version: version,
    endList: endList,
    hasByteRange: hasByteRange,
  );
}

String _afterColon(String line) {
  final i = line.indexOf(':');
  return i < 0 ? '' : line.substring(i + 1);
}

/// 解析 `KEY=VALUE,KEY="VALUE"` 形式的属性串
Map<String, String> _parseAttributes(String s) {
  final out = <String, String>{};
  for (final m in RegExp(r'([A-Za-z0-9-]+)=("[^"]*"|[^,]*)').allMatches(s)) {
    var v = m.group(2) ?? '';
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
      v = v.substring(1, v.length - 1);
    }
    out[m.group(1)!] = v;
  }
  return out;
}

/// 生成一份指向本地文件的播放列表（用于离线播放）
String buildLocalPlaylist({
  required List<M3u8Segment> segments,
  required List<String> localNames,
  required Map<String, String> keyFiles, // 原始 key uri -> 本地文件名
  required String? localInitMap,
  required int mediaSequence,
  required int version,
}) {
  final buf = StringBuffer('#EXTM3U\n');
  buf.write('#EXT-X-VERSION:${version > 0 ? version : 3}\n');
  final maxDur = segments.isEmpty
      ? 10.0
      : segments.map((s) => s.duration).reduce((a, b) => a > b ? a : b);
  buf.write('#EXT-X-TARGETDURATION:${maxDur.ceil()}\n');
  buf.write('#EXT-X-MEDIA-SEQUENCE:$mediaSequence\n');
  buf.write('#EXT-X-PLAYLIST-TYPE:VOD\n');
  if (localInitMap != null) {
    buf.write('#EXT-X-MAP:URI="$localInitMap"\n');
  }

  String? currentKeyLine;
  for (var i = 0; i < segments.length; i++) {
    final seg = segments[i];
    final key = seg.key;
    final line = key == null || !key.isEncrypted
        ? '#EXT-X-KEY:METHOD=NONE'
        : '#EXT-X-KEY:METHOD=${key.method}'
            ',URI="${keyFiles[key.uri.toString()]}"'
            '${key.iv == null ? '' : ',IV=${key.iv}'}';
    if (line != currentKeyLine) {
      // 明文流无需写 METHOD=NONE
      if (!(line == '#EXT-X-KEY:METHOD=NONE' && currentKeyLine == null)) {
        buf.write('$line\n');
      }
      currentKeyLine = line;
    }
    final dur = seg.duration <= 0 ? 0 : seg.duration;
    buf.write('#EXTINF:${dur.toStringAsFixed(3)},\n');
    buf.write('${localNames[i]}\n');
  }
  buf.write('#EXT-X-ENDLIST\n');
  return buf.toString();
}
