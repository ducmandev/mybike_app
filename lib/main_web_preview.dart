// WEB PREVIEW — chạy giao diện app trên trình duyệt với dữ liệu GIẢ LẬP
// (không BLE). Dùng để xem/thiết kế UI nhanh:
//   flutter run -d web-server --web-port 8099 -t lib/main_web_preview.dart
// Mở: http://localhost:8099
// Nút điều khiển sẽ báo lỗi BLE (web không có bluetooth) — đây chỉ là preview UI.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/ble/ble_controller.dart';
import 'core/proto/bike_log.dart';
import 'features/scan/scan_screen.dart';
import 'features/scan/connecting_screen.dart';
import 'features/dashboard/dashboard_screen.dart';
import 'features/battery/battery_diagnostics_screen.dart';
import 'features/charging/charging_screen.dart';
import 'features/settings/vehicle_settings_screen.dart';
import 'features/settings/vehicle_management_screen.dart';
import 'features/home/home_shell.dart';
import 'ui/app_theme.dart';

/// Controller giả lập: xe "Quantum S1" đang bật, số liệu dao động sinh động.
class PreviewBleController extends BleController {
  Timer? _t;
  int _tick = 0;

  @override
  BleState build() {
    _t ??= Timer.periodic(const Duration(seconds: 1), (_) {
      _tick++;
      state = _next(state);
    });
    return _base();
  }

  BleState _base() => BleState(
        phase: BlePhase.connected,
        bikeName: 'Dat Bike Quantum S1',
        isAuthorized: true,
        sessionKey: Uint8List(16),
        frameSerial: 'RL9C4NGSSSCC00187',
        lastTelemetry: _telemetry(0),
        trip: _mockTrip(0),
        savedBikes: [
          SavedBike(
            id: 'CC:BA:F9:88:24:01',
            name: 'Dat Bike Quantum S1',
            model: 'Quantum S1',
            licensePlate: '29-A1 999.99',
            frameSerial: 'RL9C4NGSSSCC00187',
            lastBatteryPercent: 85,
            lastOdo: 12450.0,
            isDefault: true,
            lastConnectedAt: DateTime.now(),
          ),
          SavedBike(
            id: 'CC:BA:F9:11:45:99',
            name: 'Dat Bike Weaver++',
            model: 'Weaver++',
            licensePlate: '59-X3 888.88',
            frameSerial: 'RL9WPLUS12345678',
            lastBatteryPercent: 62,
            lastOdo: 8900.0,
            isDefault: false,
            lastConnectedAt: DateTime.now().subtract(const Duration(days: 2)),
          ),
        ],
        activeBikeId: 'CC:BA:F9:88:24:01',
      );

  BleState _next(BleState s) => s.copyWith(
        lastTelemetry: _telemetry(_tick),
        trip: _mockTrip(_tick),
      );

  int _resetTick = -1;

  TripData _mockTrip(int t) {
    if (_resetTick >= 0) {
      final elapsed = t - _resetTick;
      final dist = elapsed * 0.005;
      return TripData(
        distanceKm: dist,
        duration: Duration(seconds: elapsed),
        avgSpeedKmh: elapsed > 2 ? 28.5 : 0.0,
        maxSpeedKmh: elapsed > 2 ? 45.0 : 0.0,
        usedPercent: 0,
        powerKw: 1.2,
      );
    }
    return TripData(
      distanceKm: 14.8 + (t * 0.005),
      duration: Duration(minutes: 28, seconds: t % 60),
      avgSpeedKmh: 34.2,
      maxSpeedKmh: 58.0,
      usedPercent: 6,
      powerKw: 1.8,
    );
  }

  @override
  Future<void> resetTrip() async {
    _resetTick = _tick;
    state = state.copyWith(
      trip: const TripData(
        distanceKm: 0.0,
        duration: Duration.zero,
        avgSpeedKmh: 0.0,
        maxSpeedKmh: 0.0,
        usedPercent: 0,
        powerKw: 0.0,
      ),
    );
  }

  BikeLogMsg _telemetry(int t) {
    final wave = math.sin(t / 6.0);
    final riding = wave > -0.25;
    return BikeLogMsg()
      ..name = 'Dat Bike Quantum S1'
      ..model = 'QT_S1'
      ..frame = 'RL9C4NGSSSCC00187'
      ..odo = 31238.2 + t * 0.004
      ..speed = riding ? 36 + 20 * wave : 0.0
      ..percent = 68 - (t ~/ 240)
      ..voltage = riding ? 75.8 - 0.4 * wave : 76.4
      ..phase = riding ? -(9.0 + 15.0 * math.max(0.0, wave)).toDouble() : -0.3
      ..kmLeft = 41.0
      ..bmsTemp = 33.0
      ..motor = riding ? 44.0 + 4 * wave : 38.0
      ..ecu = 31.0
      ..parking = false
      ..state = riding ? BikeState.drive : BikeState.standBy;
  }
}

void main() {
  runApp(
    ProviderScope(
      overrides: [
        bleProvider.overrideWith(PreviewBleController.new),
      ],
      child: const DatBikePreviewApp(),
    ),
  );
}

class DatBikePreviewApp extends StatelessWidget {
  const DatBikePreviewApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dat Bike — Web Preview',
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
      },
    );
  }
}
