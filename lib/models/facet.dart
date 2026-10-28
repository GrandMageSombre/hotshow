import 'genre.dart';

/// 多维度筛选：类型 / 地区 / 年份。
///
/// 豆瓣 frodo 推荐流的 `tags` 是逗号分隔的多值串，实测组合有效：
/// `喜剧,2024`、`喜剧,中国大陆`、`短剧,古装,2024`、`电影,2024` 均能取到数据。
/// 因此多维筛选不需要新接口，只要把各维度的 tag 依次拼起来。
class FacetOption {
  /// 展示文案，如「全部」「中国大陆」「2024」
  final String label;

  /// 拼进 tags 的值；null 表示该维度不筛选
  final String? tag;

  const FacetOption(this.label, [this.tag]);

  bool get isAll => tag == null || tag!.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is FacetOption && other.label == label && other.tag == tag;

  @override
  int get hashCode => Object.hash(label, tag);

  @override
  String toString() => 'FacetOption($label${tag == null ? '' : ', $tag'})';
}

const FacetOption kFacetAll = FacetOption('全部');

/// 地区维度（豆瓣 tag 用「中国大陆 / 美国 / 日本」这类写法）
const List<FacetOption> kAreas = [
  kFacetAll,
  FacetOption('中国大陆', '中国大陆'),
  FacetOption('美国', '美国'),
  FacetOption('日本', '日本'),
  FacetOption('韩国', '韩国'),
  FacetOption('英国', '英国'),
  FacetOption('中国香港', '中国香港'),
  FacetOption('中国台湾', '中国台湾'),
  FacetOption('泰国', '泰国'),
];

/// 年份维度（默认近 12 年）。
/// 豆瓣的年份也是 tag（`1994` 有效），要找更老的片把 [span] 调大即可。
List<FacetOption> buildYears(int currentYear, {int span = 12}) => [
      kFacetAll,
      for (var y = currentYear; y >= currentYear - span + 1; y--)
        FacetOption('$y', '$y'),
    ];

/// 一次筛选的全部选择。用 [tagList] 拼成接口需要的 tags。
///
/// 类型维度直接持有 [Genre] 实体，而不是两个裸字符串 ——
/// 否则 `copyWith(genreTag: '喜剧', genreLabel: '爱情')` 这类调用
/// 能造出「标签是喜剧、显示是爱情」的不一致状态。
class FilterSelection {
  final Genre genre;
  final FacetOption area;
  final FacetOption year;

  const FilterSelection({
    this.genre = kGenreAll,
    this.area = kFacetAll,
    this.year = kFacetAll,
  });

  /// 按类型筛选（搜索页 / 详情页跳转用）
  factory FilterSelection.genreOnly(Genre genre) => FilterSelection(genre: genre);

  /// 类型的 tags 值（空串表示不筛选）
  String get genreTag => genre.tag ?? '';

  String get genreLabel => genre.label;

  bool get isAll => genre.isAll && area.isAll && year.isAll;

  /// 各维度有效 tag，按「类型 → 地区 → 年份」顺序
  List<String> get tagList => [
        if (!genre.isAll) genre.tag!,
        if (!area.isAll) area.tag!,
        if (!year.isAll) year.tag!,
      ];

  String get tags => tagList.join(',');

  /// 缓存键：任一维度变化都要换一份缓存
  String get key => '${genre.tag ?? ''}|${area.tag ?? ''}|${year.tag ?? ''}';

  /// 用于提示文案，如「喜剧 · 中国大陆 · 2024」
  String get summary => [
        if (!genre.isAll) genre.label,
        if (!area.isAll) area.label,
        if (!year.isAll) year.label,
      ].join(' · ');

  FilterSelection copyWith({
    Genre? genre,
    FacetOption? area,
    FacetOption? year,
  }) =>
      FilterSelection(
        genre: genre ?? this.genre,
        area: area ?? this.area,
        year: year ?? this.year,
      );

  @override
  bool operator ==(Object other) =>
      other is FilterSelection && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => 'FilterSelection($key)';
}
