/// 红果短剧（hongguoduanju.com，抖音集团旗下免费短剧）网页版抓取。
///
/// 网页是 React Router 7 的 SSR 页面，所有数据都塞在页面里的
/// `_ROUTER_DATA = {...}` 中（`__MODERN_ROUTER_DATA__` 只放路由骨架，
/// 真正的 loaderData 在页尾的内联脚本里）。因此**不需要任何签名、token、
/// 登录态**，只按页面 HTML 解析即可：
///
/// | 页面 | 取什么 |
/// | --- | --- |
/// | `/rank/hot-drama`、`/category/real-drama` | `loaderData["category_$"].recommendList` |
/// | `/category/xxx?page=2` | 同上，24 条/页 |
/// | `/detail?series_id=…` | `loaderData["detail_$"]`，含 `vid_list`（全部剧集 id） |
///
/// 播放地址是固定的 CDN 规则：`/video/public/{vid}/360p.mp4`
/// （实测 720p/480p/1080p 均 404，网页版只给 360p，与 App 内一致）。
/// 红果的一个短剧条目（列表页/首页卡片）

library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/media_resource.dart';
import '../models/show_item.dart';
import 'remote_ua.dart';

class HongguoItem {
  final String seriesId;
  final String title;
  final String cover;
  final String intro;
  final int episodeCount;
  final List<String> tags;

  const HongguoItem({
    required this.seriesId,
    required this.title,
    this.cover = '',
    this.intro = '',
    this.episodeCount = 0,
    this.tags = const [],
  });

  /// 列表页副标题：全90集 · 战争/家国正义
  String get subtitle {
    final parts = [
      if (episodeCount > 0) '全$episodeCount集',
      if (tags.isNotEmpty) tags.take(2).join(' / '),
    ];
    return parts.join(' · ');
  }

  ShowItem toShowItem() => ShowItem(
        id: 'hg$seriesId',
        title: title,
        cover: cover,
        subtitle: subtitle,
        isTv: episodeCount > 1,
      );

  static HongguoItem? fromJson(Map<String, dynamic> j) {
    final id = _text(j['series_id']);
    final name = _text(j['series_name']);
    if (id.isEmpty || name.isEmpty) return null;
    final rawTags = j['tags'];
    return HongguoItem(
      seriesId: id,
      title: name,
      cover: _text(j['series_cover']),
      intro: _text(j['series_intro']),
      episodeCount: _asInt(j['episode_cnt']),
      tags: rawTags is List ? rawTags.map(_text).where((e) => e.isNotEmpty).toList() : const [],
    );
  }
}

/// 红果分类（网页「分类」页的分区）
class HongguoChannel {
  final String path; // 形如 real-drama
  final String label;

  const HongguoChannel(this.path, this.label);
}

/// 分类顺序与官网一致：真人剧 / 漫剧 / AI 剧（comic 是漫画，不列）
const List<HongguoChannel> kHongguoChannels = [
  HongguoChannel('real-drama', '真人剧'),
  HongguoChannel('comic-drama', '漫剧'),
  HongguoChannel('ai-drama', 'AI 剧'),
];

/// 首页热门榜单入口
const String kHongguoHotRank = 'rank/hot-drama';

/// 分类页每页条数。翻页时用它判断「还有没有下一页」：
/// 不足一页就说明到底了（千万别在 UI 里重复硬编码 20）。
const int kHongguoPageSize = 24;

/// 红果短剧网页版服务。
class HongguoService {
  static final HongguoService instance = HongguoService._();

  static const String base = 'https://www.hongguoduanju.com';

  final HttpClient _http;

  HongguoService._()
      : _http = HttpClient()
          ..connectionTimeout = const Duration(seconds: 12)
          ..autoUncompress = true;

  /// 供测试注入（传 null 时只能跑纯函数解析）
  HongguoService.withClient(HttpClient client) : _http = client;

  /// 榜单页（`rank/hot-drama`）。注意榜单页的 loaderData 里**没有**剧集数组
  /// （只有 `rankKey`/`updatedText`），条目全在 HTML 卡片里，走 HTML 兜底。
  Future<List<HongguoItem>> fetchHot() => fetchRank(kHongguoHotRank);

  /// 分类页，24 条/页，`page` 从 1 开始。
  Future<List<HongguoItem>> fetchCategory(String path, {int page = 1}) =>
      _fetchList('category/$path', page: page);

  /// 榜单页（`rank/hot-drama` 等），解析 HTML 卡片。
  Future<List<HongguoItem>> fetchRank(String path) async {
    final html = await _getHtml('$base/$path');
    final items = parseRankCards(html);
    if (items.isEmpty) {
      throw const FormatException('榜单页没有解析到条目（页面结构可能变了）');
    }
    return items;
  }

