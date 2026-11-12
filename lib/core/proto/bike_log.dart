// Decoder protobuf cho telemetry xe Dat Bike.
// 
// Schema nguồn: `../datbike-eproject/docs/proto/bike.proto` (trích nguyên văn
// từ app gốc). Viết decoder thủ công theo wire-format proto3 để tránh phụ thuộc
// protoc — trường chỉ dùng: varint (uint32/bool/enum), fixed32 (float),
// length-delimited (string/bytes/submessage/repeated packed).
// 
// Lưu ý tương thích: decode "lỏng" — gặp field số/wire-type lạ thì bỏ qua
// (đúng hành vi proto3 với unknown fields), giúp sống sót khi firmware thêm field.

import 'dart:convert';
import 'dart:typed_data';

// enum State của xe (bike.proto).
enum BikeState {
  off,
  standBy,
  parking,
  drive,
  super_, // SUPER = 4
  cruiseControl,
  reverse,
  lock,
  turtle;

  static BikeState fromInt(int v) =>
      BikeState.values.firstWhere((e) => e.index == v, orElse: () => BikeState.off);
}

class ChargerLogMsg {
  int stage = 0;
  int fault = 0;
  int profile = 0;
  int fetTemp = 0;
  int power = 0;
  int etaSec = 0;
  int boostLeftSec = 0;
  int vinRms = 0;
  int stageSec = 0;

  @override
  String toString() => 'Charger(stage=$stage, fault=$fault, profile=$profile, '
      'power=${power}W, eta=${etaSec}s, vinRms=$vinRms)';
}

class BikeLogMsg {
  String name = '';
  String model = '';
  String frame = '';
  int distance = 0; // m
  bool idleOff = false;
  String version = '';
  String hash = '';
  double ecu = 0; // °C
  double motor = 0; // °C
  double adc1 = 0;
  double adc2 = 0;
  double phase = 0; // A
  BikeState state = BikeState.off;
  int error = 0;
  double odo = 0; // km
  double speed = 0; // km/h
  double throttle = 0; // %
  bool left = false;
  bool right = false;
  bool headlight = false;
  double kmLeft = 0; // km
  double voltage = 0; // V (pack pin)
  int percent = 0; // % SoC pin (0-100)
  double bmsTemp = 0; // °C (nhiệt độ BMS)
  bool parking = false; // chân chống (true = đỗ/hạ chân chống)
  ChargerLogMsg? charging; // presence = đang sạc
  int chargeProfile = 0;

  /// Xe đang bật nguồn (không ở trạng thái off hoặc lock)
  bool get isBikeOn => state != BikeState.off && state != BikeState.lock;

  /// Mode lái hiển thị trên Badge
  String get drivingModeLabel {
    switch (state) {
      case BikeState.drive:
        return 'DRIVE (D)';
      case BikeState.super_:
        return 'SPORT (S)';
      case BikeState.reverse:
        return 'REVERSE (R)';
      case BikeState.turtle:
        return 'ECO (E)';
      case BikeState.parking:
        return 'PARKING (P)';
      case BikeState.standBy:
        return 'STANDBY';
      case BikeState.off:
        return 'OFF';
      case BikeState.lock:
        return 'LOCKED';
      case BikeState.cruiseControl:
        return 'CRUISE';
    }
  }

  String get drivingModeShort {
    switch (state) {
      case BikeState.super_:
        return 'S';
      case BikeState.reverse:
        return 'R';
      case BikeState.turtle:
        return 'E';
      case BikeState.parking:
        return 'P';
      case BikeState.drive:
      default:
        return 'D';
    }
  }

  bool get isSideStandDown => parking;

  @override
  String toString() => 'Bike(name=$name, model=$model, state=$state, '
      'speed=$speed, odo=$odo, kmLeft=$kmLeft, soc=$percent%, v=$voltage, '
      'ecu=$ecu, motor=$motor, bms=$bmsTemp, parking=$parking, error=$error, '
      'charging=${charging == null ? "no" : "yes"})';
}

