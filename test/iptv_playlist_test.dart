import 'package:flutter_test/flutter_test.dart';
import 'package:hotshow/models/iptv_channel.dart';
import 'package:hotshow/services/iptv_service.dart';

void main() {
  group('parseIptvPlaylist 基本解析', () {
    test('标准 #EXTINF 能取出名字/分组/台标/tvg-id', () {
      const s = '''
#EXTM3U x-tvg-url="http://epg.example/e.xml"
#EXTINF:-1 tvg-id="CCTV1" tvg-name="CCTV1" tvg-logo="http://a/1.png" group-title="央视频道",CCTV-1 综合
http://1.2.3.4/hls/1/index.m3u8
#EXTINF:-1 group-title="卫视频道",湖南卫视
http://5.6.7.8/live/hn.m3u8
''';
      final p = parseIptvPlaylist(s);
      expect(p.length, 2);
      expect(p.channels.first.name, 'CCTV-1 综合');
      expect(p.channels.first.group, '央视频道');
      expect(p.channels.first.logo, 'http://a/1.png');
      expect(p.channels.first.tvgId, 'CCTV1');
      expect(p.groups, ['央视频道', '卫视频道']);
    });

    test('没有名字时退回 tvg-name', () {
      const s = '''
#EXTM3U
#EXTINF:-1 tvg-name="CCTV5", 
http://a/5.m3u8
''';
      final p = parseIptvPlaylist(s);
      expect(p.length, 1);
      // 名字位置是空白 → 用 tvg-name 兜底
      expect(p.channels.first.name, 'CCTV5');
    });

    test('group-title 里带逗号不会把名字截断', () {
      const s = '''
#EXTM3U
#EXTINF:-1 group-title="央视,付费" tvg-logo="http://a/x.png",CCTV-5+ 体育赛事
http://a/5p.m3u8
''';
      final p = parseIptvPlaylist(s);
      expect(p.channels.first.name, 'CCTV-5+ 体育赛事');
      expect(p.channels.first.group, '央视,付费');
    });

    test('支持 #EXTGRP 分组写法', () {
      const s = '''
#EXTM3U
#EXTINF:-1,北京卫视
#EXTGRP:地方台
http://a/bj.m3u8
''';
      final p = parseIptvPlaylist(s);
      expect(p.channels.first.group, '地方台');
      expect(p.groups, ['地方台']);
    });

    test('group-title 优先于 #EXTGRP', () {
      const s = '''
#EXTM3U
#EXTINF:-1 group-title="卫视",东方卫视
#EXTGRP:地方台
http://a/df.m3u8
''';
      expect(parseIptvPlaylist(s).channels.first.group, '卫视');
    });
  });

  group('parseIptvPlaylist 健壮性', () {
    test('同名同地址的重复条目只留一条', () {
      const s = '''
#EXTM3U
#EXTINF:-1,CCTV1
http://a/1.m3u8
#EXTINF:-1,CCTV1
http://a/1.m3u8
#EXTINF:-1,CCTV1
http://b/1.m3u8
''';
      final p = parseIptvPlaylist(s);
      // 地址不同算两条（互为备份），完全相同的才去重
      expect(p.length, 2);
    });

    test('没有 #EXTINF 的裸地址不算是频道', () {
      expect(parseIptvPlaylist('http://a/1.m3u8\nhttp://a/2.m3u8').length, 0);
    });

    test('非协议行（注释/说明文字）被跳过', () {
      const s = '''
#EXTM3U
#PLAYLIST: IPTV Channel List
#AUTHOR: Jenkins Auto Build
#DATE: 2026-11-05 05:26:24
#EXTINF:-1,CCTV1
这是一段说明文字
http://a/1.m3u8
''';
      final p = parseIptvPlaylist(s);
      expect(p.length, 1);
      expect(p.channels.first.url, 'http://a/1.m3u8');
    });

    test('CRLF 换行也能解析', () {
      const s = '#EXTM3U\r\n#EXTINF:-1,CCTV1\r\nhttp://a/1.m3u8\r\n';
      expect(parseIptvPlaylist(s).length, 1);
    });

    test('空文本返回空列表', () {
      expect(parseIptvPlaylist('').isEmpty, true);
      expect(parseIptvPlaylist('#EXTM3U\n').isEmpty, true);
    });

    test('没有 group-title 的频道归到「其他」', () {
      const s = '''
#EXTM3U
#EXTINF:-1 tvg-id="AndoTV.cn@SD",Ando TV (1080p)
http://a/x.m3u8
''';
      final p = parseIptvPlaylist(s);
      expect(p.channels.first.group, '其他');
      expect(p.groups, ['其他']);
    });

    test('台名本身带逗号时不会被截断', () {
      // 分界必须取「第一个引号外逗号」，取最后一个会把台名切成「综合」
      const s = '''
#EXTM3U
#EXTINF:-1 group-title="央视",CCTV-1, 综合
http://a/1.m3u8
#EXTINF:-1 tvg-name="A, B",C, D
http://a/2.m3u8
''';
      final p = parseIptvPlaylist(s);
      expect(p.channels[0].name, 'CCTV-1, 综合');
      expect(p.channels[0].group, '央视');
      expect(p.channels[1].name, 'C, D');
    });

    test('属性里的引号值不会被当成显示名的一部分', () {
      const s = '''
#EXTM3U
#EXTINF:-1 tvg-logo="http://a/x.png" tvg-id="cctv1",CCTV-1 综合
http://a/1.m3u8
''';
      final p = parseIptvPlaylist(s);
      expect(p.channels.first.name, 'CCTV-1 综合');
      expect(p.channels.first.tvgId, 'cctv1');
    });

    test('#EXTVLCOPT 之类的播放器参数不影响解析', () {
      const s = '''
#EXTM3U
#EXTINF:-1,CCTV1
#EXTVLCOPT:http-user-agent=Mozilla/5.0
#EXTVLCOPT:http-referrer=http://a/
http://a/1.m3u8
''';
      final p = parseIptvPlaylist(s);
      expect(p.length, 1);
      expect(p.channels.first.url, 'http://a/1.m3u8');
    });
  });

  group('IptvChannel 判定', () {
    IptvChannel ch(String name, [String url = 'http://a/1.m3u8']) =>
        IptvChannel(name: name, url: url);

    test('4K / UHD / 2160 认成 4K', () {
      expect(ch('CCTV4K 超高清').is4K, true);
      expect(ch('CCTV-1 UHD').is4K, true);
      expect(ch('某台 2160P').is4K, true);
    });

    test('HD/1080/超清 算高清但不算 4K', () {
      expect(ch('湖南卫视 HD').isHd, true);
      expect(ch('湖南卫视 HD').is4K, false);
      expect(ch('某台 1080P').isHd, true);
      expect(ch('某台 1080P').is4K, false);
    });

    test('普通频道两个都是 false', () {
      expect(ch('CCTV-1 综合').isHd, false);
      expect(ch('CCTV-1 综合').is4K, false);
    });

    test('rtp/udp 组播地址标为不可播', () {
      expect(ch('组播台', 'rtp://239.1.1.1:5000').playable, false);
      expect(ch('组播台', 'udp://@239.1.1.1:5000').playable, false);
    });

    test('http/https/rtsp/rtmp 可播', () {
      expect(ch('a', 'http://a/1.m3u8').playable, true);
      expect(ch('a', 'https://a/1.m3u8').playable, true);
      expect(ch('a', 'rtsp://a/1').playable, true);
      expect(ch('a', 'rtmp://a/1').playable, true);
    });
  });

  group('IptvPlaylist 过滤', () {
    final p = parseIptvPlaylist('''
#EXTM3U
#EXTINF:-1 group-title="央视",CCTV1
http://a/1.m3u8
#EXTINF:-1 group-title="央视",CCTV5 体育
http://a/5.m3u8
#EXTINF:-1 group-title="卫视",湖南卫视
http://a/hn.m3u8
''');

    test('按分组过滤', () {
      expect(p.filterGroup('央视').length, 2);
      expect(p.filterGroup('卫视').length, 1);
      expect(p.filterGroup(null).length, 3);
    });

    test('搜索匹配频道名与分组', () {
      expect(p.search('cctv').length, 2);
      expect(p.search('湖南').length, 1);
      expect(p.search('卫视').length, 1);
      expect(p.search('').length, 3);
    });
  });

  group('播放要求（UA / Referer）', () {
    test('#EXTINF 里的 http-user-agent 会被取出来', () {
      // iptv-org 体育源里 54 条是这样：UA 值自带括号和逗号，
      // 必须先找到引号外的逗号才能正确切出频道名
      const s = '''
#EXTM3U
#EXTINF:-1 tvg-id="ArenaSport1.sk@SD" tvg-logo="http://a/x.png" http-user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.3" group-title="Sports",Arena Sport 1
http://a/as1.m3u8
''';
      final p = parseIptvPlaylist(s);
      expect(p.length, 1);
      final c = p.channels.first;
      expect(c.name, 'Arena Sport 1');
      expect(c.group, 'Sports');
      expect(c.userAgent, contains('Chrome/149'));
      expect(c.playHeaders?['User-Agent'], contains('Chrome/149'));
    });

    test('http-referrer 也会被取出来', () {
      const s = '''
#EXTM3U
#EXTINF:-1 http-referrer="https://live.example.com/" group-title="Sports",NBA TV
http://a/nba.m3u8
''';
      final c = parseIptvPlaylist(s).channels.first;
      expect(c.referrer, 'https://live.example.com/');
      expect(c.playHeaders?['Referer'], 'https://live.example.com/');
    });

    test('#EXTVLCOPT 形式的 UA 也认', () {
      const s = '''
#EXTM3U
#EXTINF:-1,CCTV5
#EXTVLCOPT:http-user-agent=Mozilla/5.0 (Windows NT 10.0)
http://a/c5.m3u8
''';
      final c = parseIptvPlaylist(s).channels.first;
      expect(c.userAgent, contains('Mozilla/5.0'));
    });

    test('http-referer（单个 r）也要认', () {
      const s = '''
#EXTM3U
#EXTINF:-1 http-referer="https://live.example.com/" group-title="Sports",NBA TV
http://a/nba.m3u8
''';
      final c = parseIptvPlaylist(s).channels.first;
      expect(c.referrer, 'https://live.example.com/');
    });

    test('withGroup 只换分组，其余字段原样保留', () {
      const line = '#EXTINF:-1 tvg-id="x" tvg-logo="http://a/l.png" '
          'http-user-agent="UA" http-referrer="http://r/" '
          'group-title="Kids;Sports",NBA TV';
      final c = parseIptvPlaylist('#EXTM3U\n$line\nhttp://a/nba.m3u8\n')
          .channels
          .first;
      expect(c.userAgent, 'UA');
      expect(c.referrer, 'http://r/');
      final moved = c.withGroup('体育');
      expect(moved.group, '体育');
      expect(moved.name, c.name);
      expect(moved.url, c.url);
      expect(moved.logo, c.logo);
      expect(moved.tvgId, c.tvgId);
      expect(moved.userAgent, c.userAgent);
      expect(moved.referrer, c.referrer);
    });

    test('没有播放要求时 playHeaders 为 null', () {
      const s = '''
#EXTM3U
#EXTINF:-1,CCTV1
http://a/1.m3u8
''';
      expect(parseIptvPlaylist(s).channels.first.playHeaders, null);
    });

    test('UA 不会串到下一条频道上', () {
      const s = '''
#EXTM3U
#EXTINF:-1 http-user-agent="UA-A",台一
http://a/1.m3u8
#EXTINF:-1,台二
http://a/2.m3u8
''';
      final p = parseIptvPlaylist(s);
      expect(p.channels[0].userAgent, 'UA-A');
      expect(p.channels[1].userAgent, '');
    });
  });

  group('体育频道判定', () {
    IptvChannel ch(String name, [String group = '']) =>
        IptvChannel(name: name, url: 'http://a/1.m3u8', group: group);

    test('分组是 Sports 就算体育', () {
      expect(ch('ESPN', 'Sports').isSports, true);
    });

    test('中文体育台按名字识别', () {
      expect(ch('CCTV5 体育赛事').isSports, true);
      expect(ch('五星体育').isSports, true);
      expect(ch('NBA TV').isSports, true);
      expect(ch('睛彩篮球').isSports, true);
    });

    test('普通卫视不算体育', () {
      expect(ch('湖南卫视', '卫视频道').isSports, false);
      expect(ch('CCTV1', '央视频道').isSports, false);
    });

    test('体育彩票不算体育直播', () {
      expect(ch('体育彩票开奖', '其他').isSports, false);
    });

    test('扩充后的关键词（英超/斯诺克/F1）也能认', () {
      expect(ch('英超直播').isSports, true);
      expect(ch('斯诺克台').isSports, true);
      expect(ch('F1 赛车').isSports, true);
    });
  });

  group('内置源定义', () {
    test('每个源的 path 都形如 owner/repo/branch/file', () {
      for (final s in kIptvSources) {
        expect(s.path.split('/').length >= 4, true, reason: s.id);
        expect(s.channels > 0, true, reason: s.id);
        expect(s.health >= 0 && s.health <= 100, true, reason: s.id);
      }
    });

    test('源 id 不重复', () {
      final ids = kIptvSources.map((s) => s.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('sourceOf 能查到，未知 id 返回 null', () {
      expect(IptvService.sourceOf(kIptvSources.first.id)?.id,
          kIptvSources.first.id);
      expect(IptvService.sourceOf('不存在'), null);
    });

    test('镜像列表最后一项是直连（兜底）', () {
      expect(kIptvMirrors.last,
          'https://raw.githubusercontent.com/');
    });

    test('体育源存在且可直接取（绝对地址不走镜像）', () {
      final sports =
          kIptvSources.where((s) => s.category == IptvCategory.sports);
      expect(sports.isNotEmpty, true);
      for (final s in sports) {
        expect(s.isAbsolute, true, reason: '${s.id} 应指向 github.io 完整地址');
        expect(s.path, startsWith('http'));
      }
    });

    test('其它源都是 raw 相对路径（要走镜像降级）', () {
      for (final s in kIptvSources) {
        if (s.category == IptvCategory.sports) continue;
        expect(s.isAbsolute, false, reason: s.id);
      }
    });

    test('statsText 在没测过的源上不会显示成 0 台', () {
      const unknown = IptvSourceDef(id: 'x', name: '自定义', path: 'a/b/c/d');
      expect(unknown.statsText, '');
      const measured = IptvSourceDef(
          id: 'y', name: '内置', path: 'a/b/c/d', channels: 200, health: 80);
      expect(measured.statsText, '200台 · ~80%');
    });

    test('体育源带 NBA 角标', () {
      final sports =
          kIptvSources.firstWhere((s) => s.category == IptvCategory.sports);
      expect(sports.badge, 'NBA');
      expect(sports.groupOverride, '体育');
    });
  });
}
