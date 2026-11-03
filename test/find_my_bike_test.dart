import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mybike_app/core/models/parked_location.dart';
import 'package:mybike_app/core/services/parking_storage_service.dart';
import 'package:mybike_app/features/parking/widgets/precision_radar_gauge.dart';
import 'package:mybike_app/features/parking/find_my_bike_screen.dart';

void main() {
  group('Smart Parking & Find My Bike Models & Service', () {
    test('ParkedLocation json encode / decode roundtrip', () {
      final now = DateTime(2026, 11, 3, 14, 30);
      final loc = ParkedLocation(
        latitude: 10.7769,
        longitude: 106.7009,
        accuracy: 4.5,
        timestamp: now,
        bikeId: 'bike_test_01',
        bikeName: 'Dat Bike Quantum S1',
        batteryPercent: 82,
        voltage: 72.4,
        address: 'Hầm B2 - Cột K12',
        note: 'Cột K12',
        isLocked: true,
      );

      final json = loc.toJson();
      final restored = ParkedLocation.fromJson(json);

      expect(restored.latitude, 10.7769);
      expect(restored.longitude, 106.7009);
      expect(restored.bikeId, 'bike_test_01');
      expect(restored.bikeName, 'Dat Bike Quantum S1');
      expect(restored.batteryPercent, 82);
      expect(restored.isLocked, isTrue);
      expect(restored.note, 'Cột K12');
    });

    test('ParkingStorageService saves and loads parked location', () async {
      SharedPreferences.setMockInitialValues({});
      final service = ParkingStorageService.instance;

      final loc = ParkedLocation(
        latitude: 10.7769,
        longitude: 106.7009,
        timestamp: DateTime.now(),
        bikeId: 'bike_quantum_01',
        bikeName: 'Dat Bike Quantum S1',
        batteryPercent: 85,
        note: 'Gần thang máy số 2',
      );

      await service.saveParkedLocation(loc);
      final loaded = await service.loadParkedLocation(bikeId: 'bike_quantum_01');

      expect(loaded, isNotNull);
      expect(loaded!.bikeId, 'bike_quantum_01');
      expect(loaded.batteryPercent, 85);
      expect(loaded.note, 'Gần thang máy số 2');

      // Update note
      await service.updateNote(bikeId: 'bike_quantum_01', note: 'Cột B2-09');
      final updated = await service.loadParkedLocation(bikeId: 'bike_quantum_01');
      expect(updated!.note, 'Cột B2-09');
    });
  });

  group('PrecisionRadarGauge Widget Tests', () {
    testWidgets('Renders responsively without errors at various distances', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                height: 400,
                child: PrecisionRadarGauge(
                  distanceMeters: 4.5,
                  headingDegrees: 45.0,
                  rssi: -58,
                  isBleConnected: true,
                ),
              ),
            ),
          ),
        ),
      );

      await tester.pump();
      expect(find.text('4.5'), findsOneWidget);
      expect(find.text('MÉT'), findsOneWidget);
      expect(find.text('RẤT GẦN (< 6M)'), findsOneWidget);
      expect(find.text('RSSI: -58 dBm'), findsOneWidget);
    });

    testWidgets('Renders when very close (< 1.5m) with immediate vicinity status', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                height: 400,
                child: PrecisionRadarGauge(
                  distanceMeters: 1.2,
                  headingDegrees: 0.0,
                  rssi: -42,
                  isBleConnected: true,
                ),
              ),
            ),
          ),
        ),
      );

      await tester.pump();
      expect(find.text('1.2'), findsOneWidget);
      expect(find.text('XE Ở NGAY BÊN CẠNH BẠN!'), findsOneWidget);
    });

    testWidgets('Renders when far (> 25m) with GPS walking status', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                height: 400,
                child: PrecisionRadarGauge(
                  distanceMeters: 110.0,
                  headingDegrees: 180.0,
                  isBleConnected: false,
                ),
              ),
            ),
          ),
        ),
      );

      await tester.pump();
      expect(find.text('110.0'), findsOneWidget);
      expect(find.text('DẪN ĐƯỜNG ĐI BỘ (GPS)'), findsOneWidget);
    });
  });

  group('FindMyBikeScreen Responsiveness & Layout', () {
    testWidgets('Renders without overflow on portrait (360x780)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: FindMyBikeScreen(),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('TÌM XE & VỊ TRÍ ĐỖ'), findsOneWidget);
      expect(find.text('Kêu Còi'), findsOneWidget);
      expect(find.text('Xi-nhan'), findsOneWidget);
      expect(find.text('Mở Khóa'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Renders without overflow in landscape cockpit 70/30 mode (800x400)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(800, 400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: FindMyBikeScreen(),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('TÌM XE & VỊ TRÍ ĐỖ'), findsOneWidget);
      expect(find.text('Kêu Còi'), findsOneWidget);
      expect(find.text('Xi-nhan'), findsOneWidget);
      expect(find.text('Mở Khóa'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
