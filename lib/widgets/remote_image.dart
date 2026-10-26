import 'dart:async';

import 'package:flutter/material.dart';

import '../app_info.dart';
import '../services/remote_ua.dart';

/// 海报/封面统一加载组件。
///
/// 豆瓣图床（`img*.doubanio.com`）会按 **User-Agent** 拦截请求：
/// 不带浏览器 UA 时（Flutter 的 [NetworkImage] 默认发 `Dart/3.x (dart:io)`）
/// 直接返回 403 / 418，只有 `Referer` 也没用；换成浏览器 UA + 站点 Referer
/// 才会返回 200。这就是「有些剧的抓取图片加载不出来」的根因。
///
/// 线上还遇到过几类失败，所以这里按「尝试链」逐级降级：
/// 1. `img1/2/3/9.doubanio.com` 四个域名（带 UA + Referer）；
/// 2. 原域名的 `http://`（个别网络会破坏 CDN 的 TLS）；
/// 3. 原地址但**不带自定义请求头**（极少数代理会拒绝带 Referer 的请求）。
/// 每一步有 12 秒看门狗，失败后自动换下一个；全部失败才落占位图，
/// 并记住 10 分钟避免列表滚动时反复重试。
///
/// 长按封面可弹出诊断信息（地址 / 错误 / 已尝试项 / 应用版本），
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

/// 一次加载尝试：地址 + 是否带自定义请求头
class _Attempt {
  final String url;
  final bool useHeaders;

  const _Attempt(this.url, this.useHeaders);

  String get label => useHeaders ? url : '$url（无自定义头）';
}

List<_Attempt> _attemptsFor(String raw) {
  final url = normalizeImageUrl(raw);
  if (url.isEmpty) return const [];
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasAuthority) return [_Attempt(url, true)];

  final result = <_Attempt>[];
  void add(String u, bool headers) {
    if (result.any((a) => a.url == u && a.useHeaders == headers)) return;
    result.add(_Attempt(u, headers));
  }

  if (_isDoubanHost(uri.host)) {
    for (final h in _doubanHosts) {
      add(uri.replace(scheme: 'https', host: '$h.doubanio.com').toString(), true);
    }
    add(uri.replace(scheme: 'http').toString(), true);
    add(uri.replace(scheme: 'https').toString(), false);
  } else {
    add(url, true);
    add(url, false);
  }
  return result;
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
  /// 加载失败的图（含所有候选都失败）在这里记一笔，
  /// 列表滚动回来时不再重复打一轮请求。
  static final Map<String, DateTime> _deadUrls = {};
  static const Duration _deadTtl = Duration(minutes: 10);
  static const Duration _attemptTimeout = Duration(seconds: 12);

  late List<_Attempt> _attempts = _attemptsFor(widget.url);
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
      _attempts = _attemptsFor(widget.url);
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

  @override
  Widget build(BuildContext context) {
    if (_attempts.isEmpty) {
      return GestureDetector(
        onLongPress: _showDiagnostics,
        child: widget.placeholder(context),
      );
    }
    if (_isDead) {
      return GestureDetector(
        onLongPress: _showDiagnostics,
        child: widget.placeholder(context),
      );
    }
    final index = _index.clamp(0, _attempts.length - 1);
    final attempt = _attempts[index];
    return Image.network(
      attempt.url,
      fit: widget.fit,
      headers: attempt.useHeaders ? imageHeaders(attempt.url) : null,
      cacheWidth: widget.cacheWidth,
      gaplessPlayback: true,
      // 加载中先占位，加载完直接显示，避免列表里出现「先空后跳」
      frameBuilder: (context, child, frame, wasSyncLoaded) {
        if (wasSyncLoaded) {
          _watchdog?.cancel();
          return child;
        }
        if (frame == null) {
          return GestureDetector(
            onLongPress: _showDiagnostics,
            child: widget.placeholder(context),
          );
        }
        _watchdog?.cancel();
        return child;
      },
      errorBuilder: (context, error, stack) {
        _tryNext(error);
        return GestureDetector(
          onLongPress: _showDiagnostics,
          child: widget.placeholder(context),
        );
      },
    );
  }
}
