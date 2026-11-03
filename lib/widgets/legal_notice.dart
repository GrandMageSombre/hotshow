import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';


/// 使用声明：本软件为 umena 个人自用，禁止商业使用。
///
/// - **每次冷启动都会弹**（默认），弹窗最下方的勾选项可以关掉自动弹出；
/// - 关掉之后仍可从首页右上角「i」随时查看，并在弹窗里重新打开；
/// - 同一进程内只弹一次（进程被系统回收后重新打开算一次新的冷启动）；
/// - 设置存在 SharedPreferences 的 `legal_notice_on_launch`（默认 true）。
class LegalNotice {
  static const String appName = '热剧速览';
  static const String owner = 'umena';

  /// 项目仓库：反馈、侵权处理、Star 都指向这里
  static const String repoUrl = 'https://github.com/GrandMageSombre/hotshow';
  static const String repoLabel = 'github.com/GrandMageSombre/hotshow';

  /// 启动时是否显示声明的开关（默认开）
  static const String onLaunchKey = 'legal_notice_on_launch';

  /// 同一时刻只允许一个弹窗（防 HotShowApp 重建导致的叠弹）
  static bool _showing = false;

  /// 本次启动已弹过，同一进程内不重复弹（重启后会再弹）
  static bool _seenThisSession = false;

  /// 仅供测试：重置会话内状态（进程内单例，测试之间会互相影响）
  @visibleForTesting
  static void debugResetSession() {
    _showing = false;
    _seenThisSession = false;
  }

  static Future<bool> readOnLaunch() async {
    try {
      final sp = await SharedPreferences.getInstance();
      return sp.getBool(onLaunchKey) ?? true;
    } catch (e) {
      debugPrint('LegalNotice: 读取开关失败（按开启处理）$e');
      return true;
    }
  }

  static Future<void> _writeOnLaunch(bool value) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(onLaunchKey, value);
    } catch (e) {
      debugPrint('LegalNotice: 保存开关失败 $e');
    }
  }

  /// 启动时调用：开关开着就弹（每次启动都弹）
  static Future<void> showIfNeeded(BuildContext context) async {
    if (_showing || _seenThisSession) return;
    // 先占位再 await：读设置期间用户可能点首页「i」，双弹会叠两层模态
    _showing = true;

    final enabled = await readOnLaunch();
    if (!enabled || !context.mounted) {
      _showing = false;
      return;
    }

    try {
      // 已读到的值直接透传，避免 _present 里再读一次盘
      await _present(context, initialOnLaunch: enabled);
      // 弹成功才记账：中途失败时下次还能再弹，不会静默失联
      _seenThisSession = true;
    } finally {
      _showing = false;
    }
  }

  /// 主动展示（首页「i」按钮）。正在自动弹时忽略，避免叠两层
  static Future<void> show(BuildContext context) async {
    if (_showing) return;
    _showing = true;
    try {
      await _present(context);
    } finally {
      _showing = false;
    }
  }

  /// [initialOnLaunch] 为 null 时才去读盘（自动弹路径已读过，直接传值避免二次读）
  static Future<void> _present(
    BuildContext context, {
    bool? initialOnLaunch,
  }) async {
    if (!context.mounted) return;
    try {
      final onLaunch = initialOnLaunch ?? await readOnLaunch();
      if (!context.mounted) return;
      final result = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _LegalNoticeDialog(initialOnLaunch: onLaunch),
      );
      // 弹窗里改过开关就保存；null 表示异常关闭，保持原值
      if (result != null) await _writeOnLaunch(result);
    } catch (e) {
      // 导航栈异常（例如页面已销毁）时不该把 App 崩掉
      debugPrint('LegalNotice: 弹窗展示失败 $e');
    }
  }
}

class _LegalNoticeDialog extends StatefulWidget {
  /// 打开时读取到的开关值
  final bool initialOnLaunch;
  const _LegalNoticeDialog({required this.initialOnLaunch});

  @override
  State<_LegalNoticeDialog> createState() => _LegalNoticeDialogState();
}

class _LegalNoticeDialogState extends State<_LegalNoticeDialog> {
  late bool _showOnLaunch = widget.initialOnLaunch;

