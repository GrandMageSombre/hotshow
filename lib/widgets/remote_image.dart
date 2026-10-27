import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_info.dart';
import '../services/remote_ua.dart';

/// 海报/封面统一加载组件。
///
/// 豆瓣图床（`img*.doubanio.com`）的 WAF 会拒绝两类请求，都返回 403/418：
///
/// 1. **User-Agent 不是浏览器**：Flutter 的 [NetworkImage] 默认发 `Dart/x.y (dart:io)`；
/// 2. **请求里出现两个 User-Agent**：`HttpClient.getUrl()` 会先自动塞一个默认的
///    `Dart/x.y`，而 [NetworkImage] 用 `headers.add()` 加自定义头 —— 结果请求带着
///    `Dart/x.y` 和浏览器 UA **两个** UA 头，WAF 照样判成机器人。
///
/// 因此这里不用 [Image.network]，而是用自定义 provider 走 `headers.set()`
/// （覆盖语义）自己发请求。实测同一张图：add 双 UA → 403，set 单 UA → 200。
///
/// 线上还遇到过其它失败，按「尝试链」逐级降级：
/// 1. `img1/2/3/9.doubanio.com` 四个域名（浏览器 UA + Referer + Accept）；
/// 2. 原域名的 `http://`（个别网络会破坏 CDN 的 TLS）；
/// 3. 裸请求（去掉 UA/Referer/Accept，模拟无头客户端）。
/// 每步 12 秒看门狗，失败自动切下一个；全部失败落占位图并记 10 分钟负缓存。
///
/// **长按封面**可弹出诊断信息（地址 / 错误 / 尝试链 / 版本），
/// 方便在拿不到 logcat 的手机上定位问题。
const String kImageUserAgent = kBrowserUserAgent;

const String _doubanReferer = 'https://movie.douban.com/';
const List<String> _doubanHosts = ['img1', 'img2', 'img3', 'img9'];

/// 规整图片地址：去空白、补全协议、豆瓣的 http 地址升级成 https。
String normalizeImageUrl(String raw) {
  var url = raw.trim();
  if (url.isEmpty) return '';
  if (url.startsWith('//')) url = 'https:$url';
  final uri = Uri.tryParse(url);
  // 豆瓣只认 https，历史数据里偶尔混着 http（按 host 判断，别看整串）
  if (uri != null && _isDoubanHost(uri.host) && uri.scheme == 'http') {
    return uri.replace(scheme: 'https').toString();
  }
  return url;
}

bool _isDoubanHost(String host) =>
    host.endsWith('doubanio.com') || host.endsWith('douban.com');

/// 豆瓣图片路径：`/view/photo/{尺寸}/public/p1234567890.jpg`
/// 兼容 `p123.jpg.webp` 这类双扩展名（捕获主扩展名）
final RegExp _doubanPhotoPath = RegExp(
  r'/view/photo/[^/]+/public/(p\d+)(?:\.(jpg|jpeg|webp|png))?(?:\.[a-z0-9]+)?$',
  caseSensitive: false,
);

/// 把任意豆瓣图片地址（含 `qnmob*-sign` 的**签名临时地址**）转成稳定地址。
///
/// 搜索接口返回的封面是带 `sa_cv/sa_ct` 签名的 CDN 地址，签名会过期；
/// 过期后 WAF 直接 403/418 —— 表现为「过一会儿再看，动漫封面全白了」。
/// 但路径里的 `p<id>` 是不变的，用它能拼出永不过期的 `img*.doubanio.com` 地址。
/// 扩展名沿用原图（png 强制改成 jpg 可能 404），拿不到就按 jpg。
///
/// 尺寸默认取 `m_ratio_poster`（约 35~90KB）：列表一屏 20 张，用 `l_ratio_poster`
/// （约 320KB）会让流量涨 3 倍多；详情页大图传 [large] 取 `l_ratio_poster`。
List<String> stablePosterCandidates(String raw, {bool large = false}) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || !uri.hasAuthority) return const [];
  if (!_isDoubanHost(uri.host)) return const [];
  final m = _doubanPhotoPath.firstMatch(uri.path);
  if (m == null) return const [];
  final id = m.group(1)!;
  final ext = (m.group(2) ?? 'jpg').toLowerCase();
  final size = large ? 'l_ratio_poster' : 'm_ratio_poster';
  return [
    for (final h in _doubanHosts)
      'https://$h.doubanio.com/view/photo/$size/public/$id.$ext',
  ];
}

