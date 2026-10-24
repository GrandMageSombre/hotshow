import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../models/media_resource.dart';
import '../services/offline_cache.dart';
import '../services/playback_store.dart';

/// 播放页：media_kit（libmpv）播放 m3u8，支持选集、线路切换、倍速、
/// 自动连播、播放进度记忆与离线缓存。
class PlayerPage extends StatefulWidget {
  final MediaResource resource;

  /// 是否沿用上次播放进度（从资源列表进入时为 true，手动选集时为 false）
  final bool resume;

  const PlayerPage({super.key, required this.resource, this.resume = true});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
  static const _rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];

  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);

  late final StreamSubscription<bool> _completedSub;
  late final StreamSubscription<String> _errorSub;
  Timer? _progressTimer;

  int _groupIndex = 0;
  int _episodeIndex = 0;
  Duration? _pendingSeek;
  double _rate = 1.0;
  bool _autoNext = true;
  bool _isLocal = false;
  bool _opening = true;
  String? _error;

  // 整条线路批量缓存
  int _batchDone = 0;
  int _batchTotal = 0;
  bool _batchAbort = false;

  MediaResource get _r => widget.resource;

  PlayGroup? get _group => _r.groupAt(_groupIndex);

  Episode? get _episode {
    final g = _group;
    if (g == null) return null;
    return (_episodeIndex >= 0 && _episodeIndex < g.episodes.length)
        ? g.episodes[_episodeIndex]
        : null;
  }

  OfflineCache get _cache => offlineCache;

  @override
  void initState() {
    super.initState();
    _groupIndex = _resolveInitialGroup();
    _episodeIndex = _resolveInitialEpisode();
    _applyResumeRecord();

    _completedSub = _player.stream.completed.listen(_onCompleted);
    _errorSub = _player.stream.error.listen((e) {
      if (mounted) setState(() => _error = e);
    });
    _progressTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _saveProgress(),
    );
    _cache.addListener(_onCacheTick);

    WidgetsBinding.instance.addPostFrameCallback((_) => _openCurrent());
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    _completedSub.cancel();
    _errorSub.cancel();
    _cache.removeListener(_onCacheTick);
    _saveProgress();
    _player.dispose();
    super.dispose();
  }

  void _onCacheTick() {
    if (mounted) setState(() {});
  }

  int _resolveInitialGroup() {
    final d = _r.defaultGroup;
    if (d == null) return 0;
    return _r.groups.indexOf(d);
  }

  int _resolveInitialEpisode() => 0;

  /// 若存在上次进度且未看完，则沿用上次的线路 / 集 / 位置
  void _applyResumeRecord() {
    if (!widget.resume) return;
    final rec = playbackStore.of(_r.key);
    if (rec == null || rec.finished || !rec.hasProgress) return;
    final g = _r.groupAt(rec.groupIndex);
    if (g == null || rec.episodeIndex >= g.episodes.length) return;
    _groupIndex = rec.groupIndex;
    _episodeIndex = rec.episodeIndex;
    _pendingSeek = Duration(milliseconds: rec.positionMs);
  }

  Map<String, String> _headersFor(String url) {
    final u = Uri.tryParse(url);
    return {
      'User-Agent': _ua,
      if (u != null && u.hasAuthority)
        'Referer': '${u.scheme}://${u.authority}/',
    };
  }

  String _cacheKeyFor(int group, int episode) =>
      cacheKeyOf(_r.siteId, _r.vodId, group, episode);

  Future<void> _openCurrent({Duration? seekTo}) async {
    final ep = _episode;
    if (ep == null) {
      setState(() {
        _opening = false;
        _error = '该线路没有可播放的剧集';
      });
      return;
    }
    final cached = _cache.byKey(_cacheKeyFor(_groupIndex, _episodeIndex));
    final useLocal =
        cached != null && File(cached.localFile).existsSync();
    final uri = useLocal ? Uri.file(cached.localFile).toString() : ep.url;

    setState(() {
      _opening = true;
      _error = null;
      _isLocal = useLocal;
    });
    try {
      await _player.open(
        Media(uri, httpHeaders: useLocal ? null : _headersFor(ep.url)),
        play: true,
      );
      final target = seekTo ?? _pendingSeek;
      _pendingSeek = null;
      if (target != null && target > const Duration(seconds: 3)) {
        await _player.seek(target);
      }
      await _player.setRate(_rate);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _switchEpisode(int index, {int? group}) async {
    if (group != null && group != _groupIndex) {
      final len = _r.groupAt(group)?.length ?? 1;
      setState(() {
        _groupIndex = group;
        _episodeIndex = index.clamp(0, len - 1).toInt();
      });
    } else {
      setState(() => _episodeIndex = index);
    }
    await _saveProgress();
    await _openCurrent();
  }

  Future<void> _onCompleted(bool completed) async {
    if (!completed || !_autoNext) return;
    final g = _group;
    if (g == null || _episodeIndex + 1 >= g.episodes.length) return;
    await _switchEpisode(_episodeIndex + 1);
  }

  Future<void> _saveProgress() async {
    final ep = _episode;
    if (ep == null) return;
    final pos = _player.state.position;
    final dur = _player.state.duration;
    if (pos.inMilliseconds <= 0) return;
    await playbackStore.save(PlaybackRecord(
      key: _r.key,
      groupIndex: _groupIndex,
      episodeIndex: _episodeIndex,
      positionMs: pos.inMilliseconds,
      durationMs: dur.inMilliseconds,
      title: _r.title,
      episodeName: ep.name,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  // ---------------------------------------------------------------- 缓存

  Future<void> _cacheCurrentEpisode() async {
    final ep = _episode;
    if (ep == null) return;
    final key = _cacheKeyFor(_groupIndex, _episodeIndex);
    if (_cache.byKey(key) != null) {
      _toast('该集已缓存');
      return;
    }
    _toast('开始缓存「${ep.name}」');
    try {
      await _cache.download(
        key: key,
        title: _r.title,
        episodeName: ep.name,
        m3u8Url: ep.url,
        headers: _headersFor(ep.url),
      );
      _toast('「${ep.name}」缓存完成，可在离线状态播放');
    } on OfflineCacheException catch (e) {
      _toast('缓存失败：${e.message}');
    }
  }

  Future<void> _cacheWholeGroup() async {
    final g = _group;
    if (g == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('缓存整条线路'),
        content: Text(
            '将顺序缓存「${g.name}」线路共 ${g.episodes.length} 集到本地，'
            '耗时与占用的存储空间取决于片源大小。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('开始')),
        ],
      ),
    );
    if (ok != true) return;

    setState(() {
      _batchAbort = false;
      _batchDone = 0;
      _batchTotal = g.episodes.length;
    });
    for (var i = 0; i < g.episodes.length; i++) {
      if (_batchAbort || !mounted) break;
      final key = _cacheKeyFor(_groupIndex, i);
      if (_cache.byKey(key) != null) {
        setState(() => _batchDone = i + 1);
        continue;
      }
      try {
        await _cache.download(
          key: key,
          title: _r.title,
          episodeName: g.episodes[i].name,
          m3u8Url: g.episodes[i].url,
          headers: _headersFor(g.episodes[i].url),
        );
      } on OfflineCacheException catch (e) {
        _toast('第 ${i + 1} 集缓存失败：${e.message}');
      }
      if (mounted) setState(() => _batchDone = i + 1);
    }
    final aborted = _batchAbort;
    if (mounted) {
      setState(() {
        _batchTotal = 0;
        _batchDone = 0;
      });
    }
    _toast(aborted ? '已停止批量缓存' : '整条线路缓存完成');
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 3),
      ));
  }

  // ---------------------------------------------------------------- 界面

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_r.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15)),
            Text(
              '${_episode?.name ?? ''} · ${_r.siteName} · ${_group?.name ?? ''}'
              '${_isLocal ? ' · 本地' : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Colors.white70),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: _autoNext ? '关闭自动连播' : '开启自动连播',
            onPressed: () => setState(() => _autoNext = !_autoNext),
            icon: Icon(_autoNext
                ? Icons.playlist_play_rounded
                : Icons.playlist_remove_rounded),
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (v) {
              switch (v) {
                case 'replay':
                  _openCurrent(seekTo: Duration.zero);
                case 'cache':
                  _cacheCurrentEpisode();
                case 'cache_all':
                  _cacheWholeGroup();
                case 'clear':
                  _cache.remove(_cacheKeyFor(_groupIndex, _episodeIndex));
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'replay', child: Text('从头播放')),
              PopupMenuItem(value: 'cache', child: Text('缓存当前集')),
              PopupMenuItem(value: 'cache_all', child: Text('缓存整条线路')),
              PopupMenuItem(value: 'clear', child: Text('清除本集缓存')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: _wrapControls()),
                if (_opening)
                  const Positioned.fill(
                    child: IgnorePointer(
                      child: Center(
                        child: SizedBox(
                          width: 34,
                          height: 34,
                          child: CircularProgressIndicator(strokeWidth: 2.4),
                        ),
                      ),
                    ),
                  ),
                if (_error != null)
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 16,
                    child: Material(
                      color: Colors.red.shade900,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Text(
                          '播放失败：$_error',
                          style: const TextStyle(
                              fontSize: 12, color: Colors.white),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          _bottomBar(),
        ],
      ),
    );
  }

  /// 用 media_kit 自带的 AdaptiveVideoControls（进度条/手势/全屏），
  /// 并按平台定制底部按钮栏，额外挂上「选集 / 缓存 / 倍速」。
  Widget _wrapControls() {
    final video = Video(
      controller: _controller,
      // 每次 build 传新闭包，使自定义按钮能跟随页面状态（倍速、缓存进度）刷新
      controls: (state) => AdaptiveVideoControls(state),
      fit: BoxFit.contain,
    );
    final desktop = _isDesktop;
    final bar = <Widget>[
      if (desktop)
        const MaterialDesktopPositionIndicator()
      else
        const MaterialPositionIndicator(),
      const Spacer(),
      _barButton(desktop, Icons.video_library_outlined, _openEpisodesSheet, '选集'),
      _cacheBarButton(desktop),
      _rateButton(desktop),
      if (desktop)
        const MaterialDesktopFullscreenButton()
      else
        const MaterialFullscreenButton(),
    ];

    if (desktop) {
      return MaterialDesktopVideoControlsTheme(
        normal: MaterialDesktopVideoControlsThemeData(
          topButtonBar: const [],
          bottomButtonBar: bar,
          visibleOnMount: true,
          modifyVolumeOnScroll: true,
        ),
        fullscreen: MaterialDesktopVideoControlsThemeData(
          topButtonBar: const [],
          bottomButtonBar: bar,
        ),
        child: video,
      );
    }
    return MaterialVideoControlsTheme(
      normal: MaterialVideoControlsThemeData(
        topButtonBar: const [],
        bottomButtonBar: bar,
        visibleOnMount: true,
        seekOnDoubleTap: true,
        speedUpOnLongPress: true,
        speedUpFactor: 2.0,
      ),
      fullscreen: MaterialVideoControlsThemeData(
        topButtonBar: const [],
        bottomButtonBar: bar,
      ),
      child: video,
    );
  }

  bool get _isDesktop {
    final p = defaultTargetPlatform;
    return p == TargetPlatform.windows ||
        p == TargetPlatform.linux ||
        p == TargetPlatform.macOS;
  }

  Widget _barButton(
      bool desktop, IconData icon, VoidCallback onPressed, String tooltip) {
    return Tooltip(
      message: tooltip,
      child: desktop
          ? MaterialDesktopCustomButton(
              icon: Icon(icon), onPressed: onPressed)
          : MaterialCustomButton(icon: Icon(icon), onPressed: onPressed),
    );
  }

  Widget _rateButton(bool desktop) {
    return PopupMenuButton<double>(
      tooltip: '倍速',
      initialValue: _rate,
      onSelected: (v) {
        setState(() => _rate = v);
        _player.setRate(v);
      },
      itemBuilder: (_) => [
        for (final r in _rates)
          PopupMenuItem(value: r, child: Text('${r}x')),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Text(
          '${_rate}x',
          style: const TextStyle(
              color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _cacheBarButton(bool desktop) {
    final key = _cacheKeyFor(_groupIndex, _episodeIndex);
    final cached = _cache.byKey(key);
    final progress = _cache.progressOf(key);
    if (progress != null) {
      return Tooltip(
        message: progress.text,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: SizedBox(
            width: 24,
            height: 24,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(
                  value: progress.total == 0 ? null : progress.ratio,
                  strokeWidth: 2.2,
                  color: Colors.white,
                ),
                Text(
                  '${(progress.ratio * 100).toInt()}',
                  style: const TextStyle(fontSize: 8, color: Colors.white),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return _barButton(
      desktop,
      cached != null
          ? Icons.download_done_rounded
          : Icons.download_outlined,
      cached != null
          ? () => _toast('本集已缓存到本地')
          : _cacheCurrentEpisode,
      cached != null ? '已缓存本集' : '缓存本集',
    );
  }

  Widget _bottomBar() {
    final scheme = Colors.white;
    return Container(
      color: Colors.black,
      padding: EdgeInsets.fromLTRB(16, 10, 12, 10 + MediaQuery.of(context).padding.bottom),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _episode?.name ?? '—',
                  style: TextStyle(
                      color: scheme, fontSize: 15, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_r.siteName} · ${_group?.name ?? ''} · '
                  '${_group?.length ?? 0} 集'
                  '${_isLocal ? ' · 本地缓存' : ''}',
                  style: const TextStyle(color: Colors.white60, fontSize: 11),
                ),
              ],
            ),
          ),
          if (_batchTotal > 0)
            Text('缓存中 $_batchDone/$_batchTotal',
                style: const TextStyle(color: Colors.orangeAccent, fontSize: 11)),
          IconButton(
            tooltip: '选集',
            onPressed: _openEpisodesSheet,
            icon: const Icon(Icons.list_rounded),
            color: Colors.white,
          ),
        ],
      ),
    );
  }

  Future<void> _openEpisodesSheet() async {
    final g = _group;
    if (g == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _EpisodeSheet(
        resource: _r,
        groupIndex: _groupIndex,
        episodeIndex: _episodeIndex,
        onPick: (group, episode) {
          Navigator.pop(context);
          _switchEpisode(episode, group: group);
        },
      ),
    );
  }
}

/// 选集面板：线路切换 + 分集网格
class _EpisodeSheet extends StatefulWidget {
  final MediaResource resource;
  final int groupIndex;
  final int episodeIndex;
  final void Function(int groupIndex, int episodeIndex) onPick;

  const _EpisodeSheet({
    required this.resource,
    required this.groupIndex,
    required this.episodeIndex,
    required this.onPick,
  });

  @override
  State<_EpisodeSheet> createState() => _EpisodeSheetState();
}

class _EpisodeSheetState extends State<_EpisodeSheet> {
  late int _g = widget.groupIndex;

  @override
  void initState() {
    super.initState();
    offlineCache.addListener(_tick);
  }

  @override
  void dispose() {
    offlineCache.removeListener(_tick);
    super.dispose();
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final groups = widget.resource.groups;
    final episodes = groups[_g].episodes;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                const Text('选集',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const Spacer(),
                Text('共 ${episodes.length} 集',
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          if (groups.length > 1) ...[
            SizedBox(
              height: 46,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  for (var i = 0; i < groups.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text('${groups[i].name}（${groups[i].length}）'),
                        selected: i == _g,
                        onSelected: (_) => setState(() => _g = i),
                      ),
                    ),
                ],
              ),
            ),
          ],
          Flexible(
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              shrinkWrap: true,
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 108,
                childAspectRatio: 2.5,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              itemCount: episodes.length,
              itemBuilder: (context, i) {
                final active = _g == widget.groupIndex && i == widget.episodeIndex;
                final cached = offlineCache.byKey(
                  cacheKeyOf(
                      widget.resource.siteId, widget.resource.vodId, _g, i),
                );
                return InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => widget.onPick(_g, i),
                  child: Container(
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      color: active
                          ? scheme.primaryContainer
                          : scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: active ? scheme.primary : Colors.transparent,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(
                            episodes[i].name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight:
                                  active ? FontWeight.bold : FontWeight.normal,
                            ),
                          ),
                        ),
                        if (cached != null)
                          const Padding(
                            padding: EdgeInsets.only(left: 3),
                            child: Icon(Icons.offline_pin_rounded,
                                size: 12, color: Colors.green),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
