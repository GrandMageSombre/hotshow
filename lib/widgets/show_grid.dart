import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// 海报网格度量：**列数、卡片宽度、卡片高度由同一处推导**。
///
/// 之前首页/搜索/历史各自写了一份计算：宽度按 `(可用宽度 - 左右内边距)` 求列数、
/// 而 GridView 的 `crossAxisCount` 却按 `整个视口 / 118` 求列数，两者在
/// 354–377dp 这类宽度上会算出一边两列、一边三列（360dp 的机器几乎必现），
/// 于是 `childAspectRatio` 把单元格压矮，海报比单元格高出一大截，
/// 表现为「整张剧照顶出屏幕、盖住下一行」。
///
/// 现在统一走 [ShowGridMetrics.resolve]，并用 `mainAxisExtent`（而不是
/// `childAspectRatio`）锁定单元格高度，任何屏宽都不会再溢出。
class ShowGridMetrics {
  /// 网格左右内边距（GridView 的 padding，不计入单元格宽度）
  static const double horizontalPadding = 12;

  /// 单元格横向/纵向间距
  static const double spacing = 12;
  static const double mainAxisSpacing = 14;

  /// 单张海报的最小宽度，用于决定列数。
  /// 取 100dp：360dp 的常见机型排 3 列（约 104dp），平板最多 6 列。
  static const double minCardWidth = 100;

  /// 海报宽高比：宽 1 : 高 1.4
  static const double posterAspectRatio = 1.4;

  /// 卡片文字区最大放大倍率。系统字体调得很大时只放大到这里，
  /// 保证「海报 + 两行标题」始终能在单元格内排下（再无节制放大就等于不给排版）。
  static const double maxTextScale = 1.6;

  /// 卡片文字样式（与 [ShowCard] 保持一致，改一处即可）
  static const double titleFontSize = 13;
  static const double subtitleFontSize = 11;
  static const double lineHeightFactor = 1.25;
  static const double coverTextGap = 6;
  static const double subtitleGap = 2;

  /// 行高取整会带来不到 1px 的误差，留 2px 余量兜底
  static const double heightSlack = 2;

  final int columns;
  final double itemWidth;
  final double itemHeight;

  const ShowGridMetrics._(this.columns, this.itemWidth, this.itemHeight);

  /// [availableWidth] 是**已经扣掉左右内边距**的可用宽度。
  factory ShowGridMetrics.resolve({
    required double availableWidth,
    required TextScaler textScaler,
  }) {
    final usable = availableWidth.isFinite && availableWidth > 0
        ? availableWidth
        : 1.0;
    // 反推能放下几列：(宽度 + 间距) / (卡片最小宽 + 间距)
    final columns = ((usable + spacing) / (minCardWidth + spacing))
        .floor()
        .clamp(2, 6);
    final itemWidth =
        math.max(1.0, (usable - spacing * (columns - 1)) / columns);
    final scale = effectiveTextScale(textScaler);
    final textHeight = coverTextGap +
        titleFontSize * lineHeightFactor * 2 * scale +
        subtitleGap +
        subtitleFontSize * lineHeightFactor * scale +
        heightSlack;
    return ShowGridMetrics._(
      columns,
      itemWidth,
      itemWidth * posterAspectRatio + textHeight,
    );
  }

  /// 卡片内部实际使用的字体放大倍率（与 [maxTextScale] 对齐）
  static double effectiveTextScale(TextScaler textScaler) =>
      math.min(textScaler.scale(1), maxTextScale);

  /// 配合 [resolve] 使用：GridView 的 padding 与这里的水平内边距保持一致
  SliverGridDelegate delegate() => SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        crossAxisSpacing: spacing,
        mainAxisSpacing: mainAxisSpacing,
        mainAxisExtent: itemHeight,
      );
}
