// ignore_for_file: avoid_print
// 清晰度诊断：拿真实采集站搜一部片，打印各线路的地址与 m3u8 头部，
// 判断「没有多码率」还是「探测失败」。
// 用法：dart run tool/quality_diag.dart [片名]
import 'dart:convert';
import 'dart:io';

import 'package:hotshow/models/media_resource.dart';
import 'package:hotshow/models/source_site.dart';
import 'package:hotshow/services/quality_service.dart';
import 'package:hotshow/services/resource_service.dart';
import 'package:hotshow/services/remote_ua.dart';
import 'package:hotshow/services/source_discovery.dart';

const _catalog =
    'https://cdn.jsdelivr.net/gh/gaotianliuyun/gao@master/0821.json';

Future<String> _fetch(String url) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..autoUncompress = true;
  try {
    final uri = Uri.parse(url);
    final req = await client.getUrl(uri);
    req.headers.set('User-Agent', kBrowserUserAgent);
    req.headers.set('Referer', '${uri.scheme}://${uri.authority}/');
    final resp = await req.close().timeout(const Duration(seconds: 12));
    final bytes = await resp.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    return utf8.decode(bytes, allowMalformed: true);
  } finally {
    client.close(force: true);
  }
}

String _head(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';

Future<void> main(List<String> args) async {
  final keyword = args.isEmpty ? '赛博朋克' : args.first;
  print('== 取内置清单 ==');
  final catalog = await SourceDiscovery.instance.fetchCatalog(_catalog);
  print('候选 ${catalog.candidates.length} 个，警告 ${catalog.warnings.length} 条');
  final picked = catalog.candidates
      .where((c) => c.api.contains('provide/vod'))
      .take(24)
      .toList();

  final working = <SourceCandidate>[];
  for (final c in picked) {
    if (working.length >= 6) break;
    final r = await SourceDiscovery.instance.probe(c);
    if (r.ok) {
      working.add(c);
      print('可用: ${c.name} ${c.api} (${r.itemCount} 条, ${r.milliseconds}ms)');
    }
  }
  if (working.isEmpty) {
    print('没有可用站点，退出');
    return;
  }

  print('\n== 搜索「$keyword」 ==');
  final found = <(String, MediaResource)>[];
  for (final c in working) {
    final site = SourceSite(id: c.name, name: c.name, api: c.api);
    final result = await ResourceService.instance.searchSite(site, keyword);
    if (result.items.isEmpty) {
      print('${c.name}: 0 条${result.error == null ? '' : '（${result.error}）'}');
      continue;
    }
    for (final r in result.items.take(2)) {
      found.add((c.name, r));
      print('${c.name}: ${r.title} / ${r.groups.length} 线路 / '
          '${r.episodeCount} 集 / ${r.remarks}');
    }
  }

  print('\n== 逐线路看 m3u8 ==');
  var inspected = 0;
  for (final (siteName, resource) in found) {
    for (var gi = 0; gi < resource.groups.length && inspected < 8; gi++) {
      final g = resource.groups[gi];
      if (g.episodes.isEmpty) continue;
      final url = g.episodes.first.url;
      inspected++;
      final headers = {
        'User-Agent': kBrowserUserAgent,
        if (Uri.tryParse(url)?.hasAuthority ?? false)
          'Referer': '${Uri.parse(url).scheme}://${Uri.parse(url).authority}/',
      };
      final options = await qualityService.probe(url, headers: headers);
      print('\n[$siteName] 线路「${g.name}」第1集');
      print('  url   = $_head(url, 110)');
      print('  可选项 = ${options.length} 项 ${options.map((o) => o.label).toList()}');
      try {
        final text = await _fetch(url);
        final isMaster = text.contains('#EXT-X-STREAM-INF');
        print('  首行  = ${_head(text.trimLeft(), 90).replaceAll('\n', ' | ')}');
        print('  master变体 = $isMaster');
      } catch (e) {
        print('  裸抓失败 = $e');
      }
    }
  }
  ResourceService.instance.close();
  SourceDiscovery.instance.close();
}
