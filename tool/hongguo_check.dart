import 'dart:io';

import 'package:hotshow/services/hongguo_service.dart';
import 'package:hotshow/services/page_scraper.dart';

/// 红果 + 网页抓取的真实联网自检（`dart run tool/hongguo_check.dart [关键词/网址]`）
Future<void> main(List<String> args) async {
  final hg = HongguoService.instance;
  try {
    final hot = await hg.fetchHot();
    print('红果榜单: ${hot.length} 条');
    for (final e in hot.take(3)) {
      print('  ${e.seriesId}  ${e.title}  ${e.subtitle}');
    }
    if (hot.isNotEmpty) {
      final res = await hg.fetchDetail(hot.first.seriesId, fallback: hot.first);
      print('详情: ${res.title} / ${res.episodeCount} 集 / '
          '${res.groups.first.name}');
      print('  第1集 ${res.groups.first.episodes.first.url}');
    }
    final page2 = await hg.fetchCategory('real-drama', page: 2);
    print('真人剧第2页: ${page2.length} 条 → ${page2.first.title}');
  } catch (e) {
    print('红果失败: $e');
  }

  final scraper = PageScraper.instance;
  final target = args.isNotEmpty ? args.first : 'https://www.ikanbot.com/search?q=庆余年';
  try {
    final r = await scraper.grab(target);
    print('抓取 ${r.pageUrl} → ${r.title}');
    print('  视频 ${r.videos.length} 条，线路: '
        '${r.videos.map((e) => e.group).toSet().join(', ')}');
    for (final v in r.videos.take(3)) {
      print('  ${v.group} | ${v.note} | ${v.url}');
    }
    if (r.note != null) print('  备注: ${r.note}');
  } catch (e) {
    print('抓取失败: $e');
  }
  exit(0);
}
