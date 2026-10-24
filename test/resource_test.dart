// 采集站数据层单元测试：用本地假 maccms 接口验证检索、归一化与排序，
// 全程不访问外网。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotshow/models/media_resource.dart';
import 'package:hotshow/services/resource_service.dart';
import 'package:hotshow/models/source_site.dart';

/// 构造一条 maccms `ac=detail` 的 vod 记录
Map<String, dynamic> vod({
  required int id,
  required String name,
  String year = '2019',
  String remarks = '全2集',
  String typeName = '国产剧',
  String playFrom = 'm3u8',
  List<String> episodes = const ['第01集', '第02集'],
}) =>
    {
      'vod_id': id,
      'vod_name': name,
      'vod_pic': 'https://img.example.com/$id.jpg',
      'vod_remarks': remarks,
      'vod_year': year,
      'vod_area': '中国大陆',
      'type_name': typeName,
      'vod_content': '<p>简介<br/>第二行&nbsp;内容</p>',
      'vod_play_from': playFrom,
      'vod_play_url': episodes
          .map((e) => '$e\$https://cdn.example.com/$id/$e.m3u8')
          .join('#'),
    };

/// 起一个本地假站点，返回 `(server, 收到的关键词列表)`
Future<(HttpServer, List<String>)> startFakeSite(
  Map<String, dynamic> Function(String keyword) handler,
) async {
  final seen = <String>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final wd = req.uri.queryParameters['wd'] ?? '';
    seen.add(wd);
    req.response
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(handler(wd)));
    await req.response.close();
  });
  return (server, seen);
}

String urlOf(HttpServer server) =>
    'http://127.0.0.1:${server.port}/api.php/provide/vod/';

