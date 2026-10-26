import 'package:flutter/material.dart';

import '../models/show_item.dart';
import '../pages/detail_page.dart';
import '../services/history_store.dart';
import 'remote_image.dart';
import 'show_grid.dart';

/// 海报卡片，首页/搜索/历史通用。
///
/// 卡片宽度由网格决定，海报用 [AspectRatio] 跟随单元格宽度，
/// 不再接收外部传死的 `coverWidth`（旧实现里卡片宽度和网格列数各算一套，
/// 窄屏上会把海报顶出单元格）。
class ShowCard extends StatelessWidget {
  final ShowItem item;

  const ShowCard({super.key, required this.item});

  String? get _ratingText {
    final r = item.rating;
    if (r == null || r <= 0) return null;
    return r.toStringAsFixed(1);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () {
        historyStore.addView(item);
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => DetailPage(item: item)),
        );
      },
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: ShowGridMetrics.maxTextScale,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 1 / ShowGridMetrics.posterAspectRatio,
              child: LayoutBuilder(builder: (context, box) {
                final dpr = MediaQuery.devicePixelRatioOf(context);
                return Stack(
                  children: [
                    Positioned.fill(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: RemoteImage(
                          url: item.cover,
                          cacheWidth: (box.maxWidth * dpr).round(),
                          placeholder: (_) => _coverFallback(scheme),
                        ),
                      ),
                    ),
                    if (_ratingText != null)
                      Positioned(
                        left: 0,
                        bottom: 6,
                        child: _ratingBadge(_ratingText!),
                      ),
                  ],
                );
              }),
            ),
            const SizedBox(height: ShowGridMetrics.coverTextGap),
            Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: ShowGridMetrics.titleFontSize,
                height: ShowGridMetrics.lineHeightFactor,
              ),
            ),
            if (item.subtitle.isNotEmpty)
              Text(
                item.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: ShowGridMetrics.subtitleFontSize,
                  height: ShowGridMetrics.lineHeightFactor,
                  color: scheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _ratingBadge(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.72),
          borderRadius: const BorderRadius.horizontal(right: Radius.circular(6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.star_rounded, color: Colors.amber, size: 13),
            const SizedBox(width: 2),
            Text(
              text,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      );

  Widget _coverFallback(ColorScheme scheme) => Container(
        color: scheme.surfaceContainerHighest,
        child: Center(
          child: Icon(Icons.movie_creation_outlined,
              size: 30, color: scheme.outlineVariant),
        ),
      );
}
