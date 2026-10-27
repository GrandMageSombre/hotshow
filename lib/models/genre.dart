/// 片源类型（分类）定义。
///
/// 每个 [Genre] 对应豆瓣 frodo 推荐流的 `tags` 参数：
/// - 电视剧 / 短剧：直接传类型名，如 `喜剧`、`战争`；
/// - 动漫：必须带 `动画` 前缀，如 `动画,热血`，否则会混进真人剧。
///
/// [tag] 为空表示「全部」，此时回落到该大分类的默认榜单接口。
class Genre {
  final String label;
  final String? tag;

  const Genre(this.label, [this.tag]);

  bool get isAll => tag == null || tag!.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is Genre && other.label == label && other.tag == tag;

  @override
  int get hashCode => Object.hash(label, tag);

  @override
  String toString() => 'Genre($label${tag == null ? '' : ', $tag'})';
}

const Genre kGenreAll = Genre('全部');

/// 电视剧 / 短剧 / 全部 共用的类型（已对接口实测，均有 20 条以上数据）
const List<Genre> kTvGenres = [
  kGenreAll,
  Genre('喜剧', '喜剧'),
  Genre('爱情', '爱情'),
  Genre('悬疑', '悬疑'),
  Genre('犯罪', '犯罪'),
  Genre('科幻', '科幻'),
  Genre('战争', '战争'),
  Genre('古装', '古装'),
  Genre('武侠', '武侠'),
  Genre('家庭', '家庭'),
  Genre('历史', '历史'),
  Genre('动作', '动作'),
  Genre('奇幻', '奇幻'),
  Genre('青春', '青春'),
  Genre('剧情', '剧情'),
  Genre('恐怖', '恐怖'),
];

/// 短剧专用类型。必须带 `短剧` 前缀 —— 直接用「古装」会返回《庆余年》这类长剧，
/// 实测 `短剧,古装` 才是短剧池里的古装。
const List<Genre> kShortDramaGenres = [
  kGenreAll,
  Genre('喜剧', '短剧,喜剧'),
  Genre('爱情', '短剧,爱情'),
  Genre('古装', '短剧,古装'),
  Genre('悬疑', '短剧,悬疑'),
  Genre('甜宠', '短剧,甜宠'),
  Genre('家庭', '短剧,家庭'),
  Genre('职场', '短剧,职场'),
];

/// 动漫专用类型：标签统一加 `动画` 前缀做二次约束
const List<Genre> kAnimeGenres = [
  kGenreAll,
  Genre('热血', '动画,热血'),
  Genre('战斗', '动画,战斗'),
  Genre('冒险', '动画,冒险'),
  Genre('治愈', '动画,治愈'),
  Genre('搞笑', '动画,搞笑'),
  Genre('科幻', '动画,科幻'),
  Genre('奇幻', '动画,奇幻'),
  Genre('悬疑', '动画,悬疑'),
  Genre('校园', '动画,校园'),
];

/// 搜索页用的混合类型条：电视剧类型 + 动漫独有类型（热血/治愈/搞笑/校园），
/// 让搜索页也能按动漫类型浏览，且不与电视剧类型重名。
const List<Genre> kSearchGenres = [
  ...kTvGenres,
  Genre('热血', '动画,热血'),
  Genre('治愈', '动画,治愈'),
  Genre('搞笑', '动画,搞笑'),
  Genre('校园', '动画,校园'),
];

/// 从详情页的类型名反查可跳转的 [Genre]。
/// [anime] 为真时优先用动漫标签表，并补 `动画,` 前缀；都没有就按同名 tag 现造一个。
Genre genreForLabel(String label, {bool anime = false}) {
  final table = anime ? kAnimeGenres : kTvGenres;
  for (final g in table) {
    if (g.label == label && !g.isAll) return g;
  }
  return Genre(label, anime ? '动画,$label' : label);
}
