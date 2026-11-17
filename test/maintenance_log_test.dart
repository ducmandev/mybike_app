import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mybike_app/core/ble/ble_controller.dart';
import 'package:mybike_app/core/models/maintenance_item.dart';
import 'package:mybike_app/core/proto/bike_log.dart';
import 'package:mybike_app/core/services/maintenance_storage_service.dart';
import 'package:mybike_app/features/settings/maintenance_log_screen.dart';

class _MockBleController extends BleController {
  final BleState initialState;
  _MockBleController(this.initialState);

  @override
  BleState build() => initialState;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  group('MaintenanceItem Model Tests', () {
    test('computes nextDueOdo, remainingKm, progress, overdue and dueSoon', () {
      const item = MaintenanceItem(
        id: 't1',
        bikeId: 'bike_1',
        title: 'Kiểm tra lốp',
        category: 'Lốp & Bánh',
        intervalKm: 1000.0,
        lastServiceOdo: 2000.0,
      );

      expect(item.nextDueOdo, 3000.0);

      // Before start / at start
      expect(item.remainingKm(1800.0), 1200.0);
      expect(item.progress(1800.0), 0.0);
      expect(item.progress(2000.0), 0.0);
      expect(item.isOverdue(2000.0), isFalse);
      expect(item.isDueSoon(2000.0), isFalse);

      // Halfway
      expect(item.remainingKm(2500.0), 500.0);
      expect(item.progress(2500.0), 0.5);
      expect(item.isDueSoon(2500.0), isFalse);

      // Boundary dueSoon: (0, 200]
      expect(item.isDueSoon(2799.0), isFalse); // rem = 201
      expect(item.isDueSoon(2800.0), isTrue); // rem = 200
      expect(item.isDueSoon(2999.0), isTrue); // rem = 1
      expect(item.isOverdue(2800.0), isFalse);

      // Exact due & overdue: rem <= 0
      expect(item.remainingKm(3000.0), 0.0);
      expect(item.progress(3000.0), 1.0);
      expect(item.isOverdue(3000.0), isTrue);
      expect(item.isDueSoon(3000.0), isFalse);

      expect(item.remainingKm(3250.0), -250.0);
      expect(item.progress(3250.0), 1.0);
      expect(item.isOverdue(3250.0), isTrue);
    });

    test('handles zero or negative intervalKm safely', () {
      const zeroInterval = MaintenanceItem(
        id: 'z',
        bikeId: 'b',
        title: 'Test',
        category: 'Test',
        intervalKm: 0.0,
        lastServiceOdo: 100.0,
      );
      expect(zeroInterval.progress(99.0), 0.0);
      expect(zeroInterval.progress(100.0), 1.0);
    });

    test('toJson, fromJson and copyWith preserve fields accurately', () {
      final at = DateTime.utc(2026, 5, 1, 10, 30);
      final item = MaintenanceItem(
        id: 'custom_1',
        bikeId: 'bike_a',
        title: 'Thay dầu hộp số',
        category: 'Truyền động',
        intervalKm: 4000.0,
        lastServiceOdo: 1200.0,
        lastServiceAt: at,
        notes: 'Dùng dầu 80W-90',
        isDefault: false,
      );

      final decoded = MaintenanceItem.fromJson(item.toJson());
      expect(decoded.id, item.id);
      expect(decoded.bikeId, item.bikeId);
      expect(decoded.title, item.title);
      expect(decoded.category, item.category);
      expect(decoded.intervalKm, 4000.0);
      expect(decoded.lastServiceOdo, 1200.0);
      expect(decoded.lastServiceAt, at);
      expect(decoded.notes, 'Dùng dầu 80W-90');
      expect(decoded.isDefault, isFalse);

      final copied = decoded.copyWith(lastServiceOdo: 5200.0, clearNotes: true);
      expect(copied.lastServiceOdo, 5200.0);
      expect(copied.nextDueOdo, 9200.0);
      expect(copied.notes, isNull);
    });
  });

