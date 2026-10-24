import 'package:flutter/material.dart';

import '../services/api_client.dart';

/// 错误占位 + 重试按钮
class ErrorRetry extends StatelessWidget {
  final Object? error;
  final VoidCallback onRetry;

  const ErrorRetry({super.key, this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final msg = error is ApiException
        ? (error as ApiException).message
        : '加载失败，请检查网络后重试';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded,
                size: 44, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(msg, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}

/// 空数据占位
class EmptyHint extends StatelessWidget {
  final String message;
  const EmptyHint({super.key, this.message = '暂无内容'});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inbox_rounded,
                size: 44, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

/// 列表加载更多/到底提示
class ListTail extends StatelessWidget {
  final bool hasMore;
  const ListTail({super.key, required this.hasMore});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Center(
        child: hasMore
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              )
            : Text('— 没有更多了 —',
                style: TextStyle(fontSize: 12, color: scheme.outline)),
      ),
    );
  }
}
