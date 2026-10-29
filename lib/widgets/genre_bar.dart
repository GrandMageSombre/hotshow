import 'package:flutter/material.dart';

import '../models/genre.dart';

/// 全应用通用的「类型」筛选条。
///
/// 横向滚动的紧凑 chip 列表，首项固定是「全部」。放在榜单/搜索结果上方，
/// 命中后由调用方切换数据源（[ShowService.fetchByGenre]）。
class GenreBar extends StatefulWidget {
  final List<Genre> genres;
  final Genre selected;
  final ValueChanged<Genre> onSelected;

  /// 左侧说明文字，传空串可隐藏
  final String label;
  final EdgeInsetsGeometry padding;

  const GenreBar({
    super.key,
    required this.genres,
    required this.selected,
    required this.onSelected,
    this.label = '类型',
    this.padding = const EdgeInsets.fromLTRB(12, 0, 12, 6),
  });

  @override
  State<GenreBar> createState() => _GenreBarState();
}

class _GenreBarState extends State<GenreBar> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 高度按字号缩放（上限 1.6 倍），避免大字号下 chip 被裁
    final height = MediaQuery.textScalerOf(context)
        .clamp(maxScaleFactor: 1.6)
        .scale(20) * 2;
    return Padding(
      padding: widget.padding,
      child: SizedBox(
        height: height.clamp(40, 64),
        child: ListView(
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          children: [
            if (widget.label.isNotEmpty)
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Row(
                    children: [
                      Icon(Icons.category_outlined,
                          size: 15, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 4),
                      Text(
                        widget.label,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            for (final g in widget.genres)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text(g.label),
                  selected: g == widget.selected,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  labelStyle: const TextStyle(fontSize: 12),
                  // 已选中的 chip 也要回调：搜索页的「全部」在关键词模式下虽然高亮，
                  // 但点它应当回到搜索历史（调用方各自决定是否真的重取数据）
                  onSelected: (_) => widget.onSelected(g),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