  group('MaintenanceStorageService Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('seeds 4 default Dat Bike EV schedules on first load and persists per bike', () async {
      final items = await MaintenanceStorageService.instance.loadItems(
        'CC:BA:F9:88:24:01',
        initialOdo: 1500.0,
      );

      expect(items.length, 4);
      expect(items.map((e) => e.title).toList(), [
        'Kiểm tra áp suất & gai lốp',
        'Vệ sinh má phanh & kiểm tra truyền động',
        'Bảo dưỡng tổng quát & cổ lái',
        'Kiểm tra giảm xóc & dầu phanh',
      ]);
      expect(items.map((e) => e.intervalKm).toList(), [1000, 3000, 5000, 10000]);
      expect(items.map((e) => e.category).toList(), [
        'Lốp & Bánh',
        'Phanh & Truyền động',
        'Khung & Lái',
        'Hệ thống treo & Phanh',
      ]);
      expect(items.every((e) => e.lastServiceOdo == 1500.0 && e.isDefault), isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('maintenance_items_v1_CC_BA_F9_88_24_01'),
        isNotNull,
      );

      // Empty bikeId falls back to default_bike
      final defaultItems = await MaintenanceStorageService.instance.loadItems(
        '   ',
        initialOdo: 200.0,
      );
      expect(defaultItems.length, 4);
      expect(prefs.getString('maintenance_items_v1_default_bike'), isNotNull);
    });

    test('isolates maintenance items between different bikes', () async {
      await MaintenanceStorageService.instance.loadItems('BIKE_A', initialOdo: 100.0);
      await MaintenanceStorageService.instance.loadItems('BIKE_B', initialOdo: 5000.0);

      await MaintenanceStorageService.instance.addItem(
        'BIKE_A',
        const MaintenanceItem(
          id: 'custom_a',
          bikeId: 'BIKE_A',
          title: 'Rửa xe',
          category: 'Vệ sinh',
          intervalKm: 500.0,
          lastServiceOdo: 100.0,
        ),
      );

      final listA = await MaintenanceStorageService.instance.loadItems('BIKE_A');
      final listB = await MaintenanceStorageService.instance.loadItems('BIKE_B');

      expect(listA.length, 5);
      expect(listB.length, 4);
      expect(listB.first.lastServiceOdo, 5000.0);
    });

    test('markServiced resets cycle to currentOdo + intervalKm and persists', () async {
      final initial = await MaintenanceStorageService.instance.loadItems(
        'BIKE_1',
        initialOdo: 0.0,
      );
      final target = initial.first; // 1000 km interval
      final serviceTime = DateTime.utc(2026, 6, 15, 8, 0);

      final updated = await MaintenanceStorageService.instance.markServiced(
        'BIKE_1',
        target.id,
        1350.0,
        now: serviceTime,
      );

      final updatedTarget = updated.firstWhere((e) => e.id == target.id);
      expect(updatedTarget.lastServiceOdo, 1350.0);
      expect(updatedTarget.nextDueOdo, 2350.0);
      expect(updatedTarget.lastServiceAt, serviceTime);

      final reloaded = await MaintenanceStorageService.instance.loadItems('BIKE_1');
      final reloadedTarget = reloaded.firstWhere((e) => e.id == target.id);
      expect(reloadedTarget.lastServiceOdo, 1350.0);
      expect(reloadedTarget.nextDueOdo, 2350.0);
    });

    test('addItem and deleteItem persist accurately', () async {
      await MaintenanceStorageService.instance.loadItems('BIKE_2');
      const custom = MaintenanceItem(
        id: 'custom_99',
        bikeId: 'BIKE_2',
        title: 'Siết ốc chân chống',
        category: 'Khung & Lái',
        intervalKm: 2500.0,
        lastServiceOdo: 500.0,
      );

      var list = await MaintenanceStorageService.instance.addItem('BIKE_2', custom);
      expect(list.any((e) => e.id == 'custom_99'), isTrue);

      list = await MaintenanceStorageService.instance.deleteItem('BIKE_2', 'custom_99');
      expect(list.any((e) => e.id == 'custom_99'), isFalse);
      expect(list.length, 4);
    });
  });

  group('MaintenanceLogScreen Widget Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    testWidgets('renders at 360x780 without overflow in offline saved ODO mode', (tester) async {
      tester.view.physicalSize = const Size(360 * 2.0, 780 * 2.0);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      // Seed items at 0 km while saved ODO is 1200 km -> first item is overdue by 200 km
      await MaintenanceStorageService.instance.loadItems(
        'BIKE_OFFLINE',
        initialOdo: 0.0,
      );

      final mock = _MockBleController(
        const BleState(
          phase: BlePhase.disconnected,
          activeBikeId: 'BIKE_OFFLINE',
          bikeName: 'Quantum S1',
          savedBikes: [
            SavedBike(
              id: 'BIKE_OFFLINE',
              name: 'Quantum S1',
              lastOdo: 1200.0,
              isDefault: true,
            ),
          ],
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [bleProvider.overrideWith(() => mock)],
          child: const MaterialApp(home: MaintenanceLogScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Nhật ký bảo dưỡng'), findsOneWidget);
      expect(find.text('ODO ĐÃ LƯU'), findsOneWidget);
      expect(find.text('1200'), findsOneWidget);
      expect(find.text('Quá hạn 200 km'), findsOneWidget);
      expect(find.text('Kiểm tra áp suất & gai lốp'), findsOneWidget);
      expect(find.text('Thêm hạng mục'), findsOneWidget);
    });

    testWidgets('renders ODO LIVE and handles markServiced tap at 360x780', (tester) async {
      tester.view.physicalSize = const Size(360 * 2.0, 780 * 2.0);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await MaintenanceStorageService.instance.loadItems(
        'BIKE_LIVE',
        initialOdo: 0.0,
      );

      final telemetry = BikeLogMsg()..odo = 1500.0;
      final mock = _MockBleController(
        BleState(
          phase: BlePhase.connected,
          activeBikeId: 'BIKE_LIVE',
          bikeName: 'Dat Bike Quantum',
          lastTelemetry: telemetry,
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [bleProvider.overrideWith(() => mock)],
          child: const MaterialApp(home: MaintenanceLogScreen()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull);
      expect(find.text('ODO LIVE'), findsOneWidget);
      expect(find.text('Quá hạn 500 km'), findsOneWidget);

      // Tap the first 'Đã bảo dưỡng' button
      await tester.tap(find.text('Đã bảo dưỡng').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull);
      expect(find.text('Quá hạn 500 km'), findsNothing);
      expect(find.text('Còn 1000 km'), findsOneWidget);
      expect(find.text('Mốc kế tiếp: 2500 km'), findsOneWidget);
    });

    testWidgets('adds and deletes a custom maintenance item via dialog at 360x780', (tester) async {
      tester.view.physicalSize = const Size(360 * 2.0, 780 * 2.0);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final mock = _MockBleController(
        const BleState(
          phase: BlePhase.idle,
          activeBikeId: 'BIKE_CUSTOM',
          bikeName: 'Weaver++',
          savedBikes: [
            SavedBike(id: 'BIKE_CUSTOM', name: 'Weaver++', lastOdo: 400.0),
          ],
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [bleProvider.overrideWith(() => mock)],
          child: const MaterialApp(home: MaintenanceLogScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Thêm hạng mục'));
      await tester.pumpAndSettle();

      expect(find.text('Thêm hạng mục bảo dưỡng'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Tên hạng mục'),
        'Thay dầu hộp số',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Chu kỳ lặp lại (km)'),
        '2500',
      );
      await tester.tap(find.text('Lưu'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('Thay dầu hộp số'),
        200.0,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('Thay dầu hộp số'), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline_rounded), findsOneWidget);

      await tester.tap(find.byIcon(Icons.delete_outline_rounded));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Thay dầu hộp số'), findsNothing);
    });

    testWidgets('renders at 360x780 with textScaleFactor 1.3 without overflow', (tester) async {
      tester.view.physicalSize = const Size(360 * 2.0, 780 * 2.0);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final mock = _MockBleController(
        const BleState(
          phase: BlePhase.idle,
          activeBikeId: 'BIKE_SCALE',
          bikeName: 'Quantum S2',
          savedBikes: [
            SavedBike(id: 'BIKE_SCALE', name: 'Quantum S2', lastOdo: 2900.0),
          ],
        ),
      );

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            textScaler: TextScaler.linear(1.3),
            size: Size(360, 780),
          ),
          child: ProviderScope(
            overrides: [bleProvider.overrideWith(() => mock)],
            child: const MaterialApp(home: MaintenanceLogScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });
}