  Future<List<HongguoItem>> _fetchList(String path, {int page = 1}) async {
    final html = await _getHtml('$base/$path${page > 1 ? '?page=$page' : ''}');
    final data = parseRouterData(html);
    if (data == null) {
      throw const FormatException('页面结构变化：没有找到 _ROUTER_DATA');
    }
    final groups = routerGroups(data);
    if (groups.isEmpty) return const [];
    final list = groups.last['recommendList'];
    if (list is! List) return const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(HongguoItem.fromJson)
        .whereType<HongguoItem>()
        .toList();
  }

  /// 详情页 → 播放用的 [MediaResource]。
  ///
  /// [fallback] 是列表页拿到的卡片信息，详情页解析不全时用来兜底展示。
  Future<MediaResource> fetchDetail(String seriesId,
      {HongguoItem? fallback}) async {
    final html = await _getHtml('$base/detail?series_id=$seriesId');
    final data = parseRouterData(html);
    if (data == null) {
      throw const FormatException('页面结构变化：没有找到 _ROUTER_DATA');
    }
    final detail = _findDetail(groupsOf(data));
    if (detail == null) {
      throw const FormatException('没有解析到剧集信息（可能已下架或需要登录）');
    }
    return buildResource(detail, seriesId: seriesId, fallback: fallback);
  }

  /// 纯函数：把详情页的 `detail_$` 数据转成 [MediaResource]。
  /// 独立出来便于单测（不需要网络）。
  static MediaResource buildResource(
    Map<String, dynamic> detail, {
    required String seriesId,
    HongguoItem? fallback,
  }) {
    final series = detail['seriesDetail'];
    final sd = series is Map<String, dynamic> ? series : const <String, dynamic>{};
    final name = _text(sd['series_name']).isNotEmpty
        ? _text(sd['series_name'])
        : (fallback?.title ?? '红果短剧');
    final vids = <String>[];
    final rawVids = sd['vid_list'];
    if (rawVids is List) {
      for (final v in rawVids) {
        final id = _text(v);
        if (id.isNotEmpty) vids.add(id);
      }
    }
    final episodes = <Episode>[
      for (var i = 0; i < vids.length; i++)
        Episode(name: '第${i + 1}集', url: mp4UrlOf(vids[i])),
    ];
    final tags = sd['tags'];
    final intro = _stripTags(_text(sd['series_intro']));
    return MediaResource(
      siteId: siteId,
      siteName: siteName,
      vodId: seriesId,
      title: name,
      cover: _text(sd['series_cover']).isNotEmpty
          ? _text(sd['series_cover'])
          : (fallback?.cover ?? ''),
      remarks: _text(sd['episode_right_text']),
      typeName: tags is List
          ? tags.map(_text).where((e) => e.isNotEmpty).join(' / ')
          : '',
      intro: intro.isNotEmpty ? intro : (fallback?.intro ?? ''),
      groups: [
        if (episodes.isNotEmpty) PlayGroup(name: '红果短剧', episodes: episodes),
      ],
    );
  }

  /// 红果的固定播放地址规则（网页版只提供 360p）。
  static String mp4UrlOf(String vid) => '$base/video/public/$vid/360p.mp4';

  /// 从任意红果网址里取出 `series_id`（详情页、播放页都行）
  static String? seriesIdOf(String url) {
    final m = RegExp(r'series_id[=/](\d{5,})').firstMatch(url) ??
        RegExp(r'/detail[/?](\d{5,})').firstMatch(url) ??
        RegExp(r'/player/(\d{5,})').firstMatch(url);
    return m?.group(1);
  }

