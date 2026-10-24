import 'package:flutter/material.dart';

import '../models/show_item.dart';
import '../pages/detail_page.dart';
import '../services/history_store.dart';

/// 海报卡片，首页/搜索/历史通用。
class ShowCard extends StatelessWidget {
  final ShowItem item;
  final double coverWidth;

  const ShowCard({super.key, required this.item, this.coverWidth = 108});

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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: coverWidth,
                  height: coverWidth * 1.4,
                  child: item.cover.isEmpty
                      ? _coverFallback(scheme)
                      : Image.network(
                          item.cover,
                          fit: BoxFit.cover,
                          headers: const {'Referer': 'https://movie.douban.com/'},
                          errorBuilder: (_, _, _) => _coverFallback(scheme),
                          loadingBuilder: (c, child, progress) =>
                              progress == null ? child : _coverFallback(scheme),
                        ),
                ),
              ),
              if (_ratingText != null)
                Positioned(
                  left: 0,
                  bottom: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.72),
                      borderRadius: const BorderRadius.horizontal(
                          right: Radius.circular(6)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.star_rounded,
                            color: Colors.amber, size: 13),
                        const SizedBox(width: 2),
                        Text(
                          _ratingText!,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: coverWidth,
            child: Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, height: 1.25),
            ),
          ),
          if (item.subtitle.isNotEmpty)
            SizedBox(
              width: coverWidth,
              child: Text(
                item.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _coverFallback(ColorScheme scheme) => Container(
        color: scheme.surfaceContainerHighest,
        child: Center(
          child: Icon(Icons.movie_creation_outlined,
              size: 30, color: scheme.outlineVariant),
        ),
      );
}

/// 统计 3 列网格的卡片宽度。
double gridCardWidth(double viewportWidth) {
  const padding = 12.0;
  const spacing = 12.0;
  final usable = viewportWidth - padding * 2;
  final columns = (usable / 118).floor().clamp(2, 6);
  return (usable - spacing * (columns - 1)) / columns;
}
