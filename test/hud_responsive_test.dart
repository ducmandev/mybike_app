import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mybike_app/ui/gauge.dart';
import 'package:mybike_app/ui/widgets.dart';
import 'package:mybike_app/features/dashboard/dashboard_screen.dart';

void main() {
  testWidgets('SpeedGauge renders responsively without errors at various sizes', (tester) async {
    for (final size in [160.0, 200.0, 240.0, 280.0]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SpeedGauge(
                size: size,
                speed: 45.6,
                maxSpeed: 100,
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('MetricTile fits within narrow constrained containers without overflow', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 95,
              child: MetricTile(
                icon: Icons.battery_charging_full_rounded,
                label: 'PIN (100%)',
                value: '12580',
                unit: 'km',
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('DashboardScreen renders without overflow on narrow screen (320dp)', (tester) async {
    tester.view.physicalSize = const Size(320 * 2.0, 640 * 2.0);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: DashboardScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('CHUYẾN ĐI (TRIP A)'), findsOneWidget);
    expect(find.text('SỨC KHỎE & MÃ LỖI'), findsOneWidget);
  });

  testWidgets('DashboardScreen renders without overflow on large text scale (1.3x)', (tester) async {
    tester.view.physicalSize = const Size(360 * 2.0, 740 * 2.0);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            textScaler: TextScaler.linear(1.3),
            size: Size(360, 740),
          ),
          child: const ProviderScope(
            child: DashboardScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('DashboardScreen renders in landscape cockpit HUD mode without overflow', (tester) async {
    tester.view.physicalSize = const Size(800 * 2.0, 390 * 2.0);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: DashboardScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(SpeedGauge), findsOneWidget);
  });

  testWidgets('DashboardScreen toggles independent speedometer and map zoom modes in portrait', (tester) async {
    tester.view.physicalSize = const Size(380 * 2.0, 800 * 2.0);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: DashboardScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Initially in normal mode: zoom button for speedometer exists
    final speedZoomBtn = find.byTooltip('Phóng to đồng hồ tốc độ');
    expect(speedZoomBtn, findsOneWidget);

    // Zoom into Speedometer
    await tester.tap(speedZoomBtn);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Exit zoom button should appear
    final exitSpeedZoomBtn = find.byTooltip('Thu nhỏ về mặc định');
    expect(exitSpeedZoomBtn, findsOneWidget);

    // Unzoom back to normal
    await tester.tap(exitSpeedZoomBtn);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Now test map zoom
    final mapZoomBtn = find.byTooltip('Phóng to bản đồ');
    expect(mapZoomBtn, findsOneWidget);

    await tester.tap(mapZoomBtn);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // In map zoom mode, unzoom button appears
    final exitMapZoomBtn = find.byTooltip('Thu nhỏ về mặc định');
    expect(exitMapZoomBtn, findsWidgets);

    // Unzoom back to normal
    await tester.tap(exitMapZoomBtn.first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byTooltip('Phóng to đồng hồ tốc độ'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
