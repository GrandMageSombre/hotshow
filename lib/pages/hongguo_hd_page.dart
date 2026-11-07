import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models/media_resource.dart';
import '../services/hongguo_hd_fetcher.dart';
import 'player_page.dart';

/// 红果高清（720p）：**原生播放**。
///
/// 页面上看不到任何网页 —— 解密在一个 2×2、藏在页面角落的隐藏 WebView 里跑
/// （站点自带的加密播放器负责解密），拿到的明文 fMP4 合并成 mp4 缓存到本地，
/// 再交给项目自己的 [PlayerPage]（media_kit/libmpv）播放。
///
/// 相比 v1.17.0「可见 WebView 直接播」：不会带出站点 UI、不会被站点跳转打断、
/// 站点播放器抢不到前台，失败率明显下降；播放体验和采集站片源完全一致。
///
/// 一集解码后落盘缓存（`.../hongguo_hd/{series}_{vid}_720p.mp4`），重看/切集回来不再解密。
class HongguoHdPage extends StatefulWidget {
  const HongguoHdPage({
    super.key,
    required this.seriesId,
    required this.title,
    required this.vids,
    this.initialIndex = 0,
  });

  final String seriesId;
  final String title;

  /// 全部单集 vid（详情页 `vid_list`）
  final List<String> vids;
  final int initialIndex;

  @override
  State<HongguoHdPage> createState() => _HongguoHdPageState();
}

class _HongguoHdPageState extends State<HongguoHdPage> {
  late final HongguoHdFetcher _fetcher;
  late int _index;

  String _status = '';
  double? _progress;
  bool _failed = false;
  bool _busy = false;

  bool get _supported {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

  @override
  void initState() {
    super.initState();
    _index = widget.vids.isEmpty
        ? 0
        : widget.initialIndex.clamp(0, widget.vids.length - 1);
    _fetcher = HongguoHdFetcher(onStatus: (s, {progress, failed}) {
      if (!mounted) return;
      setState(() {
        _status = s;
        _progress = progress;
        _failed = failed ?? false;
      });
    });
    if (_supported && widget.vids.isNotEmpty) {
      // 进页就自动准备当前集
      WidgetsBinding.instance.addPostFrameCallback((_) => _play(_index));
    }
  }

  @override
  void dispose() {
    _fetcher.dispose();
    super.dispose();
  }

  Future<void> _play(int index) async {
    if (_busy || widget.vids.isEmpty) return;
    setState(() {
      _index = index;
      _busy = true;
      _failed = false;
      _status = '正在准备第 ${index + 1} 集…';
      _progress = null;
    });
    try {
      final File file = await _fetcher.fetch(
        seriesId: widget.seriesId,
        vid: widget.vids[index],
        definition: '720p',
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '';
        _progress = null;
      });
      final res = MediaResource(
        siteId: 'hongguo_hd',
        siteName: '红果高清 720P',
        vodId: widget.seriesId,
        title: widget.title,
        remarks: '第${index + 1}集 · 本地解密',
        groups: [
          PlayGroup(
            name: '高清 720P',
            episodes: [
              Episode(
                name: '第${index + 1}集',
                url: Uri.file(file.path).toString(),
              ),
            ],
          ),
        ],
      );
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PlayerPage(resource: res, altTitles: [widget.title]),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _failed = true;
        _status = _friendly(e);
        _progress = null;
      });
    }
  }

  static String _friendly(Object e) {
    final s = e.toString();
    if (s.contains('unsupported')) {
      return '当前系统 WebView 太旧，不支持高清解密。\n'
          '请在应用商店更新「Android System WebView」或 Chrome 后重试。';
    }
    return s.replaceFirst('Bad state: ', '').replaceFirst('Exception: ', '');
  }

  Future<void> _pickEpisode() async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    const Text('选集', style: TextStyle(fontWeight: FontWeight.w600)),
                    const Spacer(),
                    Text('共 ${widget.vids.length} 集',
                        style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(ctx).colorScheme.outline)),
                  ],
                ),
              ),
              SizedBox(
                height: 240,
                child: GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 64,
                    mainAxisExtent: 44,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: widget.vids.length,
                  itemBuilder: (_, i) {
                    final on = i == _index;
                    return InkWell(
                      onTap: () => Navigator.pop(ctx, i),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: on
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text('${i + 1}', style: const TextStyle(fontSize: 13)),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
    if (picked == null || picked == _index) return;
    await _play(picked);
  }

  @override
  Widget build(BuildContext context) {
    if (!_supported) return _unsupported(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton.icon(
            onPressed: _busy ? null : _pickEpisode,
            icon: const Icon(Icons.list_rounded, size: 18),
            label: Text('第${_index + 1}集'),
          ),
        ],
      ),
      body: Stack(
        children: [
          // 隐藏的解密用 WebView（2×2，压在角落，不接手势）
          Positioned(
            left: 0,
            top: 0,
            child: IgnorePointer(
              child: SizedBox(
                width: 2,
                height: 2,
                child: WebViewWidget(controller: _fetcher.controller),
              ),
            ),
          ),
          Positioned.fill(child: _body(context)),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!_failed)
              SizedBox(
                width: 46,
                height: 46,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  value: _progress,
                ),
              ),
            const SizedBox(height: 20),
            Text(
              _status.isEmpty ? '高清 720P' : _status,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                height: 1.6,
                color: _failed ? scheme.error : scheme.onSurfaceVariant,
              ),
            ),
            if (_progress != null && !_failed) ...[
              const SizedBox(height: 8),
              Text('${(_progress! * 100).toStringAsFixed(0)}%',
                  style: TextStyle(fontSize: 12, color: scheme.outline)),
            ],
            const SizedBox(height: 22),
            Wrap(
              spacing: 12,
              alignment: WrapAlignment.center,
              children: [
                if (_failed)
                  FilledButton.tonalIcon(
                    onPressed: () => _play(_index),
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('重试'),
                  ),
                if (!_busy)
                  OutlinedButton.icon(
                    onPressed: _pickEpisode,
                    icon: const Icon(Icons.list_rounded),
                    label: const Text('选集'),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            Text(
              '首次播放需在本机解密这一集（几十秒），之后有缓存、秒开。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: scheme.outline, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _unsupported(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.phone_android_rounded, size: 44),
              const SizedBox(height: 16),
              const Text(
                '手机端高清解密只在 Android / iOS 上可用。\n'
                '当前环境没有系统 WebView。',
                textAlign: TextAlign.center,
                style: TextStyle(height: 1.6),
              ),
              const SizedBox(height: 12),
              Text(
                '桌面端请用：tool/hongguo_hd/decrypt.cjs',
                style: TextStyle(
                    fontSize: 12, color: Theme.of(context).colorScheme.outline),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
