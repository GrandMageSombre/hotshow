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
class SubChannel {
  final String label;
  final String sourceKind;
  final String sourceId; // collection 名或 tag 名
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
    SubChannel('日本动画', 'frodoTag', '日本动画'),
    SubChannel('国漫', 'frodoTag', '国漫'),
  ],
};

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
      final data = await client.frodoGet('/api/v2/tv/recommend', {
        'tags': channel.sourceId,
        'start': '$start',
        'count': '$count',
        'sort': 'T',
        'refresh': '0',
      });
      final list = (data['items'] as List? ?? [])
          .map((e) => ShowItem.fromRecommendJson(e))
          .whereType<ShowItem>()
          .toList();
      return list;
    }
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
