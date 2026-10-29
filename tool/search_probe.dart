// ignore_for_file: avoid_print
// 真实搜索探针：确认 search 接口/解析链路现在是否还通。
import 'package:hotshow/models/show_item.dart';
import 'package:hotshow/services/api_client.dart';
import 'package:hotshow/services/show_service.dart';

Future<void> main() async {
  final svc = ShowService();
  for (final kw in ['庆余年', '芙莉莲', '三体']) {
    try {
      final list = await svc.search(kw);
      print('search "$kw" -> ${list.length} 条');
      for (final it in list.take(3)) {
        print('   ${it.title} | ${it.rating} | cover=${it.cover.substring(0, it.cover.length.clamp(0, 60))}');
      }
    } catch (e, st) {
      print('search "$kw" -> ERR ${e.runtimeType}: $e');
      print(st.toString().split('\n').take(4).join('\n'));
    }
  }

  // 直接打接口，看原始返回
  try {
    final d = await ApiClient.instance.rexxarGet('/search', {
      'q': '庆余年',
      'start': '0',
      'count': '20',
    });
    final items = d['items'] as List? ?? [];
    print('raw rexxar /search -> ${items.length} items; first keys=${items.isNotEmpty ? (items.first as Map).keys.toList() : '-'}');
    if (items.isNotEmpty) {
      final it = ShowItem.fromCollectionJson(items.first);
      print('parsed: ${it?.title} / cover=${it?.cover}');
    }
  } catch (e) {
    print('raw rexxar /search -> ERR $e');
  }
  ApiClient.instance.close();
}
