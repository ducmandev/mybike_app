// Dat Bike — app điều khiển xe điện (thay app gốc 4.5.0).
// Không có đăng nhập: mở app là thấy xe. Phase 1 = kết nối ổn định + dashboard
// + OTA metadata; Phase 2 = session handshake + lệnh điều khiển + OTA BLE.

import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/ble/ble_logger.dart';
import 'features/scan/scan_screen.dart';
import 'features/scan/connecting_screen.dart';
import 'features/dashboard/dashboard_screen.dart';
import 'features/battery/battery_diagnostics_screen.dart';
import 'features/charging/charging_screen.dart';
import 'features/settings/vehicle_settings_screen.dart';
import 'features/settings/vehicle_management_screen.dart';
import 'features/home/home_shell.dart';
import 'features/logs/logs_screen.dart';
import 'features/firmware_lab/firmware_lab_screen.dart';
import 'ui/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Bắt toàn bộ lỗi chưa xử lý → ghi ra ble_logs/app_errors.jsonl (xem qua
  // màn Logs). Lỗi framework (build widget) và lỗi async/uncaught đều được
  // ghi kèm stack trace, không phụ thuộc session BLE.
  FlutterError.onError = (details) {
    BleLogger.logAppError('flutter_error', details.exception, details.stack);
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stackTrace) {
    BleLogger.logAppError('uncaught_error', error, stackTrace);
    return true; // đã ghi log — chặn crash trắng màn hình
  };

  runApp(const ProviderScope(child: MyBikeApp()));
}

class MyBikeApp extends StatelessWidget {
  const MyBikeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'My Bike',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.light(),
      themeMode: ThemeMode.light,
      initialRoute: '/',
      routes: {
        '/': (_) => const HomeShell(),
        '/scan': (_) => const ScanScreen(),
        '/connecting': (_) => const ConnectingScreen(),
        '/dashboard': (_) => const DashboardScreen(),
        '/battery': (_) => const BatteryDiagnosticsScreen(),
        '/charging': (_) => const ChargingScreen(),
        '/settings': (_) => const VehicleSettingsScreen(),
        '/garage': (_) => const VehicleManagementScreen(),
        '/logs': (_) => const LogsScreen(),
        '/lab': (_) => const FirmwareLabScreen(),
      },
    );
  }
}
