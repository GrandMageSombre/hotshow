/// 片源类型（分类）定义。
///
/// 每个 [Genre] 对应豆瓣 frodo 推荐流的 `tags` 参数中的「类型」一段：
/// - 电视剧 / 电影：直接传类型名，如 `喜剧`、`战争`；
/// - 短剧：必须带 `短剧` 前缀（`短剧,古装`），否则返回的是长剧；
/// - 动漫：必须带 `动画` 前缀（`动画,热血`），否则会混进真人剧。
///
/// [tag] 为空表示「全部」，此时回落到该大分类的默认榜单/子榜单交织。
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

/// 内容域：不同域的默认类型表、tag 前缀、取数接口都不同。
/// 与首页大分类一一对应，但不依赖 UI 层枚举。
enum GenreScope { tv, movie, shortDrama, anime }

/// 电视剧 / 「全部」共用的类型（均已对接口实测，20 条以上）
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

/// 电影类型。电影走 `/api/v2/movie/recommend`，tag 不加前缀即可，
/// 与地区/年份组合（`喜剧,2024`）实测有效。
const List<Genre> kMovieGenres = [
  kGenreAll,
  Genre('喜剧', '喜剧'),
  Genre('爱情', '爱情'),
  Genre('动作', '动作'),
  Genre('科幻', '科幻'),
  Genre('悬疑', '悬疑'),
  Genre('犯罪', '犯罪'),
  Genre('战争', '战争'),
  Genre('剧情', '剧情'),
  Genre('动画', '动画'),
  Genre('恐怖', '恐怖'),
  Genre('奇幻', '奇幻'),
  Genre('冒险', '冒险'),
  Genre('纪录片', '纪录片'),
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

/// 某个内容域可用的类型表
List<Genre> genresForScope(GenreScope scope) {
  switch (scope) {
    case GenreScope.anime:
      return kAnimeGenres;
    case GenreScope.shortDrama:
      return kShortDramaGenres;
    case GenreScope.movie:
      return kMovieGenres;
    case GenreScope.tv:
      return kTvGenres;
  }
}

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
/// 表里没有时按同名 tag 现造一条，并按 [scope] 补前缀。
Genre genreForLabel(String label, {GenreScope scope = GenreScope.tv}) {
  for (final g in genresForScope(scope)) {
    if (g.label == label && !g.isAll) return g;
  }
  switch (scope) {
    case GenreScope.anime:
      return Genre(label, '动画,$label');
    case GenreScope.shortDrama:
      return Genre(label, '短剧,$label');
    case GenreScope.tv:
    case GenreScope.movie:
      return Genre(label, label);
  }
}
