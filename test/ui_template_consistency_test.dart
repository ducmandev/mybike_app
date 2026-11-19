import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mybike_app/core/ble/ble_controller.dart';
import 'package:mybike_app/core/proto/bike_log.dart';
import 'package:mybike_app/features/charging/charging_screen.dart';
import 'package:mybike_app/features/home/home_shell.dart';
import 'package:mybike_app/features/profile/profile_screen.dart';
import 'package:mybike_app/features/settings/vehicle_management_screen.dart';
import 'package:mybike_app/ui/app_theme.dart';
import 'package:mybike_app/ui/widgets.dart';

class _TemplateTestBleController extends BleController {
  final BleState initialState;
  _TemplateTestBleController(this.initialState);

  @override
  BleState build() => initialState;

  @override
  Future<void> refreshFwSettings() async {}
}

void _setPhoneViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(360 * 2.0, 780 * 2.0);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Kinetic Stitch EV Template Widgets', () {
    testWidgets('SheetDragHandle and TemplateBadgeIcon render with expected tokens', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SheetDragHandle(),
                SizedBox(height: 12),
                TemplateBadgeIcon(
                  icon: Icons.bolt_rounded,
                  color: AppColors.primary,
                ),
                TemplateBadgeIcon(
                  icon: Icons.tune_rounded,
                  color: AppColors.mint,
                  size: 44,
                  borderRadius: 12,
                  bordered: false,
                ),
              ],
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.byType(SheetDragHandle), findsOneWidget);
      expect(find.byType(TemplateBadgeIcon), findsNWidgets(2));
      expect(find.byIcon(Icons.bolt_rounded), findsOneWidget);
      expect(find.byIcon(Icons.tune_rounded), findsOneWidget);
    });

    testWidgets('PanelActionRow and PanelDivider render inside Panel and fire onTap', (tester) async {
      var tapped = false;

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Panel(
              padding: EdgeInsets.zero,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PanelActionRow(
                    icon: Icons.garage_rounded,
                    iconColor: AppColors.primary,
                    title: 'Nhà xe của tôi',
                    subtitle: '2 xe đã lưu',
                    onTap: () => tapped = true,
                  ),
                  const PanelDivider(),
                  const PanelActionRow(
                    leading: TemplateBadgeIcon(
                      icon: Icons.info_outline_rounded,
                      color: AppColors.textPrimary,
                    ),
                    title: 'Thông tin ứng dụng',
                    trailing: Text('v2.6.50'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Nhà xe của tôi'), findsOneWidget);
      expect(find.text('2 xe đã lưu'), findsOneWidget);
      expect(find.text('Thông tin ứng dụng'), findsOneWidget);
      expect(find.text('v2.6.50'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
      expect(find.byType(PanelDivider), findsOneWidget);

      await tester.tap(find.text('Nhà xe của tôi'));
      await tester.pump();
      expect(tapped, isTrue);
    });

    testWidgets('KineticBottomSheet renders handle, title, subtitle, and child cleanly', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  KineticBottomSheet.show(
                    context: context,
                    builder: (_) => const KineticBottomSheet(
                      title: 'Tiêu đề Sheet',
                      subtitle: 'Mô tả ngắn gọn',
                      maxHeightFactor: 0.85,
                      child: PanelActionRow(
                        icon: Icons.bluetooth_searching_rounded,
                        title: 'Quét BLE',
                      ),
                    ),
                  );
                },
                child: const Text('Mở Sheet'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Mở Sheet'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(KineticBottomSheet), findsOneWidget);
      expect(find.byType(SheetDragHandle), findsOneWidget);
      expect(find.text('Tiêu đề Sheet'), findsOneWidget);
      expect(find.text('Mô tả ngắn gọn'), findsOneWidget);
      expect(find.text('Quét BLE'), findsOneWidget);
    });
  });

  group('Responsive 360x780 & Template Consistency on Refactored Screens', () {
    testWidgets('HomeShell renders 3 tabs and switches cleanly across Xe / Năng Lượng / Chủ Xe', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            bleProvider.overrideWith(
              () => _TemplateTestBleController(
                const BleState(phase: BlePhase.idle),
              ),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const HomeShell(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
      expect(find.text('Xe'), findsOneWidget);
      expect(find.text('Năng Lượng'), findsOneWidget);
      expect(find.text('Chủ Xe'), findsOneWidget);

      await tester.tap(find.text('Năng Lượng'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      expect(find.text('Power Control'), findsOneWidget);

      await tester.tap(find.text('Chủ Xe'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      expect(find.text('TÀI KHOẢN & XE'), findsOneWidget);
    });

    testWidgets('ProfileScreen renders standardized PanelActionRows and About version at 360x780', (tester) async {
      _setPhoneViewport(tester);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            bleProvider.overrideWith(
              () => _TemplateTestBleController(
                const BleState(
                  phase: BlePhase.idle,
                  userName: 'Dat Bike Rider',
                  savedBikes: [
                    SavedBike(id: 'AA:BB:CC:11:22:33', name: 'Quantum S1', isDefault: true),
                  ],
                ),
              ),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const ProfileScreen(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
      expect(find.text('TÀI KHOẢN & XE'), findsOneWidget);
      expect(find.byType(StatusPill), findsOneWidget);
      expect(find.byType(Panel), findsOneWidget);
      expect(find.byType(PanelActionRow), findsWidgets);
      expect(find.byType(PanelDivider), findsWidgets);
      expect(find.text('Nhà xe của tôi (1 xe)'), findsOneWidget);
      expect(find.text('Cài đặt xe'), findsOneWidget);
      expect(find.text('Bác sĩ pin & BMS'), findsOneWidget);
      expect(find.text('Sổ bảo dưỡng theo ODO'), findsOneWidget);

      await tester.ensureVisible(find.text('Thông tin ứng dụng'));
      await tester.tap(find.text('Thông tin ứng dụng'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
      expect(find.text('v2.6.50'), findsOneWidget);
    });

    testWidgets('ChargingScreen renders telemetry and charging details without overflow at 360x780', (tester) async {
      _setPhoneViewport(tester);

      final telemetry = BikeLogMsg()
        ..percent = 82
        ..voltage = 72.4
        ..phase = 18.5
        ..kmLeft = 196.0
        ..bmsTemp = 33.5
        ..charging = (ChargerLogMsg()..etaSec = 1800);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            bleProvider.overrideWith(
              () => _TemplateTestBleController(
                BleState(
                  phase: BlePhase.connected,
                  chargingProfile: 1,
                  lastTelemetry: telemetry,
                ),
              ),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const ChargingScreen(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
      expect(find.text('Power Control'), findsOneWidget);
      expect(find.text('196'), findsOneWidget);
      expect(find.text('82%'), findsOneWidget);
      expect(find.byType(Panel), findsNWidgets(2));
      expect(find.byType(StatusPill), findsNWidgets(2));
      expect(find.byType(SectionTitle), findsOneWidget);
      expect(find.text('CHARGING DETAILS'), findsOneWidget);
      expect(find.text('Remaining Time'), findsOneWidget);
      expect(find.text('Current / Power'), findsOneWidget);
      expect(find.text('Nhiệt độ BMS / Pin'), findsOneWidget);
      expect(find.text('Cấu Hình Profile Sạc (Era 8a2b0d10)'), findsOneWidget);
      expect(find.text('Bác Sĩ Pin & Chẩn Đoán 24 Cell'), findsOneWidget);
    });

    testWidgets('VehicleManagementScreen renders garage cards and KineticBottomSheet without overflow at 360x780', (tester) async {
      _setPhoneViewport(tester);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            bleProvider.overrideWith(
              () => _TemplateTestBleController(
                const BleState(
                  phase: BlePhase.idle,
                  activeBikeId: 'CC:BA:F9:11:22:33',
                  savedBikes: [
                    SavedBike(
                      id: 'CC:BA:F9:11:22:33',
                      name: 'Quantum S1 Đen',
                      model: 'Quantum S1',
                      licensePlate: '29-A1 999.99',
                      lastBatteryPercent: 88,
                      lastOdo: 4200,
                      isDefault: true,
                    ),
                    SavedBike(
                      id: 'DD:EE:FF:44:55:66',
                      name: 'Weaver++ Cam',
                      model: 'Weaver++',
                    ),
                  ],
                ),
              ),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const VehicleManagementScreen(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
      expect(find.text('Nhà Xe Của Bạn'), findsOneWidget);
      expect(find.text('QUẢN LÝ NHÀ XE (2 XE)'), findsOneWidget);
      expect(find.text('Quantum S1 Đen'), findsOneWidget);
      expect(find.text('Weaver++ Cam'), findsOneWidget);
      expect(find.byType(StatusPill), findsNWidgets(2));
      expect(find.byType(Panel), findsNWidgets(2));

      await tester.tap(find.text('THÊM XE'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(KineticBottomSheet), findsOneWidget);
      expect(find.byType(SheetDragHandle), findsOneWidget);
      expect(find.text('Thêm Xe Dat Bike'), findsOneWidget);
      expect(find.text('Quét Bluetooth BLE (Khuyên dùng)'), findsOneWidget);
      expect(find.text('Nhập thông tin thủ công'), findsOneWidget);
    });
  });
}
