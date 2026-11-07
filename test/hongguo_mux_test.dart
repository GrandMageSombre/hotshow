import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotshow/services/hongguo_mux.dart';

/// 造一个最小的 fMP4 片段：ftyp + moov(trak) + moof+mdat
Uint8List fakeFmp4({required int trackId, required bool video, int frags = 2}) {
  final w = _BytesWriter();
  w.box('ftyp', (b) {
    b.ascii('isom');
    b.u32(0x200);
    b.ascii('isomavc1');
  });
  w.box('moov', (b) {
    b.box('mvhd', (c) {
      c.u8(0);
      c.u24(0);
      c.zeros(8); // creation/modification
      c.u32(1000);
      c.u32(10000);
      c.zeros(64);
      c.u32(0xFFFFFFFF); // next_track_ID
    });
    b.box('trak', (c) {
      c.box('tkhd', (d) {
        d.u8(0);
        d.u24(7);
        d.zeros(8);
        d.u32(trackId);
        d.zeros(68);
      });
      c.box('mdia', (d) {
        d.box('mdhd', (e) {
          e.u8(0);
          e.u24(0);
          e.zeros(8);
          e.u32(video ? 12800 : 44100);
          e.u32(0);
          e.zeros(4);
        });
        d.box('hdlr', (e) {
          e.u8(0);
          e.u24(0);
          e.zeros(4);
          e.ascii(video ? 'vide' : 'soun');
          e.zeros(13);
        });
      });
    });
    b.box('mvex', (c) {
      c.box('trex', (d) {
        d.u8(0);
        d.u24(0);
        d.u32(trackId);
        d.u32(1);
        d.u32(0);
        d.u32(0);
        d.u32(0);
      });
    });
  });
  for (var i = 0; i < frags; i++) {
    w.box('moof', (b) {
      b.box('mfhd', (c) {
        c.u8(0);
        c.u24(0);
        c.u32(i + 1);
      });
      b.box('traf', (c) {
        c.box('tfhd', (d) {
          d.u8(0);
          d.u24(0x020000);
          d.u32(trackId);
        });
        c.box('tfdt', (d) {
          d.u8(1);
          d.u24(0);
          d.u64(BigInt.from(i * 1000));
        });
      });
    });
    w.box('mdat', (b) {
      b.zeros(16);
    });
  }
  return w.bytes();
}

class _BytesWriter {
  final BytesBuilder _b = BytesBuilder(copy: true);

  void u8(int v) => _b.addByte(v & 0xFF);
  void u24(int v) {
    _b.addByte((v >> 16) & 0xFF);
    _b.addByte((v >> 8) & 0xFF);
    _b.addByte(v & 0xFF);
  }

  void u32(int v) {
    _b.addByte((v >> 24) & 0xFF);
    _b.addByte((v >> 16) & 0xFF);
    _b.addByte((v >> 8) & 0xFF);
    _b.addByte(v & 0xFF);
  }

  void u64(BigInt v) {
    for (var i = 56; i >= 0; i -= 8) {
      _b.addByte(((v >> i) & BigInt.from(0xFF)).toInt());
    }
  }

  void zeros(int n) {
    for (var i = 0; i < n; i++) {
      _b.addByte(0);
    }
  }

  void ascii(String s) {
    for (final c in s.codeUnits) {
      _b.addByte(c);
    }
  }

  void box(String type, void Function(_BytesWriter b) fill) {
    final inner = _BytesWriter();
    fill(inner);
    final body = inner._b.toBytes();
    u32(body.length + 8);
    ascii(type);
    _b.add(body);
  }

  Uint8List bytes() => _b.toBytes();
}

void main() {
  test('任一轨为空时原样返回另一轨', () {
    final v = fakeFmp4(trackId: 1, video: true);
    expect(HongguoMux.mux(v, Uint8List(0)), same(v));
    expect(HongguoMux.mux(Uint8List(0), v), same(v));
  });

  test('合并后含两条轨、mvhd next_track_ID=3、分片交错', () {
    final v = fakeFmp4(trackId: 1, video: true, frags: 2);
    final a = fakeFmp4(trackId: 2, video: false, frags: 2);
    final out = HongguoMux.mux(v, a);

    // 顶层 box 走一遍
    final types = <String>[];
    var off = 0;
    final bd = ByteData.sublistView(out);
    while (off + 8 <= out.length) {
      final size = bd.getUint32(off);
      final type = String.fromCharCodes(out.sublist(off + 4, off + 8));
      types.add(type);
      if (size < 8) break;
      off += size;
    }
    expect(types.first, 'ftyp');
    expect(types.where((t) => t == 'moov').length, 1);
    expect(types.where((t) => t == 'moof').length, 4);
    expect(types.where((t) => t == 'mdat').length, 4);
    // moov 必须在所有 moof 之前
    expect(types.indexOf('moov'), lessThan(types.indexOf('moof')));

    // moov 里应该有 2 个 trak、mvex 里 2 个 trex、next_track_ID=3
    final moovStart = _findTop(out, 'moov')!;
    final moovSize = ByteData.sublistView(out).getUint32(moovStart);
    final moovBytes = out.sublist(moovStart, moovStart + moovSize);
    final kids = _children(moovBytes, 8, moovSize);
    expect(kids.where((c) => c.type == 'trak').length, 2);
    expect(kids.where((c) => c.type == 'mvhd').length, 1);
    final mvex = kids.firstWhere((c) => c.type == 'mvex');
    final trexKids = _children(moovBytes, mvex.body, mvex.end);
    expect(trexKids.where((c) => c.type == 'trex').length, 2);
    // next_track_ID 是 mvhd 的最后 4 字节
    final mvhd = kids.firstWhere((c) => c.type == 'mvhd');
    final nextTrack = ByteData.sublistView(moovBytes).getUint32(mvhd.end - 4);
    expect(nextTrack, 3);
  });

  test('缺 moov 时抛 FormatException', () {
    final bad = Uint8List.fromList(List.filled(32, 0));
    expect(() => HongguoMux.mux(bad, fakeFmp4(trackId: 1, video: true)),
        throwsA(isA<FormatException>()));
  });
}

class _Kid {
  final String type;
  final int start;
  final int end;
  final int body;
  _Kid(this.type, this.start, this.end, this.body);
}

List<_Kid> _children(Uint8List b, int start, int end) {
  final bd = ByteData.sublistView(b);
  final out = <_Kid>[];
  var off = start;
  while (off + 8 <= end) {
    final size = bd.getUint32(off);
    if (size < 8 || off + size > end) break;
    out.add(_Kid(String.fromCharCodes(b.sublist(off + 4, off + 8)), off,
        off + size, off + 8));
    off += size;
  }
  return out;
}

int? _findTop(Uint8List b, String type) {
  for (final c in _children(b, 0, b.length)) {
    if (c.type == type) return c.start;
  }
  return null;
}
