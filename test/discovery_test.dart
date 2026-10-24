// 采集站自动发现测试：清单解析（纯文本 / JSON / TVBox 风格）与并发探测。
// 探测部分使用本地假服务，不访问外网。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotshow/services/source_discovery.dart';

void main() {
  setUp(() {
    // flutter_test 默认把 HttpClient 换成「一律 400」的桩，这里恢复真实实现
    HttpOverrides.global = null;
  });

  group('候选清单解析', () {
    test('纯文本：每行一个地址，忽略注释与空行', () {
      final list = SourceDiscovery.parseCatalog('''
# 采集站清单
https://a.example.com/api.php/provide/vod/

// 另一种注释
https://b.example.com/api.php/provide/vod/
''');
      expect(list.length, 2);
      expect(list[0].api, 'https://a.example.com/api.php/provide/vod/');
      expect(list[0].name, 'a.example.com');
      expect(list[1].name, 'b.example.com');
    });

    test('纯文本：站点名 | 地址、行尾注释、裸域名自动补全', () {
      final list = SourceDiscovery.parseCatalog('''
站点A | https://a.example.com/api.php/provide/vod/
站点B,https://b.example.com/api.php/provide/vod/
c.example.com
https://d.example.com  # 只给站点根
''');
      expect(list.length, 4);
      expect(list[0].name, '站点A');
      expect(list[0].api, 'https://a.example.com/api.php/provide/vod/');
      expect(list[1].name, '站点B');
      // 裸域名按 maccms 约定补全
      expect(list[2].api, 'https://c.example.com/api.php/provide/vod/');
      expect(list[3].api, 'https://d.example.com/api.php/provide/vod/');
    });

    test('JSON 数组：字符串与对象混排', () {
      final list = SourceDiscovery.parseCatalog(jsonEncode([
        'https://a.example.com/api.php/provide/vod',
        {'name': '站点B', 'api': 'https://b.example.com/api.php/provide/vod/'},
      ]));
      expect(list.length, 2);
      expect(list[0].name, 'a.example.com');
      expect(list[1].name, '站点B');
      expect(list[1].api, 'https://b.example.com/api.php/provide/vod');
    });

    test('JSON 对象：{"sites":[…]} 与 {"data":{…}} 都能取到', () {
      final list = SourceDiscovery.parseCatalog(jsonEncode({
        'code': 1,
        'sites': [
          {'name': 'A', 'api': 'https://a.example.com/api.php/provide/vod/'},
        ],
        'data': [
          {'name': 'B', 'url': 'https://b.example.com/api.php/provide/vod/'},
        ],
      }));
      expect(list.length, 2);
      expect(list.map((c) => c.name), containsAll(['A', 'B']));
    });

    test('TVBox 风格：api 是类型名时从 ext.site 还原采集地址', () {
      final list = SourceDiscovery.parseCatalog(jsonEncode({
        'sites': [
          {
            'key': 'csp_A',
            'name': '站点A',
            'type': 3,
            'api': 'csp_XBPQ',
            'ext': '{"site":"https://a.example.com"}',
          },
          {
            'key': 'csp_B',
            'name': '站点B',
            'type': 3,
            'api': 'https://b.example.com/api.php/provide/vod/',
            'ext': {},
          },
          {
            'key': 'csp_C',
            'name': '没有地址的项',
            'api': 'csp_AppYsV2',
            'ext': '{"key":"abc"}',
          },
        ],
      }));
      expect(list.length, 2);
      expect(list[0].api, 'https://a.example.com/api.php/provide/vod');
      expect(list[1].api, 'https://b.example.com/api.php/provide/vod');
    });

    test('去重：忽略协议、大小写、末尾斜杠与查询串', () {
      final list = SourceDiscovery.parseCatalog('''
https://a.example.com/api.php/provide/vod/
http://a.example.com/api.php/provide/vod
站点A | https://A.EXAMPLE.COM/api.php/provide/vod/?token=1
''');
      expect(list.length, 1);
      expect(list.single.name, 'a.example.com');
    });

    test('去重保留非默认端口，默认端口视为等同', () {
      final list = SourceDiscovery.parseCatalog('''
http://127.0.0.1:8080/api.php/provide/vod/
http://127.0.0.1:9090/api.php/provide/vod/
https://b.example.com:443/api.php/provide/vod/
https://b.example.com/api.php/provide/vod/
''');
      expect(list.length, 3);
      expect(
        list.map((c) => SourceDiscovery.normalizeApi(c.api)).toSet(),
        hasLength(3),
      );
    });

    test('非地址内容不会产出候选', () {
      expect(SourceDiscovery.parseCatalog('hello world\nftp://x/y'), isEmpty);
      expect(SourceDiscovery.parseCatalog(''), isEmpty);
    });

    test('TVBox 风格：ext 是纯 URL 字符串时直接当站点地址', () {
      final list = SourceDiscovery.parseCatalog(jsonEncode({
        'sites': [
          {
            'key': 'zxzj',
            'name': '在线┃秒播',
            'type': 3,
            'api': 'csp_Zxzj',
            'ext': 'https://www.zxzjhd.com/',
          },
          {
            'key': 'cz',
            'name': '厂长┃不卡',
            'type': 3,
            'api': 'csp_NewCz',
            'ext': 'https://www.czzy77.com/',
          },
        ],
      }));
      expect(list.length, 2);
      expect(list[0].name, '在线┃秒播');
      expect(list[0].api, 'https://www.zxzjhd.com/api.php/provide/vod');
      expect(list[1].api, 'https://www.czzy77.com/api.php/provide/vod');
    });

    test('TVBox 风格：ext 对象里的 siteUrl 也算站点地址', () {
      final list = SourceDiscovery.parseCatalog(jsonEncode({
        'sites': [
          {
            'key': 'wogg',
            'name': '玩偶哥哥',
            'api': 'csp_WoGG',
            'ext': {'siteUrl': 'https://www.wogg.net/', 'from': '4k|auto'},
          },
        ],
      }));
      expect(list.length, 1);
      expect(list.single.api, 'https://www.wogg.net/api.php/provide/vod');
    });

    test('跳过 drpy/JS 脚本源与本地相对路径脚本', () {
      final list = SourceDiscovery.parseCatalog(jsonEncode({
        'sites': [
          {
            'key': 'a',
            'name': 'JS 源',
            'api': 'https://notabug.org/x/ext/raw/main/drpy2.min.js',
            'ext': 'https://notabug.org/x/ext/raw/main/a.js',
          },
          {
            'key': 'b',
            'name': '本地脚本源',
            'api': './lib/drpy2.min.js',
            'ext': './js/a.js',
          },
          {
            'key': 'c',
            'name': '真采集站',
            'api': 'https://real.example.com/api.php/provide/vod/',
          },
        ],
      }));
      expect(list.length, 1);
      expect(list.single.name, '真采集站');
    });

    test('maccms 的 at/xml 后缀被归一化为默认 JSON 接口', () {
      final list = SourceDiscovery.parseCatalog(jsonEncode({
        'sites': [
          {
            'key': 'lz',
            'name': '量子',
            'api': 'https://cj.lziapi.com/api.php/provide/vod/at/xml/',
          },
          {
            'key': 'ff',
            'name': '非凡',
            'api': 'http://cj.ffzyapi.com/api.php/provide/vod/at/xml/',
          },
        ],
      }));
      expect(list.length, 2);
      expect(list[0].api, 'https://cj.lziapi.com/api.php/provide/vod');
      expect(list[1].api, 'http://cj.ffzyapi.com/api.php/provide/vod');
    });

    test('站点地址上的查询参数被保留', () {
      final list = SourceDiscovery.parseCatalog(jsonEncode({
        'sites': [
          {
            'key': 'bd',
            'name': '百度采集',
            'api': 'https://api.apibdzy.com/api.php/provide/vod?ac=list',
          },
        ],
      }));
      expect(
        list.single.api,
        'https://api.apibdzy.com/api.php/provide/vod?ac=list',
      );
    });
  });

  group('站点探测', () {
    late HttpServer server;

    Future<void> startServer({
      required Map<String, dynamic> Function(String path) handler,
    }) async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(handler(req.uri.path)));
        await req.response.close();
      });
    }

    tearDown(() => server.close(force: true));

    String apiOf() => 'http://127.0.0.1:${server.port}/api.php/provide/vod/';

    test('可用的 maccms 站点被标记为可用并带上数据量', () async {
      await startServer(handler: (_) => {
            'code': 1,
            'msg': '数据列表',
            'total': 12345,
            'list': [
              {'vod_id': 1, 'vod_name': 'x'},
            ],
          });
      final discovery = SourceDiscovery.withClient(HttpClient());
      final r = await discovery.probe(
        SourceCandidate(name: '本地站', api: apiOf()),
      );
      expect(r.ok, isTrue);
      expect(r.usable, isTrue);
      expect(r.itemCount, 12345);
      expect(r.milliseconds, greaterThanOrEqualTo(0));
    });

    test('返回非 maccms 结构时给出原因', () async {
      await startServer(handler: (_) => {'hello': 'world'});
      final discovery = SourceDiscovery.withClient(HttpClient());
      final r = await discovery.probe(
        SourceCandidate(name: '伪站', api: apiOf()),
      );
      expect(r.ok, isFalse);
      expect(r.error, contains('缺少 list'));
    });

    test('code != 1 时把站点给的说明带出来', () async {
      await startServer(handler: (_) => {'code': 0, 'msg': '站点维护中'});
      final discovery = SourceDiscovery.withClient(HttpClient());
      final r = await discovery.probe(
        SourceCandidate(name: '维护中', api: apiOf()),
      );
      expect(r.ok, isFalse);
      expect(r.error, contains('站点维护中'));
    });

    test('已在站点列表中的地址标记为已添加、不再请求', () async {
      final discovery = SourceDiscovery.withClient(HttpClient());
      const api = 'https://a.example.com/api.php/provide/vod/';
      final r = await discovery.probe(
        const SourceCandidate(name: 'A', api: api),
        existing: {SourceDiscovery.normalizeApi(api)},
      );
      expect(r.alreadyAdded, isTrue);
      expect(r.usable, isFalse);
    });

    test('端口不通时报网络错误而不是抛异常', () async {
      await startServer(handler: (_) => {'code': 1, 'list': <dynamic>[]});
      final port = server.port;
      await server.close(force: true);
      final discovery = SourceDiscovery.withClient(HttpClient());
      final r = await discovery.probe(SourceCandidate(
        name: '已下线',
        api: 'http://127.0.0.1:$port/api.php/provide/vod/',
      ));
      expect(r.ok, isFalse);
      expect(r.error, isNotNull);
      // tearDown 会再关一次，这里补一个空服务器避免重复关闭报错
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });

    test('probeAll 流式返回全部结果，可用项排在前面由页面决定', () async {
      await startServer(handler: (path) => path.contains('bad')
          ? {'hello': 'world'}
          : {
              'code': 1,
              'total': 7,
              'list': <dynamic>[],
            });
      final discovery = SourceDiscovery.withClient(HttpClient());
      final candidates = [
        SourceCandidate(name: 'ok1', api: apiOf()),
        SourceCandidate(
            name: 'bad', api: 'http://127.0.0.1:${server.port}/bad/vod/'),
        SourceCandidate(name: 'ok2', api: apiOf()),
      ];
      final results = await discovery.probeAll(candidates).toList();
      expect(results.length, 3);
      expect(results.where((r) => r.usable).length, 2);
      expect(results.where((r) => !r.usable).length, 1);
    });

    test('空候选清单直接结束', () async {
      final discovery = SourceDiscovery.withClient(HttpClient());
      final results = await discovery.probeAll(const []).toList();
      expect(results, isEmpty);
    });
  });

  group('远程清单拉取', () {
    late HttpServer server;

    Future<void> startServer(String body, {int status = 200}) async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response.statusCode = status;
        req.response.write(body);
        await req.response.close();
      });
    }

    tearDown(() => server.close(force: true));

    test('拉取 JSON 清单并解析出候选站点', () async {
      await startServer(jsonEncode({
        'sites': [
          {'name': 'A', 'api': 'https://a.example.com/api.php/provide/vod/'},
          {'name': 'B', 'api': 'https://b.example.com/api.php/provide/vod/'},
        ],
      }));
      final discovery = SourceDiscovery.withClient(HttpClient());
      final res = await discovery.fetchCatalog(
          'http://127.0.0.1:${server.port}/sites.json');
      expect(res.warnings, isEmpty);
      expect(res.candidates.length, 2);
      expect(res.candidates.first.name, 'A');
    });

    test('拉取纯文本清单', () async {
      await startServer('https://a.example.com/api.php/provide/vod/\n');
      final discovery = SourceDiscovery.withClient(HttpClient());
      final res = await discovery.fetchCatalog(
          'http://127.0.0.1:${server.port}/sites.txt');
      expect(res.candidates.length, 1);
    });

    test('清单内容解析不出站点时给出提示', () async {
      await startServer('<html>404</html>');
      final discovery = SourceDiscovery.withClient(HttpClient());
      final res = await discovery.fetchCatalog(
          'http://127.0.0.1:${server.port}/sites.txt');
      expect(res.candidates, isEmpty);
      expect(res.warnings.single, contains('没有解析出'));
    });

    test('清单地址不合法时直接拒绝，不发请求', () async {
      final discovery = SourceDiscovery.withClient(HttpClient());
      final res = await discovery.fetchCatalog('not-a-url');
      expect(res.candidates, isEmpty);
      expect(res.warnings.single, contains('不合法'));
    });

    test('清单地址不可达时返回网络错误提示', () async {
      await startServer('x');
      final port = server.port;
      await server.close(force: true);
      final discovery = SourceDiscovery.withClient(HttpClient());
      final res = await discovery.fetchCatalog(
          'http://127.0.0.1:$port/sites.json');
      expect(res.candidates, isEmpty);
      expect(res.warnings, isNotEmpty);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });

    test('fetchCatalogs：合并多个源并去重，单源失败不影响其它源', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final base = 'http://127.0.0.1:${server.port}';
      server.listen((req) async {
        final payload = req.uri.path == '/a.json'
            ? {
                'sites': [
                  {'name': 'A站', 'api': '$base/api.php/provide/vod/'},
                ],
              }
            : {
                'sites': [
                  // 与 a.json 指向同一站点，应被合并去重
                  {'name': 'A站别名', 'api': '$base/api.php/provide/vod'},
                  {
                    'name': 'B站',
                    'api': 'https://b.example.com/api.php/provide/vod/',
                  },
                ],
              };
        req.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(payload));
        await req.response.close();
      });

      final discovery = SourceDiscovery.withClient(HttpClient());
      final res = await discovery.fetchCatalogs([
        'not-a-url', // 非法地址，应被跳过而不是中断整轮
        '$base/a.json',
        '$base/b.json',
      ]);

      expect(res.candidates.length, 2);
      expect(res.candidates.map((c) => c.name), ['A站', 'B站']);
    });
  });
}
