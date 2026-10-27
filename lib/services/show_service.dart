import '../models/genre.dart';
import '../models/show_item.dart';
import 'api_client.dart';

/// 首页大分类
enum HotTab {
  all('全部'),
  tv('电视剧'),
  shortDrama('短剧'),
  anime('动漫');

  final String label;
  const HotTab(this.label);
}

/// 大分类下的子榜单。sourceKind 决定走哪个接口：
/// - all:       全分类聚合（把其它大分类的所有子榜单轮播交织成一列）
/// - collection: rexxar subject_collection（编辑精选榜）
/// - frodoTag:   frodo tv/recommend tags（标签聚合）
/// - multiTag:  多个 tag 各自取一页再轮播交织（用于「国漫」这类单标签过少的分类，
///              sourceId 用 `|` 分隔多个 tag）
class SubChannel {
  final String label;
  final String sourceKind;
  final String sourceId; // collection 名 / tag 名 / tag1|tag2|tag3
  const SubChannel(this.label, this.sourceKind, this.sourceId);
}

const Map<HotTab, List<SubChannel>> kChannels = {
  HotTab.all: [SubChannel('全部', 'all', 'all')],
  HotTab.tv: [
    SubChannel('热门', 'collection', 'tv_hot'),
    SubChannel('国产剧', 'collection', 'tv_domestic'),
    SubChannel('美剧', 'collection', 'tv_american'),
    SubChannel('日剧', 'collection', 'tv_japanese'),
    SubChannel('韩剧', 'collection', 'tv_korean'),
    SubChannel('综艺', 'collection', 'tv_variety_show'),
    SubChannel('纪录片', 'collection', 'tv_documentary'),
  ],
  HotTab.shortDrama: [
    SubChannel('热门短剧', 'frodoTag', '短剧'),
    SubChannel('网络剧', 'frodoTag', '网络剧'),
  ],
  HotTab.anime: [
    SubChannel('热门动漫', 'collection', 'tv_animation'),
    SubChannel('日本动画', 'frodoTag', '动画,日本'),
    // 国漫单用「国漫」标签只有 3 条，合并三个同义标签后再交织去重
    SubChannel('国漫', 'multiTag', '国产动画|国漫|中国动画'),
    SubChannel('欧美动画', 'frodoTag', '动画,美国'),
  ],
};

/// 某大分类可用的「片源类型」。短剧/动漫各有专用标签前缀，
/// 直接复用电视剧类型会串味（「古装」会返回长剧，「热血」会返回真人剧）。
List<Genre> genresOf(HotTab tab) {
  switch (tab) {
    case HotTab.anime:
      return kAnimeGenres;
    case HotTab.shortDrama:
      return kShortDramaGenres;
    case HotTab.all:
    case HotTab.tv:
      return kTvGenres;
  }
}

/// 把多份榜单按「轮播交织」合并成一列：第 i 轮取各榜单的第 i 条，
/// 按 id 去重（保留首次出现），再切出 [start, start+count) 一页。
/// 纯函数，便于单测。
List<ShowItem> mergeShowPages(
  List<List<ShowItem>> pages, {
  int start = 0,
  int count = 21,
}) {
  final maxLen = pages.fold<int>(0, (m, l) => l.length > m ? l.length : m);
  final merged = <ShowItem>[];
  final seen = <String>{};
  for (var i = 0; i < maxLen; i++) {
    for (final list in pages) {
      if (i >= list.length) continue;
      final item = list[i];
      if (item.id.isNotEmpty && seen.add(item.id)) merged.add(item);
    }
  }
  if (start >= merged.length) return const [];
  return merged.skip(start).take(count).toList();
}

/// 业务数据层：榜单、搜索、详情。
/// 不依赖 Flutter，可在纯 Dart 环境下运行（见 tool/api_check.dart）。
class ShowService {
  final ApiClient client;
  ShowService([ApiClient? client]) : client = client ?? ApiClient.instance;

  /// 拉取某一子榜单的一页数据
  Future<List<ShowItem>> fetchHot({
    required HotTab tab,
    required SubChannel channel,
    int start = 0,
    int count = 21,
  }) async {
    if (channel.sourceKind == 'all') {
      return fetchAll(start: start, count: count);
    }
    if (channel.sourceKind == 'multiTag') {
      final tags = channel.sourceId
          .split('|')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      if (tags.isEmpty) return const [];
      // 每个标签都从头取满一页：单标签可能只有 2~3 条（如「国漫」），
      // 按 (start+count)/标签数 分摊会导致交织后凑不够一屏
      final per = count;
      final pages = await Future.wait([
        for (final t in tags)
          _tagFeed(t, start: 0, count: per)
              .then<List<ShowItem>>((l) => l)
              .catchError((Object _) => <ShowItem>[]),
      ]);
      return mergeShowPages(pages, start: start, count: count);
    }
    if (channel.sourceKind == 'collection') {
      final data = await client.rexxarGet(
        '/subject_collection/${channel.sourceId}/items',
        {'start': '$start', 'count': '$count'},
      );
      final list = (data['subject_collection_items'] as List? ?? [])
          .map((e) => ShowItem.fromCollectionJson(e))
          .whereType<ShowItem>()
          .toList();
      if (list.isEmpty && start == 0) {
        throw ApiException('榜单暂无数据，请稍后重试');
      }
      return list;
    } else {
      return _tagFeed(channel.sourceId, start: start, count: count);
    }
  }