class BatteryLogMsg {
  double voltage = 0; // V
  double current = 0; // A
  int balancing = 0;
  int protection = 0;
  bool charge = false;
  bool discharge = false;
  List<double> ntcs = [];
  double resistor = 0;
  double fet = 0;
  List<int> protections = [];
  int error = 0;
  List<double> cellVols = []; // điện áp từng cell
  double socV = 0;
  double socI = 0;
  double socAh = 0;
  double socCycles = 0;
  double socSoc = 0;
  double socAbsAh = 0;

  double get minCellVol {
    if (cellVols.isEmpty) return 0.0;
    return cellVols.reduce((a, b) => a < b ? a : b);
  }

  double get maxCellVol {
    if (cellVols.isEmpty) return 0.0;
    return cellVols.reduce((a, b) => a > b ? a : b);
  }

  double get deltaCellMv {
    if (cellVols.isEmpty) return 0.0;
    return (maxCellVol - minCellVol) * 1000.0;
  }

  bool get isDeltaCritical => deltaCellMv > 30.0;

  @override
  String toString() => 'Battery(v=$voltage, i=$current, cells=${cellVols.length}, '
      'delta=${deltaCellMv.toStringAsFixed(1)}mV, soc=$socSoc, cycles=$socCycles, error=$error)';
}

/// Giải mã Identity Protobuf 108B từ cổng 018e6a6f (BikeIdentity)
BikeLogMsg decodeBikeIdentityLog(Uint8List data) => decodeBikeLogMsg(data);

// ---------------------------------------------------------------------------
// Wire-format primitives
// ---------------------------------------------------------------------------

class _Reader {
  final Uint8List b;
  int pos = 0;
  _Reader(this.b);
  bool get eof => pos >= b.length;

  int readVarint() {
    var result = 0;
    var shift = 0;
    while (!eof) {
      final byte = b[pos++];
      result |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) break;
      shift += 7;
      if (shift > 63) break; // chống buffer lỗi
    }
    return result;
  }

  double readFloat() {
    final v = ByteData.sublistView(b, pos, pos + 4).getFloat32(0, Endian.little);
    pos += 4;
    return v;
  }

  Uint8List readBytes(int len) {
    final out = Uint8List.sublistView(b, pos, pos + len);
    pos += len;
    return out;
  }
}

void _forEachField(Uint8List data, void Function(int field, int wire, _Reader r) fn) {
  final r = _Reader(data);
  while (!r.eof) {
    final tag = r.readVarint();
    final field = tag >> 3;
    final wire = tag & 7;
    final before = r.pos;
    fn(field, wire, r);
    // Field quen thuộc nhưng wire-type sai (frame hỏng/firmware lạ): không có gì
    // được tiêu thụ → skip theo wire-type để không desync phần sau của frame.
    if (r.pos == before) _skip(r, wire);
  }
}

String? _readString(_Reader r, int wire) {
  if (wire != 2) return null;
  final len = r.readVarint();
  return utf8.decode(r.readBytes(len), allowMalformed: true);
}

double? _readFloat(_Reader r, int wire) {
  if (wire != 5) return null;
  return r.readFloat();
}

int? _readVarint(_Reader r, int wire) {
  if (wire != 0) return null;
  return r.readVarint();
}

List<double>? _readPackedFloats(_Reader r, int wire) {
  if (wire != 2) return null;
  final len = r.readVarint();
  final body = r.readBytes(len);
  final out = <double>[];
  final rr = _Reader(body);
  while (!rr.eof) {
    out.add(rr.readFloat());
  }
  return out;
}

List<int>? _readPackedVarints(_Reader r, int wire) {
  if (wire != 2) return null;
  final len = r.readVarint();
  final body = r.readBytes(len);
  final out = <int>[];
  final rr = _Reader(body);
  while (!rr.eof) {
    out.add(rr.readVarint());
  }
  return out;
}

