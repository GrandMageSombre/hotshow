/// 「输入网址就能抓视频」——类似夸克浏览器的网页视频嗅探。
///
/// 三层策略，从省事到费事依次尝试：
/// 1. **直接是播放地址**：`.m3u8` / `.mp4` 等，直接丢给播放器；
/// 2. **站点专用解析**：目前内置 ikanbot（爱看机器人）。它是多线路聚合站，
///    播放页里没有地址，要先算 token 再调 `/api/getResN` 才拿得到，
///    因此单独写一条通道（见 [IkanbotParser]）；
/// 3. **通用网页嗅探**：拉 HTML，用正则扫 `<video>/<source>/<iframe>`、
///    m3u8/mp4 明文地址、JSON 里转义的地址，补全相对路径后去重。
///
/// 不追求「什么站都能播」——只静态解析，不执行 JS，也不做 MITM 抓包。
/// 解析不到的站点会给出明确提示，而不是假装成功。
/// 嗅探结果里的一条视频

library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:charset/charset.dart';

import '../models/media_resource.dart';
import 'remote_ua.dart';

class GrabbedVideo {
  /// 所属线路名（通用嗅探时是页面域名/文件类型）
  final String group;
  final String url;
  final String note;

  const GrabbedVideo({required this.group, required this.url, this.note = ''});

  bool get isHls {
    final u = url.toLowerCase();
    return u.contains('.m3u8') || u.contains('/hls/');
  }

  bool get isMp4 => url.toLowerCase().contains('.mp4');

  @override
  String toString() => '$group -> $url';
}

/// 嗅探的整体结果
class GrabResult {
  final String pageUrl;

  /// 页面标题（解析不到就是空）
  final String title;
  final List<GrabbedVideo> videos;

  /// 解出视频但无法直接播放时（需要登录/加密/JS 播放器）的说明
  final String? note;

  const GrabResult({
    required this.pageUrl,
    this.title = '',
    this.videos = const [],
    this.note,
  });

  bool get isEmpty => videos.isEmpty;

  /// 转成播放页认识的 [MediaResource]：同名线路合并为一组，每个地址一集。
  ///
  /// 线路名必须是**人可读、且能被 `qualityRankOfName` 认出档位**的词：
  /// 播放页的清晰度菜单只认「蓝光/1080p/高清/720p…」这类名字，直接拿域名
  /// 当线路名会让菜单整体判为 0 档而静默消失。
  MediaResource toResource() {
    final byGroup = <String, List<Episode>>{};
    for (final v in videos) {
      final name = v.note.isNotEmpty ? v.note : '第${_count(byGroup, v.group) + 1}集';
      byGroup.putIfAbsent(v.group, () => []).add(Episode(name: name, url: v.url));
    }
    return MediaResource(
      siteId: kGrabSiteId,
      siteName: '网页抓取',
      // 必须是**稳定**的 id：`String.hashCode` 在不同进程间不保证一致，
      // 拿它当 vodId 会让播放进度、离线缓存、字幕偏移在重启后全部对不上。
      vodId: pageUrl,
      title: title.isNotEmpty ? title : PageScraper.hostOf(pageUrl),
      intro: '来源：$pageUrl',
      groups: [
        for (final e in byGroup.entries)
          PlayGroup(name: _lineName(e.key), episodes: e.value),
      ],
    );
  }

  /// 域名 / 文件类型 → 线路名。
  ///
  /// 单码率的网页源本来就没有档位，硬写「高清(1080p)」是虚标；但线路名
  /// 必须带上「高清」二字，因为播放页的清晰度菜单只认这类字样，
  /// 全判 0 档时整个菜单会静默消失，用户会以为「这版本又不能切清晰度」。
  static String _lineName(String group) {
    if (!isEnglishHost(group)) return group;
    final low = group.toLowerCase();
    final hls = low.contains('m3u8') || low.contains('hls');
    return hls ? '网页直连 高清' : '网页直连 标清';
  }

  /// 形如 `abc.com` / `10.0.0.1` 的纯域名（不含中文）
  static bool isEnglishHost(String s) =>
      RegExp(r'^[a-z0-9.\-]+(:\d+)?$', caseSensitive: false).hasMatch(s) &&
      RegExp('[a-zA-Z]').hasMatch(s);

  static int _count(Map<String, List<Episode>> m, String g) => m[g]?.length ?? 0;
}

