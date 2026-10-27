// ignore_for_file: avoid_print
// 分类 / 图床探针：验证「按类型取片源」的接口可用性与海报可达性。
// 运行：dart run tool/genre_tag_probe.dart
import 'dart:convert';
import 'dart:io';

import 'package:hotshow/models/show_item.dart';
import 'package:hotshow/services/api_client.dart';
import 'package:hotshow/services/show_service.dart';

const genres = <String>[
  '喜剧', '爱情', '悬疑', '武侠', '古装', '战争', '犯罪', '科幻',
  '恐怖', '动画', '家庭', '历史', '动作', '奇幻', '青春', '剧情',
];

const collections = <String>[
  'tv_animation',
  'tv_animation_chinese',
  'tv_animation_japanese',
  'tv_animation_american',
  'tv_domestic',
  'tv_american',
  'tv_japanese',
  'tv_korean',
];

Future<int> probeImage(String url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.removeAll(HttpHeaders.userAgentHeader);
    req.headers.set(HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');
    req.headers.set('Referer', 'https://movie.douban.com/');
    final resp = await req.close().timeout(const Duration(seconds: 10));
    final n = await resp.fold<int>(0, (a, b) => a + b.length);
    return resp.statusCode * 1000000 + n;
  } catch (e) {
    print('    img err: $e');
    return -1;
  } finally {
    client.close(force: true);
  }
}

Future<void> main() async {
  final client = ApiClient.instance;
  final svc = ShowService();

  print('=== 1) frodo recommend 按 tag（类型）取数 ===');
  for (final g in genres) {
    try {
      final data = await client.frodoGet('/api/v2/tv/recommend', {
        'tags': g,
        'start': '0',
        'count': '20',
        'sort': 'T',
        'refresh': '0',
      });
      final items = (data['items'] as List? ?? []);
      final list = items.map((e) => ShowItem.fromRecommendJson(e as Map<String, dynamic>)).whereType<ShowItem>().toList();
      print('  $g -> raw ${items.length} / parsed ${list.length}'
          '${list.isNotEmpty ? '  e.g. ${list.take(3).map((e) => e.title).join("、")}' : ''}'
          '${list.isEmpty ? '  keys=${data.keys.toList()}' : ''}');
    } catch (e) {
      print('  $g -> ERR $e');
    }
  }

  print('\n=== 2) rexxar collection 变动检查 ===');
  for (final c in collections) {
    try {
      final data = await client.rexxarGet('/subject_collection/$c/items', {'start': '0', 'count': '20'});
      final items = data['subject_collection_items'] as List? ?? [];
      final list = items.map((e) => ShowItem.fromCollectionJson(e as Map<String, dynamic>)).whereType<ShowItem>().toList();
      print('  $c -> raw ${items.length} / parsed ${list.length}'
          '${list.isNotEmpty ? '  e.g. ${list.take(2).map((e) => e.title).join("、")}' : ''}');
    } catch (e) {
      print('  $c -> ERR $e');
    }
  }

  print('\n=== 3) 动漫各渠道条数（当前实现） ===');
  for (final ch in kChannels[HotTab.anime]!) {
    try {
      final l = await svc.fetchHot(tab: HotTab.anime, channel: ch);
      print('  ${ch.label}(${ch.sourceKind}:${ch.sourceId}) -> ${l.length}');
    } catch (e) {
      print('  ${ch.label} -> ERR $e');
    }
  }

  print('\n=== 4) 动漫海报可达性抽查（当前尝试链首步） ===');
  final anime = await svc.fetchHot(tab: HotTab.anime, channel: kChannels[HotTab.anime]!.first);
  for (final it in anime.take(8)) {
    final code = await probeImage(it.cover);
    print('  ${it.title} status=${code > 0 ? code ~/ 1000000 : "ERR"} bytes=${code > 0 ? code % 1000000 : 0}  ${it.cover}');
  }

  print('\n=== 5) 搜索结果里的动漫海报字段 ===');
  try {
    final list = await svc.search('芙莉莲');
    for (final it in list.take(5)) {
      final code = await probeImage(it.cover);
      print('  ${it.title} status=${code > 0 ? code ~/ 1000000 : "ERR"} ${it.cover}');
      print('    subtitle=${it.subtitle} isTv=${it.isTv}');
    }
  } catch (e) {
    print('  ERR $e');
  }

  client.close();
  debugDump();
}

void debugDump() {
  // 占位：方便以后加输出
  print(jsonEncode({'done': true}));
}