// ---------------------------------------------------------------------------
// Message decoders
// ---------------------------------------------------------------------------

ChargerLogMsg? decodeChargerLogMsg(Uint8List data) {
  final m = ChargerLogMsg();
  var seen = false;
  void setInt(void Function(int) assign, _Reader r, int wire) {
    final v = _readVarint(r, wire);
    if (v != null) {
      assign(v);
      seen = true;
    }
  }

  _forEachField(data, (field, wire, r) {
    switch (field) {
      case 1:
        setInt((x) => m.stage = x, r, wire);
      case 2:
        setInt((x) => m.fault = x, r, wire);
      case 3:
        setInt((x) => m.profile = x, r, wire);
      case 4:
        setInt((x) => m.fetTemp = x, r, wire);
      case 5:
        setInt((x) => m.power = x, r, wire);
      case 6:
        setInt((x) => m.etaSec = x, r, wire);
      case 7:
        setInt((x) => m.boostLeftSec = x, r, wire);
      case 8:
        setInt((x) => m.vinRms = x, r, wire);
      case 9:
        setInt((x) => m.stageSec = x, r, wire);
      default:
        _skip(r, wire);
    }
  });
  return seen ? m : null;
}

BikeLogMsg decodeBikeLogMsg(Uint8List data) {
  final m = BikeLogMsg();
  _forEachField(data, (field, wire, r) {
    switch (field) {
      case 1:
        m.name = _readString(r, wire) ?? m.name;
      case 2:
        m.model = _readString(r, wire) ?? m.model;
      case 3:
        m.frame = _readString(r, wire) ?? m.frame;
      case 4:
        m.distance = _readVarint(r, wire) ?? m.distance;
      case 5:
        m.idleOff = (_readVarint(r, wire) ?? 0) != 0;
      case 6:
        m.version = _readString(r, wire) ?? m.version;
      case 7:
        m.hash = _readString(r, wire) ?? m.hash;
      case 8:
        m.ecu = _readFloat(r, wire) ?? m.ecu;
      case 9:
        m.motor = _readFloat(r, wire) ?? m.motor;
      case 10:
        m.adc1 = _readFloat(r, wire) ?? m.adc1;
      case 11:
        m.adc2 = _readFloat(r, wire) ?? m.adc2;
      case 12:
        m.phase = _readFloat(r, wire) ?? m.phase;
      case 13:
        m.state = BikeState.fromInt(_readVarint(r, wire) ?? 0);
      case 14:
        m.error = _readVarint(r, wire) ?? m.error;
      case 15:
        m.odo = _readFloat(r, wire) ?? m.odo;
      case 16:
        m.speed = _readFloat(r, wire) ?? m.speed;
      case 17:
        m.throttle = _readFloat(r, wire) ?? m.throttle;
      case 18:
        m.left = (_readVarint(r, wire) ?? 0) != 0;
      case 19:
        m.right = (_readVarint(r, wire) ?? 0) != 0;
      case 20:
        m.headlight = (_readVarint(r, wire) ?? 0) != 0;
      case 21:
        m.kmLeft = _readFloat(r, wire) ?? m.kmLeft;
      case 22:
        if (wire == 2) {
          final len = r.readVarint();
          m.charging = decodeChargerLogMsg(r.readBytes(len));
        }
      case 23:
        m.chargeProfile = _readVarint(r, wire) ?? m.chargeProfile;
      default:
        _skip(r, wire);
    }
  });
  return m;
}

