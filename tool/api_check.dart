// ignore_for_file: avoid_print
// 数据层集成测试：直接调用 ShowService 访问豆瓣真实接口。
// 运行：dart run tool/api_check.dart
// （无需 Flutter/模拟器，可在任何装有 Dart 的机器上验证数据源是否可用）
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
