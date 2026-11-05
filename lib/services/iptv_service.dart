/// IPTV 直播源服务：从 GitHub 上的公开 m3u 仓库拉取频道列表。
///
/// ## 为什么要过镜像
///
/// `raw.githubusercontent.com` 在国内经常连不上或者握手极慢（实测首次 49 秒），
/// 所以默认先走 GitHub 加速前缀，失败再依次降级，最后才直连。
/// 前缀只是拼接，不改变仓库内容。
///
/// ## 源是怎么挑的
///
/// 每个源都抽样 40 个频道实测过「能不能拉回 m3u8」，可播率记在
/// [IptvSourceDef.health] 里，UI 上直接显示——避免用户点进一个大而全
/// 但全死链的列表里空转。数据截至 2026-11-05。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:charset/charset.dart';

import '../models/iptv_channel.dart';
import 'remote_ua.dart';

/// 源的类别，决定直播页上它归在「电视」还是「体育」那一栏
enum IptvCategory {
  tv('电视'),
  sports('体育');

  final String label;
  const IptvCategory(this.label);
}

/// 一个直播源（GitHub 仓库里的一个 m3u 文件，或一个完整 URL）
class IptvSourceDef {
  final String id;
  final String name;

  /// `owner/repo/branch/path`；以 http 开头时当成完整地址直接用
  /// （iptv-org 的分类列表在 GitHub Pages 上，不在 raw 仓库里）
  final String path;
  final String note;
  final IptvCategory category;

  /// 实测频道条数（0 表示没测过——自定义源就没有这个数）
  final int channels;

  /// 抽样实测可播率（百分比，0 表示没测过）
  final int health;

  /// 源标签上要看得到的关键信息，比如体育源的「NBA」
  final String badge;

  /// 把整个源的频道都归到这一个分组。
  ///
  /// iptv-org 的分类列表里 `group-title` 是多分类拼接（`Kids;Sports`、
  /// `News;Sports`），直接拿来当分组会冒出几十个怪名字，归一成「体育」更好用。
  final String groupOverride;

  const IptvSourceDef({
    required this.id,
    required this.name,
    required this.path,
    this.note = '',
    this.category = IptvCategory.tv,
    this.channels = 0,
    this.health = 0,
    this.badge = '',
    this.groupOverride = '',
  });

  bool get isAbsolute => path.startsWith('http');

  /// 源标签上的第二行小字
  String get statsText {
    if (channels <= 0) return health > 0 ? '~$health%' : '';
    return health > 0 ? '$channels台 · ~$health%' : '$channels台';
  }
}

/// 内置源：按可播率从高到低排，合并时同名频道优先取前面的。
const List<IptvSourceDef> kIptvSources = [
  IptvSourceDef(
    id: 'vbskycn',
    name: '卫视 + 地方台',
    path: 'vbskycn/iptv/master/tv/iptv4.m3u',
    note: '央视频道 / 地方频道 / 纪录 / 儿童，实测最稳',
    channels: 214,
    health: 95,
  ),
  IptvSourceDef(
    id: 'iptvorg_sports',
    name: '体育赛事',
    // 分类列表是 iptv-org 的构建产物，只在 GitHub Pages 上
    path: 'https://iptv-org.github.io/iptv/categories/sports.m3u',
    note: '全球体育台合集：NBA TV、ESPN、Sky Sports、Eurosport，'
        '外加 5 个 CCTV 体育台（5+/16/台球/高尔夫网球/风云足球）',
    category: IptvCategory.sports,
    badge: 'NBA',
    channels: 477,
    health: 80,
    groupOverride: '体育',
  ),
  IptvSourceDef(
    id: 'bestfan_province',
    name: '卫视频道',
    path: 'best-fan/iptv-sources/main/cn_province.m3u8',
    note: '各省卫视，每日自动检测',
    channels: 188,
    health: 82,
  ),
  IptvSourceDef(
    id: 'bestfan_all',
    name: '央视 + 卫视',
    path: 'best-fan/iptv-sources/main/cn_all.m3u8',
    note: '央视 124 + 卫视 188，覆盖面最全的央视源',
    channels: 339,
    health: 72,
  ),
  IptvSourceDef(
    id: 'bestfan_cctv',
    name: '央视频道',
    path: 'best-fan/iptv-sources/main/cn_cctv.m3u8',
    note: 'CCTV 全套 + 付费频道',
    channels: 138,
    health: 65,
  ),
  IptvSourceDef(
    id: 'iptvorg_cn',
    name: '国际视野',
    path: 'iptv-org/iptv/master/streams/cn.m3u',
    note: 'iptv-org 官方中国列表，含港澳台与外语台；无分组，建议直接搜',
    channels: 518,
    health: 25,
  ),
  IptvSourceDef(
    id: 'dazui_4k',
    name: '大合集（含 4K）',
    path: 'imDazui/Tvlist-awesome-m3u-m3u8/master/m3u/'
        '1300个直播源全部有效【全部4k老电脑别用】.m3u8',
    note: '1300 条，含 4K/50FPS，但死链多，建议配合「只看高清」筛',
    channels: 1298,
    health: 5,
  ),
];

/// 「全部源」的伪 id
const String kIptvAllSources = '__all__';

/// GitHub 加速前缀，按顺序尝试
const List<String> kIptvMirrors = [
  'https://gh-proxy.com/https://raw.githubusercontent.com/',
  'https://ghproxy.net/https://raw.githubusercontent.com/',
  'https://raw.githubusercontent.com/',
];

