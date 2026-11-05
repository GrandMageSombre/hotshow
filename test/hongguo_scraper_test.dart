// 红果短剧 + 网页抓取解析测试：全部用离线 HTML 片段，不联网。
import 'package:flutter_test/flutter_test.dart';
import 'package:hotshow/services/hongguo_service.dart';
import 'package:hotshow/services/page_scraper.dart';
import 'package:hotshow/services/quality_service.dart' show qualityRankOfName;

/// 一段真实的红果榜单卡片结构（来自 /rank/hot-drama 的 SSR HTML）
const _rankHtml = '''
<ol class="pc-list-sXM2Rt" aria-label="红果热播榜">
<li><article><a class="pc-cover-link-Qbvkrw" aria-label="查看甲剧"
  href="/detail?series_id=7701935931787316286">
  <img class="pc-cover-VgjqQf" src="https://img.example.com/a.image"
       alt="甲剧封面" width="160"/></a>
  <div class="pc-content"><a href="/detail?series_id=7701935931787316286">
    <h2 id="rank-title-7701935931787316286" class="pc-title-LHxn_J">甲剧全名</h2></a>
    <ul class="pc-engagement"><li class="pc-status-tag-jwQilp">新剧</li>
      <li class="pc-score-tag-bG08FR">评分9.5</li><li>234.6万收藏</li></ul>
  </div></article></li>
<li><article><a href="/detail?series_id=7600000000000000002">
  <img src="https://img.example.com/b.image" alt="乙剧封面"/></a>
  <div><h2 id="rank-title-7600000000000000002" class="pc-title-LHxn_J">乙剧</h2></div>
</article></li>
</ol>
''';