/// 抓取失败（带用户可读中文）
class GrabException implements Exception {
  final String message;
  const GrabException(this.message);
  @override
  String toString() => message;
}

const String kGrabSiteId = 'webgrab';

/// 网页视频嗅探服务
class PageScraper {
  static final PageScraper instance = PageScraper._();

  final HttpClient _http;
  final IkanbotParser ikanbot = const IkanbotParser();

  PageScraper._()
      : _http = HttpClient()
          ..connectionTimeout = const Duration(seconds: 12)
          ..autoUncompress = true;

  PageScraper.withClient(this._http);

  /// 主入口：[input] 可以是网址，也可以是一整段分享文案（自动抠出第一个 http 链接）
  Future<GrabResult> grab(String input) async {
    final pageUrl = extractUrl(input);
    if (pageUrl == null) {
      throw const GrabException('没有识别到网址，请粘贴形如 https://example.com/xxx 的链接');
    }
    // 1. 直接是媒体文件
    final ext = detectMediaUrl(pageUrl);
    if (ext != null) {
      return GrabResult(
        pageUrl: pageUrl,
        title: _baseNameOf(pageUrl),
        videos: [
          GrabbedVideo(group: '直链', url: pageUrl, note: ext.toUpperCase()),
        ],
      );
    }
    // 2. 站点专用
    if (ikanbot.handles(pageUrl)) {
      try {
        final r = await ikanbot.parse(_http, pageUrl);
        if (r.videos.isNotEmpty) return r;
      } on GrabException {
        rethrow;
      } catch (e) {
        // 专用解析挂了就走通用嗅探兜底
      }
    }
    // 3. 通用嗅探
    final html = await fetchHtml(pageUrl);
    return parseHtml(html, pageUrl);
  }