/// 同一张图的候选地址：豆瓣图床按 img1→img2→img3→img9 轮询。
List<String> imageCandidates(String raw) {
  final url = normalizeImageUrl(raw);
  if (url.isEmpty) return const [];
  final uri = Uri.tryParse(url);
  if (uri == null || !_isDoubanHost(uri.host)) return [url];
  final host = uri.host.split('.').first;
  final stable = stablePosterCandidates(url);
  if (!_doubanHosts.contains(host)) {
    return [...stable, url];
  }
  final result = <String>[...stable];
  if (!result.contains(url)) result.add(url);
  for (final h in _doubanHosts) {
    final u = uri.replace(host: '$h.doubanio.com').toString();
    if (!result.contains(u)) result.add(u);
  }
  return result;
}

/// 按图源生成请求头：豆瓣固定用 movie.douban.com 做 Referer，
/// 其它站点用自身源站，二者都带上浏览器 UA。
Map<String, String> imageHeaders(String url) {
  final uri = Uri.tryParse(url);
  final headers = <String, String>{
    'User-Agent': kImageUserAgent,
    'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
  };
  if (uri == null || !uri.hasAuthority) return headers;
  headers['Referer'] = _isDoubanHost(uri.host)
      ? _doubanReferer
      : '${uri.scheme}://${uri.authority}/';
  return headers;
}

/// 一次加载尝试：地址 + 请求头模式
class _Attempt {
  final String url;

  /// true = 浏览器 UA + Referer + Accept；false = 裸请求（去掉 UA/Referer/Accept）
  final bool withHeaders;

  const _Attempt(this.url, this.withHeaders);

  String get label => withHeaders ? url : '$url（裸请求，无 UA/Referer）';
}

List<_Attempt> _attemptsFor(String raw, {bool large = false}) {
  final url = normalizeImageUrl(raw);
  if (url.isEmpty) return const [];
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasAuthority) return [_Attempt(url, true)];

  final result = <_Attempt>[];
  void add(String u, bool headers) {
    if (result.any((a) => a.url == u && a.withHeaders == headers)) return;
    result.add(_Attempt(u, headers));
  }

  if (_isDoubanHost(uri.host)) {
    final stable = stablePosterCandidates(url, large: large);
    if (stable.isNotEmpty) {
      // 有稳定地址时只排 2 个镜像 + 原地址：四个域名是同一张图，
      // 全排进链会让一张死图拖到一分多钟（每步 12s 看门狗）
      for (final s in stable.take(2)) {
        add(s, true);
      }
      add(url, true);
    } else {
      // 形如 /f/movie/ 的固定路径无法改写，按镜像轮询
      for (final h in _doubanHosts) {
        add(uri.replace(scheme: 'https', host: '$h.doubanio.com').toString(), true);
      }
    }
    add(uri.replace(scheme: 'http').toString(), true);
    add(uri.replace(scheme: 'https').toString(), false);
  } else {
    add(url, true);
    add(url, false);
  }
  return result;
}

/// 自定义图片 provider：用 `headers.set()` 覆盖默认 Dart UA，
/// 避开 [Image.network] 的 `add()` 双 UA 问题；带 12s 超时与体积上限。
class _FetchImageProvider extends ImageProvider<_FetchImageProvider> {
  const _FetchImageProvider(
    this.url, {
    required this.plain,
    this.cacheWidth,
  });

  final String url;

  /// true = 裸请求（移除 UA/Referer/Accept）
  final bool plain;
  final int? cacheWidth;