void main() {
  group('红果 loaderData 解析', () {
    test('按花括号配对取出 JSON，后面跟着代码也能截断', () {
      const html = '<script>_ROUTER_DATA = {"loaderData":{"x":{"a":1}}};'
          'function runWindowFn(){}</script>';
      final data = parseRouterData(html);
      expect(data, isNotNull);
      expect(data!['loaderData'], isA<Map>());
    });

    test('字符串里的花括号不影响配对', () {
      const html = '_ROUTER_DATA = {"k":"} not end {","n":2};';
      expect(parseRouterData(html)!['n'], 2);
    });

    test('没有标记时返回 null', () {
      expect(parseRouterData('<html></html>'), isNull);
    });
  });

  group('红果榜单卡片', () {
    test('抠出剧名/封面/评分/收藏，且按 series_id 去重', () {
      final items = parseRankCards(_rankHtml);
      expect(items.length, 2);
      expect(items.first.seriesId, '7701935931787316286');
      expect(items.first.title, '甲剧全名');
      expect(items.first.cover, 'https://img.example.com/a.image');
      expect(items.first.tags, contains('新剧'));
      expect(items.first.tags.join(), contains('评分9.5'));
      expect(items[1].title, '乙剧');
    });

    test('副标题拼装', () {
      const item = HongguoItem(
        seriesId: '1',
        title: 'x',
        episodeCount: 90,
        tags: ['战争', '家国'],
      );
      expect(item.subtitle, '全90集 · 战争 / 家国');
    });
  });

  group('红果详情 → MediaResource', () {
    test('vid_list 转成逐集 360p 地址', () {
      final res = HongguoService.buildResource(
        {
          'seriesDetail': {
            'series_id': '100',
            'series_name': '测试剧',
            'series_cover': 'https://img/cover.jpg',
            'series_intro': '<p>简介</p>',
            'tags': ['都市'],
            'episode_right_text': '全3集',
            'vid_list': ['111', '222', '333'],
          }
        },
        seriesId: '100',
      );
      expect(res.title, '测试剧');
      expect(res.episodeCount, 3);
      expect(res.intro, '简介');
      expect(res.groups.single.name, '红果短剧');
      expect(res.groups.single.episodes.first.url,
          'https://www.hongguoduanju.com/video/public/111/360p.mp4');
      expect(res.key, 'hongguo#100');
    });

    test('详情缺字段时用列表页卡片兜底', () {
      final res = HongguoService.buildResource(
        {
          'seriesDetail': {'vid_list': ['9']}
        },
        seriesId: '9',
        fallback: const HongguoItem(
            seriesId: '9', title: '兜底标题', cover: 'https://img/x.jpg'),
      );
      expect(res.title, '兜底标题');
      expect(res.cover, 'https://img/x.jpg');
    });

    test('从各种红果网址里取 series_id', () {
      expect(HongguoService.seriesIdOf(
          'https://www.hongguoduanju.com/detail?series_id=77019'), '77019');
      expect(HongguoService.seriesIdOf(
          'https://www.hongguoduanju.com/player/77019'), '77019');
      expect(HongguoService.seriesIdOf('https://example.com/x'), isNull);
    });
  });

  group('爱看机器人 token', () {
    test('取 id 后 4 位、逐位 %3+1 跳过并取 8 位', () {
      // id 后四位 1100 → offs = 2,2,1,1：跳过 2 取 8 → 跳过 2 取 8 → 跳过 1 取 8 …
      const eToken = 'ab' 'cdefghij' 'kl' 'mnopqrst' 'u' 'vwxyz012';
      expect(IkanbotParser.calcToken('611100', eToken),
          'cdefghij' 'mnopqrst' 'vwxyz012');
    });

    test('e_token 不够长时按 JS substring 语义自然变短，而不是整段丢弃', () {
      // id 后四位 9999 → off = 9%3+1 = 1：首轮 substring(1,9) 夹到末尾得 'bcdwxyz'，
      // 之后 rest 已空跳过——对应 JS 里 substring 的夹断行为（旧实现会 break 成 ''）。
      expect(IkanbotParser.calcToken('9999', 'abcdwxyz'), 'bcdwxyz');
      // 比 off 只长 3 位：substring(1,3) 取到 'bc'，而不是整个丢掉（旧实现 break 成 ''）
      expect(IkanbotParser.calcToken('9999', 'abc'), 'bc');
    });

    test('分集地址拆分：集名\$地址#集名\$地址', () {
      final eps = IkanbotParser.splitEpisodeUrls(
          '第01集\$https://a/1.m3u8#第02集\$https://a/2.m3u8');
      expect(eps.length, 2);
      expect(eps.first.name, '第01集');
      expect(eps.first.url, 'https://a/1.m3u8');
    });

    test('换行/制表符/竖线分隔也能拆', () {
      final eps = IkanbotParser.splitEpisodeUrls(
          '第01集\$https://a/1.m3u8\n第02集\$https://a/2.m3u8\t'
          '第03集\$https://a/3.m3u8|https://b/3.m3u8');
      expect(eps.map((e) => e.url).toList(), [
        'https://a/1.m3u8',
        'https://a/2.m3u8',
        'https://a/3.m3u8',
        'https://b/3.m3u8',
      ]);
      expect(eps.last.name, '第03集');
    });

    test('handles 只认本站与其子域，不放行仿冒域名', () {
      const p = IkanbotParser();
      expect(p.handles('https://www.ikanbot.com/play/1'), isTrue);
      expect(p.handles('https://ikanbot.com/play/1'), isTrue);
      expect(p.handles('https://evilikanbot.com/play/1'), isFalse);
      expect(p.handles('https://ikanbot.com.evil.cn/play/1'), isFalse);
    });

    test('只有地址（没有集名）也认', () {
      final eps = IkanbotParser.splitEpisodeUrls('https://a/1.m3u8');
      expect(eps.single.url, 'https://a/1.m3u8');
      expect(eps.single.name, '');
    });
  });

  group('通用网页嗅探', () {
    test('video/source/明文 m3u8/iframe 都能抓到，且去重', () {
      const html = '''
<html><head><title>我的片子</title></head><body>
<video src="https://cdn.example.com/a.mp4"></video>
<source src="//cdn.example.com/b.m3u8">
<script>var u = "https:\\/\\/cdn.example.com\\/a.mp4";</script>
<iframe src="https://player.example.com/embed/1"></iframe>
<a href="https://other.example.com/c.m3u8?sign=1&amp;t=2">x</a>
<img src="https://cdn.example.com/pic.jpg">
</body></html>''';
      final r = PageScraper.parseHtml(html, 'https://example.com/p/1');
      expect(r.title, '我的片子');
      final urls = r.videos.map((e) => e.url).toList();
      expect(urls, contains('https://cdn.example.com/a.mp4'));
      expect(urls, contains('https://cdn.example.com/b.m3u8'));
      expect(urls, contains('https://other.example.com/c.m3u8?sign=1&t=2'));
      expect(urls.where((u) => u == 'https://cdn.example.com/a.mp4').length, 1);
      expect(urls.any((u) => u.endsWith('.jpg')), isFalse);
      // HLS 排前面
      expect(r.videos.first.isHls, isTrue);
    });

    test('抓不到时给出明确说明，而不是空成功', () {
      final r = PageScraper.parseHtml('<html><body>无</body></html>',
          'https://example.com/');
      expect(r.isEmpty, isTrue);
      expect(r.note, isNotNull);
    });

    test('video 标签属性换行、地址含字母 s 也要完整抓出', () {
      // 回归：正则若写成普通字符串 `'\\s'` 会变成「排除字母 s」，这里会被截断
      const html = '<video\n  class="v"\n  src="https://cdn.example.com/s1/sample.m3u8">'
          '</video>';
      final r = PageScraper.parseHtml(html, 'https://example.com/p/1');
      expect(r.videos.single.url, 'https://cdn.example.com/s1/sample.m3u8');
    });

    test('相对地址补全为绝对地址', () {
      expect(
        PageScraper.absolutize('/v/1.m3u8', 'https://a.com/p/x.html'),
        'https://a.com/v/1.m3u8',
      );
      expect(
        PageScraper.absolutize('//cdn.a.com/1.mp4', 'http://a.com/x'),
        'http://cdn.a.com/1.mp4',
      );
      expect(PageScraper.absolutize('javascript:void(0)', 'https://a.com'),
          isNull);
    });

    test('分享文案里抠链接（含中文标点收尾）', () {
      expect(
        PageScraper.extractUrl('快来看 https://a.com/p/1，超好看'),
        'https://a.com/p/1',
      );
      expect(PageScraper.extractUrl('www.b.com/play/2 复制打开'),
          'https://www.b.com/play/2');
      // 裸域名（没写路径）也要认，否则用户直接打域名会被判「没识别到网址」
      expect(PageScraper.extractUrl('ikanbot.com'), 'https://ikanbot.com');
      expect(PageScraper.extractUrl('没有链接'), isNull);
    });

    test('直链识别', () {
      expect(PageScraper.detectMediaUrl('https://a/x.m3u8?a=1'), 'm3u8');
      expect(PageScraper.detectMediaUrl('https://a/x.MP4'), 'mp4');
      expect(PageScraper.detectMediaUrl('https://a/x.html'), isNull);
    });

    test('抓取结果转 MediaResource：线路分组、逐集保留', () {
      const r = GrabResult(
        pageUrl: 'https://site.com/play/1',
        title: '片名',
        videos: [
          GrabbedVideo(group: 'A', url: 'https://a/1.m3u8', note: '第1集'),
          GrabbedVideo(group: 'A', url: 'https://a/2.m3u8', note: '第2集'),
          GrabbedVideo(group: 'B', url: 'https://b/1.m3u8', note: '第1集'),
        ],
      );
      final res = r.toResource();
      expect(res.title, '片名');
      expect(res.groups.length, 2);
      expect(res.groups.first.episodes.length, 2);
      expect(res.siteId, kGrabSiteId);
      expect(res.playable, isTrue);
    });

    test('域名线路名要转成可读档位，否则清晰度菜单会整体消失', () {
      const r = GrabResult(
        pageUrl: 'https://cdn.example.com/play/1',
        videos: [GrabbedVideo(group: 'cdn.example.com', url: 'https://a/1.m3u8')],
      );
      final name = r.toResource().groups.single.name;
      expect(name.contains('example.com'), isFalse);
      expect(qualityRankOfName(name), greaterThan(0));
    });

    test('vodId 用页面地址，不用 hashCode（跨进程不稳定）', () {
      const r = GrabResult(
        pageUrl: 'https://site.com/play/1',
        videos: [GrabbedVideo(group: 'A', url: 'https://a/1.m3u8')],
      );
      expect(r.toResource().vodId, 'https://site.com/play/1');
    });
  });

  group('搜全集用的剧名清洗', () {
    test('去掉「第X部 / 第X季」后缀', () {
      expect(hongguoSearchKeywordOf('十八岁太奶奶驾到，重整家族荣耀第五部'),
          '十八岁太奶奶驾到，重整家族荣耀');
      expect(hongguoSearchKeywordOf('聚宝仙盆之杂灵根才是真BOSS第十五季'),
          '聚宝仙盆之杂灵根才是真BOSS');
      expect(hongguoSearchKeywordOf('某某传第2季'), '某某传');
    });

    test('去掉结尾的括号备注', () {
      expect(hongguoSearchKeywordOf('某某剧（2026）'), '某某剧');
    });

    test('没有后缀的剧名原样返回', () {
      expect(hongguoSearchKeywordOf('和离后我带女儿横扫魔域'),
          '和离后我带女儿横扫魔域');
    });

    test('清洗后太短就保留原名', () {
      // 去掉「第5季」只剩 1 个字，说明原名就靠这个字，别改
      expect(hongguoSearchKeywordOf('第5季'), '第5季');
    });
  });
}
