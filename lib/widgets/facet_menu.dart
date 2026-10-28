import 'package:flutter/material.dart';

import '../models/facet.dart';

/// 紧凑的「地区 / 年份」下拉筛选：一颗 chip + 弹出菜单。
///
/// 类型用横向 chip 条（[GenreBar]），地区/年份选项多达十几个，
/// 再铺两条 chip 会占掉 80dp 高度，改成一排可点的小按钮。
class FacetMenu extends StatelessWidget {
  final String label;
  final List<FacetOption> options;
  final FacetOption selected;
  final ValueChanged<FacetOption> onSelected;

  const FacetMenu({
    super.key,
    required this.label,
    required this.options,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = !selected.isAll;
    return PopupMenuButton<FacetOption>(
      tooltip: label,
      initialValue: selected,
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final o in options)
          PopupMenuItem<FacetOption>(
            value: o,
            child: Row(
              children: [
                Expanded(child: Text(o.label)),
                if (o == selected)
                  Icon(Icons.check_rounded, size: 16, color: scheme.primary),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active
              ? scheme.primary.withValues(alpha: 0.12)
              : scheme.surfaceContainerHighest.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              selected.isAll ? label : selected.label,
              style: TextStyle(
                fontSize: 12,
                color: active ? scheme.primary : scheme.onSurfaceVariant,
                fontWeight: active ? FontWeight.bold : FontWeight.normal,
              ),
            ),
            Icon(
              Icons.arrow_drop_down_rounded,
              size: 16,
              color: active ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}