  @override
  Future<_FetchImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_FetchImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    _FetchImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _load(key),
      scale: 1.0,
      debugLabel: key.url,
      informationCollector: () sync* {
        yield StringProperty('url', key.url);
        yield FlagProperty('plain', value: key.plain, ifTrue: '裸请求');
      },
    );
  }

  static const int _maxBytes = 20 * 1024 * 1024;

  Future<ui.Codec> _load(_FetchImageProvider key) async {
    final client = HttpClient()..autoUncompress = true;
    try {
      final request = await client.getUrl(Uri.parse(key.url));
      // HttpClient.getUrl() 已经塞了默认 `Dart/x.y` UA，必须 set 覆盖；
      // 用 add 会带上两个 UA，被豆瓣 WAF 判成机器人（403/418）。
      if (key.plain) {
        request.headers.removeAll(HttpHeaders.userAgentHeader);
      } else {
        request.headers.set(HttpHeaders.userAgentHeader, kImageUserAgent);
        imageHeaders(key.url).forEach(request.headers.set);
      }
      final response =
          await request.close().timeout(const Duration(seconds: 12));
      if (response.statusCode != HttpStatus.ok) {
        throw NetworkImageLoadException(
          statusCode: response.statusCode,
          uri: Uri.parse(key.url),
        );
      }
      final bytes = await response.fold<List<int>>(<int>[], (a, b) {
        a.addAll(b);
        if (a.length > _maxBytes) {
          throw Exception('图片超过 ${_maxBytes ~/ 1024 / 1024}MB，已中止');
        }
        return a;
      }).timeout(const Duration(seconds: 20));
      if (bytes.isEmpty) {
        throw Exception('图片内容为空');
      }
      return await ui.instantiateImageCodec(
        Uint8List.fromList(bytes),
        targetWidth: key.cacheWidth,
      );
    } finally {
      client.close(force: true);
    }
  }

  @override
  bool operator ==(Object other) =>
      other is _FetchImageProvider &&
      other.url == url &&
      other.plain == plain &&
      other.cacheWidth == cacheWidth;

  @override
  int get hashCode => Object.hash(url, plain, cacheWidth);

  @override
  String toString() =>
      '${objectRuntimeType(this, "_FetchImageProvider")}("$url")';
}

/// 带 Referer / UA、失败自动降级的图片组件。
///
/// [placeholder] 用于空地址、加载中与最终失败三种情况（保持列表骨架稳定）。
class RemoteImage extends StatefulWidget {
  final String url;
  final BoxFit fit;
  final WidgetBuilder placeholder;

  /// 解码尺寸（物理像素），传了可显著降低大图在手机上的内存占用
  final int? cacheWidth;

  /// 详情页等大尺寸场景传 true，优先取 `l_ratio_poster` 大图
  final bool highQuality;

  const RemoteImage({
    super.key,
    required this.url,
    required this.placeholder,
    this.fit = BoxFit.cover,
    this.cacheWidth,
    this.highQuality = false,
  });

  @override
  State<RemoteImage> createState() => _RemoteImageState();
}

class _RemoteImageState extends State<RemoteImage> {
  /// 加载失败的图（含所有候选都失败）在这里记一笔，
  /// 列表滚动回来时不再重复打一轮请求。
  static final Map<String, DateTime> _deadUrls = {};
  static const Duration _deadTtl = Duration(minutes: 10);
  static const Duration _attemptTimeout = Duration(seconds: 12);

  late List<_Attempt> _attempts = _attemptsFor(
    widget.url,
    large: widget.highQuality,
  );
  int _index = 0;

  /// 换 item / 换地址时自增，用于作废上一张图排队中的重试回调
  int _generation = 0;
  bool _advancing = false;

  Timer? _watchdog;
  Object? _lastError;
  String? _lastUrl;

  @override
  void initState() {
    super.initState();
    _armWatchdog();
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(RemoteImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _attempts = _attemptsFor(widget.url, large: widget.highQuality);
      _index = 0;
      _generation++;
      _advancing = false;
      _lastError = null;
      _lastUrl = null;
      _armWatchdog();
    }
  }

  /// 防止某次请求既不出图也不报错（弱网/被墙时常见）：超时就当失败处理
  void _armWatchdog() {
    _watchdog?.cancel();
    if (_attempts.isEmpty) return;
    _watchdog = Timer(_attemptTimeout, () {
      if (!mounted) return;
      _tryNext(TimeoutException('超过 ${_attemptTimeout.inSeconds}s 未返回'));
    });
  }

