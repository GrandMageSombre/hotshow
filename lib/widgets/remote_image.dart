import 'package:flutter/material.dart';

import '../services/remote_ua.dart';

/// 海报/封面统一加载组件。
///
/// 豆瓣图床（`img*.doubanio.com`）会按 **User-Agent** 拦截请求：
/// 不带浏览器 UA 时（Flutter 的 [NetworkImage] 默认发 `Dart/3.x (dart:io)`）
/// 直接返回 403 / 418，只有 `Referer` 也没用；换成浏览器 UA + 站点 Referer
/// 才会返回 200。这就是「有些剧的抓取图片加载不出来」的根因。
///
/// 另外豆瓣把同一张图分发在 img1 / img2 / img3 / img9 多个域名上，个别网络下
/// 某个域名可能解析失败，因此这里按域名轮询重试；采集站的海报则按同源
/// Referer + 浏览器 UA 请求，避免多数站点的防盗链。
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

/// 同一张图的候选地址：豆瓣图床按 img1→img2→img3→img9 轮询。
List<String> imageCandidates(String raw) {
  final url = normalizeImageUrl(raw);
  if (url.isEmpty) return const [];
  final uri = Uri.tryParse(url);
  if (uri == null || !_isDoubanHost(uri.host)) return [url];
  final host = uri.host.split('.').first;
  if (!_doubanHosts.contains(host)) return [url];
  final result = <String>[url];
  for (final h in _doubanHosts) {
    if (h == host) continue;
    result.add(uri.replace(host: '$h.doubanio.com').toString());
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

/// 带 Referer / UA、失败自动换域名重试的图片组件。
///
/// [placeholder] 用于空地址、加载中与最终失败三种情况（保持列表骨架稳定）。
class RemoteImage extends StatefulWidget {
  final String url;
  final BoxFit fit;
  final WidgetBuilder placeholder;

  /// 解码尺寸（物理像素），传了可显著降低大图在手机上的内存占用
  final int? cacheWidth;

  const RemoteImage({
    super.key,
    required this.url,
    required this.placeholder,
    this.fit = BoxFit.cover,
    this.cacheWidth,
  });

  @override
  State<RemoteImage> createState() => _RemoteImageState();
}

class _RemoteImageState extends State<RemoteImage> {
  /// 加载失败的图（含所有候选域名都失败）在这里记一笔，
  /// 列表滚动回来时不再重复打 4 次请求。
  static final Map<String, DateTime> _deadUrls = {};
  static const Duration _deadTtl = Duration(minutes: 10);

  late List<String> _urls = imageCandidates(widget.url);
  int _index = 0;

  /// 换 item / 换地址时自增，用于作废上一张图排队中的重试回调
  int _generation = 0;
  bool _advancing = false;

  @override
  void didUpdateWidget(RemoteImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _urls = imageCandidates(widget.url);
      _index = 0;
      _generation++;
      _advancing = false;
    }
  }

  /// 当前地址失败时换下一个域名。errorBuilder 在 build 期间执行，
  /// 因此用 postFrame 推迟 setState，避免「build 中 setState」。
  void _tryNextHost(Object error) {
    if (_advancing) return;

    // 404 / 410 说明这个路径在 CDN 上根本不存在，换域名也一样，直接记死
    final notFound = error is NetworkImageLoadException &&
        (error.statusCode == 404 || error.statusCode == 410);
    if (notFound || _index + 1 >= _urls.length) {
      _markDead();
      return;
    }

    _advancing = true;
    final generation = _generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        if (_index + 1 < _urls.length) _index++;
        _advancing = false;
      });
    });
  }

  void _markDead() {
    if (_urls.isEmpty) return;
    if (_deadUrls.length > 300) _deadUrls.clear();
    _deadUrls[_urls.first] = DateTime.now();
  }

  bool get _isDead {
    if (_urls.isEmpty) return false;
    final key = _urls.first;
    final at = _deadUrls[key];
    if (at == null) return false;
    if (DateTime.now().difference(at) > _deadTtl) {
      _deadUrls.remove(key);
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    if (_urls.isEmpty || _isDead) return widget.placeholder(context);
    final index = _index.clamp(0, _urls.length - 1);
    final url = _urls[index];
    return Image.network(
      url,
      fit: widget.fit,
      headers: imageHeaders(url),
      cacheWidth: widget.cacheWidth,
      gaplessPlayback: true,
      // 加载中先占位，加载完直接显示，避免列表里出现「先空后跳」
      frameBuilder: (context, child, frame, wasSyncLoaded) {
        if (wasSyncLoaded) return child;
        if (frame == null) return widget.placeholder(context);
        return child;
      },
      errorBuilder: (context, error, stack) {
        _tryNextHost(error);
        return widget.placeholder(context);
      },
    );
  }
}
