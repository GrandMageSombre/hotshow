import 'package:flutter/material.dart';

import '../models/show_item.dart';
import '../services/paged_show_list.dart';
import 'common_views.dart';
import 'show_card.dart';
import 'show_grid.dart';

/// 三个列表页共用的「三态 + 海报网格 + 触底加载」视图。
///
/// 只负责渲染与滚动触发，数据在 [PagedShowList] 里；页面切筛选时
/// 调 `list.reset()` 并（可选）`scroll.jumpTo(0)`。
class PagedShowGrid extends StatefulWidget {
  final PagedShowList list;
  final Future<void> Function() onRefresh;
  final String emptyMessage;
  final String loadingMoreHint;
  final ScrollController? controller;
  final EdgeInsets padding;

  /// 卡片渲染器。默认海报卡；以后要做「列表视图」只换这里，不用动分页逻辑。
  final Widget Function(BuildContext, ShowItem)? itemBuilder;

  const PagedShowGrid({
    super.key,
    required this.list,
    required this.onRefresh,
    this.emptyMessage = '暂无内容',
    this.loadingMoreHint = '— 没有更多了 —',
    this.controller,
    this.padding = const EdgeInsets.fromLTRB(
      ShowGridMetrics.horizontalPadding,
      4,
      ShowGridMetrics.horizontalPadding,
      12,
    ),
    this.itemBuilder,
  });

  @override
  State<PagedShowGrid> createState() => _PagedShowGridState();
}

class _PagedShowGridState extends State<PagedShowGrid> {
  ScrollController? _own;

  ScrollController get _scroll => widget.controller ?? (_own ??= ScrollController());

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.list,
      builder: (context, _) {
        final list = widget.list;
        if (list.error != null && list.isEmpty) {
          return ErrorRetry(error: list.error, onRetry: () => list.reset());
        }
        if (list.isEmpty && list.loading) {
          return const Center(child: CircularProgressIndicator());
        }
        if (list.isEmpty) {
          return RefreshIndicator(
            onRefresh: widget.onRefresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                const SizedBox(height: 80),
                EmptyHint(message: widget.emptyMessage),
              ],
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: widget.onRefresh,
          child: LayoutBuilder(builder: (context, box) {
            final metrics = ShowGridMetrics.resolve(
              availableWidth: box.maxWidth -
                  ShowGridMetrics.horizontalPadding * 2,
              textScaler: MediaQuery.textScalerOf(context),
            );
            return NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n.metrics.extentAfter < 400) list.loadMore();
                return false;
              },
              child: GridView.builder(
                controller: _scroll,
                physics: const AlwaysScrollableScrollPhysics(),
                padding: widget.padding,
                gridDelegate: metrics.delegate(),
                itemCount: list.items.length + 1,
                itemBuilder: (context, i) {
                  if (i >= list.items.length) {
                    // 翻页失败但已有内容：给个可点的尾巴，而不是静默卡住
                    if (list.error != null) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Center(
                          child: TextButton.icon(
                            onPressed: list.retryMore,
                            icon: const Icon(Icons.refresh_rounded, size: 16),
                            label: const Text('加载失败，点此重试'),
                          ),
                        ),
                      );
                    }
                    return ListTail(hasMore: list.hasMore || list.loading);
                  }
                  final item = list.items[i];
                  return widget.itemBuilder?.call(context, item) ??
                      ShowCard(item: item);
                },
              ),
            );
          }),
        );
      },
    );
  }
}
