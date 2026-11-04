import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mybike_app/core/ble/ble_controller.dart';
import 'package:mybike_app/core/proto/bike_log.dart';
import 'package:mybike_app/features/home/my_bike_screen.dart';
import 'package:mybike_app/features/settings/vehicle_settings_screen.dart';

class TestBleController extends BleController {
  final BleState initialState;
  TestBleController(this.initialState);

  @override
  BleState build() => initialState;

  @override
  Future<void> refreshFwSettings() async {}
}


void main() {
  group('Proximity Automation V2 (§4.6) toggles', () {
    test('walkUpUnlock + antiTheft5m setters update state', () async {
      SharedPreferences.setMockInitialValues({});
      final controller = TestBleController(const BleState(phase: BlePhase.idle));
      final container = ProviderContainer(
        overrides: [bleProvider.overrideWith(() => controller)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(bleProvider.notifier);
      expect(container.read(bleProvider).walkUpUnlock, isFalse);
      expect(container.read(bleProvider).antiTheft5m, isFalse);
      await notifier.setWalkUpUnlock(true);
      await notifier.setAntiTheft5m(true);
      expect(container.read(bleProvider).walkUpUnlock, isTrue);
      expect(container.read(bleProvider).antiTheft5m, isTrue);
      // Auto-secure flag độc lập, không bị ảnh hưởng
      expect(container.read(bleProvider).autoLockWalkAway, isFalse);
    });

    test('walkUpAutoPowerOn + customizable RSSI ranges update state and persist', () async {
      SharedPreferences.setMockInitialValues({});
      final controller = TestBleController(const BleState(phase: BlePhase.idle));
      final container = ProviderContainer(
        overrides: [bleProvider.overrideWith(() => controller)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(bleProvider.notifier);

      expect(container.read(bleProvider).walkUpAutoPowerOn, isFalse);
      expect(container.read(bleProvider).walkUpRssiThreshold, isNull);
      expect(container.read(bleProvider).autoLockRssiThreshold, isNull);

      // Kích hoạt tính năng phụ: Bật xe sẵn khi tới gần
      await notifier.setWalkUpAutoPowerOn(true);
      expect(container.read(bleProvider).walkUpAutoPowerOn, isTrue);

      // Tùy chỉnh mức sóng khi tới gần
      await notifier.setWalkUpRssiThreshold(-50.0);
      expect(container.read(bleProvider).walkUpRssiThreshold, -50.0);

      // Tùy chỉnh mức sóng khi rời xa
      await notifier.setAutoLockRssiThreshold(-88.5);
      expect(container.read(bleProvider).autoLockRssiThreshold, -88.5);
      expect(container.read(bleProvider).autoLockDistance, 2); // Xa
    });
  });


  group('Immobilizer & Safe Speed Limit 60 km/h Logic Tests', () {
    test('setSafeSpeedLimit60(true) sets both speedLimitMode and eceMode to 1', () async {
      final controller = TestBleController(
        const BleState(phase: BlePhase.idle),
      );
      final container = ProviderContainer(
        overrides: [
          bleProvider.overrideWith(() => controller),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(bleProvider.notifier);
      final msg = await notifier.setSafeSpeedLimit60(true);

      final state = container.read(bleProvider);
      expect(state.speedLimitMode, 1);
      expect(state.eceMode, 1);
      expect(state.fwSpeedLimitRaw, 1);
      expect(msg, contains('giới hạn tốc độ 60 km/h'));
    });

    test('setSafeSpeedLimit60(false) sets both to 0 and warns about VESC RAM power-cycle', () async {
      final controller = TestBleController(
        const BleState(phase: BlePhase.idle, speedLimitMode: 1, eceMode: 1, fwSpeedLimitRaw: 1),
      );
      final container = ProviderContainer(
        overrides: [
          bleProvider.overrideWith(() => controller),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(bleProvider.notifier);
      final msg = await notifier.setSafeSpeedLimit60(false);
      final state = container.read(bleProvider);
      expect(state.speedLimitMode, 0);
      expect(state.eceMode, 0);
      expect(state.fwSpeedLimitRaw, 0);
      expect(msg, contains('VESC'));
      expect(msg, contains('RAM'));
    });

    test('setImmobilizer(true) sets isLocked to true when speed <= 0.5 km/h', () async {
      final controller = TestBleController(
        const BleState(phase: BlePhase.idle, isLocked: false),
      );
      final container = ProviderContainer(
        overrides: [
          bleProvider.overrideWith(() => controller),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(bleProvider.notifier);
      await notifier.setImmobilizer(true);
      expect(container.read(bleProvider).isLocked, isTrue);

      await notifier.setImmobilizer(false);
      expect(container.read(bleProvider).isLocked, isFalse);
    });

    test('setImmobilizer(true) is rejected when bike is moving (speed > 0.5 km/h)', () async {
      final movingTelemetry = BikeLogMsg()..speed = 25.5;
      final controller = TestBleController(
        BleState(
          phase: BlePhase.connected,
          lastTelemetry: movingTelemetry,
          isLocked: false,
        ),
      );
      final container = ProviderContainer(
        overrides: [
          bleProvider.overrideWith(() => controller),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(bleProvider.notifier);
      final msg = await notifier.setImmobilizer(true);
      expect(msg, contains('CẢNH BÁO'));
      expect(msg, contains('Không thể khóa khi xe đang di chuyển'));
      expect(container.read(bleProvider).isLocked, isFalse);
    });
  });

  group('MyBikeScreen Immobilizer UI Tests', () {
    testWidgets('MyBikeScreen displays Anti-theft Immobilizer controls when connected', (tester) async {
      final controller = TestBleController(
        const BleState(
          phase: BlePhase.connected,
          bikeName: 'Dat Bike Quantum S',
          isLocked: false,
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            bleProvider.overrideWith(() => controller),
          ],
          child: const MaterialApp(
            home: MyBikeScreen(),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
      expect(find.text('Khóa Cổ'), findsOneWidget);
      expect(find.text('Tìm Xe'), findsOneWidget);
      expect(find.text('Đồng bộ giờ'), findsOneWidget);
    });

    testWidgets('MyBikeScreen shows locked badge and unlock button when isLocked is true', (tester) async {
      final controller = TestBleController(
        const BleState(
          phase: BlePhase.connected,
          bikeName: 'Dat Bike Quantum S',
          isLocked: true,
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            bleProvider.overrideWith(() => controller),
          ],
          child: const MaterialApp(
            home: MyBikeScreen(),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Đang khóa an toàn'), findsWidgets);
      expect(find.text('Mở Khóa'), findsOneWidget);
    });
  });

  group('VehicleSettingsScreen Safe Speed Limit 60 km/h UI Tests', () {
    testWidgets('VehicleSettingsScreen shows unified 60 km/h section in Advanced section', (tester) async {
      tester.view.physicalSize = const Size(360 * 2.0, 2200 * 2.0);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final controller = TestBleController(
        const BleState(
          phase: BlePhase.connected,
          bikeName: 'Dat Bike Quantum',
          speedLimitMode: 1,
          eceMode: 1,
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            bleProvider.overrideWith(() => controller),
          ],
          child: const MaterialApp(
            home: VehicleSettingsScreen(),
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final titleFinder = find.text('AN TOÀN XE');
      await tester.scrollUntilVisible(titleFinder, 300, scrollable: find.byType(Scrollable).first);
      expect(titleFinder, findsOneWidget);

      final advFinder = find.text('NÂNG CAO & VẬN HÀNH THỬ NGHIỆM');
      await tester.scrollUntilVisible(advFinder, 300, scrollable: find.byType(Scrollable).first);
      expect(advFinder, findsOneWidget);

      // Mở mục nâng cao
      await tester.tap(advFinder);
      await tester.pumpAndSettle();

      final limitFinder = find.text('Giới hạn 60 km/h');
      await tester.scrollUntilVisible(limitFinder, 300, scrollable: find.byType(Scrollable).first);
      expect(limitFinder, findsOneWidget);

      final unlimitedFinder = find.text('Không giới hạn');
      expect(unlimitedFinder, findsOneWidget);
    });

    testWidgets('Tapping Không giới hạn when limited prompts power-cycle dialog', (tester) async {
      tester.view.physicalSize = const Size(400 * 2.0, 3000 * 2.0);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final controller = TestBleController(
        const BleState(
          phase: BlePhase.connected,
          bikeName: 'Dat Bike Quantum',
          speedLimitMode: 1,
          eceMode: 1,
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            bleProvider.overrideWith(() => controller),
          ],
          child: const MaterialApp(
            home: VehicleSettingsScreen(),
          ),
        ),
      );

      await tester.pumpAndSettle();

      final advFinder = find.text('NÂNG CAO & VẬN HÀNH THỬ NGHIỆM');
      await tester.scrollUntilVisible(advFinder, 300, scrollable: find.byType(Scrollable).first);
      await tester.tap(advFinder);
      await tester.pumpAndSettle();

      final unlimitedOption = find.text('Không giới hạn');
      await tester.scrollUntilVisible(unlimitedOption, 300, scrollable: find.byType(Scrollable).first);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(unlimitedOption, findsOneWidget);
      await tester.tap(unlimitedOption);
      await tester.pumpAndSettle();

      // Check dialog appears with clean explanation
      expect(find.text('Tắt Giới Hạn Tốc Độ?'), findsOneWidget);
      expect(find.textContaining('tắt máy và khởi động lại xe'), findsOneWidget);
      expect(find.text('XÁC NHẬN TẮT'), findsOneWidget);
    });
  });
}