  /// frodo 推荐流按标签取一页。分类（类型）与子榜单共用这条接口。
  Future<List<ShowItem>> _tagFeed(
    String tags, {
    int start = 0,
    int count = 21,
  }) async {
    final data = await client.frodoGet('/api/v2/tv/recommend', {
      'tags': tags,
      'start': '$start',
      'count': '$count',
      'sort': 'T',
      'refresh': '0',
    });
    return (data['items'] as List? ?? [])
        .map((e) => ShowItem.fromRecommendJson(e))
        .whereType<ShowItem>()
        .toList();
  }

  /// 按「片源类型」取一页数据；[Genre.isAll] 时回落成**该大分类下所有子榜单的交织**，
  /// 而不是单个默认榜单 —— 否则「全部类型」只是「热门榜」的别名，名不副实。
  Future<List<ShowItem>> fetchByGenre({
    required HotTab tab,
    required Genre genre,
    int start = 0,
    int count = 21,
  }) {
    if (!genre.isAll) return _tagFeed(genre.tag!, start: start, count: count);
    if (tab == HotTab.all) return fetchAll(start: start, count: count);
    return _mixChannels(tab, start: start, count: count);
  }

  /// 把某大分类下的所有子榜单轮播交织成一列（「全部类型」用）
  Future<List<ShowItem>> _mixChannels(
    HotTab tab, {
    int start = 0,
    int count = 21,
  }) async {
    final channels = kChannels[tab] ?? const <SubChannel>[];
    if (channels.isEmpty) return const [];
    if (channels.length == 1) {
      return fetchHot(
        tab: tab,
        channel: channels.first,
        start: start,
        count: count,
      );
    }
    final per = count > (start + count) ~/ channels.length + 1
        ? count
        : (start + count) ~/ channels.length + 1;
    final pages = await Future.wait([
      for (final c in channels)
        fetchHot(tab: tab, channel: c, start: 0, count: per)
            .then<List<ShowItem>>((l) => l)
            .catchError((Object _) => <ShowItem>[]),
    ]);
    return mergeShowPages(pages, start: start, count: count);
  }

  /// 「全部」聚合流：把其它大分类的所有子榜单**轮播交织**成一列。
  ///
  /// 分页策略：请求第 [start] 页时，每个子榜单都从头取够
  /// `(start + count) / 榜单数 + 1` 条（保证交织前缀逐页稳定），
  /// 按 id 去重后切片，因此同一部剧不会重复出现。
  /// 单个榜单失败只影响它自己（返回空列表），不拖垮整页。
  Future<List<ShowItem>> fetchAll({int start = 0, int count = 21}) async {
    final channels = <SubChannel>[
      for (final entry in kChannels.entries)
        if (entry.key != HotTab.all) ...entry.value,
    ];
    if (channels.isEmpty) return const [];
    final per = (start + count) ~/ channels.length + 1;
    final pages = await Future.wait([
      for (final c in channels)
        fetchHot(tab: HotTab.all, channel: c, start: 0, count: per)
            .then<List<ShowItem>>((l) => l)
            .catchError((Object _) => <ShowItem>[]),
    ]);
    return mergeShowPages(pages, start: start, count: count);
  }

  /// 关键词搜索（影视综合结果：电视剧/动漫/电影）
  Future<List<ShowItem>> search(String keyword, {int start = 0, int count = 20}) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return const [];
    final data = await client.frodoGet('/api/v2/search/subjects', {
      'q': kw,
      'start': '$start',
      'count': '$count',
    });
    final list = (data['items'] as List? ?? [])
        .map((e) => ShowItem.fromSearchJson(e))
        .whereType<ShowItem>()
        .toList();
    return list;
  }

  /// 条目详情
  Future<ShowDetail> detail(ShowItem item) async {
    final kind = item.isTv ? 'tv' : 'movie';
    final data = await client.frodoGet('/api/v2/$kind/${item.id}');
    return ShowDetail.fromJson(data, isTv: item.isTv);
  }
}
