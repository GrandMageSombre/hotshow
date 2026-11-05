import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotshow/services/live_catalog.dart';

void main() {
  group('LiveCatalog.parse', () {
    const jsonText = '''
{
 "updated": "2026-11-05",
 "groups": [
  {"id":"cctv","name":"央视","channels":[
    {"name":"CCTV-1 综合","url":"http://a/1.m3u8","backup":["http://b/1.m3u8"],"logo":"http://a/1.png"},
    {"name":"CCTV-5 体育","url":"http://a/5.m3u8"}
  ]},
  {"id":"sports","name":"体育","channels":[
    {"name":"NBA TV","url":"http://a/nba.m3u8","ua":"UA-X","ref":"http://r/"}
  ]}
 ]
}
''';

    test('分类与频道都能读出来', () {
      final c = LiveCatalog.parse(jsonText);
      expect(c.updated, '2026-11-05');
      expect(c.groups.length, 2);
      expect(c.groups.first.name, '央视');
      expect(c.groups.first.channels.length, 2);
      expect(c.total, 3);
    });

    test('主地址 + 备用地址按顺序合并', () {
      final c = LiveCatalog.parse(jsonText);
      final cctv1 = c.groups.first.channels.first;
      expect(cctv1.urls, ['http://a/1.m3u8', 'http://b/1.m3u8']);
      expect(cctv1.url, 'http://a/1.m3u8');
    });

    test('没有备用地址时只有一条', () {
      final c = LiveCatalog.parse(jsonText);
      final cctv5 = c.groups.first.channels[1];
      expect(cctv5.urls.length, 1);
    });

    test('播放要求能读出来，没有时 playHeaders 为 null', () {
      final c = LiveCatalog.parse(jsonText);
      final nba = c.groups[1].channels.first;
      expect(nba.playHeaders?['User-Agent'], 'UA-X');
      expect(nba.playHeaders?['Referer'], 'http://r/');
      expect(c.groups.first.channels.first.playHeaders, null);
    });

    test('toResource 把主备地址变成两条线路', () {
      final c = LiveCatalog.parse(jsonText);
      final r = c.groups.first.channels.first.toResource();
      expect(r.groups.length, 2);
      expect(r.groups[0].name, '默认线路');
      expect(r.groups[0].episodes.single.url, 'http://a/1.m3u8');
      expect(r.groups[1].name, '备用线路 1');
      expect(r.groups[1].episodes.single.url, 'http://b/1.m3u8');
      expect(r.title, 'CCTV-1 综合');
      expect(r.playable, true);
    });

    test('groupOf 按 id 查分类', () {
      final c = LiveCatalog.parse(jsonText);
      expect(c.groupOf('sports')?.name, '体育');
      expect(c.groupOf('不存在'), null);
    });

    test('search 跨分类搜台名', () {
      final c = LiveCatalog.parse(jsonText);
      expect(c.search('cctv').length, 2);
      expect(c.search('NBA').single.name, 'NBA TV');
      expect(c.search('  ').isEmpty, true);
    });

    test('空 groups 不炸', () {
      final c = LiveCatalog.parse('{"updated":"","groups":[]}');
      expect(c.total, 0);
      expect(c.search('x').isEmpty, true);
    });
  });

  group('内置 assets/live_channels.json', () {
    final file = File('assets/live_channels.json');

    test('文件存在且能解析', () {
      expect(file.existsSync(), true, reason: '精选目录必须随仓库提交');
      final c = LiveCatalog.parse(file.readAsStringSync());
      expect(c.groups.length, 4);
      expect(c.total > 50, true, reason: '精选台太少会显得功能缺失');
    });

    test('四个分类齐全且都有台', () {
      final c = LiveCatalog.parse(file.readAsStringSync());
      for (final id in ['cctv', 'local', 'foreign', 'sports']) {
        final g = c.groupOf(id);
        expect(g, isNotNull, reason: '缺分类 $id');
        expect(g!.channels.isNotEmpty, true, reason: '$id 分类是空的');
      }
    });

    test('每个台都有名字和至少一个 http 地址', () {
      final c = LiveCatalog.parse(file.readAsStringSync());
      for (final g in c.groups) {
        for (final ch in g.channels) {
          expect(ch.name.trim().isNotEmpty, true);
          expect(ch.urls.isNotEmpty, true, reason: '${ch.name} 没有地址');
          for (final u in ch.urls) {
            expect(RegExp(r'^https?://').hasMatch(u), true,
                reason: '${ch.name} 的地址不合法：$u');
          }
        }
      }
    });

    test('央视分类含 CCTV-1 和 CCTV-5', () {
      final c = LiveCatalog.parse(file.readAsStringSync());
      final names = c.groupOf('cctv')!.channels.map((e) => e.name).join('|');
      expect(names.contains('CCTV-1'), true);
      expect(names.contains('CCTV-5'), true);
    });

    test('体育分类含 NBA', () {
      final c = LiveCatalog.parse(file.readAsStringSync());
      final nba = c.groupOf('sports')!
          .channels
          .where((e) => e.name.toUpperCase().contains('NBA'));
      expect(nba.isNotEmpty, true);
    });

    test('没有重复的台名', () {
      final c = LiveCatalog.parse(file.readAsStringSync());
      for (final g in c.groups) {
        final names = g.channels.map((e) => e.name).toList();
        expect(names.toSet().length, names.length, reason: '${g.name} 有重名台');
      }
    });

    test('JSON 是合法 UTF-8（中文台名不乱码）', () {
      final raw = file.readAsBytesSync();
      final text = utf8.decode(raw);
      expect(text.contains('央视'), true);
      expect(text.contains('�'), false);
    });
  });
}
