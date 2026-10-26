import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/show_item.dart';
import '../services/show_service.dart';
import '../widgets/common_views.dart';
import '../widgets/remote_image.dart';
import 'resource_page.dart';

class DetailPage extends StatefulWidget {
  final ShowItem item;
  const DetailPage({super.key, required this.item});

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  late Future<ShowDetail> _future;
  ShowDetail? _detail;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _future = ShowService().detail(widget.item).then((d) {
      _detail = d;
      return d;
    });
  }

  /// 用于提升采集站片名匹配精度的年份
  String? get _year {
    final text = _detail?.pubdate ?? widget.item.subtitle;
    return RegExp(r'(?:19|20)\d{2}').firstMatch(text)?.group(0);
  }

  Future<void> _openPlay() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ResourcePage(
          item: widget.item,
          year: _year,
          altTitles: _detail?.aka ?? const [],
        ),
      ),
    );
  }

  Future<void> _openDouban() async {
    final uri = Uri.parse(widget.item.doubanUrl);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法打开浏览器')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '在浏览器中打开豆瓣页面',
            onPressed: _openDouban,
            icon: const Icon(Icons.open_in_new_rounded),
          ),
        ],
      ),
      body: FutureBuilder<ShowDetail>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) {
            return ErrorRetry(
              error: snap.error,
              onRetry: () => setState(_load),
            );
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return _DetailBody(item: widget.item, detail: snap.data!);
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            onPressed: _openPlay,
            icon: const Icon(Icons.play_circle_fill_rounded),
            label: const Text('播放（检索完整资源）'),
          ),
        ),
      ),
    );
  }
}

class _DetailBody extends StatelessWidget {
  final ShowItem item;
  final ShowDetail detail;
  const _DetailBody({required this.item, required this.detail});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final d = detail;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 120,
                height: 168,
                child: RemoteImage(
                  url: item.cover,
                  cacheWidth:
                      (120 * MediaQuery.devicePixelRatioOf(context)).round(),
                  placeholder: (_) => Container(
                    color: scheme.surfaceContainerHighest,
                    child: const Icon(Icons.movie_outlined),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    d.item.title,
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  if (d.aka.isNotEmpty && d.aka.first != d.item.title)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        d.aka.take(2).join(' / '),
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.star_rounded,
                          size: 20, color: Colors.amber.shade700),
                      const SizedBox(width: 2),
                      Text(
                        (d.item.rating ?? 0) > 0
                            ? d.item.rating!.toStringAsFixed(1)
                            : '暂无评分',
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      if ((d.item.ratingCount ?? 0) > 0)
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Text(
                            '${d.item.ratingCount} 人评价',
                            style: TextStyle(
                                fontSize: 12, color: scheme.onSurfaceVariant),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (d.genres.isNotEmpty)
                    Text('类型：${d.genres.join(' / ')}',
                        style: const TextStyle(fontSize: 13)),
                  if (d.countries.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('地区：${d.countries.join(' / ')}',
                          style: const TextStyle(fontSize: 13)),
                    ),
                  if (d.pubdate.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('首播：${d.pubdate}',
                          style: const TextStyle(fontSize: 13)),
                    ),
                  if (d.episodesCount != null && d.episodesCount! > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('集数：${d.episodesCount}',
                          style: const TextStyle(fontSize: 13)),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        if (d.directors.isNotEmpty)
          _personRow('导演', d.directors),
        if (d.actors.isNotEmpty)
          _personRow('主演', d.actors.take(6).toList()),
        if (item.comment != null && item.comment!.isNotEmpty) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.format_quote_rounded,
                        size: 16, color: scheme.primary),
                    const SizedBox(width: 4),
                    Text('热门短评',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: scheme.primary)),
                  ],
                ),
                const SizedBox(height: 6),
                Text(item.comment!, style: const TextStyle(fontSize: 13, height: 1.5)),
              ],
            ),
          ),
        ],
        const SizedBox(height: 18),
        const Text('剧情简介',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(
          d.intro.isEmpty ? '暂无简介' : d.intro,
          style: const TextStyle(fontSize: 14, height: 1.7),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _personRow(String label, List<String> names) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$label：', style: const TextStyle(fontSize: 13)),
          Expanded(
            child: Text(names.join(' / '),
                style: const TextStyle(fontSize: 13, height: 1.4)),
          ),
        ],
      ),
    );
  }
}
