// Xin quyền runtime cho BLE — flutter_blue_plus KHÔNG tự xin trên Android.
// Android 12+: BLUETOOTH_SCAN + BLUETOOTH_CONNECT
// Android < 12: ACCESS_FINE_LOCATION (bắt buộc để scan có kết quả)
// iOS: Quyền Bluetooth được cấp phép qua NSBluetoothAlwaysUsageDescription và CoreBluetooth.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

class BlePermissions {
  BlePermissions._();

  /// Xin đủ quyền BLE. Trả về true nếu scan được phép chạy.
  static Future<bool> ensure() async {
    if (kIsWeb) return true;
    if (Platform.isIOS) {
      // 1. Xin quyền Bluetooth hệ thống qua permission_handler (hiển thị popup xin quyền iOS)
      try {
        final status = await Permission.bluetooth.request();
        if (status.isPermanentlyDenied || status.isRestricted) {
          return false;
        }
      } catch (_) {}

      // 2. Chờ CoreBluetooth Adapter khởi tạo bất đồng bộ (tránh trường hợp còn ở unknown)
      var adapter = FlutterBluePlus.adapterStateNow;
      if (adapter == BluetoothAdapterState.unknown) {
        try {
          adapter = await FlutterBluePlus.adapterState
              .where((s) => s != BluetoothAdapterState.unknown)
              .first
              .timeout(const Duration(seconds: 4));
        } catch (_) {}
      }

      return adapter != BluetoothAdapterState.unauthorized;
    }
    if (!Platform.isAndroid) return true;

    final results = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    // Android 12+ (API 31+): bluetoothScan/bluetoothConnect quyết định.
    // Android < 12: locationWhenInUse quyết định.
    final scan = results[Permission.bluetoothScan] ??
        PermissionStatus.permanentlyDenied;
    final connect = results[Permission.bluetoothConnect] ??
        PermissionStatus.permanentlyDenied;
    final location =
        results[Permission.locationWhenInUse] ?? PermissionStatus.permanentlyDenied;

    final scanOk = scan.isGranted || location.isGranted;
    return scanOk && connect.isGranted;
  }

  /// Quyền bị từ chối vĩnh viễn? → cần mở Settings.
  static Future<bool> permanentlyDenied() async {
    if (kIsWeb) return false;
    if (Platform.isIOS) {
      try {
        final status = await Permission.bluetooth.status;
        if (status.isPermanentlyDenied || status.isRestricted) return true;
      } catch (_) {}
      return FlutterBluePlus.adapterStateNow == BluetoothAdapterState.unauthorized;
    }
    if (!Platform.isAndroid) return false;
    final scan = await Permission.bluetoothScan.status;
    final location = await Permission.locationWhenInUse.status;
    return scan.isPermanentlyDenied || location.isPermanentlyDenied;
  }
}