  Future<String> fetchHtml(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasAuthority) {
      throw const GrabException('网址格式不对');
    }
    try {
      final req = await _http.getUrl(uri);
      req.headers
        ..set('User-Agent', kBrowserUserAgent)
        ..set('Accept', 'text/html,application/xhtml+xml,*/*;q=0.8')
        ..set('Accept-Language', 'zh-CN,zh;q=0.9');
      final resp = await req.close().timeout(const Duration(seconds: 20));
      final bytes = await resp.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      if (resp.statusCode >= 400) {
        throw GrabException('页面返回 HTTP ${resp.statusCode}');
      }
      return decodeBody(bytes, resp.headers.contentType?.charset);
    } on GrabException {
      rethrow;
    } on TimeoutException {
      throw const GrabException('打开页面超时');
    } on SocketException {
      throw const GrabException('无法连接该网站（域名解析或端口不通）');
    } on HandshakeException {
      throw const GrabException('HTTPS 证书校验失败');
    } on HttpException {
      throw const GrabException('打开页面失败');
    }
  }

  /// 纯函数：从 HTML 里抽视频。可与网络无关地单测。
  static GrabResult parseHtml(String html, String pageUrl) {
    final title = extractTitle(html);
    final found = <String, GrabbedVideo>{};

    void add(String raw, String group, {String note = ''}) {
      final abs = absolutize(raw, pageUrl);
      if (abs == null) return;
      final ext = detectMediaUrl(abs);
      if (ext == null) return;
      found.putIfAbsent(abs, () => GrabbedVideo(group: group, url: abs, note: note));
    }

    // 3.1 <video src> / <source src>
    //     注意必须用 raw 字符串：普通字符串里的 `\s` 会被当成字面 `s`，
    //     变成「排除字母 s」，含 s 的地址会被整条截断。
    for (final m in RegExp(
      r'''(?:video|source)[^>]*?\ssrc\s*=\s*["']([^"']+)''',
      caseSensitive: false,
    ).allMatches(html)) {
      add(_unescape(m.group(1)!), '页面视频');
    }
    // 3.2 <iframe src>：单独成线路，标出来源
    for (final m in RegExp(
      r'''iframe[^>]*?\ssrc\s*=\s*["']([^"']+)''',
      caseSensitive: false,
    ).allMatches(html)) {
      add(_unescape(m.group(1)!), '嵌套播放器');
    }
    // 3.3 明文 m3u8 / mp4（含被 JS 字符串转义的 \/）
    //     排除 `&`：HTML 里的 `&amp;`、JSON 里的 `\u0026` 会把后面的实体吞进地址
    final plain = html.replaceAll(r'\/', '/').replaceAll(r'\u002F', '/');
    for (final m in RegExp(
      r'''https?://[^\s"'<>\\]+?\.(?:m3u8|mp4|flv)(?:\?[^\s"'<>\\]*)?''',
    ).allMatches(plain)) {
      // 先还原 `&amp;`（不还原的话 `t=2` 会被当成实体名一起截掉）
      final url = _unescape(m.group(0)!);
      add(url, '页面直链');
    }
    // 3.4 协议相对 //host/x.m3u8
    for (final m in RegExp(r'''["'](//[^\s"'<>\\]+\.(?:m3u8|mp4|flv)[^"']*)''')
        .allMatches(plain)) {
      add(_unescape(m.group(1)!), '页面直链');
    }

    final list = found.values.toList()
      ..sort((a, b) {
        // 有备注（HLS 优先）的排前面，其次按线路名稳定排序
        final byNote = b.isHls == a.isHls ? 0 : (a.isHls ? -1 : 1);
        return byNote != 0 ? byNote : a.group.compareTo(b.group);
      });
    return GrabResult(
      pageUrl: pageUrl,
      title: title,
      videos: list,
      note: list.isEmpty
          ? '这个页面里没有找到直链视频。多数网站的视频地址是 JS 动态请求后才出现的'
              '（常见于 m3u8 加密或需要登录），静态解析拿不到，可以换播放页/分享链接再试。'
          : null,
    );
  }

  /// 从分享文案里抠出第一个 http(s) 链接，并补上缺失的协议前缀。
  static String? extractUrl(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    final m = RegExp(r'''https?://[^\s"<>，。；！？、）】》]+''').firstMatch(t);
    if (m != null) return _trimUrl(m.group(0)!);
    // 用户只输入了 www.xxx.com/abc 或裸域名 www.xxx.com。
    // 路径分支必须用贪婪匹配并排在前面：非贪婪会让 `b.com/play/2` 停在 `b.com`。
    final m2 = RegExp(
            r'''(?:www\.)?[a-z0-9-]+(?:\.[a-z0-9-]+)+(?::\d+)?(?:/[^\s"<>，。；！？、）】》]*)?''',
            caseSensitive: false)
        .firstMatch(t);
    if (m2 != null) return 'https://${_trimUrl(m2.group(0)!)}';
    return null;
  }

  static String _trimUrl(String u) {
    var s = u;
    while (s.isNotEmpty && '，。、）)]】，,.;'.contains(s[s.length - 1])) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  /// 判断是否视频直链，返回扩展名（m3u8/mp4/flv），否则 null。
  static String? detectMediaUrl(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    for (final ext in const ['m3u8', 'mp4', 'flv']) {
      if (path.endsWith('.$ext')) return ext;
    }
    return null;
  }

  /// 相对地址 → 绝对地址；非 http(s)（javascript:、data:、blob:）返回 null。
  static String? absolutize(String raw, String base) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    final b = Uri.tryParse(base);
    if (s.startsWith('//')) {
      return '${b?.scheme ?? 'https'}:$s';
    }
    final u = Uri.tryParse(s);
    if (u == null) return null;
    if (u.hasScheme) {
      if (u.scheme != 'http' && u.scheme != 'https') return null;
      return u.toString();
    }
    if (b == null) return null;
    try {
      return b.resolveUri(u).toString();
    } on ArgumentError {
      return null;
    }
  }

  static String extractTitle(String html) {
    final m = RegExp(r'<title[^>]*>([\s\S]{0,200}?)</title>', caseSensitive: false)
        .firstMatch(html);
    if (m == null) return '';
    return _unescape(m.group(1)!.replaceAll(RegExp(r'\s+'), ' ')).trim();
  }

  static String _unescape(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');

  /// 取域名（供 [GrabResult] 兜底标题用）
  static String hostOf(String url) => Uri.tryParse(url)?.host ?? url;

  static String _baseNameOf(String url) {
    final segs = Uri.tryParse(url)?.pathSegments ?? const [];
    return segs.isEmpty ? '网页视频' : segs.last;
  }

  /// 按 meta charset / HTTP charset 解码（国内老站多为 gbk/gb2312）
  static String decodeBody(List<int> bytes, String? charset) {
    final cs = (charset ?? '').toLowerCase();
    if (cs.contains('gb')) {
      return gbkDecode(bytes);
    }
    if (cs.isEmpty) {
      final head = latin1.decode(
          bytes.length > 2048 ? bytes.sublist(0, 2048) : bytes,
          allowInvalid: true);
      final m = RegExp(r'''charset=["']?\s*([\w-]+)''', caseSensitive: false)
          .firstMatch(head);
      if (m != null && m.group(1)!.toLowerCase().contains('gb')) {
        return gbkDecode(bytes);
      }
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  static String gbkDecode(List<int> bytes) =>
      gbk.decode(bytes, allowMalformed: true);

  void close() => _http.close();
}

/// ikanbot（爱看机器人）专用解析。
///
/// 流程：`/search?q=` 拿结果 → `/play/{id}` 拿 `current_id`/`e_token`/`mtype`
/// → 用 token 算法算出 `v_tks` → `GET /api/getResN?videoId=&mtype=&token=`
/// → 返回 `data.list[].resData`（JSON 字符串），里面就是
/// `第01集$https://…/index.m3u8#第02集$…` 这种 maccms 风格的分集地址。
class IkanbotParser {
  const IkanbotParser();

  static const String host = 'ikanbot.com';

  /// 只认主域本身或其子域。用 `endsWith` 会把 `evilikanbot.com` 之类
  /// 仿冒域名也当成本站，进而拿着页面里的 docid 去拼请求。
  bool handles(String url) {
    final h = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    return h == host || h.endsWith('.$host');
  }

  /// token 算法（对应页面里的 `get_tks()`）：
  /// 取视频 id 的后 4 位，逐位 `n = 数字 % 3 + 1`，从 e_token 里
  /// 依次跳过 n 个字符再取 8 个字符拼起来。注意游标要累加
  /// （JS 里是 `substring(n, n+8)` 之后 `e_token = e_token.substring(n+8)`）。
  static String calcToken(String videoId, String eToken) {
    final tail = videoId.length >= 4
        ? videoId.substring(videoId.length - 4)
        : videoId;
    final buf = StringBuffer();
    var rest = eToken;
    for (var i = 0; i < tail.length; i++) {
      final digit = int.tryParse(tail[i]) ?? 0;
      final off = digit % 3 + 1;
      // 对应 JS 的 substring(off, off + 8)：越界时自然变短，而不是直接放弃。
      // 这里若 break 会把已经算出来的片段之后全丢掉，token 静默截短 → 接口 403。
      if (off >= rest.length) continue;
      final end = off + 8 > rest.length ? rest.length : off + 8;
      buf.write(rest.substring(off, end));
      // JS 的 substring 越界会夹到长度上限，这里必须同样夹住，否则 RangeError
      rest = rest.substring(end > rest.length ? rest.length : end);
    }
    return buf.toString();
  }

  Future<GrabResult> parse(HttpClient http, String url) async {
    final b = Uri.parse(url);
    final origin = '${b.scheme}://${b.host}';
    String? playPath;
    // 已经是播放页
    final playMatch = RegExp(r'^/play/(\d+)').firstMatch(b.path);
    if (playMatch != null) {
      playPath = '/play/${playMatch.group(1)}';
    } else {
      final q = b.queryParameters['q'] ??
          b.queryParameters['keyword'] ??
          b.queryParameters['wd'];
      if (q == null || q.trim().isEmpty) {
        throw const GrabException('爱看机器人请用搜索页或播放页地址（…/search?q=片名 或 …/play/123）');
      }
      // 搜索页是本站最高层级，不能带 Referer（带了会被 WAF 判为盗链直接 403）
      final searchHtml =
          await _get(http, '$origin/search?q=${Uri.encodeQueryComponent(q)}');
      final id = RegExp(r'/play/(\d{3,})').firstMatch(searchHtml)?.group(1);
      if (id == null) {
        throw const GrabException('爱看机器人没有搜到这部片，换个片名试试');
      }
      playPath = '/play/$id';
    }

    final pageUrl = '$origin$playPath';
    final playHtml = await _get(http, pageUrl);
    final id = _input(playHtml, 'current_id') ??
        RegExp(r'/play/(\d{3,})').firstMatch(pageUrl)?.group(1);
    final eToken = _input(playHtml, 'e_token');
    final mType = _input(playHtml, 'mtype') ?? '1';
    final title = PageScraper.extractTitle(playHtml).replaceAll('-爱看机器人-ikanbot.com', '').trim();
    if (id == null || eToken == null) {
      throw const GrabException('爱看机器人页面结构变化（缺少 current_id / e_token）');
    }

    final api = '$origin/api/getResN?videoId=$id&mtype=$mType'
        '&token=${Uri.encodeQueryComponent(calcToken(id, eToken))}';
    final raw = await _get(http, api, pageUrl);
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const GrabException('爱看机器人接口返回异常');
    }
    if (decoded is! Map || decoded['state']?.toString() != '1') {
      throw const GrabException('爱看机器人接口拒绝了请求（token 可能已过期，稍后重试）');
    }
    final data = decoded['data'];
    final list = data is Map ? data['list'] : null;
    if (list is! List) throw const GrabException('爱看机器人没有返回线路');

    final videos = <GrabbedVideo>[];
    var lineNo = 0;
    for (final line in list) {
      if (line is! Map) continue;
      lineNo++;
      final res = _decodeResData(line['resData']);
      final flag = _flagOf(res);
      final group = flag.isNotEmpty ? flag : '线路$lineNo';
      for (final ep in splitEpisodeUrls(_rawUrlOf(res))) {
        videos.add(GrabbedVideo(group: group, url: ep.url, note: ep.name));
      }
    }
    if (videos.isEmpty) {
      throw const GrabException('爱看机器人返回的线路都是空的');
    }
    return GrabResult(pageUrl: pageUrl, title: title, videos: videos);
  }

  /// `resData` 有时是 JSON 字符串，有时已经是数组
  static Object? _decodeResData(Object? res) {
    if (res is String) {
      try {
        return jsonDecode(res);
      } on FormatException {
        return null;
      }
    }
    return res;
  }

  static String _flagOf(Object? res) {
    if (res is List && res.isNotEmpty) {
      final first = res.first;
      if (first is Map) return first['flag']?.toString() ?? '';
    }
    return '';
  }

  static String _rawUrlOf(Object? res) {
    if (res is! List) return '';
    final buf = StringBuffer();
    for (var i = 0; i < res.length; i++) {
      final e = res[i];
      if (e is! Map) continue;
      final u = e['url']?.toString() ?? '';
      if (u.isEmpty) continue;
      if (buf.isNotEmpty) buf.write('#');
      buf.write(u);
    }
    return buf.toString();
  }

  /// 把 `第01集$url#第02集$url` 拆成集名+地址。
  ///
  /// 除了 `#`，还认换行与制表符（部分站点一条一行），`|` 也当分隔符
  /// （有的站写 `url1|url2` 多备选地址）。纯地址串按同样的分隔规则拆。
  static List<({String name, String url})> splitEpisodeUrls(String raw) {
    final out = <({String name, String url})>[];
    for (final piece in raw.split(RegExp(r'[#\r\n\t]'))) {
      final item = piece.trim();
      if (item.isEmpty) continue;
      final sep = item.indexOf(r'$');
      var name = '';
      var url = item;
      if (sep > 0) {
        name = item.substring(0, sep).trim();
        url = item.substring(sep + 1).split(r'$').first.trim();
      }
      for (final one in url.split('|')) {
        final u = one.trim();
        if (!u.startsWith('http')) continue;
        out.add((name: name, url: u));
      }
    }
    return out;
  }

  static String? _input(String html, String id) =>
      RegExp('id="$id"[^>]*value="([^"]*)"').firstMatch(html)?.group(1);

  Future<String> _get(HttpClient http, String url, [String? referer]) async {
    try {
      final req = await http.getUrl(Uri.parse(url));
      req.headers
        ..set('User-Agent', kBrowserUserAgent)
        ..set('Accept', '*/*');
      // 实测：同一站点的 play 页带 Referer 会被 WAF 拦成 403，
      // 只有 /api/getResN 需要带播放页 Referer
      if (referer != null) req.headers.set('Referer', referer);
      final resp = await req.close().timeout(const Duration(seconds: 20));
      final bytes = await resp.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      if (resp.statusCode != 200) {
        throw GrabException('爱看机器人返回 HTTP ${resp.statusCode}');
      }
      return utf8.decode(bytes, allowMalformed: true);
    } on GrabException {
      rethrow;
    } on TimeoutException {
      throw const GrabException('连接爱看机器人超时');
    } on SocketException {
      throw const GrabException('连不上爱看机器人（可能需要梯子或站点已换域名）');
    }
  }
}
