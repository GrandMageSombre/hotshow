import '../models/show_item.dart';
import 'api_client.dart';

/// 首页大分类
enum HotTab {
  tv('电视剧'),
  shortDrama('短剧'),
  anime('动漫');

  final String label;
  const HotTab(this.label);
}

/// 大分类下的子榜单。sourceKind 决定走哪个接口：
/// - collection: rexxar subject_collection（编辑精选榜）
/// - frodoTag:   frodo tv/recommend tags（标签聚合）
class SubChannel {
  final String label;
  final String sourceKind;
  final String sourceId; // collection 名或 tag 名
  const SubChannel(this.label, this.sourceKind, this.sourceId);
}

const Map<HotTab, List<SubChannel>> kChannels = {
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