BatteryLogMsg decodeBatteryLogMsg(Uint8List data) {
  if (data.isEmpty) return BatteryLogMsg();

  // 1. App gốc fallback: nếu payload bắt đầu bằng '{' (0x7B) -> JSON text UTF-8
  if (data[0] == 0x7B) {
    try {
      final jsonStr = utf8.decode(data, allowMalformed: true).trim();
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      final m = BatteryLogMsg();
      m.voltage = (map['voltage'] as num?)?.toDouble() ?? 0;
      m.current = (map['current'] as num?)?.toDouble() ?? 0;
      m.balancing = (map['balancing'] as num?)?.toInt() ?? 0;
      m.protection = (map['protection'] as num?)?.toInt() ?? 0;
      m.charge = map['charge'] == true;
      m.discharge = map['discharge'] == true;
      m.resistor = (map['resistor'] as num?)?.toDouble() ?? 0;
      m.fet = (map['fet'] as num?)?.toDouble() ?? 0;
      m.error = (map['error'] as num?)?.toInt() ?? 0;

      if (map['cellVols'] is List) {
        m.cellVols = (map['cellVols'] as List)
            .map((e) => (e as num).toDouble())
            .where((v) => v >= 0.0 && v <= 6.0)
            .toList();
      }
      if (map['NTCs'] is List) {
        m.ntcs = (map['NTCs'] as List).map((e) => (e as num).toDouble()).toList();
      }
      if (map['protections'] is List) {
        m.protections = (map['protections'] as List).map((e) => (e as num).toInt()).toList();
      }
      if (map['soc'] is Map) {
        final s = map['soc'] as Map<String, dynamic>;
        m.socV = (s['V'] as num?)?.toDouble() ?? 0;
        m.socI = (s['I'] as num?)?.toDouble() ?? 0;
        m.socAh = (s['Ah'] as num?)?.toDouble() ?? 0;
        m.socCycles = (s['cycles'] as num?)?.toDouble() ?? 0;
        m.socSoc = (s['soc'] as num?)?.toDouble() ?? 0;
        m.socAbsAh = (s['absAh'] as num?)?.toDouble() ?? 0;
      }
      return m;
    } catch (_) {
      // Tiếp tục thử decode protobuf nếu chuỗi không phải JSON hợp lệ
    }
  }

  // 2. Decode Protobuf binary format
  final m = BatteryLogMsg();
  _forEachField(data, (field, wire, r) {
    switch (field) {
      case 1:
        m.voltage = _readFloat(r, wire) ?? m.voltage;
      case 2:
        m.current = _readFloat(r, wire) ?? m.current;
      case 3:
        m.balancing = _readVarint(r, wire) ?? m.balancing;
      case 4:
        m.protection = _readVarint(r, wire) ?? m.protection;
      case 5:
        m.charge = (_readVarint(r, wire) ?? 0) != 0;
      case 6:
        m.discharge = (_readVarint(r, wire) ?? 0) != 0;
      case 7:
        if (wire == 2) {
          m.ntcs = _readPackedFloats(r, wire) ?? m.ntcs;
        } else if (wire == 5) {
          m.ntcs.add(r.readFloat());
        }
      case 8:
        m.resistor = _readFloat(r, wire) ?? m.resistor;
      case 9:
        m.fet = _readFloat(r, wire) ?? m.fet;
      case 10:
        if (wire == 2) {
          m.protections = _readPackedVarints(r, wire) ?? m.protections;
        } else if (wire == 0) {
          final v = _readVarint(r, wire);
          if (v != null) m.protections.add(v);
        }
      case 11:
        m.error = _readVarint(r, wire) ?? m.error;
      case 12:
        if (wire == 2) {
          m.cellVols = _readPackedFloats(r, wire) ?? m.cellVols;
        } else if (wire == 5) {
          m.cellVols.add(r.readFloat());
        }
      case 13:
        m.socV = _readFloat(r, wire) ?? m.socV;
      case 14:
        m.socI = _readFloat(r, wire) ?? m.socI;
      case 15:
        m.socAh = _readFloat(r, wire) ?? m.socAh;
      case 16:
        m.socCycles = _readFloat(r, wire) ?? m.socCycles;
      case 17:
        m.socSoc = _readFloat(r, wire) ?? m.socSoc;
      case 18:
        m.socAbsAh = _readFloat(r, wire) ?? m.socAbsAh;
      default:
        _skip(r, wire);
    }
  });
  return m;
}