class IptvException implements Exception {
  final String message;
  const IptvException(this.message);
  @override
  String toString() => message;
}

class _Cached {
  final IptvPlaylist playlist;
  final DateTime at;
  const _Cached(this.playlist, this.at);
}

class IptvService {
  static final IptvService instance = IptvService._();

  IptvService._() : _http = _newClient();

  /// 供测试注入
  IptvService.withClient(HttpClient client) : _http = client;

  final HttpClient _http;

  /// 同一份列表 30 分钟内不重复拉
  static const Duration _ttl = Duration(minutes: 30);
  final Map<String, _Cached> _cache = {};

  static HttpClient _newClient() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 12)
    ..autoUncompress = true
    ..idleTimeout = const Duration(seconds: 5);

  /// 拉某个源（[sourceId] 为 [kIptvAllSources] 时合并全部）
  Future<IptvPlaylist> load(String sourceId, {bool force = false}) async {
    final hit = _cache[sourceId];
    if (!force && hit != null && DateTime.now().difference(hit.at) < _ttl) {
      return hit.playlist;
    }

    IptvPlaylist result;
    if (sourceId == kIptvAllSources) {
      result = await _loadAll();
    } else {
      final def = sourceOf(sourceId);
      if (def == null) throw IptvException('未知的直播源：$sourceId');
      result = await _loadOne(def);
    }
    if (result.isEmpty) {
      throw const IptvException('列表里没有解析到频道（源可能改结构了）');
    }
    _cache[sourceId] = _Cached(result, DateTime.now());
    return result;
  }

  static IptvSourceDef? sourceOf(String id) {
    for (final s in kIptvSources) {
      if (s.id == id) return s;
    }
    return null;
  }

  Future<IptvPlaylist> _loadOne(IptvSourceDef def) async {
    final text = await _fetchWithMirrors(def);
    final parsed = parseIptvPlaylist(text);
    if (def.groupOverride.isEmpty) return parsed;
    // 整源归一到一个分组（体育源的多分类拼接名）
    final g = def.groupOverride;
    return IptvPlaylist(
      channels: [for (final c in parsed.channels) c.withGroup(g)],
      groups: [g],
    );
  }

  /// 全部合并：并发拉，按名字去重（源已按可播率排序，先到先得）
  Future<IptvPlaylist> _loadAll() async {
    final results = await Future.wait<IptvPlaylist>([
      for (final s in kIptvSources)
        // 单个源失败不影响整体，返回空列表跳过
        _loadOne(s).catchError((Object _) => const IptvPlaylist()),
    ]);
    final seen = <String>{};
    final channels = <IptvChannel>[];
    final groups = <String>[];
    for (final p in results) {
      for (final c in p.channels) {
        if (!seen.add(c.name)) continue;
        channels.add(c);
        if (c.group.isNotEmpty && !groups.contains(c.group)) {
          groups.add(c.group);
        }
      }
    }
    return IptvPlaylist(channels: channels, groups: groups);
  }

  /// 依次尝试镜像，返回第一份拿到的文本。
  ///
  /// 每个镜像单独限时 12 秒：加速度前缀正常只要 1 秒左右，
  /// 一个镜像卡住就不该继续等它的 20 秒默认超时——否则合并六个源时
  /// 最坏要等到一分多钟。
  Future<String> _fetchWithMirrors(IptvSourceDef def) async {
    // 完整 URL（GitHub Pages 上的分类列表）没有镜像可用，直接取
    final urls = def.isAbsolute
        ? [def.path]
        : [for (final prefix in kIptvMirrors) '$prefix${def.path}'];
    Object? lastError;
    for (final url in urls) {
      try {
        return await _fetch(url).timeout(const Duration(seconds: 12));
      } catch (e) {
        lastError = e;
      }
    }
    throw IptvException('拉取失败：${_describe(lastError)}');
  }

  Future<String> _fetch(String url) async {
    final req = await _http.getUrl(_uriOf(url));
    req.headers
      ..set('User-Agent', kBrowserUserAgent)
      ..set('Accept', 'text/plain,*/*');
    final resp = await req.close().timeout(const Duration(seconds: 20));
    final bytes = await resp
        .fold<List<int>>(<int>[], (a, b) => a..addAll(b))
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      throw IptvException('HTTP ${resp.statusCode}');
    }
    return _decode(bytes);
  }

  /// 频道列表的编码很杂：新的仓库都是 UTF-8，老的国内源常是 GB18030。
  /// UTF-8 严格解失败就按 GBK 再试一次，实在不行才允许坏字符兜底
  /// （台名乱码总比整个源报错好）。
  static String _decode(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      // ignore: avoid_catching_errors
    }
    try {
      return gbk.decode(bytes);
    } catch (_) {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }

  /// 仓库路径里有中文和【】（`1300个直播源…【全部4k…】.m3u8`）。
  ///
  /// `Uri.tryParse` 自己就会把非 ASCII 和空格转成 %XX，不用手动
  /// `encodeFull` —— 后者会把已有的 `%20` 变成 `%2520`，反而弄坏地址。
  static Uri _uriOf(String url) {
    final u = Uri.tryParse(url);
    if (u == null || u.host.isEmpty) {
      throw IptvException('地址不合法：$url');
    }
    return u;
  }

  static String _describe(Object? e) {
    if (e == null) return '未知错误';
    if (e is IptvException) return e.message;
    if (e is TimeoutException) return '超时';
    if (e is SocketException) return '网络不可达';
    return e.toString();
  }

  void clearCache() => _cache.clear();

  void close() => _http.close();
}
