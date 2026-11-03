import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/page_scraper.dart';
import 'player_page.dart';

/// 「输入网址就能播」：类似夸克浏览器的网页视频抓取。
///
/// 输入框接受：
/// - 视频直链（.m3u8 / .mp4）；
/// - 任意影视站播放页（先走专用解析，再走通用 HTML 嗅探）；
/// - 一整段分享文案（自动抠出里面的链接）。
class WebGrabPage extends StatefulWidget {
  final String? initialUrl;
  const WebGrabPage({super.key, this.initialUrl});

  @override
  State<WebGrabPage> createState() => _WebGrabPageState();
}

class _WebGrabPageState extends State<WebGrabPage> {
  final TextEditingController _input = TextEditingController();
  final PageScraper _scraper = PageScraper.instance;

  GrabResult? _result;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final init = widget.initialUrl;
    if (init != null && init.isNotEmpty) {
      _input.text = init;
      WidgetsBinding.instance.addPostFrameCallback((_) => _grab());
    }
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _pasteAndGrab() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.trim().isEmpty) {
      _toast('剪贴板里没有文字');
      return;
    }
    _input.text = text.trim();
    await _grab();
  }

  Future<void> _grab() async {
    final raw = _input.text.trim();
    if (raw.isEmpty) {
      _toast('先粘贴一个网址');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
      _result = null;
    });
    try {
      final r = await _scraper.grab(raw);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _result = r;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is GrabException ? e.message : e.toString();
      });
    }
  }

  void _playAll() {
    final r = _result;
    if (r == null || r.videos.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerPage(resource: r.toResource(), resume: false),
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final r = _result;
    return Scaffold(
      appBar: AppBar(
        title: const Text('网址抓取'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          TextField(
            controller: _input,
            minLines: 1,
            maxLines: 4,
            textInputAction: TextInputAction.go,
            onSubmitted: (_) => _grab(),
            decoration: InputDecoration(
              hintText: '粘贴视频页网址或分享文案，如 https://example.com/play/123',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              prefixIcon: const Icon(Icons.link_rounded),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _loading ? null : _grab,
                  icon: _loading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.radar_rounded),
                  label: Text(_loading ? '正在解析…' : '解析这个网址'),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _loading ? null : _pasteAndGrab,
                icon: const Icon(Icons.content_paste_rounded, size: 18),
                label: const Text('粘贴'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _tips(scheme),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.errorContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline_rounded,
                      size: 18, color: scheme.error),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_error!, style: const TextStyle(fontSize: 13))),
                ],
              ),
            ),
          ],
          if (r != null) ...[
            const SizedBox(height: 18),
            _ResultCard(
              result: r,
              onPlay: _playAll,
            ),
          ],
        ],
      ),
    );
  }

  Widget _tips(ColorScheme scheme) {
    final lines = const [
      '· 视频直链（.m3u8 / .mp4）可以直接丢进来播',
      '· 爱看机器人（ikanbot）能一次抓出全部线路和分集',
      '· 其它网站只读一次 HTML：地址在 JS 里动态生成（含加密/登录）就抓不到',
      '· 抓到的地址只用于本次播放，不会保存到服务器',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final l in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Text(
              l,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }
}

class _ResultCard extends StatelessWidget {
  final GrabResult result;
  final VoidCallback onPlay;

  const _ResultCard({required this.result, required this.onPlay});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final groups = <String, int>{};
    for (final v in result.videos) {
      groups[v.group] = (groups[v.group] ?? 0) + 1;
    }
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // 0 条结果不是「完成」：给对勾会让用户以为成功了、只是没显示
                Icon(
                  result.isEmpty
                      ? Icons.search_off_rounded
                      : Icons.check_circle_rounded,
                  size: 18,
                  color: result.isEmpty ? scheme.error : scheme.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    result.title.isEmpty
                        ? (result.isEmpty ? '没找到视频地址' : '解析完成')
                        : result.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              result.isEmpty
                  ? '静态解析没在这个页面里找到可播放地址'
                  : '共 ${result.videos.length} 个地址 · ${groups.length} 条线路',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final e in groups.entries)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text('${e.key}（${e.value}）',
                        style: const TextStyle(fontSize: 11)),
                  ),
              ],
            ),
            if (result.note != null) ...[
              const SizedBox(height: 8),
              Text(
                result.note!,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: onPlay,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('播放全部（按线路分组）'),
              ),
            ),
            if (result.videos.length <= 6) ...[
              const Divider(height: 20),
              for (final v in result.videos)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        v.isHls
                            ? Icons.playlist_play_rounded
                            : Icons.movie_outlined,
                        size: 16,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${v.group} ${v.note.isEmpty ? '' : '· ${v.note}'}\n${v.url}',
                          style: const TextStyle(fontSize: 11, height: 1.4),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
