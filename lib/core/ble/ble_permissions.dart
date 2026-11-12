// Xin quyền runtime cho BLE — flutter_blue_plus KHÔNG tự xin trên Android.
// Android 12+: BLUETOOTH_SCAN + BLUETOOTH_CONNECT
// Android < 12: ACCESS_FINE_LOCATION (bắt buộc để scan có kết quả)
// iOS: Quyền Bluetooth được cấp phép tự nhiên qua NSBluetoothAlwaysUsageDescription
// và CBCentralManager của FlutterBluePlus (không gọi Permission.bluetooth.request()
// của permission_handler vì tạo CBCentralManager thứ 2 gây treo callback khi NotDetermined).

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
      // 1. Khởi tạo CBCentralManager thông qua FlutterBluePlus.adapterState (hiển thị popup
      // xin quyền Bluetooth gốc của iOS nếu lần đầu mở ứng dụng) và chờ thoát trạng thái unknown.
      // Tuyệt đối không gọi Permission.bluetooth.request() của permission_handler để tránh tạo
      // CBCentralManager thứ 2 gây xung đột với FlutterBluePlus.
      var adapter = FlutterBluePlus.adapterStateNow;
      if (adapter == BluetoothAdapterState.unknown) {
        try {
          adapter = await FlutterBluePlus.adapterState
              .where((s) => s != BluetoothAdapterState.unknown)
              .first
              .timeout(const Duration(seconds: 6));
        } catch (_) {
          adapter = FlutterBluePlus.adapterStateNow;
        }
      }

      // 2. Xin Permission.locationWhenInUse nếu chưa granted
      try {
        if (!await Permission.locationWhenInUse.isGranted) {
          await Permission.locationWhenInUse.request();
        }
      } catch (_) {}

      // 3. Sau khi có locationWhenInUse, kiểm tra Permission.locationAlways:
      // nếu chưa granted thì gọi await Permission.locationAlways.request() để nâng cấp lên "Always"
      // (quyền bắt buộc để iOS giữ sống Dart VM chạy nền 24/7 và vẽ bản đồ GPS khi tắt màn hình)
      try {
        if (await Permission.locationWhenInUse.isGranted) {
          if (!await Permission.locationAlways.isGranted) {
            await Permission.locationAlways.request();
          }
        }
      } catch (_) {}

      // 4. Xin Permission.notification nếu chưa granted
      try {
        if (!await Permission.notification.isGranted) {
          await Permission.notification.request();
        }
      } catch (_) {}

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
      return FlutterBluePlus.adapterStateNow == BluetoothAdapterState.unauthorized;
    }
    if (!Platform.isAndroid) return false;
    final scan = await Permission.bluetoothScan.status;
    final location = await Permission.locationWhenInUse.status;
    return scan.isPermanentlyDenied || location.isPermanentlyDenied;
  }
}