void main() {
  // flutter_test 默认把 HttpClient 替换成「一律 400」的桩，这里恢复真实实现，
  // 以便请求本地假站点。
  setUp(() => HttpOverrides.global = null);

  group('maccms 播放地址解析', () {
    test('多线路 / 多分集按 \$\$\$ 与 # 正确分组', () {
      final groups = parsePlayGroups(
        '线路A\$\$\$m3u8',
        '第01集\$https://a.com/1.m3u8#第02集\$https://a.com/2.m3u8'
        '\$\$\$第01集\$https://b.com/1.m3u8',
      );
      expect(groups.length, 2);
      expect(groups[0].name, '线路A');
      expect(groups[0].episodes.length, 2);
      expect(groups[0].episodes[0].name, '第01集');
      expect(groups[0].episodes[0].url, 'https://a.com/1.m3u8');
      expect(groups[1].name, 'm3u8');
      expect(groups[1].isHls, isTrue);
    });

    test('缺失集名时自动补序号，地址后的播放器标识被丢弃', () {
      final groups = parsePlayGroups('', 'https://a.com/1.m3u8#第02集\$https://a.com/2.m3u8\$qq');
      expect(groups.first.name, '线路1');
      expect(groups.first.episodes[0].name, '第1集');
      expect(groups.first.episodes[1].url, 'https://a.com/2.m3u8');
    });

    test('无播放地址时返回空线路', () {
      expect(parsePlayGroups('m3u8', ''), isEmpty);
      expect(parsePlayGroups('m3u8', '\$\$\$'), isEmpty);
    });

    test('MediaResource 归一化字段并清理简介 HTML', () {
      final r = MediaResource.fromMaccmsJson(
        vod(id: 7, name: '庆余年', year: '2019'),
        siteId: 's1',
        siteName: '站点一',
      );
      expect(r.title, '庆余年');
      expect(r.year, '2019');
      expect(r.typeName, '国产剧');
      expect(r.episodeCount, 2);
      expect(r.groups.length, 1);
      expect(r.playable, isTrue);
      expect(r.intro, contains('简介'));
      expect(r.intro, isNot(contains('<p>')));
      expect(r.key, 's1#7');
    });
  });

  group('SourceSite 请求地址', () {
    test('拼接 ac / wd，并保留地址上已有的查询参数', () {
      const site = SourceSite(
        id: 's1',
        name: '站点一',
        api: 'https://ex.com/api.php/provide/vod/?token=abc',
      );
      final uri = site.buildSearchUri('庆余年 第二季');
      expect(uri.host, 'ex.com');
      expect(uri.path, '/api.php/provide/vod/');
      expect(uri.queryParameters['token'], 'abc');
      expect(uri.queryParameters['ac'], 'detail');
      expect(uri.queryParameters['wd'], '庆余年 第二季');
      expect(site.buildDetailUri('1,2').queryParameters['ids'], '1,2');
    });

    test('地址合法性校验', () {
      expect(SourceSite.isValidApi('https://a.com/api.php/provide/vod'), isTrue);
      expect(SourceSite.isValidApi('http://a.com/x'), isTrue);
      expect(SourceSite.isValidApi('a.com/x'), isFalse);
      expect(SourceSite.isValidApi('ftp://a.com/x'), isFalse);
      expect(SourceSite.isValidApi(''), isFalse);
    });
  });

  group('片名匹配与排序', () {
    test('完全匹配得分最高，无关项得 0', () {
      expect(titleScore('庆余年', '庆余年'), 1.0);
      // 季数后缀会被归一化，因此与主片名同分
      expect(titleScore('庆余年 第二季', '庆余年'), 1.0);
      expect(titleScore('庆余年之风起', '庆余年'), greaterThan(0.6));
      expect(titleScore('狂飙', '庆余年'), 0);
    });

    test('排序：同名词条优先，年份不符者被压后', () {
      final list = [
        MediaResource.fromMaccmsJson(
            vod(id: 1, name: '庆余年 老版', year: '1998'),
            siteId: 's',
            siteName: '站'),
        MediaResource.fromMaccmsJson(vod(id: 2, name: '狂飙'), siteId: 's', siteName: '站'),
        MediaResource.fromMaccmsJson(
            vod(id: 3, name: '庆余年', year: '2019'),
            siteId: 's',
            siteName: '站'),
      ];
      final ranked = rankResources(list, '庆余年', year: '2019');
      expect(ranked.length, 2); // 无关的「狂飙」被过滤
      expect(ranked.first.title, '庆余年');
      expect(ranked.last.title, '庆余年 老版');
    });
  });

  group('站点检索', () {
    late HttpServer server;

    tearDown(() => server.close(force: true));

    test('searchSite 解析完整剧集列表', () async {
      final started = await startFakeSite((wd) => {
            'code': 1,
            'list': [
              vod(id: 100, name: '庆余年', episodes: ['第01集', '第02集', '第03集']),
            ],
          });
      server = started.$1;
      final site = SourceSite(id: 's1', name: '站点一', api: urlOf(server));

      final result = await ResourceService.instance.searchSite(site, '庆余年');
      expect(result.ok, isTrue);
      expect(result.items.length, 1);
      expect(result.items.first.episodeCount, 3);
      expect(started.$2, ['庆余年']);
    });

    test('站点返回 code != 1 时给出可读错误', () async {
      final started = await startFakeSite(
          (_) => {'code': 0, 'msg': '关键词不能为空', 'list': <dynamic>[]});
      server = started.$1;
      final site = SourceSite(id: 's2', name: '站点二', api: urlOf(server));

      final result = await ResourceService.instance.searchSite(site, '任意');
      expect(result.ok, isFalse);
      expect(result.error, contains('关键词不能为空'));
    });

    test('返回非 JSON 时提示接口地址可能有误', () async {
      final plain = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server = plain;
      plain.listen((req) async {
        req.response.write('<xml>not json</xml>');
        await req.response.close();
      });

      final site = SourceSite(
          id: 's3', name: '站点三', api: 'http://127.0.0.1:${plain.port}/vod/');
      final result = await ResourceService.instance.searchSite(site, '任意');
      expect(result.ok, isFalse);
      expect(result.error, contains('不是 JSON'));
    });

    test('searchAll 逐站推送结果，单站失败不影响其它站点', () async {
      final okSite = await startFakeSite(
          (wd) => {'code': 1, 'list': [vod(id: 1, name: '庆余年')]});
      final badSite = await startFakeSite((_) => {'code': 0, 'msg': '维护中'});
      server = okSite.$1;

      final sites = [
        SourceSite(id: 'ok', name: '可用站', api: urlOf(okSite.$1)),
        SourceSite(id: 'bad', name: '故障站', api: urlOf(badSite.$1)),
      ];
      final results =
          await ResourceService.instance.searchAll(sites, '庆余年').toList();

      expect(results.length, 2);
      expect(results.firstWhere((r) => r.site.id == 'ok').items.length, 1);
      final bad = results.firstWhere((r) => r.site.id == 'bad');
      expect(bad.ok, isFalse);
      expect(bad.error, contains('维护中'));

      await badSite.$1.close(force: true);
    });

    test('未配置站点时给出引导提示', () async {
      final results = await ResourceService.instance.searchAll([], '庆余年').toList();
      expect(results.length, 1);
      expect(results.first.ok, isFalse);
      expect(results.first.error, contains('尚未配置采集站'));
    });
  });
}
