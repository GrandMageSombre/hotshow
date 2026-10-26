// 字幕工具与海报网格的离线单测：不访问网络，全部用内存数据驱动。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotshow/models/subtitle.dart';
import 'package:hotshow/services/subtitle/open_subtitles.dart';
import 'package:hotshow/services/subtitle/subtitle_text.dart';
import 'package:hotshow/services/subtitle/zip_reader.dart';
import 'package:hotshow/services/subtitle_service.dart';
import 'package:hotshow/services/subtitle_store.dart';
import 'package:hotshow/widgets/remote_image.dart';
import 'package:hotshow/widgets/show_grid.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _srt = '1\r\n00:00:01,000 --> 00:00:03,000\r\n你好\r\n\r\n';

void main() {
  group('字幕编码', () {
    test('UTF-8 BOM 会被去掉', () {
      final bytes = <int>[0xEF, 0xBB, 0xBF, ...utf8.encode(_srt)];
      final text = decodeSubtitleBytes(bytes);
      expect(text.startsWith('\uFEFF'), isFalse);
      expect(text, contains('你好'));
    });

    test('无 BOM 的 UTF-8 正常解码', () {
      expect(decodeSubtitleBytes(utf8.encode(_srt)), contains('你好'));
    });

    test('GBK 字幕能正确解码成中文', () {
      // "你好" 的 GBK 编码
      final text = decodeSubtitleBytes([0xC4, 0xE3, 0xBA, 0xC3]);
      expect(text, '你好');
    });

    test('纯西文文件不会被误判成 GBK', () {
      final bytes = latin1.encode('1\n00:00:01,000 --> 00:00:03,000\nCafé\n');
      expect(decodeSubtitleBytes(bytes), contains('Café'));
    });
  });

  group('归档解包', () {
    test('stored zip 能取出 srt', () {
      final zip = _buildZip({'movie.chs.srt': utf8.encode(_srt)});
      final archive = unpackSubtitleBytes(zip);
      expect(archive.name, 'movie.chs.srt');
      expect(utf8.decode(archive.bytes), contains('你好'));
    });

    test('deflate zip 能取出 ass，且优先于其它文件', () {
      final zip = _buildZip(
        {
          'readme.txt': utf8.encode('说明'),
          'movie.ass': utf8.encode('[Script Info]\nTitle: t\n'),
        },
        deflate: true,
      );
      final archive = unpackSubtitleBytes(zip);
      expect(archive.name, 'movie.ass');
      expect(utf8.decode(archive.bytes), contains('[Script Info]'));
    });

    test('gzip 单文件也能解包', () {
      final packed = gzip.encode(utf8.encode(_srt));
      final archive = unpackSubtitleBytes(packed);
      expect(utf8.decode(archive.bytes), contains('你好'));
    });

    test('非压缩内容原样返回', () {
      final archive = unpackSubtitleBytes(utf8.encode(_srt), name: 'a.srt');
      expect(archive.name, 'a.srt');
    });
  });

  group('格式与时间轴', () {
    test('识别 srt / ass / vtt', () {
      expect(detectSubtitleFormat(fileName: 'a.srt', text: _srt), 'srt');
      expect(detectSubtitleFormat(fileName: 'a.ass', text: ''), 'ass');
      expect(detectSubtitleFormat(fileName: 'a.vtt', text: ''), 'vtt');
      expect(
        detectSubtitleFormat(fileName: 'x', text: 'WEBVTT\n\n00:00.000 --> 00:01.000\n'),
        'vtt',
      );
      expect(
        detectSubtitleFormat(fileName: 'x', text: '[Script Info]\nTitle: t\n'),
        'ass',
      );
    });

    test('SRT 整体延后 500ms', () {
      final out = shiftSubtitleText(_srt, 'srt', 500);
      expect(out, contains('00:00:01,500 --> 00:00:03,500'));
    });

    test('SRT 提前到负数会被夹到 0', () {
      final out = shiftSubtitleText(_srt, 'srt', -5000);
      expect(out, contains('00:00:00,000 --> 00:00:00,000'));
    });

    test('VTT 省略小时的写法也能偏移', () {
      const vtt = 'WEBVTT\n\n00:01.000 --> 00:03.500\nhi\n';
      final out = shiftSubtitleText(vtt, 'vtt', 1000);
      expect(out, contains('00:02.000 --> 00:04.500'));
    });

    test('ASS 只改 Dialogue 的起止时间', () {
      const ass = '[Events]\n'
          'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n'
          'Dialogue: 0,0:00:01.00,0:00:03.50,Default,,0,0,0,,你好, 世界\n';
      final out = shiftSubtitleText(ass, 'ass', 1000);
      expect(out, contains('Dialogue: 0,0:00:02.00,0:00:04.50,Default,,0,0,0,,你好, 世界'));
    });
  });

  group('OpenSubtitles 解析', () {
    test('从搜索响应里取出可下载的候选', () {
      final payload = {
        'data': [
          {
            'attributes': {
              'subtitle_id': '5241563',
              'language': 'zh-cn',
              'download_count': 4315,
              'hd': true,
              'release': 'Inception.2010.720p.BluRay.x264-CROSSBOW.chs',
              'legacy_subtitle_id': 8142102,
              'feature_details': {'title': 'Inception', 'year': 2010},
              'files': [
                {'file_id': 5345056, 'file_name': 'Inception.chs'}
              ],
            }
          },
          {'attributes': <String, dynamic>{}},
        ]
      };
      final list = OpenSubtitlesSource().parseSearchPayload(payload);
      expect(list.length, 1);
      final c = list.first;
      expect(c.title, contains('Inception'));
      expect(c.languageLabel, '简体');
      expect(c.legacyId, 8142102);
      expect(c.fileId, 5345056);
      expect(c.freeDownloadable, isTrue);
      expect(c.year, 2010);
      expect(c.downloads, 4315);
      expect(c.hd, isTrue);
    });

    test('语言代码映射', () {
      expect(subtitleLanguageLabel('zh-tw'), '繁体');
      expect(subtitleLanguageLabel('zh-cn'), '简体');
      expect(subtitleLanguageLabel('en'), '英文');
      expect(subtitleLanguageLabel('ja'), '日文');
      expect(subtitleLanguageLabel('pt-br'), '葡萄牙文');
    });
  });

  group('本地字幕存取', () {
    late Directory tmp;
    late SubtitleStore store;
    late SubtitleService service;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tmp = await Directory.systemTemp.createTemp('hotshow_subtitle_test');
      store = SubtitleStore()..debugSetRoot(tmp);
      await store.load();
      service = SubtitleService(store: store);
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('保存后按剧集键取回，并记住选中项', () async {
      final file = await store.addBytes(
        showKey: 'site#1',
        label: '测试字幕',
        language: 'zh-cn',
        source: 'test',
        utf8Bytes: utf8.encode(_srt),
        ext: 'srt',
      );
      await store.select('site#1', file);

      expect(store.selectedFor('site#1')?.path, file.path);
      expect(store.existingFilesFor('site#1').length, 1);
      expect(File(file.path).readAsStringSync(), contains('你好'));
    });

    test('时间轴调整以原文件为基准，反复调整不累积误差', () async {
      final file = await store.addBytes(
        showKey: 'site#1',
        label: '测试字幕',
        language: 'zh-cn',
        source: 'test',
        utf8Bytes: utf8.encode(_srt),
        ext: 'srt',
      );

      final delayed = await service.bakeDelay(file, 500);
      expect(File(delayed.path).readAsStringSync(),
          contains('00:00:01,500 --> 00:00:03,500'));

      // 再在 +500 的基础上加 +500，结果应是 +1000（而不是 +1500）
      final more = await service.bakeDelay(delayed, 1000);
      expect(File(more.path).readAsStringSync(),
          contains('00:00:02,000 --> 00:00:04,000'));

      // 归零回到原时间轴
      final reset = await service.bakeDelay(more, 0);
      expect(File(reset.path).readAsStringSync(),
          contains('00:00:01,000 --> 00:00:03,000'));
    });

    test('删除字幕会同时清掉偏移副本', () async {
      final file = await store.addBytes(
        showKey: 'site#1',
        label: '测试字幕',
        language: 'zh-cn',
        source: 'test',
        utf8Bytes: utf8.encode(_srt),
        ext: 'srt',
      );
      final shifted = await service.bakeDelay(file, 500);
      expect(File(shifted.path).existsSync(), isTrue);

      await store.removeFile(shifted);
      expect(File(file.basePath).existsSync(), isFalse);
      expect(File(shifted.path).existsSync(), isFalse);
      expect(store.existingFilesFor('site#1'), isEmpty);
    });
  });

  group('海报网格度量', () {
    test('任意屏宽下卡片宽度与列数自洽（不再出现溢出）', () {
      for (final width in [320.0, 360.0, 375.0, 393.0, 411.0, 480.0, 600.0, 900.0]) {
        final usable = width - ShowGridMetrics.horizontalPadding * 2;
        final m = ShowGridMetrics.resolve(
          availableWidth: usable,
          textScaler: TextScaler.noScaling,
        );
        expect(m.columns, inInclusiveRange(2, 6));
        // 列宽 + 间距刚好铺满可用宽度
        expect(
          m.columns * m.itemWidth + ShowGridMetrics.spacing * (m.columns - 1),
          closeTo(usable, 0.01),
        );
        // 高度 = 海报 + 文字区，一像素都不差
        final textHeight = ShowGridMetrics.coverTextGap +
            ShowGridMetrics.titleFontSize *
                ShowGridMetrics.lineHeightFactor *
                2 +
            ShowGridMetrics.subtitleGap +
            ShowGridMetrics.subtitleFontSize *
                ShowGridMetrics.lineHeightFactor +
            ShowGridMetrics.heightSlack;
        expect(
          m.itemHeight,
          closeTo(m.itemWidth * ShowGridMetrics.posterAspectRatio + textHeight, 0.01),
        );
      }
    });

    test('360dp 机型排 3 列', () {
      final m = ShowGridMetrics.resolve(
        availableWidth: 360 - ShowGridMetrics.horizontalPadding * 2,
        textScaler: TextScaler.noScaling,
      );
      expect(m.columns, 3);
    });

    test('字体放大时单元格高度同步变大', () {
      final normal = ShowGridMetrics.resolve(
        availableWidth: 336,
        textScaler: TextScaler.noScaling,
      );
      final large = ShowGridMetrics.resolve(
        availableWidth: 336,
        textScaler: const TextScaler.linear(ShowGridMetrics.maxTextScale),
      );
      expect(large.itemHeight, greaterThan(normal.itemHeight));
      // 超过上限后不再继续放大，避免单元格无限变高
      final huge = ShowGridMetrics.resolve(
        availableWidth: 336,
        textScaler: const TextScaler.linear(2.0),
      );
      expect(huge.itemHeight, closeTo(large.itemHeight, 0.01));
    });
  });

  group('图片地址与请求头', () {
    test('豆瓣 http 地址升级为 https，并生成多域名候选', () {
      const url = 'http://img3.doubanio.com/view/photo/m_ratio_poster/public/p1.jpg';
      expect(normalizeImageUrl(url), startsWith('https://'));
      final candidates = imageCandidates(url);
      expect(candidates.first, 'https://img3.doubanio.com/view/photo/m_ratio_poster/public/p1.jpg');
      expect(candidates.length, 4);
      expect(candidates[1], contains('img1.doubanio.com'));
    });

    test('非豆瓣图源不换域名', () {
      const url = 'https://cdn.example.com/a.jpg';
      expect(imageCandidates(url), [url]);
    });

    test('请求头带上浏览器 UA 与正确 Referer', () {
      final douban = imageHeaders('https://img2.doubanio.com/x.jpg');
      expect(douban['User-Agent'], contains('Mozilla'));
      expect(douban['Referer'], 'https://movie.douban.com/');

      final other = imageHeaders('https://cdn.example.com/a.jpg');
      expect(other['Referer'], 'https://cdn.example.com/');
    });
  });
}