  Future<String> _getHtml(String url) async {
    final req = await _http.getUrl(Uri.parse(url));
    req.headers
      ..set('User-Agent', kBrowserUserAgent)
      ..set('Accept', 'text/html,application/xhtml+xml')
      ..set('Accept-Language', 'zh-CN,zh;q=0.9');
    final resp = await req.close().timeout(const Duration(seconds: 15));
    final bytes = await resp.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    if (resp.statusCode != 200) {
      throw HttpException('红果返回 HTTP ${resp.statusCode}');
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  static const String siteId = 'hongguo';
  static const String siteName = '红果短剧';

  void close() => _http.close();
}

/// 榜单页兜底解析：榜单卡片只在 SSR HTML 里（loaderData 没有数组）。
///
/// 卡片形如：
/// ```html
/// <article><a class="pc-cover-link-xxx" aria-label="查看X"
///   href="/detail?series_id=770…"><img src="封面" ...></a>
///   <h2 id="rank-title-770…" class="pc-title-xxx">剧名</h2>
///   …<li class="pc-status-tag-xxx">新剧</li>…<li>评分9.5</li>…<li>234.6万收藏</li>
/// ```
/// 按 `series_id` 切块，块内取第一个 `alt` 以「封面」结尾的图片地址、
/// `rank-title` 标题、`pc-…-tag` 徽标，最后用「评分/收藏/点赞」拼副标题。
List<HongguoItem> parseRankCards(String html) {
  final ids = <String>[];
  // 与 seriesIdOf 保持一致用 \d{5,}：站点目前都是 19 位，但早期剧集
  // 存在更短的 id，窄一点的量词会把它们整条漏掉。
  for (final m in RegExp(r'/detail\?series_id=(\d{5,})').allMatches(html)) {
    final id = m.group(1)!;
    if (!ids.contains(id)) ids.add(id);
  }
  final out = <HongguoItem>[];
  for (var i = 0; i < ids.length; i++) {
    final id = ids[i];
    final start = html.indexOf('/detail?series_id=$id');
    final end = i + 1 < ids.length
        ? html.indexOf('/detail?series_id=${ids[i + 1]}', start + 1)
        : -1;
    final block = html.substring(
        start, end > start ? end : (start + 4000).clamp(0, html.length));
    final title = RegExp(r'id="rank-title-[^"]*"[^>]*>([^<]+)<')
        .firstMatch(block)?.group(1)?.trim();
    if (title == null || title.isEmpty) continue;
    final cover = RegExp(r'<img[^>]*\ssrc="([^"]+)"[^>]*\salt="[^"]*封面"')
            .firstMatch(block)?.group(1) ??
        RegExp(r'alt="[^"]*封面"[^>]*\ssrc="([^"]+)"').firstMatch(block)?.group(1);
    final badge = RegExp(r'class="pc-[a-z]+-[^"]*tag[^"]*">([^<]{1,6})<')
        .firstMatch(block)?.group(1)?.trim();
    final score =
        RegExp(r'评分\s*([\d.]+)').firstMatch(block)?.group(1);
    final fav = RegExp(r'([\d.]+\s*万?)收藏').firstMatch(block)?.group(1);
    final tags = <String>[
      ?badge,
      if (score != null) '评分$score',
      if (fav != null) '$fav收藏',
    ];
    out.add(HongguoItem(
      seriesId: id,
      title: title,
      cover: cover ?? '',
      tags: tags,
    ));
  }
  return out;
}

/// 从 HTML 里抠出 `_ROUTER_DATA = {...}` 并解码。找不到返回 null。
/// 页面上有两处：
/// 1. `<div id="__MODERN_ROUTER_DATA__">` 里的 JSON —— 只有路由骨架；
/// 2. 页尾 `<script>` 里的 `_ROUTER_DATA = {...};` —— 真正的 loaderData。
/// 两处格式一样，统一取「最外层花括号配对」的那一段（后面还跟着函数定义，
/// 不能直接扔给 jsonDecode）。
Map<String, dynamic>? parseRouterData(String html) {
  final marker = html.indexOf('_ROUTER_DATA');
  if (marker < 0) return null;
  final start = html.indexOf('{', marker);
  if (start < 0) return null;
  final end = matchBrace(html, start);
  if (end < 0) return null;
  try {
    final decoded = jsonDecode(html.substring(start, end + 1));
    return decoded is Map<String, dynamic> ? decoded : null;
  } on FormatException {
    return null;
  }
}

/// 从 `{` 开始按配对（跳过字符串里的括号）找到对应 `}` 的下标，失败返回 -1。
int matchBrace(String s, int start) {
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = start; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (c == 0x5C) {
        escaped = true;
      } else if (c == 0x22) {
        inString = false;
      }
      continue;
    }
    if (c == 0x22) {
      inString = true;
    } else if (c == 0x7B) {
      depth++;
    } else if (c == 0x7D) {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

/// 取出 `loaderData` 里所有非空的数据组（key 形如 `category_$` / `detail_$`）。
List<Map<String, dynamic>> routerGroups(Map<String, dynamic> data) =>
    groupsOf(_asMap(data['loaderData']));

List<Map<String, dynamic>> groupsOf(Map<String, dynamic>? loader) {
  if (loader == null) return const [];
  return [
    for (final v in loader.values)
      if (v is Map<String, dynamic>) v,
  ];
}

Map<String, dynamic>? _findDetail(List<Map<String, dynamic>> groups) {
  for (final g in groups.reversed) {
    for (final v in g.values) {
      if (v is Map && v['seriesDetail'] is Map) return Map<String, dynamic>.from(v);
    }
    if (g['seriesDetail'] is Map) return g;
  }
  return null;
}

Map<String, dynamic>? _asMap(Object? v) =>
    v is Map<String, dynamic> ? v : (v is Map ? Map<String, dynamic>.from(v) : null);

int _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v?.toString() ?? '') ?? 0;
}

String _text(Object? v) => v == null ? '' : v.toString().trim();

String _stripTags(String s) => s
    .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
    .replaceAll(RegExp(r'<[^>]+>'), '')
    .replaceAll('&nbsp;', ' ')
    .trim();
