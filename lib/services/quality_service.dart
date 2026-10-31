import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/media_resource.dart';
import 'm3u8.dart';

/// 一个可切换的清晰度选项：要么是 m3u8 master 里的某个码率变体，
/// 要么是采集站里另一条「带清晰度字样」的线路（换线路看同一集）。
class QualityOption {
  /// 显示名：1080P / 4K / 自动 / 线路名
  final String label;

  /// 副标题：`1920×1080 · 4.2 Mbps` 或 `36 集 · 换线路`
  final String detail;

  /// 变体地址；线路选项为空
  final String url;

  /// 线路下标；变体选项为 -1
  final int groupIndex;

  /// 排序权重（分辨率高度优先，其次码率）
  final int rank;

  /// 「自动（自适应）」：仍用原始 master 地址，交给播放器按带宽选
  final bool isAuto;

  const QualityOption({
    required this.label,
    this.detail = '',
    this.url = '',
    this.groupIndex = -1,
    this.rank = 0,
    this.isAuto = false,
  });

  bool get isGroup => groupIndex >= 0;

  /// 同一个选项的身份（用于菜单里打勾）
  String get id => isGroup ? 'g:$groupIndex' : (isAuto ? 'auto' : url);

  @override
  String toString() => 'QualityOption($label, $id)';
}

/// 清晰度探测：抓一次 m3u8，若是 master playlist 就列出各码率变体。
///
/// 只做「读一次文本」，不下载分片；失败一律返回空列表（拿不到就不显示切换入口，
/// 不要让探测失败影响播放）。
class QualityService {
  static final QualityService instance = QualityService._();
  QualityService._();

  /// master playlist 本身很小（几 KB），超过这个大小基本说明抓到的是分片列表
  static const int _maxBytes = 512 * 1024;

  Future<List<QualityOption>> probe(
    String url, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !_looksLikePlaylist(url)) return const [];
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client.getUrl(uri);
      headers.forEach((k, v) => req.headers.set(k, v));
      final resp = await req.close().timeout(timeout);
      if (resp.statusCode != 200) return const [];
      final bytes = await resp
          .fold<List<int>>(<int>[], (a, b) => a..addAll(b))
          .timeout(timeout);
      if (bytes.isEmpty || bytes.length > _maxBytes) return const [];
      final text = utf8.decode(bytes, allowMalformed: true);
      return optionsFromPlaylist(parseM3u8(text, uri));
    } catch (_) {
      // 网络异常 / 超时 / 编码问题：静默降级为「没有更多清晰度」
      return const [];
    } finally {
      client.close(force: true);
    }
  }

  static bool _looksLikePlaylist(String url) {
    final u = url.toLowerCase();
    return u.contains('.m3u8') || u.contains('m3u8');
  }
}

/// 全局单例（与 offlineCache / subtitleStore 等保持同一风格）
final QualityService qualityService = QualityService.instance;

/// 把 master playlist 的变体转成菜单项（按清晰度从高到低）。
/// 非 master（单码率分片列表）返回空——没有可切换的东西。
List<QualityOption> optionsFromPlaylist(M3u8Playlist playlist) {
  if (!playlist.isMaster || playlist.variants.isEmpty) return const [];

  final sorted = [...playlist.variants]..sort((a, b) {
      final ha = resolutionHeight(a.resolution);
      final hb = resolutionHeight(b.resolution);
      if (ha != hb) return hb.compareTo(ha);
      return b.bandwidth.compareTo(a.bandwidth);
    });

  // HLS master 里常混着「纯音频轨」（没有 RESOLUTION）。它也是合法变体，
  // 但切过去就只剩声音没有画面，必须排除；只有在所有变体都没写分辨率时
  // 才退回按码率标签兜底（否则会一个选项都不剩）。
  final hasResolution = sorted.any((v) => resolutionHeight(v.resolution) > 0);

  final out = <QualityOption>[
    const QualityOption(
      label: '自动',
      detail: '按当前网速自适应',
      rank: 1 << 20,
      isAuto: true,
    ),
  ];
  final seen = <String>{};
  final usedLabels = <String>{};
  for (final v in sorted) {
    if (hasResolution && resolutionHeight(v.resolution) == 0) continue;
    final key = v.uri.toString();
    if (!seen.add(key)) continue;
    final label = qualityLabel(v.resolution, v.bandwidth);
    // 同一清晰度只留最高码率那一路：真实片源里常有多条无分辨率的
    // 「流畅」变体，全列出来菜单里会出现好几个一样的名字
    if (!usedLabels.add(label)) continue;
    out.add(QualityOption(
      label: label,
      // 同清晰度有多个码率时，把码率写进副标题以免看起来重复
      detail: variantDetail(v.resolution, v.bandwidth),
      url: key,
      rank: resolutionHeight(v.resolution) * 1000000 + v.bandwidth,
    ));
  }
  // 除「自动」外至少要有两档才值得给切换入口
  if (out.length < 3) return const [];
  return out;
}

