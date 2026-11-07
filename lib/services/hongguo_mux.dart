import 'dart:typed_data';

/// 把红果解密后的两条 fMP4（视频轨 + 音频轨）合并成一个可播 MP4。
///
/// 背景：红果 720p 是 CENC 加密 DASH，音/视频分离。App 用隐藏 WebView 跑站点
/// 播放器解密后，分别抓到 video.m4s / audio.m4s（都是 fragmented MP4：
/// `ftyp + moov + N×(moof+mdat)`）。libmpv 要一个文件，这里把两条轨拼进同一个
/// moov（视频 track_ID=1、音频 track_ID=2），再按解码时间交错 moof+mdat。
///
/// 纯 Dart、无第三方依赖；只做 box 级拼接，不重编码，速度很快。
class HongguoMux {
  /// 合并视频与音频 fMP4。任一为空则原样返回另一条。
  static Uint8List mux(Uint8List video, Uint8List audio) {
    if (video.isEmpty) return audio;
    if (audio.isEmpty) return video;

    final vTop = _parse(video, 0, video.length);
    final aTop = _parse(audio, 0, audio.length);
    final vMoov = _find(vTop, 'moov');
    final aMoov = _find(aTop, 'moov');
    if (vMoov == null || aMoov == null) {
      throw const FormatException('fMP4 缺少 moov，无法合并');
    }
    final vFtyp = _find(vTop, 'ftyp');

    final vChildren = _parse(video, vMoov.body, vMoov.end);
    final aChildren = _parse(audio, aMoov.body, aMoov.end);

    final vTrak = _find(vChildren, 'trak');
    final aTrak = _find(aChildren, 'trak');
    final mvhd = _find(vChildren, 'mvhd');
    if (vTrak == null || aTrak == null || mvhd == null) {
      throw const FormatException('moov 结构不完整');
    }

    // 读两条轨原来的 track_ID，强制归一为 视频=1 / 音频=2
    final vId = _trackIdOfTrak(video, vTrak);
    final aId = _trackIdOfTrak(audio, aTrak);

    final vTrakBytes = _remapTrackId(_bytes(video, vTrak), vId, 1);
    final aTrakBytes = _remapTrackId(_bytes(audio, aTrak), aId, 2);

    // mvex：把两条轨的 trex 合到一个 mvex 里
    final vMvex = _find(vChildren, 'mvex');
    final aMvex = _find(aChildren, 'mvex');
    final trexs = <Uint8List>[];
    if (vMvex != null) {
      for (final b in _parse(video, vMvex.body, vMvex.end)) {
        if (b.type == 'trex') trexs.add(_remapTrackId(_bytes(video, b), vId, 1));
      }
    }
    if (aMvex != null) {
      for (final b in _parse(audio, aMvex.body, aMvex.end)) {
        if (b.type == 'trex') trexs.add(_remapTrackId(_bytes(audio, b), aId, 2));
      }
    }

    // 新 mvhd：next_track_ID 设为 3
    final mvhdBytes = Uint8List.fromList(_bytes(video, mvhd));
    _writeU32(mvhdBytes, mvhdBytes.length - 4, 3);

    final newMoov = _box('moov', [
      mvhdBytes,
      vTrakBytes,
      aTrakBytes,
      if (trexs.isNotEmpty) _box('mvex', trexs),
    ]);

    // 收集两条轨的分片（moof+mdat 成对），按解码时间（秒）交错
    final vScale = _timescaleOfTrak(video, vTrak);
    final aScale = _timescaleOfTrak(audio, aTrak);
    final frags = <_Frag>[];
    frags.addAll(_fragments(video, vTop, vId, 1, vScale));
    frags.addAll(_fragments(audio, aTop, aId, 2, aScale));
    frags.sort((x, y) {
      final c = x.seconds.compareTo(y.seconds);
      return c != 0 ? c : x.trackId.compareTo(y.trackId);
    });

    final out = BytesBuilder(copy: false);
    if (vFtyp != null) out.add(_bytes(video, vFtyp));
    out.add(newMoov);
    for (final f in frags) {
      out.add(f.moof);
      out.add(f.mdat);
    }
    return out.takeBytes();
  }

  // ---- box 解析 ----

  static List<_Box> _parse(Uint8List b, int start, int end) {
    final res = <_Box>[];
    var off = start;
    final bd = ByteData.sublistView(b);
    while (off + 8 <= end) {
      var size = bd.getUint32(off);
      final type = String.fromCharCodes(b.sublist(off + 4, off + 8));
      var hdr = 8;
      if (size == 1) {
        if (off + 16 > end) break;
        size = bd.getUint64(off + 8);
        hdr = 16;
      } else if (size == 0) {
        size = end - off;
      }
      if (size < hdr || off + size > end) break;
      res.add(_Box(type, off, off + size, off + hdr));
      off += size;
    }
    return res;
  }

  static _Box? _find(List<_Box> boxes, String type) {
    for (final b in boxes) {
      if (b.type == type) return b;
    }
    return null;
  }

