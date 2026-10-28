// ignore_for_file: avoid_print
// 探针：电影分类 / 地区 / 年份 facet 能否用 tags 组合表达。
import 'package:hotshow/models/show_item.dart';
import 'package:hotshow/services/api_client.dart';

Future<void> tag(String tags, {String kind = 'tv'}) async {
  try {
    final d = await ApiClient.instance.frodoGet('/api/v2/$kind/recommend', {
      'tags': tags, 'start': '0', 'count': '8', 'sort': 'T', 'refresh': '0',
    });
    final items = d['items'] as List? ?? [];
    final list = items
        .map((e) => kind == 'tv'
            ? ShowItem.fromRecommendJson(e as Map<String, dynamic>)
            : ShowItem.fromRecommendJson(e as Map<String, dynamic>))
        .whereType<ShowItem>()
        .toList();
    print('  [$kind] $tags -> ${list.length}  ${list.take(3).map((e) => e.title).join("、")}');
  } catch (e) {
    print('  [$kind] $tags -> ERR $e');
  }
}

Future<void> collection(String c) async {
  try {
    final d = await ApiClient.instance
        .rexxarGet('/subject_collection/$c/items', {'start': '0', 'count': '8'});
    final items = d['subject_collection_items'] as List? ?? [];
    print('  collection $c -> ${items.length}');
  } catch (e) {
    print('  collection $c -> ERR $e');
  }
}

Future<void> main() async {
  print('=== A) 电影 collection ===');
  for (final c in ['movie_hot', 'movie_showing', 'movie_soon', 'movie_top250', 'movie_hot_gaia']) {
    await collection(c);
  }

  print('\n=== B) 电影 tag 推荐 ===');
  for (final t in ['电影', '电影,喜剧', '电影,战争', '喜剧']) {
    await tag(t, kind: 'movie');
  }

  print('\n=== C) 地区 / 年份 能否作为 tag ===');
  for (final t in ['2024', '2025', '中国大陆', '美国', '喜剧,2024', '喜剧,中国大陆', '电影,2024']) {
    await tag(t);
  }

  print('\n=== D) sort 参数是否支持评分排序 ===');
  for (final s in ['T', 'S', 'R', 'U']) {
    try {
      final d = await ApiClient.instance.frodoGet('/api/v2/tv/recommend', {
        'tags': '喜剧', 'start': '0', 'count': '5', 'sort': s, 'refresh': '0',
      });
      final items = d['items'] as List? ?? [];
      final list = items
          .map((e) => ShowItem.fromRecommendJson(e as Map<String, dynamic>))
          .whereType<ShowItem>()
          .toList();
      print('  sort=$s -> ${list.length}  ${list.take(2).map((e) => "${e.title}(${e.rating})").join("、")}');
    } catch (e) {
      print('  sort=$s -> ERR $e');
    }
  }
  ApiClient.instance.close();
}
