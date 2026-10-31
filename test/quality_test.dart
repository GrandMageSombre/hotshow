import 'package:flutter_test/flutter_test.dart';
import 'package:hotshow/models/media_resource.dart';
import 'package:hotshow/services/m3u8.dart';
import 'package:hotshow/services/quality_service.dart';

const _master = '''#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
360/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720
720/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
master1080/index.m3u8
''';

const _media = '''#EXTM3U
#EXT-X-TARGETDURATION:6
#EXTINF:6.0,
seg1.ts
#EXTINF:6.0,
seg2.ts
#EXT-X-ENDLIST
''';

void main() {
  group('master playlist → 清晰度列表', () {
    final playlist = parseM3u8(
      _master,
      Uri.parse('https://cdn.example.com/hls/master.m3u8'),
    );

    test('第一项是「自动」，其后按清晰度从高到低', () {
      final options = optionsFromPlaylist(playlist);
      expect(options.map((o) => o.label).toList(),
          ['自动', '1080P', '720P', '360P']);
      expect(options.first.isAuto, isTrue);
    });

    test('变体地址按 master 地址补全为绝对地址', () {
      final options = optionsFromPlaylist(playlist);
      expect(options[1].url, 'https://cdn.example.com/hls/master1080/index.m3u8');
    });

    test('排序权重随分辨率与码率递增', () {
      final options = optionsFromPlaylist(playlist);
      expect(options[1].rank, greaterThan(options[2].rank));
      expect(options[2].rank, greaterThan(options[3].rank));
    });

    test('单码率分片列表不给切换入口', () {
      final single = parseM3u8(
        _media,
        Uri.parse('https://cdn.example.com/hls/index.m3u8'),
      );
      expect(optionsFromPlaylist(single), isEmpty);
    });

    test('同清晰度只保留一路，菜单里不出现重复名字', () {
      const dup = '''#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=640x360
a.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=600000,RESOLUTION=640x360
b.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720
c.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=200000
audio.m3u8
''';
      final p = parseM3u8(dup, Uri.parse('https://a.com/m.m3u8'));
      final labels = optionsFromPlaylist(p).map((o) => o.label).toList();
      expect(labels, contains('360P'));
      expect(labels.toSet().length, labels.length, reason: '菜单项名字不能重复');
      // 360P 只留码率更高的 a.m3u8
      expect(
        optionsFromPlaylist(p).firstWhere((o) => o.label == '360P').url,
        'https://a.com/a.m3u8',
      );
      // 没有 RESOLUTION 的纯音频轨不能进菜单（切过去只剩声音没画面）
      expect(
        optionsFromPlaylist(p).where((o) => o.url.endsWith('audio.m3u8')),
        isEmpty,
      );
    });

    test('只有一路变体时也没必要切换', () {
      const one = '''#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=1280x720
only/index.m3u8
''';
      final p = parseM3u8(one, Uri.parse('https://a.com/x.m3u8'));
      expect(optionsFromPlaylist(p), isEmpty);
    });
  });

  group('清晰度命名', () {
    test('分辨率优先换算', () {
      expect(qualityLabel('3840x2160', 0), '4K');
      expect(qualityLabel('2560x1440', 0), '2K');
      expect(qualityLabel('1920x1080', 0), '1080P');
      expect(qualityLabel('1280x720', 0), '720P');
      expect(qualityLabel('960x540', 0), '540P');
      expect(qualityLabel('854x480', 0), '480P');
      expect(qualityLabel('640x360', 0), '360P');
    });

    test('没分辨率时退回码率', () {
      expect(qualityLabel('', 6000000), '高清');
      expect(qualityLabel('', 3000000), '标清');
      expect(qualityLabel('', 500000), '流畅');
      expect(qualityLabel('', 0), '原画');
    });

    test('只给 1080p 这种写法也能认', () {
      expect(resolutionHeight('1080p'), 1080);
      expect(resolutionHeight('1920x1080'), 1080);
      expect(resolutionHeight('unknown'), 0);
    });

    test('副标题带分辨率与 Mbps', () {
      expect(variantDetail('1920x1080', 4200000), '1920×1080 · 4.2 Mbps');
      expect(variantDetail('', 0), '未知码率');
    });
  });

  group('线路名里的清晰度', () {
    test('从线路名猜权重', () {
      expect(qualityRankOfName('线路1 蓝光'), 1080);
      expect(qualityRankOfName('4K 原盘'), 2160);
      expect(qualityRankOfName('高清线路'), 720);
      expect(qualityRankOfName('量子'), 0);
    });

    test('只有带清晰度字样的线路才进菜单，按清晰度降序', () {
      final groups = [
        const PlayGroup(name: '量子', episodes: [Episode(name: '第1集', url: 'a')]),
        const PlayGroup(name: '高清', episodes: [Episode(name: '第1集', url: 'b')]),
        const PlayGroup(name: '蓝光1080', episodes: [Episode(name: '第1集', url: 'c')]),
      ];
      final options = groupQualityOptions(groups);
      expect(options.map((o) => o.groupIndex).toList(), [2, 1]);
      expect(options.first.isGroup, isTrue);
      expect(options.first.detail, '1 集 · 换线路');
    });
  });
}