String subtitleLanguage(String code) {
  // 直接复用模型里的映射，避免测试里再抄一份
  final zh = code.startsWith('zh');
  if (zh) return code.contains('tw') ? '繁体' : '简体';
  const map = {'en': '英文', 'ja': '日文', 'pt': '葡萄牙文'};
  return map[code.split('-').first] ?? code;
}

/// 手工拼一个最小 zip（含中央目录），用于测试解包逻辑
List<int> _buildZip(Map<String, List<int>> entries, {bool deflate = false}) {
  final body = BytesBuilder();
  final central = BytesBuilder();
  final names = entries.keys.toList();

  for (final name in names) {
    final raw = entries[name]!;
    final data = deflate ? ZLibEncoder(raw: true).convert(raw) : raw;
    final nameBytes = utf8.encode(name);
    final offset = body.length;

    final local = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 0, Endian.little)
      ..setUint16(8, deflate ? 8 : 0, Endian.little)
      ..setUint32(18, data.length, Endian.little)
      ..setUint32(22, raw.length, Endian.little)
      ..setUint16(26, nameBytes.length, Endian.little);
    body.add(local.buffer.asUint8List());
    body.add(nameBytes);
    body.add(data);

    final entry = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 20, Endian.little)
      ..setUint16(10, deflate ? 8 : 0, Endian.little)
      ..setUint32(20, data.length, Endian.little)
      ..setUint32(24, raw.length, Endian.little)
      ..setUint16(28, nameBytes.length, Endian.little)
      ..setUint32(42, offset, Endian.little);
    central.add(entry.buffer.asUint8List());
    central.add(nameBytes);
  }

  final centralOffset = body.length;
  final centralBytes = central.takeBytes();
  body.add(centralBytes);

  final eocd = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, names.length, Endian.little)
    ..setUint16(10, names.length, Endian.little)
    ..setUint32(12, centralBytes.length, Endian.little)
    ..setUint32(16, centralOffset, Endian.little);
  body.add(eocd.buffer.asUint8List());
  return body.takeBytes();
}
