/// 精选直播频道目录（内置在 assets 里）。
///
/// ## 为什么不再从远程源现拉
///
/// 之前直播页是「从 GitHub 拉 7 份 m3u、合并去重给用户」，实测可播率参差
/// （5%～95%），用户点十个台有七八个打不开。现在改成：**离线全量实测过一遍
/// （主列表 + 第一个分片都要拉得回来），只把真能播的写进这份内置目录**。
///
/// 目录按用户要的四类组织：央视 / 地方 / 国外 / 体育。
/// 每个台保留 1～3 条地址，主地址放前面，备用的在播放器里就是另一条线路。
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../models/media_resource.dart';

const String kLiveCatalogAsset = 'assets/live_channels.json';

/// 一个精选频道
class LiveChannel {
  final String name;
  final String logo;

  /// 主地址 + 备用地址（都已实测可播，按响应速度排序）
  final List<String> urls;

  /// 源里声明的播放要求
  final String userAgent;
  final String referrer;

  const LiveChannel({
    required this.name,
    required this.urls,
    this.logo = '',
    this.userAgent = '',
    this.referrer = '',
  });

  String get url => urls.first;

  Map<String, String>? get playHeaders {
    if (userAgent.isEmpty && referrer.isEmpty) return null;
    return {
      if (userAgent.isNotEmpty) 'User-Agent': userAgent,
      if (referrer.isNotEmpty) 'Referer': referrer,
    };
  }

  /// 主地址和备用地址各自成一条线路，播放器里能直接切换
  MediaResource toResource() => MediaResource(
        siteId: 'live',
        siteName: '电视直播',
        vodId: url,
        title: name,
        cover: logo,
        remarks: '直播',
        intro: '直播地址：$url',
        groups: [
          for (var i = 0; i < urls.length; i++)
            PlayGroup(
              name: i == 0 ? '默认线路' : '备用线路 $i',
              episodes: [Episode(name: name, url: urls[i])],
            ),
        ],
      );

  factory LiveChannel.fromJson(Map<String, dynamic> j) {
    final urls = <String>[];
    final first = (j['url'] ?? '').toString().trim();
    if (first.isNotEmpty) urls.add(first);
    final backups = j['backup'];
    if (backups is List) {
      for (final b in backups) {
        final s = b.toString().trim();
        if (s.isNotEmpty && !urls.contains(s)) urls.add(s);
      }
    }
    return LiveChannel(
      name: (j['name'] ?? '').toString().trim(),
      logo: (j['logo'] ?? '').toString().trim(),
      urls: urls,
      userAgent: (j['ua'] ?? '').toString().trim(),
      referrer: (j['ref'] ?? '').toString().trim(),
    );
  }
}

/// 一个分类（央视 / 地方 / 国外 / 体育）
class LiveGroup {
  final String id;
  final String name;
  final List<LiveChannel> channels;

  const LiveGroup({required this.id, required this.name, required this.channels});

  /// 按台名包含匹配过滤；关键词为空时原样返回
  List<LiveChannel> search(String keyword) {
    final k = keyword.trim().toLowerCase();
    if (k.isEmpty) return channels;
    return [
      for (final c in channels)
        if (c.name.toLowerCase().contains(k)) c,
    ];
  }
}

/// 内置目录
class LiveCatalog {
  final String updated;
  final List<LiveGroup> groups;

  const LiveCatalog({required this.updated, required this.groups});

  int get total => groups.fold(0, (a, g) => a + g.channels.length);

  LiveGroup? groupOf(String id) {
    for (final g in groups) {
      if (g.id == id) return g;
    }
    return null;
  }

  /// 全目录搜索（台名包含匹配，忽略大小写）
  List<LiveChannel> search(String keyword) {
    if (keyword.trim().isEmpty) return const [];
    return [
      for (final g in groups) ...g.search(keyword),
    ];
  }

  /// 「全部」分类：把各方言区的台铺平，搜索时最有用
  LiveGroup get all => LiveGroup(
        id: '__all__',
        name: '全部',
        channels: [for (final g in groups) ...g.channels],
      );

  /// TabBar 实际要显示的分类（第一个是「全部」）
  List<LiveGroup> get tabGroups => [all, ...groups];

  static LiveCatalog parse(String jsonText) {
    final j = jsonDecode(jsonText);
    final rawGroups = j['groups'];
    return LiveCatalog(
      updated: (j['updated'] ?? '').toString(),
      groups: [
        if (rawGroups is List)
          for (final g in rawGroups)
            if (g is Map)
              LiveGroup(
                id: (g['id'] ?? '').toString(),
                name: (g['name'] ?? '').toString(),
                channels: [
                  for (final c in (g['channels'] as List? ?? const []))
                    if (c is Map)
                      LiveChannel.fromJson(Map<String, dynamic>.from(c)),
                ],
              ),
      ],
    );
  }

  static Future<LiveCatalog> load() async {
    final text = await rootBundle.loadString(kLiveCatalogAsset);
    return parse(text);
  }
}
