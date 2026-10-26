// ignore_for_file: avoid_print
// 豆瓣图床连通性探针（不需要设备，dart run 直跑）：
//   dart run tool/image_probe.dart [图片URL]
//
// 背景：豆瓣图床的 WAF 会拒绝两类请求（403/418）——
//   1. User-Agent 不是浏览器；
//   2. 请求里出现两个 User-Agent（dart:io 会先自动加 `Dart/x.y`，
//      如果用 headers.add() 加浏览器 UA 就变成双 UA）。
// 这个探针对同一张图跑四种请求头组合，用来快速区分「头的问题」还是「网络的问题」。
import 'dart:io';

const url = 'https://img3.doubanio.com/view/photo/m_ratio_poster/public/p2936594830.jpg';
const ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
const accept = 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8';

Future<void> tryFetch(String label, void Function(HttpClientRequest) setup) async {
  final client = HttpClient()..autoUncompress = true;
  try {
    final req = await client.getUrl(Uri.parse(url));
    setup(req);
    final uaValues = req.headers[HttpHeaders.userAgentHeader];
    final resp = await req.close();
    final bytes = await resp.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    print('$label -> ${resp.statusCode} ${resp.headers.contentType} ${bytes.length}B  '
        'UA=$uaValues');
  } catch (e) {
    print('$label -> ERR $e');
  } finally {
    client.close(force: true);
  }
}

Future<void> main(List<String> args) async {
  if (args.isNotEmpty) {
    print('提示：本探针使用内置的示例图片地址，参数 $args 被忽略');
  }
  print('目标：$url\n');
  await tryFetch('1 默认 UA（预期 418）', (req) {});
  await tryFetch('2 set 浏览器 UA + Referer（预期 200）', (req) {
    req.headers.set('User-Agent', ua);
    req.headers.set('Accept', accept);
    req.headers.set('Referer', 'https://movie.douban.com/');
  });
  await tryFetch('3 add 浏览器 UA（双 UA，预期 403）', (req) {
    req.headers.add('User-Agent', ua);
    req.headers.add('Accept', accept);
    req.headers.add('Referer', 'https://movie.douban.com/');
  });
  await tryFetch('4 仅 Referer（预期 403）', (req) {
    req.headers.set('Referer', 'https://movie.douban.com/');
  });
}
