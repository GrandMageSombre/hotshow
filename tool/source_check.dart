// ignore_for_file: avoid_print
// 采集站连通性 & 检索验证：不需要设备与 Flutter 运行时，直接跑
//   dart run tool/source_check.dart <采集接口地址> [片名]
//
// 例：
//   dart run tool/source_check.dart https://example.com/api.php/provide/vod/ 庆余年
//
// 用于确认自己填的接口地址是否可用、能否拿到「完整剧集」的播放地址。
import 'package:hotshow/models/source_site.dart';
import 'package:hotshow/services/resource_service.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    print('用法: dart run tool/source_check.dart <采集接口地址> [片名]');
    print('例:   dart run tool/source_check.dart '
        'https://example.com/api.php/provide/vod/ 庆余年');
    return;
  }

  final api = args.first;
  final keyword =
      args.length > 1 && args[1].trim().isNotEmpty ? args[1].trim() : '庆余年';

  if (!SourceSite.isValidApi(api)) {
    print('[FAIL] 接口地址不合法：$api');
    return;
  }

  final site = SourceSite(id: 'cli', name: 'CLI 站点', api: api);
  final svc = ResourceService.instance;
  var failed = 0;

  print('站点: $api');
  final pingError = await svc.ping(site);
  if (pingError != null) {
    failed++;
    print('[FAIL] 连通性：$pingError');
  } else {
    print('[ OK ] 连通性正常');
  }

  final result = await svc.searchSite(site, keyword);
  if (!result.ok) {
    failed++;
    print('[FAIL] 检索「$keyword」：${result.error}');
  } else if (result.items.isEmpty) {
    print('[WARN] 检索「$keyword」没有命中（换关键词或换站点试试）');
  } else {
    print('[ OK ] 检索「$keyword」命中 ${result.items.length} 条');
    for (final r in rankResources(result.items, keyword).take(5)) {
      print('   - ${r.title}  ${r.year}  ${r.remarks}  '
          '${r.groups.length} 线路 / ${r.episodeCount} 集');
      final g = r.defaultGroup;
      if (g != null && g.episodes.isNotEmpty) {
        print('     默认线路「${g.name}」首集：${g.episodes.first.url}');
      }
    }
  }

  svc.close();
  print(failed == 0 ? '\n全部通过 ✔' : '\n有 $failed 项失败 ✘');
}