void _skip(_Reader r, int wire) {
  switch (wire) {
    case 0:
      r.readVarint();
    case 1:
      r.readBytes(8);
    case 2:
      r.readBytes(r.readVarint());
    case 5:
      r.readBytes(4);
    default:
      throw FormatException('wire type $wire không hỗ trợ — buffer lỗi?');
  }
}


// ---------------------------------------------------------------------------
// RAW STRUCT decoder cho Dashboard characteristic (6d2eb205, 41 byte).
// Phát hiện 2026-10-20 bằng log thật (session 192848): payload GIẢI MÃ ĐÚNG
// ---------------------------------------------------------------------------
// 6d2eb205: characteristic DASHBOARD — struct 41B Little Endian:
//   [0:4]   f32 LE — ODO (km) (ví dụ: 31219.5 km)
//   [4:8]   f32 LE — SPEED (km/h) (tốc độ xe thực tế)
//   [8:12]  f32 LE — CURRENT (A) (dòng điện âm khi kéo ga, dương khi tái tạo)
//   [12]    u8     — LEFT (xi-nhan trái: 0/1)
//   [13]    u8     — RIGHT (xi-nhan phải: 0/1)
//   [14]    u8     — PARKING (chân chống: 1=đang hạ chống/đỗ, 0=gạt lên)
//   [15:19] f32 LE — VOLTAGE (V) (điện áp khối pin, ví dụ: 75.8V)
//   [19]    u8     — PERCENT (% SoC pin, ví dụ: 63%)
//   [20:24] f32 LE — BMS TEMP (°C) (nhiệt độ BMS / khối pin, ví dụ: 29.0°C)
//   [24:28] f32 LE — MOTOR TEMP (°C) (nhiệt độ động cơ, ví dụ: 34.0°C)
//   [28:32] f32 LE — ECU TEMP (°C) (nhiệt độ bo điều khiển ECU, ví dụ: 32.0°C)
//   [32]    u8     — STATE (BikeState enum: 2=parking, 3=drive, 4=super)
//   [33:37] u32 LE — ERROR (mã lỗi hệ thống: 0=bình thường)
//   [37:41] f32 LE — KM LEFT (km) (quãng đường đi được còn lại, ví dụ: 171.4 km)
// ---------------------------------------------------------------------------
BikeLogMsg decodeDashboardStruct(Uint8List pt) {
  final m = BikeLogMsg();
  m.model = 'Dat Bike';
  m.version = '1.14.0';
  if (pt.length < 15) return m;

  final bd = ByteData.sublistView(pt);
  if (pt.length >= 4) m.odo = bd.getFloat32(0, Endian.little);
  if (pt.length >= 8) m.speed = bd.getFloat32(4, Endian.little);
  if (pt.length >= 12) m.phase = bd.getFloat32(8, Endian.little);
  if (pt.length >= 13) m.left = pt[12] != 0;
  if (pt.length >= 14) m.right = pt[13] != 0;
  if (pt.length >= 15) m.parking = pt[14] != 0;
  if (pt.length >= 19) {
    m.voltage = bd.getFloat32(15, Endian.little);
  } else {
    m.voltage = 72.0;
  }
  if (pt.length >= 20) {
    m.percent = pt[19];
  } else {
    m.percent = 50;
  }
  if (pt.length >= 24) m.bmsTemp = bd.getFloat32(20, Endian.little);
  if (pt.length >= 28) m.motor = bd.getFloat32(24, Endian.little);
  if (pt.length >= 32) m.ecu = bd.getFloat32(28, Endian.little);
  if (pt.length >= 33) {
    m.state = BikeState.fromInt(pt[32]);
  } else {
    m.state = (!m.parking && m.speed > 0.5)
        ? BikeState.drive
        : (m.parking ? BikeState.parking : BikeState.standBy);
  }
  if (pt.length >= 37) m.error = bd.getUint32(33, Endian.little);
  if (pt.length >= 41) m.kmLeft = bd.getFloat32(37, Endian.little);
  return m;
}
