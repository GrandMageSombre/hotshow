/// 第三方影视采集站（maccms / 苹果CMS 协议）返回的资源模型。
///
/// 采集接口 `{api}?ac=detail&wd=片名` 的响应形如：
/// ```json
/// { "code": 1, "list": [ {
///     "vod_id": 12345, "vod_name": "庆余年", "vod_pic": "https://…jpg",
///     "vod_remarks": "更新至36集", "vod_year": "2019", "vod_area": "中国大陆",
///     "vod_play_from": "qiyi$$$m3u8",
///     "vod_play_url": "第01集$https://a/1.m3u8#第02集$https://a/2.m3u8$$$第01集$https://b/1.m3u8"
/// } ] }
/// ```
/// 其中 `vod_play_from`（线路名）与 `vod_play_url`（分集）都以 `$$$` 分组，
/// 组内以 `#` 分集、以 `$` 分隔「集名 / 播放地址」。
library;

/// 单集播放地址
class Episode {
  final String name;
  final String url;

  const Episode({required this.name, required this.url});

  /// 是否为 HLS（m3u8）地址
  bool get isHls => url.toLowerCase().contains('.m3u8');

  @override
  String toString() => '$name -> $url';
}

/// 一条播放线路（采集站里常叫「线路1」「m3u8」「量子」等）
class PlayGroup {
  final String name;
  final List<Episode> episodes;

  const PlayGroup({required this.name, required this.episodes});

  bool get isHls => episodes.any((e) => e.isHls);

  int get length => episodes.length;

  /// 线路质量粗判，用于默认选中：HLS 优先 → 集数多者优先
  int get quality => (isHls ? 100000 : 0) + episodes.length;

  @override
  String toString() => '$name(${episodes.length}集)';
}

/// 采集站返回的一条影视资源
class MediaResource {
  final String siteId;
  final String siteName;
  final String vodId;
  final String title;
  final String cover;
  final String remarks; // 例：更新至36集 / 全40集
  final String year;
  final String area;
  final String typeName;
  final String actor;
  final String director;
  final String intro;
  final List<PlayGroup> groups;

  const MediaResource({
    required this.siteId,
    required this.siteName,
    required this.vodId,
    required this.title,
    this.cover = '',
    this.remarks = '',
    this.year = '',
    this.area = '',
    this.typeName = '',
    this.actor = '',
    this.director = '',
    this.intro = '',
    this.groups = const [],
  });

  /// 全局唯一键：站点 + 资源 id
  String get key => '$siteId#$vodId';

  bool get playable => groups.any((g) => g.episodes.isNotEmpty);

  /// 集数取各线路中的最大值（不同线路可能更新进度不同）
  int get episodeCount =>
      groups.isEmpty ? 0 : groups.map((g) => g.length).reduce((a, b) => a > b ? a : b);

  String get subtitle {
    final parts = [
      if (year.isNotEmpty) year,
      if (area.isNotEmpty) area,
      if (typeName.isNotEmpty) typeName,
    ];
    return parts.join(' / ');
  }

  /// 默认线路：优先 HLS（m3u8）且集数最多的
  PlayGroup? get defaultGroup {
    if (groups.isEmpty) return null;
    final sorted = [...groups]..sort((a, b) => b.quality.compareTo(a.quality));
    return sorted.first;
  }

  PlayGroup? groupAt(int index) =>
      (index >= 0 && index < groups.length) ? groups[index] : null;

  /// 某条线路下有无缓存/下载意义的完整分集
  factory MediaResource.fromMaccmsJson(
    Map<String, dynamic> j, {
    required String siteId,
    required String siteName,
  }) {
    return MediaResource(
      siteId: siteId,
      siteName: siteName,
      vodId: _text(j['vod_id']),
      title: _text(j['vod_name']),
      cover: _text(j['vod_pic']),
      remarks: _text(j['vod_remarks']),
      year: _text(j['vod_year']),
      area: _text(j['vod_area']),
      typeName: _text(j['type_name'] ?? j['vod_class']),
      actor: _text(j['vod_actor']),
      director: _text(j['vod_director']),
      intro: _cleanIntro(_text(j['vod_content'] ?? j['vod_blurb'])),
      groups: parsePlayGroups(
        _text(j['vod_play_from']),
        _text(j['vod_play_url']),
      ),
    );
  }

  Map<String, dynamic> toJson() => {
        'siteId': siteId,
        'siteName': siteName,
        'vodId': vodId,
        'title': title,
        'cover': cover,
        'remarks': remarks,
        'year': year,
        'area': area,
        'typeName': typeName,
        'actor': actor,
        'director': director,
        'intro': intro,
        'groups': [
          for (final g in groups)
            {
              'name': g.name,
              'episodes': [
                for (final e in g.episodes) {'name': e.name, 'url': e.url},
              ],
            },
        ],
      };

  factory MediaResource.fromJson(Map<String, dynamic> j) => MediaResource(
        siteId: _text(j['siteId']),
        siteName: _text(j['siteName']),
        vodId: _text(j['vodId']),
        title: _text(j['title']),
        cover: _text(j['cover']),
        remarks: _text(j['remarks']),
        year: _text(j['year']),
        area: _text(j['area']),
        typeName: _text(j['typeName']),
        actor: _text(j['actor']),
        director: _text(j['director']),
        intro: _text(j['intro']),
        groups: [
          for (final g in (j['groups'] as List? ?? const []))
            if (g is Map)
              PlayGroup(
                name: _text(g['name']),
                episodes: [
                  for (final e in (g['episodes'] as List? ?? const []))
                    if (e is Map)
                      Episode(
                        name: _text(e['name']),
                        url: _text(e['url']),
                      ),
                ],
              ),
        ],
      );

  @override
  String toString() => 'MediaResource($siteName/$title/$episodeCount集)';
}

/// 把 maccms 的 `vod_play_from` + `vod_play_url` 解析成线路列表。
List<PlayGroup> parsePlayGroups(String from, String url) {
  if (url.trim().isEmpty) return const [];
  final fromNames = from.split(r'$$$');
  final rawGroups = url.split(r'$$$');
  final result = <PlayGroup>[];

  for (var i = 0; i < rawGroups.length; i++) {
    final raw = rawGroups[i].trim();
    if (raw.isEmpty) continue;

    final episodes = <Episode>[];
    for (final piece in raw.split('#')) {
      final item = piece.trim();
      if (item.isEmpty) continue;
      final sep = item.indexOf(r'$');
      String name;
      String link;
      if (sep < 0) {
        name = '';
        link = item;
      } else {
        name = item.substring(0, sep).trim();
        // 部分站点在地址后再跟 `$` 分隔的播放器标识，取第一段即可
        link = item.substring(sep + 1).split(r'$').first.trim();
      }
      if (link.isEmpty) continue;
      if (name.isEmpty) name = '第${episodes.length + 1}集';
      episodes.add(Episode(name: name, url: link));
    }
    if (episodes.isEmpty) continue;

    final rawName = i < fromNames.length ? fromNames[i].trim() : '';
    result.add(PlayGroup(
      name: rawName.isEmpty ? '线路${result.length + 1}' : rawName,
      episodes: episodes,
    ));
  }
  return result;
}

String _text(Object? v) {
  if (v == null) return '';
  if (v is String) return v.trim();
  return v.toString().trim();
}

/// 采集站的简介常带 HTML 标签与 `&nbsp;`
String _cleanIntro(String s) => s
    .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
    .replaceAll(RegExp(r'<[^>]+>'), '')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&ldquo;', '“')
    .replaceAll('&rdquo;', '”')
    .trim();
