import 'dart:math';

import 'package:flutter/foundation.dart';

/// Bộ chuẩn hóa RSSI theo nền tảng (iOS CoreBluetooth vs Android) và ước lượng khoảng cách BLE.
class RssiDistanceHelper {
  RssiDistanceHelper._();

  /// Xác định có đang chạy trên iOS hay không (cho phép ghi đè trong unit test qua [overrideIos]).
  static bool isIosPlatform({bool? overrideIos}) =>
      overrideIos ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS);

  /// Kiểm tra mẫu RSSI hợp lệ (loại bỏ sentinel `127`, `0`, giá trị dương hoặc cực nhiễu `< -115`).
  static bool isValidRssi(int rssi) => rssi < 0 && rssi >= -115;

  /// Ngưỡng RSSI rời xa mặc định [Gần, Vừa, Xa] theo nền tảng.
  static List<double> defaultAutoLockThresholds({bool? isIos}) =>
      isIosPlatform(overrideIos: isIos)
          ? const [-72.0, -80.0, -88.0]
          : const [-75.0, -83.0, -90.0];

  /// Ngưỡng RSSI lại gần mặc định theo nền tảng.
  static double defaultWalkUpThreshold({bool? isIos}) =>
      isIosPlatform(overrideIos: isIos) ? -62.0 : -55.0;

  /// Bù +5 dB trên iOS khi quy đổi RSSI sang số vạch sóng / radar.
  static int normalizeRssiForBars(int rssi, {bool? isIos}) =>
      isIosPlatform(overrideIos: isIos) ? rssi + 5 : rssi;

  /// Bù +3 dB trên iOS cho ngưỡng khóa khi rời xa.
  static double normalizeRssiForLock(double rssi, {bool? isIos}) =>
      isIosPlatform(overrideIos: isIos) ? rssi + 3.0 : rssi;

  /// Bù +6 dB trên iOS cho ngưỡng mở khóa khi lại gần.
  static double normalizeRssiForNear(double rssi, {bool? isIos}) =>
      isIosPlatform(overrideIos: isIos) ? rssi + 6.0 : rssi;

  /// Ước tính khoảng cách (mét) từ RSSI theo mô hình Path-Loss (TxPower -59 dBm @ 1m, n=2.4).
  static double estimateDistanceMeters(int rssi, {bool? isIos}) {
    final normalized =
        isIosPlatform(overrideIos: isIos) ? (rssi + 5.0) : rssi.toDouble();
    return pow(10, (-59.0 - normalized) / (10.0 * 2.4))
        .toDouble()
        .clamp(0.5, 25.0);
  }

  /// Nhãn khoảng cách ước lượng cho ngưỡng Auto-Lock.
  static String lockDistanceLabel(double rssi, {bool? isIos}) {
    final normalized = normalizeRssiForLock(rssi, isIos: isIos);
    if (normalized >= -76.0) return '3m';
    if (normalized >= -84.0) return '5m';
    if (normalized >= -90.0) return '8m';
    return '10m';
  }

  /// Nhãn khoảng cách ước lượng cho ngưỡng Walk-Up.
  static String nearDistanceLabel(double rssi, {bool? isIos}) {
    final normalized = normalizeRssiForNear(rssi, isIos: isIos);
    if (normalized >= -48.0) return '0.5m';
    if (normalized >= -52.0) return '0.8m';
    if (normalized >= -58.0) return '1.5m';
    if (normalized >= -65.0) return '2.5m';
    return '3.5m';
  }
}
