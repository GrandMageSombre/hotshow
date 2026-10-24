/// 影视采集站（maccms / 苹果CMS 协议的公开采集接口）配置模型。
///
/// 纯 Dart 模型，不依赖 Flutter，便于在 `dart run` 下做接口连通性验证
/// （见 tool/source_check.dart）。本地持久化见 `services/source_store.dart`。
class SourceSite {
  final String id;
  final String name;

  /// 采集接口地址，形如 `https://example.com/api.php/provide/vod/`
  final String api;

  /// 数据列表动作：maccms10 用 `detail`，部分老站用 `list` / `videolist`
  final String searchAction;

  final bool enabled;

  const SourceSite({
    required this.id,
    required this.name,
    required this.api,
    this.searchAction = 'detail',
    this.enabled = true,
  });

  /// 构造任意 `ac` 动作的请求地址；保留用户填写地址上已有的查询参数（如站点令牌）
  Uri buildQueryUri({
    String? action,
    String? keyword,
    Map<String, String> extra = const {},
  }) {
    final base = Uri.parse(api.trim());
    return base.replace(queryParameters: {
      ...base.queryParameters,
      'ac': action ?? searchAction,
      if (keyword != null && keyword.trim().isNotEmpty) 'wd': keyword.trim(),
      ...extra,
    });
  }

  /// 搜索地址
  Uri buildSearchUri(String keyword, {String? action}) =>
      buildQueryUri(action: action, keyword: keyword);

  /// 取资源详情（`ac=detail&ids=`）的地址
  Uri buildDetailUri(String ids) =>
      buildQueryUri(action: 'detail', extra: {'ids': ids});

  SourceSite copyWith({
    String? name,
    String? api,
    String? searchAction,
    bool? enabled,
  }) =>
      SourceSite(
        id: id,
        name: name ?? this.name,
        api: api ?? this.api,
        searchAction: searchAction ?? this.searchAction,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'api': api,
        'searchAction': searchAction,
        'enabled': enabled,
      };

  factory SourceSite.fromJson(Map<String, dynamic> j) => SourceSite(
        id: j['id']?.toString() ?? '',
        name: j['name']?.toString() ?? '',
        api: j['api']?.toString() ?? '',
        searchAction: j['searchAction']?.toString() ?? 'detail',
        enabled: j['enabled'] as bool? ?? true,
      );

  /// 地址是否像一条可用的采集接口
  static bool isValidApi(String api) {
    final u = Uri.tryParse(api.trim());
    return u != null &&
        (u.scheme == 'http' || u.scheme == 'https') &&
        u.host.isNotEmpty;
  }

  @override
  bool operator ==(Object other) => other is SourceSite && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'SourceSite($name, $api)';
}
