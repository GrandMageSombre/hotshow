// 图床地址规整的纯函数单测：签名地址转稳定地址、非豆瓣域名不动。
import 'package:flutter_test/flutter_test.dart';
import 'package:hotshow/widgets/remote_image.dart';

const signed =
    'https://qnmob3-sign.doubanio.com/view/photo/large/public/p2897218476.jpg'
    '?sa_cv=1576fccfa72b5db64a03612e5f56e56f&sa_ct=6ae0467f'
    '&imageView2/0/q/80/w/9999/h/120/format/webp';

void main() {
  test('签名图地址能抽出稳定海报地址', () {
    final list = stablePosterCandidates(signed);
    expect(list, isNotEmpty);
    expect(list.first,
        'https://img1.doubanio.com/view/photo/m_ratio_poster/public/p2897218476.jpg');
    expect(list, hasLength(4));
    for (final u in list) {
      expect(Uri.parse(u).query, isEmpty, reason: '稳定地址不应带签名参数');
    }
  });

  test('普通豆瓣图地址同样能升级为稳定地址', () {
    final list = stablePosterCandidates(
        'https://img9.doubanio.com/view/photo/m_ratio_poster/public/p2605740632.webp');
    expect(list.first, contains('m_ratio_poster/public/p2605740632.webp'));
  });

  test('非豆瓣域名不做改写', () {
    expect(stablePosterCandidates('https://img1.example.com/a/b.jpg'), isEmpty);
  });

  test('双扩展名 / 无扩展名也能解析，且保留原扩展', () {
    final double = stablePosterCandidates(
        'https://img1.doubanio.com/view/photo/large/public/p123.jpg.webp');
    // 双扩展名归一成主扩展（实测 .jpg 与 .webp 都能取到同一张图）
    expect(double.first, endsWith('p123.jpg'));
    final none =
        stablePosterCandidates('https://img1.doubanio.com/view/photo/large/public/p123');
    expect(none.first, endsWith('p123.jpg'));
  });

  test('详情页大图模式取 l_ratio_poster', () {
    final list = stablePosterCandidates(signed, large: true);
    expect(list.first, contains('l_ratio_poster'));
  });

  test('正则不匹配的豆瓣地址不硬塞', () {
    expect(stablePosterCandidates('https://img1.doubanio.com/f/movie/logo.png'),
        isEmpty);
  });

  test('候选链：稳定地址在前，原始地址仍保留作兜底', () {
    final list = imageCandidates(signed);
    expect(list.first, contains('m_ratio_poster'));
    expect(list.any((u) => u.contains('qnmob3-sign')), isTrue);
  });

  test('协议相对地址补全后按豆瓣处理', () {
    final list = stablePosterCandidates(
        '//img1.doubanio.com/view/photo/large/public/p123456.jpg');
    // Uri 对协议相对地址能解析出 authority，因此直接可用
    expect(list, hasLength(4));
    expect(normalizeImageUrl('//img1.doubanio.com/x.jpg'),
        'https://img1.doubanio.com/x.jpg');
  });

  test('空的 / 非法地址返回空列表', () {
    expect(stablePosterCandidates(''), isEmpty);
    expect(stablePosterCandidates('not a url'), isEmpty);
    expect(imageCandidates(''), isEmpty);
  });
}