/// `1920x1080` → 1080；解析不出来返回 0
int resolutionHeight(String resolution) {
  final m = RegExp(r'(\d+)\s*[x×]\s*(\d+)', caseSensitive: false)
      .firstMatch(resolution);
  if (m != null) return int.tryParse(m.group(2) ?? '') ?? 0;
  // 也可能只给 "1080p"
  final p = RegExp(r'(\d{3,4})\s*p', caseSensitive: false).firstMatch(resolution);
  return p == null ? 0 : (int.tryParse(p.group(1) ?? '') ?? 0);
}

/// 分辨率 → 中文/通行的清晰度名；没分辨率时退回码率粗判
String qualityLabel(String resolution, int bandwidth) {
  final h = resolutionHeight(resolution);
  if (h >= 2000) return '4K';
  if (h >= 1400) return '2K';
  if (h >= 1000) return '1080P';
  if (h >= 700) return '720P';
  if (h >= 520) return '540P';
  // 界值取 450：854x480 这类标准 480p 才不会被判成 360P
  if (h >= 450) return '480P';
  if (h >= 300) return '360P';
  if (bandwidth >= 5000000) return '高清';
  if (bandwidth >= 2000000) return '标清';
  if (bandwidth > 0) return '流畅';
  return '原画';
}

/// `1920×1080 · 4.2 Mbps`
String variantDetail(String resolution, int bandwidth) {
  final parts = <String>[];
  final h = resolutionHeight(resolution);
  if (h > 0) {
    final m = RegExp(r'(\d+)\s*[x×]\s*(\d+)').firstMatch(resolution);
    parts.add(m == null ? '${h}P' : '${m.group(1)}×${m.group(2)}');
  }
  if (bandwidth > 0) {
    parts.add('${(bandwidth / 1000000).toStringAsFixed(1)} Mbps');
  }
  return parts.isEmpty ? '未知码率' : parts.join(' · ');
}

/// 线路名里常见的清晰度字样 → 权重（越大越清晰）
const Map<String, int> _nameHints = {
  '4k': 2160,
  '2160': 2160,
  '蓝光': 1080,
  '1080': 1080,
  '超清': 1080,
  '高清': 720,
  '720': 720,
  '标清': 480,
  '480': 480,
  '原画': 720,
  'hd': 720,
};

/// 从线路名猜清晰度权重；猜不出返回 0
int qualityRankOfName(String name) {
  final n = name.toLowerCase();
  var best = 0;
  for (final e in _nameHints.entries) {
    if (n.contains(e.key) && e.value > best) best = e.value;
  }
  return best;
}

/// 采集站把不同清晰度拆成不同线路时（「线路1 蓝光」「线路2 高清」），
/// 把它们也做成可切换项——这是没有 master playlist 时的唯一清晰度来源。
List<QualityOption> groupQualityOptions(List<PlayGroup> groups) {
  final out = <QualityOption>[];
  for (var i = 0; i < groups.length; i++) {
    final rank = qualityRankOfName(groups[i].name);
    if (rank <= 0) continue;
    out.add(QualityOption(
      label: groups[i].name.length > 12
          ? groups[i].name.substring(0, 12)
          : groups[i].name,
      detail: '${groups[i].length} 集 · 换线路',
      groupIndex: i,
      rank: rank,
    ));
  }
  out.sort((a, b) => b.rank.compareTo(a.rank));
  return out;
}