  /// 打开仓库页；打不开就给一句提示，别静默失败
  Future<void> _openRepo(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final ok = await launchUrl(
        Uri.parse(LegalNotice.repoUrl),
        mode: LaunchMode.externalApplication,
      );
      if (!ok) {
        messenger?.showSnackBar(
          const SnackBar(content: Text('无法打开浏览器，地址：${LegalNotice.repoLabel}')),
        );
      }
    } catch (e) {
      debugPrint('LegalNotice: 打开仓库失败 $e');
      messenger?.showSnackBar(
        const SnackBar(content: Text('无法打开浏览器，地址：${LegalNotice.repoLabel}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 只有「我已知悉」一个出口：屏蔽系统返回键，避免点返回等于默认同意又没留下标记
    return PopScope(
      canPop: false,
      child: AlertDialog(
        icon: Icon(Icons.gavel_rounded, color: scheme.primary),
        title: const Text('使用声明'),
        // 默认约束只有约 280 宽，显式放宽到 440（平板/桌面更易读）
        constraints: const BoxConstraints(minWidth: 280, maxWidth: 440),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text.rich(
                        TextSpan(
                          style: DefaultTextStyle.of(context).style,
                          children: [
                            const TextSpan(text: '嗨，先占用你十秒。\n\n「${LegalNotice.appName}」是 '),
                            TextSpan(
                              text: LegalNotice.owner,
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            const TextSpan(text: ' 自己写着玩的'),
                            const TextSpan(
                              text: '个人软件',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Color(0xFFE5455C),
                              ),
                            ),
                            const TextSpan(
                              text: '——没有广告、没有会员、没有内购，也不在任何应用商店卖。'
                                  '下面几句不是免责套话，只是希望你知道自己在用什么。',
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      const _Point(
                        '别拿去卖',
                        '自己看、给朋友装都随意。但别拿它收款、代运营、塞广告或者打包进别的产品里，'
                            '也别未经同意就对外发布你改过的版本。',
                      ),
                      const _Point(
                        '别抹掉署名',
                        '想原样转发或备份，把这份声明和 LICENSE 一起带上就好；'
                            '改过之后的版本就别往外发了，改坏了容易被算到我头上。',
                      ),
                      const _Point(
                        '片子不是我存的',
                        '我只负责帮你搜到公开链接、把请求转发给播放器，不存视频、不做转码、也不卖内容。'
                            '海报和简介来自豆瓣，版权都归原作者。',
                      ),
                      const _Point(
                        '缓存自己拿主意',
                        '要不要把分片存到手机上，这个决定权在你（也由你负责）。'
                            '存下来的东西自己看就好，别再传给别人。',
                      ),
                      const _Point(
                        '按当地规矩来',
                        '希望你只在合法、合理的前提下用它。出了什么事，我没法替你兜底。',
                      ),
                      const _Point(
                        '有事找我',
                        '用着出问题、发现 bug、或者觉得哪段内容侵了权，来 GitHub 提个 issue：'
                            '${LegalNotice.repoUrl}'
                            '。看到会尽快处理。',
                      ),
                      const _Point(
                        '要是觉得好用',
                        '去仓库点个 ⭐ Star 就够意思了——不花钱，但我能知道确实有人在用。'
                            '这大概是我继续更新的主要动力。',
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '以上只是把话说在前头，具体条款以项目 LICENSE 为准。点下面的按钮就当你看过了。',
                        style:
                            TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 6),
                      // 直接给一个能点的入口：让人想支持时不用自己去搜仓库
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          onPressed: () => _openRepo(context),
                          icon: const Icon(Icons.star_rounded, size: 18),
                          label: const Text(
                            '去仓库点个 Star',
                            style: TextStyle(fontSize: 12),
                          ),
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // 开关固定在弹窗最下方，不随条款滚动：否则手机竖屏下它被挤出首屏，
              // 用户根本发现不了「可以关掉」（已用 360x800 用例兜住）
              const SizedBox(height: 4),
              Divider(height: 16, color: scheme.outlineVariant),
              CheckboxListTile(
                value: _showOnLaunch,
                onChanged: (v) => setState(() => _showOnLaunch = v ?? true),
                dense: true,
                visualDensity: VisualDensity.compact,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text(
                  '每次打开时显示此声明',
                  style: TextStyle(fontSize: 13),
                ),
                subtitle: const Text(
                  '取消勾选后不再自动弹出，仍可点首页右上角「i」查看并重新开启',
                  style: TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(_showOnLaunch),
            child: const Text('我已知悉'),
          ),
        ],
      ),
    );
  }
}

class _Point extends StatelessWidget {
  final String title;
  final String body;
  const _Point(this.title, this.body);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MergeSemantics(
      child: Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2, right: 6),
            child: ExcludeSemantics(
              child: Icon(Icons.circle, size: 6, color: scheme.primary),
            ),
          ),
          Expanded(
            child: Text.rich(
              TextSpan(
                style: DefaultTextStyle.of(context).style.copyWith(fontSize: 13),
                children: [
                  TextSpan(
                    text: '$title：',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  TextSpan(text: body),
                ],
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }
}
