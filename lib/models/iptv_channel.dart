/// IPTV 直播频道模型与 M3U 播放列表解析。
///
/// 这里的 M3U 指**频道列表**（IPTV playlist），和影视站那种 HLS 媒体播放列表
/// 不是一回事（后者在 `services/m3u8.dart` 里）。两者都以 `#EXTM3U` 开头，
/// 但 IPTV 列表用 `#EXTINF` + 一行地址描述「一个频道」，没有分片。
///
/// 常见写法：
/// ```m3u
/// #EXTM3U x-tvg-url="http://epg.example/e.xml"
/// #EXTINF:-1 tvg-id="CCTV1" tvg-name="CCTV1" tvg-logo="http://…/cctv1.png" group-title="央视频道",CCTV1
/// http://1.2.3.4/hls/1/index.m3u8
/// ```
/// 也支持分组写在下一行的变体（`#EXTGRP:分组`），以及
/// `#EXTVLCOPT:http-user-agent=…` 这种播放器参数（解析时跳过，不影响频道）。
library;

/// 一个直播频道
class IptvChannel {
  final String name;
  final String url;
  final String group;
  final String logo;
  final String tvgId;

  const IptvChannel({
    required this.name,
    required this.url,
    this.group = '',
    this.logo = '',
    this.tvgId = '',
  });

  /// 名字里带这些字样就算高清档（分组筛选和角标用）
  bool get isHd => RegExp(r'（?\(?(4K|8K|UHD|2160|1080|HD|超清|蓝光)',
          caseSensitive: false)
      .hasMatch(name);

  /// 4K / 8K 单独标出来，用户找超高清时最好用
  bool get is4K =>
      RegExp(r'(4K|8K|UHD|2160)', caseSensitive: false).hasMatch(name);

  /// 协议能不能交给播放器。组播（rtp/udp）在手机上没有对应的网络环境，
  /// 直接标成不可播，避免用户点了只看到转圈。
  bool get playable => RegExp(r'^(https?|rtsp|rtmp)://', caseSensitive: false)
      .hasMatch(url);

  @override
  String toString() => 'IptvChannel($name, $group)';
}

/// 解析出来的一份频道列表
class IptvPlaylist {
  final List<IptvChannel> channels;

  /// 分组出现的顺序（保持源里的排列，UI 直接拿来渲染筛选条）
  final List<String> groups;

  const IptvPlaylist({this.channels = const [], this.groups = const []});

  int get length => channels.length;

  bool get isEmpty => channels.isEmpty;

  IptvPlaylist filterGroup(String? group) {
    if (group == null || group.isEmpty) return this;
    return IptvPlaylist(
      channels: [
        for (final c in channels)
          if (c.group == group) c,
      ],
      groups: groups,
    );
  }

  /// 按频道名/分组/地址做包含匹配，忽略大小写
  IptvPlaylist search(String keyword) {
    final k = keyword.trim().toLowerCase();
    if (k.isEmpty) return this;
    return IptvPlaylist(
      channels: [
        for (final c in channels)
          if (c.name.toLowerCase().contains(k) ||
              c.group.toLowerCase().contains(k) ||
              c.tvgId.toLowerCase().contains(k))
            c,
      ],
      groups: groups,
    );
  }
}

/// 解析 IPTV 频道的 M3U/M3U8 文本。
///
/// 只保留有名字、有地址的条目；同一份列表里重复的（名字 + 地址都相同）
/// 会被去掉——很多源是多来源合并的，重复率能到三成。
IptvPlaylist parseIptvPlaylist(String content) {
  final channels = <IptvChannel>[];
  final groups = <String>[];
  final seen = <String>{};

  String pendingName = '';
  String pendingGroup = '';
  String pendingLogo = '';
  String pendingTvgId = '';

  for (final raw in content.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;

    if (line.startsWith('#EXTINF')) {
      final info = _parseExtInf(line);
      pendingName = info.name;
      pendingGroup = info.group;
      pendingLogo = info.logo;
      pendingTvgId = info.tvgId;
      continue;
    }
    if (line.startsWith('#EXTGRP')) {
      // `#EXTGRP:分组`，优先级低于 group-title
      final g = _afterColon(line).trim();
      if (g.isNotEmpty && pendingGroup.isEmpty) pendingGroup = g;
      continue;
    }
    if (line.startsWith('#')) continue; // 其它指令（EXTVLCOPT/EXT-X-…）跳过

    // 到这里是一行地址
    if (pendingName.isEmpty) continue;
    if (!RegExp(r'^[a-z][a-z0-9+.-]*://', caseSensitive: false).hasMatch(line)) {
      continue;
    }
    final key = '$pendingName\u0000$line';
    if (!seen.add(key)) {
      pendingName = '';
      continue;
    }
    final ch = IptvChannel(
      name: pendingName,
      url: line,
      // iptv-org 那类列表完全没有 group-title，分组栏会空掉，
      // 统一归到「其他」，至少让筛选条有个落脚点
      group: pendingGroup.isEmpty ? '其他' : pendingGroup,
      logo: pendingLogo,
      tvgId: pendingTvgId,
    );
    channels.add(ch);
    if (!groups.contains(ch.group)) groups.add(ch.group);
    pendingName = '';
    pendingGroup = '';
    pendingLogo = '';
    pendingTvgId = '';
  }

  return IptvPlaylist(channels: channels, groups: groups);
}

class _ExtInf {
  final String name;
  final String group;
  final String logo;
  final String tvgId;
  const _ExtInf(this.name, this.group, this.logo, this.tvgId);
}

/// `#EXTINF:-1 tvg-id="x" group-title="y",显示名`
///
/// 属性区和显示名的分界是**第一个引号外的逗号**：属性值全在引号里，
/// 而台名本身可能带逗号（`CCTV-1, 综合`）。取最后一个逗号会把台名截成
/// 「综合」——这是实测踩过的坑，别改回去。
_ExtInf _parseExtInf(String line) {
  final body = _afterColon(line);
  final splitAt = _firstUnquotedComma(body);

  final attrs = splitAt < 0 ? body : body.substring(0, splitAt);
  final name = splitAt < 0 ? '' : body.substring(splitAt + 1).trim();
  final map = _parseAttrs(attrs);

  return _ExtInf(
    name.isNotEmpty ? name : (map['tvg-name'] ?? ''),
    map['group-title'] ?? '',
    map['tvg-logo'] ?? '',
    map['tvg-id'] ?? '',
  );
}

int _firstUnquotedComma(String s) {
  var inQuote = false;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c == 0x22) {
      inQuote = !inQuote;
    } else if (c == 0x2C && !inQuote) {
      return i;
    }
  }
  return -1;
}

String _afterColon(String line) {
  final i = line.indexOf(':');
  return i < 0 ? '' : line.substring(i + 1);
}

/// `KEY="VALUE"` / `KEY=VALUE` 属性串
Map<String, String> _parseAttrs(String s) {
  final out = <String, String>{};
  for (final m in RegExp(r'([A-Za-z0-9-]+)=("[^"]*"|[^\s]*)').allMatches(s)) {
    var v = m.group(2) ?? '';
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
      v = v.substring(1, v.length - 1);
    }
    out[m.group(1)!] = v;
  }
  return out;
}
