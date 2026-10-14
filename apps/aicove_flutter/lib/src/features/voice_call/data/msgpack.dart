import 'dart:convert';
import 'dart:typed_data';

/// 最小 MessagePack 编解码，覆盖 Fish Audio 实时合成事件用到的类型。
abstract final class Msgpack {
  static Uint8List encode(Object? value) {
    final b = BytesBuilder(copy: false);
    _write(b, value);
    return b.takeBytes();
  }

  static void _write(BytesBuilder b, Object? v) {
    if (v == null) {
      b.addByte(0xc0);
    } else if (v is bool) {
      b.addByte(v ? 0xc3 : 0xc2);
    } else if (v is int) {
      if (v >= 0 && v < 128) {
        b.addByte(v);
      } else {
        b.addByte(0xd3);
        b.add((ByteData(8)..setInt64(0, v)).buffer.asUint8List());
      }
    } else if (v is double) {
      b.addByte(0xcb);
      b.add((ByteData(8)..setFloat64(0, v)).buffer.asUint8List());
    } else if (v is String) {
      final bytes = utf8.encode(v);
      if (bytes.length < 32) {
        b.addByte(0xa0 | bytes.length);
      } else {
        b.addByte(0xdb);
        b.add((ByteData(4)..setUint32(0, bytes.length)).buffer.asUint8List());
      }
      b.add(bytes);
    } else if (v is Uint8List) {
      b.addByte(0xc6);
      b.add((ByteData(4)..setUint32(0, v.length)).buffer.asUint8List());
      b.add(v);
    } else if (v is List) {
      b.addByte(0xdd);
      b.add((ByteData(4)..setUint32(0, v.length)).buffer.asUint8List());
      for (final e in v) {
        _write(b, e);
      }
    } else if (v is Map) {
      b.addByte(0xdf);
      b.add((ByteData(4)..setUint32(0, v.length)).buffer.asUint8List());
      v.forEach((k, e) {
        _write(b, k);
        _write(b, e);
      });
    } else {
      throw ArgumentError('Unsupported msgpack type ${v.runtimeType}');
    }
  }

  static Object? decode(Uint8List bytes) => _Reader(bytes).read();
}

class _Reader {
  _Reader(this.bytes) : data = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData data;
  int pos = 0;

  int _u8() => data.getUint8(pos++);
  int _u16() => data.getUint16((pos += 2) - 2);
  int _u32() => data.getUint32((pos += 4) - 4);
  Uint8List _take(int n) => Uint8List.sublistView(bytes, pos, pos += n);
  String _str(int n) => utf8.decode(_take(n));
  List _list(int n) => List.generate(n, (_) => read());
  Map _map(int n) {
    final m = <Object?, Object?>{};
    for (var i = 0; i < n; i++) {
      final k = read();
      m[k] = read();
    }
    return m;
  }

  Object? read() {
    final t = _u8();
    if (t <= 0x7f) return t;
    if (t >= 0xe0) return t - 0x100;
    if (t & 0xf0 == 0x80) return _map(t & 0x0f);
    if (t & 0xf0 == 0x90) return _list(t & 0x0f);
    if (t & 0xe0 == 0xa0) return _str(t & 0x1f);
    switch (t) {
      case 0xc0:
        return null;
      case 0xc2:
        return false;
      case 0xc3:
        return true;
      case 0xc4:
        return _take(_u8());
      case 0xc5:
        return _take(_u16());
      case 0xc6:
        return _take(_u32());
      case 0xca:
        return data.getFloat32((pos += 4) - 4);
      case 0xcb:
        return data.getFloat64((pos += 8) - 8);
      case 0xcc:
        return _u8();
      case 0xcd:
        return _u16();
      case 0xce:
        return _u32();
      case 0xcf:
        return data.getUint64((pos += 8) - 8);
      case 0xd0:
        return data.getInt8(pos++);
      case 0xd1:
        return data.getInt16((pos += 2) - 2);
      case 0xd2:
        return data.getInt32((pos += 4) - 4);
      case 0xd3:
        return data.getInt64((pos += 8) - 8);
      case 0xd9:
        return _str(_u8());
      case 0xda:
        return _str(_u16());
      case 0xdb:
        return _str(_u32());
      case 0xdc:
        return _list(_u16());
      case 0xdd:
        return _list(_u32());
      case 0xde:
        return _map(_u16());
      case 0xdf:
        return _map(_u32());
    }
    throw FormatException('Unsupported msgpack byte 0x${t.toRadixString(16)}');
  }
}
