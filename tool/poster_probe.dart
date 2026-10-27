// ignore_for_file: avoid_print
// 图床探针 3：验证豆瓣签名图（qnmob*-sign）转成稳定 img*.doubanio.com 地址的可行性，
// 并检查动漫各渠道封面是否可达。
// 运行：dart run tool/poster_probe.dart
import 'dart:io';

import 'package:hotshow/models/show_item.dart';
import 'package:hotshow/services/show_service.dart';

const ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

Future<String> probe(String url, {bool withHeaders = true, bool bare = false}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client.getUrl(Uri.parse(url));
    if (bare) {
      req.headers.removeAll(HttpHeaders.userAgentHeader);
    } else if (withHeaders) {
      req.headers.set(HttpHeaders.userAgentHeader, ua);
      req.headers.set('Referer', 'https://movie.douban.com/');
    }
    final resp = await req.close().timeout(const Duration(seconds: 10));
    final n = await resp.fold<int>(0, (a, b) => a + b.length);
    return '${resp.statusCode} ${n}B';
  } catch (e) {
    return 'ERR $e';
  } finally {
    client.close(force: true);
  }
}

/// 抽出 p\d+ 图片 id 与可能的尺寸段
List<String> stableVariants(String url) {
  final m = RegExp(r'/view/photo/([^/]+)/public/(p\d+)\.(jpg|webp|png)').firstMatch(url);
  if (m == null) return const [];
  final id = m.group(2)!;
  return [
    'https://img1.doubanio.com/view/photo/l_ratio_poster/public/$id.jpg',
    'https://img2.doubanio.com/view/photo/l_ratio_poster/public/$id.jpg',
    'https://img3.doubanio.com/view/photo/l_ratio_poster/public/$id.jpg',
    'https://img9.doubanio.com/view/photo/l_ratio_poster/public/$id.jpg',
    'https://img1.doubanio.com/view/photo/large/public/$id.jpg',
    'https://img1.doubanio.com/view/photo/m/public/$id.jpg',
  ];
}

Future<void> main() async {
  final svc = ShowService();

  print('=== 1) 搜索结果签名图（qnmob*-sign） ===');
  final hits = await svc.search('芙莉莲');
  for (final it in hits.take(2)) {
    print('  ${it.title}');
    print('    原始: ${await probe(it.cover)}  ${it.cover}');
    print('    原始(裸): ${await probe(it.cover, bare: true)}');
    for (final v in stableVariants(it.cover)) {
      print('    ${await probe(v)}  $v');
    }
  }

  print('\n=== 2) 动漫各渠道封面（前 3 条） ===');
  for (final ch in kChannels[HotTab.anime]!) {
    List<ShowItem> list = const [];
    try {
      list = await svc.fetchHot(tab: HotTab.anime, channel: ch);
    } catch (e) {
      print('  ${ch.label} ERR $e');
      continue;
    }
    print('  ${ch.label} (${list.length} 条)');
    for (final it in list.take(3)) {
      print('    ${await probe(it.cover)}  ${it.cover}');
    }
  }

  print('\n=== 3) 类型 tag 在动漫下的组合 ===');
  for (final t in ['动画,热血', '动画,治愈', '动画,战斗', '动画,冒险', '动画,搞笑']) {
    try {
      final d = await ShowService().client.frodoGet('/api/v2/tv/recommend', {
        'tags': t, 'start': '0', 'count': '10', 'sort': 'T', 'refresh': '0',
      });
      final items = d['items'] as List? ?? [];
      final list = items
          .map((e) => ShowItem.fromRecommendJson(e as Map<String, dynamic>))
          .whereType<ShowItem>()
          .toList();
      print('  $t -> ${list.length}  ${list.take(3).map((e) => e.title).join("、")}');
    } catch (e) {
      print('  $t -> ERR $e');
    }
  }

  svc.client.close();
}