  static Uint8List _bytes(Uint8List b, _Box box) =>
      Uint8List.sublistView(b, box.start, box.end);

  static Uint8List _box(String type, List<Uint8List> children) {
    var len = 8;
    for (final c in children) {
      len += c.length;
    }
    final out = Uint8List(len);
    final bd = ByteData.sublistView(out);
    bd.setUint32(0, len);
    for (var i = 0; i < 4; i++) {
      out[4 + i] = type.codeUnitAt(i);
    }
    var off = 8;
    for (final c in children) {
      out.setRange(off, off + c.length, c);
      off += c.length;
    }
    return out;
  }

  static void _writeU32(Uint8List b, int off, int v) {
    ByteData.sublistView(b).setUint32(off, v);
  }

  // ---- track 元数据 ----

  static int _trackIdOfTrak(Uint8List b, _Box trak) {
    final children = _parse(b, trak.body, trak.end);
    final tkhd = _find(children, 'tkhd');
    if (tkhd == null) return 1;
    final ver = b[tkhd.body];
    final off = tkhd.body + (ver == 1 ? 20 : 12);
    return ByteData.sublistView(b).getUint32(off);
  }

  static int _timescaleOfTrak(Uint8List b, _Box trak) {
    final children = _parse(b, trak.body, trak.end);
    final mdia = _find(children, 'mdia');
    if (mdia == null) return 1;
    final mdiaChildren = _parse(b, mdia.body, mdia.end);
    final mdhd = _find(mdiaChildren, 'mdhd');
    if (mdhd == null) return 1;
    final ver = b[mdhd.body];
    final off = mdhd.body + (ver == 1 ? 20 : 12);
    final ts = ByteData.sublistView(b).getUint32(off);
    return ts == 0 ? 1 : ts;
  }

  /// 把 trak 里 tkhd 的 track_ID 从 from 改成 to。
  static Uint8List _remapTrackId(Uint8List trakBytes, int from, int to) {
    if (from == to) return trakBytes;
    final out = Uint8List.fromList(trakBytes);
    _remapIn(out, 0, out.length, from, to, const {'tkhd'});
    return out;
  }

  /// 递归查找指定类型 box，改写其 track_ID 字段（tkhd/trex/tfhd）。
  static void _remapIn(
      Uint8List b, int start, int end, int from, int to, Set<String> types) {
    final boxes = _parse(b, start, end);
    for (final box in boxes) {
      if (types.contains(box.type)) {
        final bd = ByteData.sublistView(b);
        if (box.type == 'tkhd') {
          final ver = b[box.body];
          final off = box.body + (ver == 1 ? 20 : 12);
          if (bd.getUint32(off) == from) bd.setUint32(off, to);
        } else {
          // trex / tfhd: version+flags(4) 后就是 track_ID
          final off = box.body + 4;
          if (off + 4 <= box.end && bd.getUint32(off) == from) {
            bd.setUint32(off, to);
          }
        }
      }
      if (_isContainer(box.type)) {
        _remapIn(b, box.body, box.end, from, to, types);
      }
    }
  }

  static bool _isContainer(String t) => const {
        'moov', 'trak', 'mdia', 'minf', 'stbl', 'mvex', 'moof', 'traf', 'edts',
      }.contains(t);

  // ---- 分片 ----

  static List<_Frag> _fragments(
      Uint8List b, List<_Box> top, int fromId, int toId, int timescale) {
    final res = <_Frag>[];
    for (var i = 0; i < top.length; i++) {
      if (top[i].type != 'moof') continue;
      final moof = top[i];
      // 紧随其后的 mdat
      _Box? mdat;
      if (i + 1 < top.length && top[i + 1].type == 'mdat') mdat = top[i + 1];
      // 取 tfdt 解码时间
      var dt = 0;
      final traf = _find(_parse(b, moof.body, moof.end), 'traf');
      if (traf != null) {
        final tfdt = _find(_parse(b, traf.body, traf.end), 'tfdt');
        if (tfdt != null) {
          final ver = b[tfdt.body];
          final bd = ByteData.sublistView(b);
          dt = ver == 1 ? bd.getUint64(tfdt.body + 4) : bd.getUint32(tfdt.body + 4);
        }
      }
      var moofBytes = Uint8List.fromList(_bytes(b, moof));
      if (fromId != toId) {
        _remapIn(moofBytes, 0, moofBytes.length, fromId, toId, const {'tfhd'});
      }
      res.add(_Frag(
        moofBytes,
        mdat == null ? Uint8List(0) : _bytes(b, mdat),
        dt / timescale,
        toId,
      ));
    }
    return res;
  }
}

class _Box {
  final String type;
  final int start;
  final int end;
  final int body;
  _Box(this.type, this.start, this.end, this.body);
}

class _Frag {
  final Uint8List moof;
  final Uint8List mdat;
  final double seconds;
  final int trackId;
  _Frag(this.moof, this.mdat, this.seconds, this.trackId);
}