  /// 当前尝试失败后降级到下一个。errorBuilder 在 build 期间执行，
  /// 因此用 postFrame 推迟 setState，避免「build 中 setState」。
  void _tryNext(Object error) {
    if (_advancing) return;
    _lastError = error;
    if (_attempts.isNotEmpty) {
      _lastUrl = _attempts[_index.clamp(0, _attempts.length - 1)].url;
    }
    debugPrint('[image] 失败(${_index + 1}/${_attempts.length}) $_lastUrl -> $error');

    // 404 / 410 说明这个路径在 CDN 上根本不存在，换域名也一样，直接记死
    final notFound = error is NetworkImageLoadException &&
        (error.statusCode == 404 || error.statusCode == 410);
    if (notFound || _index + 1 >= _attempts.length) {
      _markDead();
      return;
    }

    _advancing = true;
    final generation = _generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _index++;
        _advancing = false;
      });
      _armWatchdog();
    });
  }

  void _markDead() {
    if (_attempts.isEmpty) return;
    if (_deadUrls.length > 300) _deadUrls.clear();
    _deadUrls[_attempts.first.url] = DateTime.now();
  }

  bool get _isDead {
    if (_attempts.isEmpty) return false;
    final key = _attempts.first.url;
    final at = _deadUrls[key];
    if (at == null) return false;
    if (DateTime.now().difference(at) > _deadTtl) {
      _deadUrls.remove(key);
      return false;
    }
    return true;
  }

  void _retryAll() {
    if (_attempts.isEmpty) return;
    _deadUrls.remove(_attempts.first.url);
    setState(() {
      _index = 0;
      _lastError = null;
      _lastUrl = null;
      _advancing = false;
      _generation++;
    });
    _armWatchdog();
  }

  /// 长按占位图弹出诊断信息：手机上不方便看 logcat 时靠它定位
  void _showDiagnostics() {
    if (!mounted) return;
    final tried = _attempts.isEmpty
        ? '（地址为空）'
        : _attempts
            .asMap()
            .entries
            .map((e) => '${e.key + 1}. ${e.value.label}')
            .join('\n');
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('图片加载诊断'),
        content: SingleChildScrollView(
          child: SelectableText(
            '应用版本：$kAppVersion\n'
            '当前进度：${_attempts.isEmpty ? 0 : _index + 1}/${_attempts.length}\n'
            '最后一次地址：${_lastUrl ?? widget.url}\n'
            '最后一次错误：${_lastError ?? '尚未返回错误（可能仍在加载）'}\n'
            '\n尝试链：\n$tried',
            style: const TextStyle(fontSize: 12, height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _retryAll();
            },
            child: const Text('重新加载'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _showLogHint(ctx);
            },
            child: const Text('日志'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _showLogHint(BuildContext ctx) {
    showDialog<void>(
      context: ctx,
      builder: (c) => AlertDialog(
        title: const Text('抓取详细日志'),
        content: const SelectableText(
          '连电脑后执行：\n\n'
          'adb logcat -s flutter\n\n'
          '再长按一次出问题的封面，就能看到每次请求的地址与错误。',
          style: TextStyle(fontSize: 12, height: 1.6),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('好')),
        ],
      ),
    );
  }

  Widget _wrap(Widget child) =>
      GestureDetector(onLongPress: _showDiagnostics, child: child);

  @override
  Widget build(BuildContext context) {
    if (_attempts.isEmpty || _isDead) {
      return _wrap(widget.placeholder(context));
    }
    final index = _index.clamp(0, _attempts.length - 1);
    final attempt = _attempts[index];
    return Image(
      image: _FetchImageProvider(
        attempt.url,
        plain: !attempt.withHeaders,
        cacheWidth: widget.cacheWidth,
      ),
      fit: widget.fit,
      gaplessPlayback: true,
      // 加载中先占位，加载完直接显示，避免列表里出现「先空后跳」
      frameBuilder: (context, child, frame, wasSyncLoaded) {
        if (wasSyncLoaded) {
          _watchdog?.cancel();
          return child;
        }
        if (frame == null) return _wrap(widget.placeholder(context));
        _watchdog?.cancel();
        return child;
      },
      errorBuilder: (context, error, stack) {
        _tryNext(error);
        return _wrap(widget.placeholder(context));
      },
    );
  }
}
