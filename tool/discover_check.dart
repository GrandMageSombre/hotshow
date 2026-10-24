// ignore_for_file: avoid_print
// 采集站清单验证：拉取清单 → 解析候选 → 并发探测，打印可用站点。
//   dart run tool/discover_check.dart <清单地址>
//
// 例：
//   dart run tool/discover_check.dart https://example.com/sites.json
//   dart run tool/discover_check.dart https://example.com/sites.txt
import 'package:hotshow/services/source_discovery.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    print('用法: dart run tool/discover_check.dart <清单地址>');
    print('例:   dart run tool/discover_check.dart https://example.com/sites.json');
    return;
  }

  final url = args.first;
  final discovery = SourceDiscovery.instance;

  print('清单: $url');
  final catalog = await discovery.fetchCatalog(url);
  for (final w in catalog.warnings) {
    print('[WARN] $w');
  }
  if (catalog.candidates.isEmpty) {
    print('\n没有解析出任何候选地址 ✘');
    discovery.close();
    return;
  }
  print('解析出 ${catalog.candidates.length} 个候选地址，开始并发探测…\n');

  final results = await discovery.probeAll(catalog.candidates).toList();
  results.sort((a, b) {
    if (a.ok != b.ok) return a.ok ? -1 : 1;
    if (a.ok) return a.milliseconds.compareTo(b.milliseconds);
    return a.candidate.name.compareTo(b.candidate.name);
  });

  var usable = 0;
  for (final r in results) {
    if (r.ok) {
      usable++;
      print('[ OK ] ${r.candidate.name}  ${r.milliseconds}ms  '
          '约 ${r.itemCount} 条\n        ${r.candidate.api}');
    } else {
      print('[FAIL] ${r.candidate.name}  ${r.error}\n'
          '        ${r.candidate.api}');
    }
  }

  discovery.close();
  print('\n可用 $usable / ${results.length}'
      '${usable == 0 ? '  没有可用站点 ✘' : '  ✔'}');
}
