import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_info.dart';

/// 使用声明：本软件为 umena 个人自用，禁止商业使用。
///
/// - 每个版本首次打开时自动弹一次（按 [kAppVersion] 记标记，升级后会再弹）；
/// - 首页右上角的「i」可随时重新查看。
class LegalNotice {
  static const String appName = '热剧速览';
  static const String owner = 'umena';

  /// 已读标记：存的是版本号，换版本就会重新弹
  static const String _seenKey = 'legal_notice_seen_version';

  /// 仅供测试：重置会话内状态（进程内单例，测试之间会互相影响）
  @visibleForTesting
  static void debugResetSession() {
    _showing = false;
    _seenThisSession = false;
  }

  /// 同一时刻只允许一个弹窗（防 HotShowApp 重建导致的叠弹）
  static bool _showing = false;

  /// 本次启动已弹过：即便持久化写失败，也不在同一会话里反复弹
  static bool _seenThisSession = false;

  /// 首次打开（或升级后首次打开）时展示
  static Future<void> showIfNeeded(BuildContext context) async {
    if (_showing || _seenThisSession) return;
    // 先占位再 await：读 SP 期间用户可能点首页「i」，双弹会叠两层模态
    _showing = true;

    var seen = false;
    try {
      final sp = await SharedPreferences.getInstance();
      seen = sp.getString(_seenKey) == kAppVersion;
    } catch (e) {
      debugPrint('LegalNotice: 读已读标记失败（按未读处理）$e');
    }
    if (seen || !context.mounted) {
      _showing = false;
      if (seen) _seenThisSession = true;
      return;
    }

    _seenThisSession = true;
    try {
      await _present(context);
    } finally {
      _showing = false;
    }
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_seenKey, kAppVersion);
    } catch (e) {
      // 写失败只影响「下次启动会不会再弹」，本次会话已由 _seenThisSession 兜住
      debugPrint('LegalNotice: 写已读标记失败 $e');
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

  static Future<void> _present(BuildContext context) async {
    if (!context.mounted) return;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => const _LegalNoticeDialog(),
      );
    } catch (e) {
      // 导航栈异常（例如页面已销毁）时不该把 App 崩掉
      debugPrint('LegalNotice: 弹窗展示失败 $e');
    }
  }
}

class _LegalNoticeDialog extends StatelessWidget {
  const _LegalNoticeDialog();

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
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text.rich(
                TextSpan(
                  style: DefaultTextStyle.of(context).style,
                  children: [
                    const TextSpan(text: '「${LegalNotice.appName}」是 '),
                    TextSpan(
                      text: LegalNotice.owner,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const TextSpan(
                      text: ' 的',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const TextSpan(
                      text: '个人自用软件',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Color(0xFFE5455C),
                      ),
                    ),
                    const TextSpan(
                      text: '，不是商业产品，也未在任何应用商店上架销售。',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const _Point(
                '禁止商业使用',
                '不得用于售卖、出租、捆绑销售、代运营、广告变现，或任何以营利为目的的经营场景；'
                    '未经作者书面许可，不得对外提供本软件或其修改版。',
              ),
              const _Point(
                '不得移除声明',
                '原样转发或备份时必须保留本声明、作者署名与 LICENSE；'
                    '修改后的版本不得公开分发。',
              ),
              const _Point(
                '内容来源',
                '本软件只聚合检索第三方公开链接并跳转播放，不托管、不制作、不销售任何视频文件；'
                    '影视元数据来自豆瓣公开接口（以其官方条款为准），版权归原权利人所有。',
              ),
              const _Point(
                '离线缓存',
                '是否把分片暂存到本机由你自行决定并自负其责；'
                    '请勿下载、录制或传播受版权保护的内容。',
              ),
              const _Point(
                '合规与免责',
                '请遵守所在地法律法规，仅将本软件用于个人学习与研究；'
                    '因使用或传播产生的后果由使用者自行承担。',
              ),
              const _Point(
                '侵权处理',
                '权利人可通过项目 issue（GitHub @GrandMageSombre）联系作者，收悉后及时处理。',
              ),
              const SizedBox(height: 10),
              Text(
                '本声明是使用提示与许可摘要，具体条款以项目 LICENSE 为准；继续使用即表示你已知悉。',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
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
