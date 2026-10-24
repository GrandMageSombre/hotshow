/// 影视条目模型。首页榜单（rexxar/frodo 两种来源）与搜索结果都归一化到这里。
class ShowItem {
  final String id;
  final String title;
  final String cover;
  final double? rating;
  final int? ratingCount;
  final String subtitle; // 例：2023 / 日本 / 动画 / 斋藤圭一郎 / 种崎敦美
  final String? comment; // 豆瓣热门短评（仅榜单接口提供）
  final bool isTv;

  const ShowItem({
    required this.id,
    required this.title,
    required this.cover,
    this.rating,
    this.ratingCount,
    this.subtitle = '',
    this.comment,
    this.isTv = true,
  });

  String get doubanUrl => 'https://movie.douban.com/subject/$id/';

  /// rexxar subject_collection 条目
  static ShowItem? fromCollectionJson(Map<String, dynamic> j) {
    final uri = j['uri'] as String? ?? '';
    final id = _idFromUri(uri) ?? (j['id']?.toString() ?? '');
    final title = j['title'] as String?;
    if (id.isEmpty || title == null || title.isEmpty) return null;
    final rating = j['rating'] as Map<String, dynamic>?;
    final pic = j['pic'] as Map<String, dynamic>?;
    return ShowItem(
      id: id,
      title: title,
      cover: (pic?['large'] ?? pic?['normal'] ?? '') as String,
      rating: (rating?['value'] as num?)?.toDouble(),
      ratingCount: rating?['count'] as int?,
      subtitle: j['card_subtitle'] as String? ?? '',
      comment: (j['comment'] as String?)?.trim().isEmpty == true
          ? null
          : j['comment'] as String?,
      isTv: uri.contains('/tv/'),
    );
  }

  /// frodo tv/recommend feed 条目
  static ShowItem? fromRecommendJson(Map<String, dynamic> j) {
    if (j['item_type'] != null && j['item_type'] != 'tv') return null;
    final uri = j['uri'] as String? ?? '';
    final id = _idFromUri(uri) ?? (j['id']?.toString() ?? '');
    final title = j['title'] as String?;
    if (id.isEmpty || title == null || title.isEmpty) return null;
    final rating = j['rating'] as Map<String, dynamic>?;
    return ShowItem(
      id: id,
      title: title,
      cover: j['cover_url'] as String? ?? j['pic']?.toString() ?? '',
      rating: (rating?['value'] as num?)?.toDouble(),
      ratingCount: rating?['count'] as int?,
      subtitle: j['card_subtitle'] as String? ?? '',
      isTv: !uri.contains('/movie/'),
    );
  }

  /// frodo search/subjects 结果条目
  static ShowItem? fromSearchJson(Map<String, dynamic> j) {
    final target = j['target'] as Map<String, dynamic>?;
    if (target == null) return null;
    final uri = target['uri'] as String? ?? '';
    final id = _idFromUri(uri) ?? target['id']?.toString() ?? '';
    final title = target['title'] as String?;
    if (id.isEmpty || title == null || title.isEmpty) return null;
    final rating = target['rating'] as Map<String, dynamic>?;
    return ShowItem(
      id: id,
      title: title,
      cover: target['cover_url'] as String? ?? '',
      rating: (rating?['value'] as num?)?.toDouble(),
      ratingCount: rating?['count'] as int?,
      subtitle: target['card_subtitle'] as String? ?? '',
      isTv: !uri.contains('/movie/'),
    );
  }

  static String? _idFromUri(String uri) {
    final m = RegExp(r'/(?:tv|movie)/(\d+)').firstMatch(uri);
    return m?.group(1);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'cover': cover,
        'rating': rating,
        'ratingCount': ratingCount,
        'subtitle': subtitle,
        'comment': comment,
        'isTv': isTv,
      };

  factory ShowItem.fromJson(Map<String, dynamic> j) => ShowItem(
        id: j['id'] as String,
        title: j['title'] as String,
        cover: j['cover'] as String? ?? '',
        rating: (j['rating'] as num?)?.toDouble(),
        ratingCount: j['ratingCount'] as int?,
        subtitle: j['subtitle'] as String? ?? '',
        comment: j['comment'] as String?,
        isTv: j['isTv'] as bool? ?? true,
      );

  @override
  bool operator ==(Object other) => other is ShowItem && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'ShowItem($id, $title)';
}

/// 详情页的完整信息（frodo /api/v2/tv/{id} 或 /api/v2/movie/{id}）
class ShowDetail {
  final ShowItem item;
  final String intro;
  final String cardSubtitle;
  final List<String> genres;
  final List<String> countries;
  final String pubdate;
  final int? episodesCount;
  final List<String> directors;
  final List<String> actors;
  final List<String> aka;
  final String durations;

  const ShowDetail({
    required this.item,
    required this.intro,
    required this.cardSubtitle,
    this.genres = const [],
    this.countries = const [],
    this.pubdate = '',
    this.episodesCount,
    this.directors = const [],
    this.actors = const [],
    this.aka = const [],
    this.durations = '',
  });

  factory ShowDetail.fromJson(Map<String, dynamic> j, {required bool isTv}) {
    List<String> names(List? l) =>
        (l ?? []).map((e) => e is Map ? (e['name'] ?? '').toString() : e.toString()).where((s) => s.isNotEmpty).toList();
    final rating = j['rating'] as Map<String, dynamic>?;
    return ShowDetail(
      item: ShowItem(
        id: j['id']?.toString() ?? '',
        title: j['title'] as String? ?? '',
        cover: j['cover_url'] as String? ?? (j['cover'] is Map ? (j['cover']['url'] ?? '') : '') as String,
        rating: (rating?['value'] as num?)?.toDouble(),
        ratingCount: rating?['count'] as int?,
        subtitle: j['card_subtitle'] as String? ?? '',
        isTv: isTv,
      ),
      intro: j['intro'] as String? ?? '',
      cardSubtitle: j['card_subtitle'] as String? ?? '',
      genres: (j['genres'] as List?)?.cast<String>() ?? const [],
      countries: (j['countries'] as List?)?.cast<String>() ?? const [],
      pubdate: j['pubdate']?.toString() ?? '',
      episodesCount: j['episodes_count'] as int?,
      directors: names(j['directors'] as List?),
      actors: names(j['actors'] as List?),
      aka: (j['aka'] as List?)?.cast<String>() ?? const [],
      durations: (j['durations'] as List?)?.cast<String>().join(' / ') ?? '',
    );
  }
}
