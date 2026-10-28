// ignore_for_file: avoid_print
// 数据层集成测试：直接调用 ShowService 访问豆瓣真实接口。
// 运行：dart run tool/api_check.dart
// （无需 Flutter/模拟器，可在任何装有 Dart 的机器上验证数据源是否可用）
import 'package:hotshow/models/facet.dart';
import 'package:hotshow/models/genre.dart';
import 'package:hotshow/models/show_item.dart';
import 'package:hotshow/services/show_service.dart';

Future<void> checkTab(String name, List<Future<List<ShowItem>>> fns) async {
  for (final f in fns) {
    final list = await f;
    print('[$name] ${list.length} 条');
    for (final it in list.take(3)) {
      print('   - ${it.title}  评分:${it.rating ?? '-'}  ${it.subtitle}');
    }
  }
}

void main() async {
  final svc = ShowService();
  var failed = 0;

  Future<void> step(String label, Future<void> Function() fn) async {
    try {
      await fn();
    } catch (e) {
      failed++;
      print('[FAIL] $label => $e');
    }
  }

  await step('电视剧·热门榜', () async {
    final list = await svc.fetchHot(tab: HotTab.tv, channel: kChannels[HotTab.tv]![0]);
    print('  热门榜 ${list.length} 条，首条: ${list.first.title} (${list.first.rating})');
    if (list.isEmpty) throw Exception('空数据');
  });

  await step('电视剧·国产剧榜', () async {
    final list = await svc.fetchHot(tab: HotTab.tv, channel: kChannels[HotTab.tv]![1]);
    print('  国产剧 ${list.length} 条，首条: ${list.first.title}');
    if (list.isEmpty) throw Exception('空数据');
  });

  await step('短剧·热门短剧', () async {
    final list = await svc.fetchHot(tab: HotTab.shortDrama, channel: kChannels[HotTab.shortDrama]![0]);
    print('  短剧 ${list.length} 条，首条: ${list.first.title} (${list.first.rating})');
    if (list.isEmpty) throw Exception('空数据');
  });

  await step('动漫·热门动漫榜', () async {
    final list = await svc.fetchHot(tab: HotTab.anime, channel: kChannels[HotTab.anime]![0]);
    print('  动漫 ${list.length} 条，首条: ${list.first.title}');
    if (list.isEmpty) throw Exception('空数据');
  });

  await step('动漫·日本动画', () async {
    final list = await svc.fetchHot(tab: HotTab.anime, channel: kChannels[HotTab.anime]![1]);
    print('  日本动画 ${list.length} 条，首条: ${list.first.title}');
    if (list.isEmpty) throw Exception('空数据');
  });

  await step('动漫·国漫（多标签合并）', () async {
    final ch = kChannels[HotTab.anime]!.firstWhere((c) => c.label == '国漫');
    final list = await svc.fetchHot(tab: HotTab.anime, channel: ch);
    print('  国漫 ${list.length} 条，首条: ${list.isEmpty ? '-' : list.first.title}');
    if (list.length < 10) throw Exception('国漫条数过少 ${list.length}');
    final ids = list.map((e) => e.id).toSet();
    if (ids.length != list.length) throw Exception('国漫出现重复条目');
    if (list.any((e) => e.cover.contains('{'))) {
      throw Exception('国漫封面仍是 {large: ...} 伪地址');
    }
  });

  await step('动漫·欧美动画', () async {
    final ch = kChannels[HotTab.anime]!.firstWhere((c) => c.label == '欧美动画');
    final list = await svc.fetchHot(tab: HotTab.anime, channel: ch);
    print('  欧美动画 ${list.length} 条，首条: ${list.isEmpty ? '-' : list.first.title}');
    if (list.isEmpty) throw Exception('空数据');
  });

  await step('分类·电视剧「喜剧」', () async {
    final genre = kTvGenres.firstWhere((g) => g.label == '喜剧');
    final list = await svc.fetchByGenre(tab: HotTab.tv, genre: genre);
    print('  喜剧 ${list.length} 条，首条: ${list.first.title}');
    if (list.length < 10) throw Exception('条数不足');
    if (list.any((e) => e.cover.contains('{'))) {
      throw Exception('封面解析异常');
    }
  });

  await step('分类·电视剧「战争」翻页', () async {
    final genre = kTvGenres.firstWhere((g) => g.label == '战争');
    final p1 = await svc.fetchByGenre(tab: HotTab.tv, genre: genre);
    final p2 = await svc.fetchByGenre(tab: HotTab.tv, genre: genre, start: 21);
    final ids1 = p1.map((e) => e.id).toSet();
    final ids2 = p2.map((e) => e.id).toSet();
    print('  第 1 页 ${p1.length} 条 / 第 2 页 ${p2.length} 条，重叠 ${ids1.intersection(ids2).length}');
    if (p2.isEmpty) throw Exception('第 2 页无数据');
  });

  await step('分类·动漫「热血」', () async {
    final genre = kAnimeGenres.firstWhere((g) => g.label == '热血');
    final list = await svc.fetchByGenre(tab: HotTab.anime, genre: genre);
    print('  动漫热血 ${list.length} 条，首条: ${list.first.title}');
    if (list.length < 10) throw Exception('条数不足');
  });

  await step('分类·「全部」= 本大分类子榜单交织', () async {
    final list = await svc.fetchByGenre(tab: HotTab.tv, genre: kGenreAll);
    print('  电视剧全部 ${list.length} 条，首条: ${list.first.title}');
    if (list.length < 20) throw Exception('交织条数不足 ${list.length}');
    final ids = list.map((e) => e.id).toSet();
    if (ids.length != list.length) throw Exception('交织出现重复');
  });

  await step('电影·热门榜', () async {
    final list = await svc.fetchHot(
        tab: HotTab.movie, channel: kChannels[HotTab.movie]!.first);
    print('  电影热门 ${list.length} 条，首条: ${list.isEmpty ? '-' : list.first.title}');
    if (list.length < 10) throw Exception('条数不足');
    if (list.any((e) => e.isTv)) throw Exception('电影榜出现剧集条目');
    if (list.any((e) => e.cover.contains('{'))) throw Exception('封面解析异常');
  });

  await step('筛选·电视剧「喜剧」+ 美国 + 2024', () async {
    final list = await svc.fetchFiltered(
      tab: HotTab.tv,
      selection: const FilterSelection(
        genre: Genre('喜剧', '喜剧'),
        area: FacetOption('美国', '美国'),
        year: FacetOption('2024', '2024'),
      ),
    );
    print('  喜剧·美国·2024 ${list.length} 条，首条: ${list.first.title}');
    print('    ${list.first.subtitle}');
    if (list.isEmpty) throw Exception('组合筛选无数据');
  });

  await step('筛选·电影「战争」+ 2024', () async {
    final list = await svc.fetchFiltered(
      tab: HotTab.movie,
      selection: const FilterSelection(
        genre: Genre('战争', '战争'),
        year: FacetOption('2024', '2024'),
      ),
    );
    print('  电影战争·2024 ${list.length} 条，首条: ${list.first.title}');
    if (list.isEmpty) throw Exception('组合筛选无数据');
  });

  await step('筛选·「全部」+ 2024 同时包含剧集与电影', () async {
    final list = await svc.fetchFiltered(
      tab: HotTab.all,
      selection: const FilterSelection(
        year: FacetOption('2024', '2024'),
      ),
    );
    final tv = list.where((e) => e.isTv).length;
    final movie = list.where((e) => !e.isTv).length;
    print('  2024 全部 ${list.length} 条（剧 $tv / 影 $movie），首条: ${list.first.title}');
    if (tv == 0 || movie == 0) throw Exception('「全部」筛选没有同时覆盖剧和影');
  });

  await step('筛选·只选年份（类型=全部）', () async {
    final list = await svc.fetchFiltered(
      tab: HotTab.tv,
      selection: const FilterSelection(
        year: FacetOption('2025', '2025'),
      ),
    );
    print('  2025 年剧集 ${list.length} 条，首条: ${list.first.title}');
    if (list.length < 10) throw Exception('条数不足');
  });

  await step('分类·短剧「古装」（短剧前缀不串味）', () async {
    final genre = kShortDramaGenres.firstWhere((g) => g.label == '古装');
    final list = await svc.fetchByGenre(tab: HotTab.shortDrama, genre: genre);
    print('  短剧古装 ${list.length} 条，首条: ${list.first.title}');
    if (list.length < 10) throw Exception('条数不足');
    if (list.any((e) => e.title.contains('庆余年'))) {
      throw Exception('短剧分类混进长剧');
    }
  });

  await step('全部·聚合流', () async {
    final list = await svc.fetchAll(start: 0, count: 21);
    print('  聚合流 ${list.length} 条，首条: ${list.first.title} (${list.first.rating})');
    if (list.length < 10) throw Exception('聚合条数不足 ${list.length}');
    final ids = list.map((e) => e.id).toSet();
    if (ids.length != list.length) throw Exception('聚合流出现重复条目');
  });

  await step('全部·聚合流翻页', () async {
    final list = await svc.fetchAll(start: 21, count: 21);
    print('  聚合流第 2 页 ${list.length} 条，首条: ${list.isEmpty ? '-' : list.first.title}');
    if (list.isEmpty) throw Exception('翻页无数据');
  });

  ShowItem? first;
  await step('搜索「庆余年」', () async {
    final list = await svc.search('庆余年');
    first = list.firstOrNull;
    print('  搜索结果 ${list.length} 条:');
    for (final it in list.take(3)) {
      print('   - ${it.title}  评分:${it.rating ?? '-'}  ${it.subtitle}');
    }
    if (list.isEmpty) throw Exception('搜索无结果');
  });

  await step('详情接口', () async {
    if (first == null) throw Exception('依赖搜索结果');
    final d = await svc.detail(first!);
    print('  ${d.item.title} | ${d.item.rating}分 | ${d.genres.join("/")} | ${d.directors.join("/")} | 简介${d.intro.length}字');
    if (d.intro.isEmpty) throw Exception('详情无简介');
  });

  print(failed == 0 ? '\n全部通过 ✔' : '\n有 $failed 项失败 ✘');
}
