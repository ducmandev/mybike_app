import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mybike_app/core/ble/ble_controller.dart' show TripRecord;
import 'package:mybike_app/core/models/merged_trip_session.dart';
import 'package:mybike_app/core/models/trip_gps_point.dart';
import 'package:mybike_app/core/services/trip_storage_service.dart';
import 'package:mybike_app/features/home/trip_route_screen.dart';

TripGpsPoint _pt(double lat, double lng, DateTime ts, {double speed = 30.0}) {
  return TripGpsPoint(lat: lat, lng: lng, speedKmh: speed, timestamp: ts);
}

TripRecord _trip({
  required String id,
  required DateTime start,
  required DateTime end,
  required double distanceKm,
  required int durationSec,
  double avgSpeedKmh = 30.0,
  double maxSpeedKmh = 50.0,
  int usedPercent = 5,
  List<TripGpsPoint> route = const [],
}) {
  return TripRecord(
    id: id,
    startTime: start,
    endTime: end,
    distanceKm: distanceKm,
    durationSec: durationSec,
    avgSpeedKmh: avgSpeedKmh,
    maxSpeedKmh: maxSpeedKmh,
    usedPercent: usedPercent,
    route: route,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TripStopover', () {
    test('label and formattedDuration format Vietnamese durations accurately', () {
      final t = DateTime(2026, 11, 16, 10, 0);
      final pt = _pt(10.77, 106.71, t);

      TripStopover makeStop(int index, Duration d) => TripStopover(
            index: index,
            location: pt,
            arrivedAt: t,
            departedAt: t.add(d),
            duration: d,
            gapDistanceMeters: 120.0,
            afterGlobalPointIndex: 4,
          );

      final s1 = makeStop(1, const Duration(seconds: 35));
      expect(s1.label, 'P1');
      expect(s1.formattedDuration, '< 1 phút');

      final s2 = makeStop(2, const Duration(minutes: 45));
      expect(s2.label, 'P2');
      expect(s2.formattedDuration, '45 phút');

      final s3 = makeStop(3, const Duration(hours: 2));
      expect(s3.formattedDuration, '2g');

      final s4 = makeStop(4, const Duration(hours: 1, minutes: 20));
      expect(s4.formattedDuration, '1g 20p');
    });
  });

  group('MergedTripSession', () {
    test('fromTrips handles empty list gracefully', () {
      final session = MergedTripSession.fromTrips(
        trips: const [],
        routesByTripId: const {},
      );
      expect(session.segmentCount, 0);
      expect(session.allPoints, isEmpty);
      expect(session.stopovers, isEmpty);
      expect(session.totalDistanceKm, 0.0);
      expect(session.totalElapsedSpanSec, 0);
      expect(session.totalStopDurationSec, 0);
      expect(session.avgMovingSpeedKmh, 0.0);
      expect(session.maxSpeedKmh, 0.0);
      expect(session.segmentAtPointIndex(0), isNull);
      expect(session.cumulativeDistanceAtPointIndex(0), 0.0);
    });

    test('fromTrips sorts chronologically, computes stopovers, Haversine gaps, and metrics', () {
      final t1Start = DateTime(2026, 11, 16, 8, 0, 0);
      final t1End = DateTime(2026, 11, 16, 8, 30, 0); // 1800s
      final t2Start = DateTime(2026, 11, 16, 9, 15, 0); // 45m stopover
      final t2End = DateTime(2026, 11, 16, 9, 45, 0); // 1800s

      final trip1 = _trip(
        id: 't1',
        start: t1Start,
        end: t1End,
        distanceKm: 15.0,
        durationSec: 1800,
        avgSpeedKmh: 30.0,
        maxSpeedKmh: 58.0,
        usedPercent: 10,
      );
      final trip2 = _trip(
        id: 't2',
        start: t2Start,
        end: t2End,
        distanceKm: 25.0,
        durationSec: 1800,
        avgSpeedKmh: 50.0,
        maxSpeedKmh: 72.0,
        usedPercent: -2, // ignored in positive sum
      );

      final p1a = _pt(10.7700, 106.7100, t1Start);
      final p1b = _pt(10.7750, 106.7100, t1Start.add(const Duration(minutes: 15)));
      final p1c = _pt(10.7800, 106.7100, t1End);

      // ~1.11 km north of p1c
      final p2a = _pt(10.7900, 106.7100, t2Start);
      final p2b = _pt(10.8000, 106.7100, t2End);

      // Pass trip2 before trip1 intentionally to test chronological sorting.
      final session = MergedTripSession.fromTrips(
        trips: [trip2, trip1],
        routesByTripId: {
          't1': [p1a, p1b, p1c],
          't2': [p2a, p2b],
        },
        mode: TripMergeMode.byDay,
      );

      expect(session.title, 'Ngày 16/11/2026 (2 chặng)');
      expect(session.isMerged, isTrue);
      expect(session.segmentCount, 2);
      expect(session.startTime, t1Start);
      expect(session.endTime, t2End);
      expect(session.allPoints.length, 5);
      expect(session.segmentStartIndices, [0, 3]);

      final seg1 = session.segments[0];
      expect(seg1.segmentIndex, 0);
      expect(seg1.displayOrder, 1);
      expect(seg1.trip.id, 't1');
      expect(seg1.startPointIndex, 0);
      expect(seg1.endPointIndex, 2);
      expect(seg1.cumulativeStartKm, 0.0);
      expect(seg1.cumulativeEndKm, 15.0);
      expect(seg1.hasPoints, isTrue);

      final seg2 = session.segments[1];
      expect(seg2.segmentIndex, 1);
      expect(seg2.displayOrder, 2);
      expect(seg2.trip.id, 't2');
      expect(seg2.startPointIndex, 3);
      expect(seg2.endPointIndex, 4);
      expect(seg2.cumulativeStartKm, 15.0);
      expect(seg2.cumulativeEndKm, 40.0);
      expect(seg2.gapBefore, const Duration(minutes: 45));
      // 0.01 deg lat is ~1111.95 m
      expect(seg2.gapDistanceBeforeMeters, closeTo(1111.95, 25.0));

      expect(session.stopovers.length, 1);
      final stop = session.stopovers.first;
      expect(stop.label, 'P1');
      expect(stop.location.lat, p1c.lat);
      expect(stop.location.lng, p1c.lng);
      expect(stop.arrivedAt, t1End);
      expect(stop.departedAt, t2Start);
      expect(stop.duration, const Duration(minutes: 45));
      expect(stop.formattedDuration, '45 phút');
      expect(stop.afterGlobalPointIndex, 2);
      expect(stop.gapDistanceMeters, closeTo(1111.95, 25.0));

      // Aggregate metrics
      expect(session.totalDistanceKm, closeTo(40.0, 1e-9));
      expect(session.totalMovingDurationSec, 3600);
      expect(session.totalElapsedSpanSec, 6300); // 1h45m = 6300s
      expect(session.totalStopDurationSec, 2700); // 45m = 2700s
      expect(session.avgMovingSpeedKmh, closeTo(40.0, 1e-9));
      expect(session.maxSpeedKmh, 72.0);
      expect(session.totalUsedPercent, 10);
      expect(session.totalCo2SavedKg, closeTo(40.0 * 0.065, 1e-9));

      // Lookup & cumulative interpolation
      expect(session.segmentAtPointIndex(-1), isNull);
      expect(session.segmentAtPointIndex(0)?.trip.id, 't1');
      expect(session.segmentAtPointIndex(2)?.trip.id, 't1');
      expect(session.segmentAtPointIndex(3)?.trip.id, 't2');
      expect(session.segmentAtPointIndex(5), isNull);

      expect(session.cumulativeDistanceAtPointIndex(0), closeTo(0.0, 1e-9));
      expect(session.cumulativeDistanceAtPointIndex(1), closeTo(7.5, 1e-9));
      expect(session.cumulativeDistanceAtPointIndex(2), closeTo(15.0, 1e-9));
      expect(session.cumulativeDistanceAtPointIndex(3), closeTo(15.0, 1e-9));
      expect(session.cumulativeDistanceAtPointIndex(4), closeTo(40.0, 1e-9));
    });

    test('handles segments with 0 and 1 GPS points cleanly and default titles', () {
      final t1 = DateTime(2026, 11, 16, 10, 0);
      final t2 = DateTime(2026, 11, 16, 11, 0);
      final t3 = DateTime(2026, 11, 16, 12, 0);

      final trip1 = _trip(
        id: 'empty_seg',
        start: t1,
        end: t1.add(const Duration(minutes: 10)),
        distanceKm: 5.0,
        durationSec: 0,
        avgSpeedKmh: 24.0,
      );
      final trip2 = _trip(
        id: 'single_pt_seg',
        start: t2,
        end: t2.add(const Duration(minutes: 10)),
        distanceKm: 3.0,
        durationSec: 0,
        avgSpeedKmh: 36.0,
      );
      final trip3 = _trip(
        id: 'multi_pt_seg',
        start: t3,
        end: t3.add(const Duration(minutes: 10)),
        distanceKm: 7.0,
        durationSec: 0,
      );

      final session = MergedTripSession.fromTrips(
        trips: [trip1, trip2, trip3],
        routesByTripId: {
          'empty_seg': const [],
          'single_pt_seg': [_pt(10.77, 106.71, t2)],
          'multi_pt_seg': [_pt(10.78, 106.71, t3), _pt(10.79, 106.71, t3.add(const Duration(minutes: 10)))],
        },
      );

      expect(session.title, 'Chuỗi 3 hành trình');
      expect(session.segments[0].hasPoints, isFalse);
      expect(session.segments[0].startPointIndex, -1);
      expect(session.segments[1].hasPoints, isTrue);
      expect(session.segments[1].startPointIndex, 0);
      expect(session.segments[1].endPointIndex, 0);
      expect(session.segments[2].startPointIndex, 1);
      expect(session.segments[2].endPointIndex, 2);

      // Single-point segment returns cumulativeEndKm (5.0 + 3.0 = 8.0)
      expect(session.cumulativeDistanceAtPointIndex(0), closeTo(8.0, 1e-9));
      expect(session.cumulativeDistanceAtPointIndex(1), closeTo(8.0, 1e-9));
      expect(session.cumulativeDistanceAtPointIndex(2), closeTo(15.0, 1e-9));
      // Fallback avg speed when totalMovingDurationSec == 0
      expect(session.avgMovingSpeedKmh, closeTo(30.0, 1e-9));

      final singleSession = MergedTripSession.fromTrips(
        trips: [trip3],
        routesByTripId: {
          'multi_pt_seg': [_pt(10.78, 106.71, t3)],
        },
        mode: TripMergeMode.single,
      );
      expect(singleSession.title, 'Hành trình');
      expect(singleSession.isMerged, isFalse);
    });
  });

  group('TripDayGroup & SavedMergedTripChain', () {
    test('groupTripsByDay groups by local midnight, newest day first, with date labels', () {
      final refNow = DateTime(2026, 11, 16, 14, 0);
      final todayMorning = _trip(
        id: 'a',
        start: DateTime(2026, 11, 16, 7, 30),
        end: DateTime(2026, 11, 16, 7, 50),
        distanceKm: 6.5,
        durationSec: 1200,
        maxSpeedKmh: 52.0,
        usedPercent: 5,
      );
      final todayEvening = _trip(
        id: 'b',
        start: DateTime(2026, 11, 16, 18, 0),
        end: DateTime(2026, 11, 16, 18, 25),
        distanceKm: 8.5,
        durationSec: 1500,
        maxSpeedKmh: 61.0,
        usedPercent: 7,
      );
      final yesterdayTrip = _trip(
        id: 'c',
        start: DateTime(2026, 11, 15, 9, 0),
        end: DateTime(2026, 11, 15, 9, 20),
        distanceKm: 4.0,
        durationSec: 900,
        maxSpeedKmh: 45.0,
        usedPercent: 3,
      );
      final olderTrip = _trip(
        id: 'd',
        start: DateTime(2026, 11, 10, 12, 0),
        end: DateTime(2026, 11, 10, 12, 30),
        distanceKm: 11.0,
        durationSec: 1800,
        maxSpeedKmh: 65.0,
        usedPercent: 9,
      );

      final groups = TripDayGroup.groupTripsByDay([
        olderTrip,
        todayEvening,
        yesterdayTrip,
        todayMorning,
      ]);

      expect(groups.length, 3);
      expect(groups[0].dateKey, '2026-11-16');
      expect(groups[0].formatDateLabel(now: refNow), 'Hôm nay · 16/11/2026');
      expect(groups[0].tripCount, 2);
      expect(groups[0].chronologicalTrips.map((t) => t.id).toList(), ['a', 'b']);
      expect(groups[0].totalDistanceKm, closeTo(15.0, 1e-9));
      expect(groups[0].totalMovingDurationSec, 2700);
      expect(groups[0].totalUsedPercent, 12);
      expect(groups[0].maxSpeedKmh, 61.0);

      expect(groups[1].dateKey, '2026-11-15');
      expect(groups[1].formatDateLabel(now: refNow), 'Hôm qua · 15/11/2026');

      expect(groups[2].dateKey, '2026-11-10');
      expect(groups[2].formatDateLabel(now: refNow), '10/11/2026');
    });

    test('SavedMergedTripChain round-trips through JSON', () {
      final created = DateTime(2026, 11, 16, 12, 30, 0);
      final chain = SavedMergedTripChain(
        id: 'chain_1',
        title: 'Đi làm & về nhà',
        createdAt: created,
        tripIds: const ['t1', 't2'],
        mode: TripMergeMode.customChain,
      );

      final restored = SavedMergedTripChain.fromJson(chain.toJson());
      expect(restored.id, 'chain_1');
      expect(restored.title, 'Đi làm & về nhà');
      expect(restored.createdAt, created);
      expect(restored.tripIds, ['t1', 't2']);
      expect(restored.mode, TripMergeMode.customChain);
    });
  });

  group('TripStorageService merged helpers', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('saveMergedChain, loadSavedMergedChains, deleteMergedChain persist via SharedPreferences', () async {
      final storage = TripStorageService.instance;
      expect(await storage.loadSavedMergedChains(), isEmpty);

      final c1 = SavedMergedTripChain(
        id: 'c1',
        title: 'Chuỗi sáng',
        createdAt: DateTime(2026, 11, 16, 9, 0),
        tripIds: const ['t1', 't2'],
      );
      final c2 = SavedMergedTripChain(
        id: 'c2',
        title: 'Chuỗi chiều',
        createdAt: DateTime(2026, 11, 16, 18, 0),
        tripIds: const ['t3', 't4'],
        mode: TripMergeMode.byDay,
      );

      await storage.saveMergedChain(c1);
      final afterSave2 = await storage.saveMergedChain(c2);
      expect(afterSave2.map((c) => c.id).toList(), ['c2', 'c1']);

      final loaded = await storage.loadSavedMergedChains();
      expect(loaded.length, 2);
      expect(loaded.first.title, 'Chuỗi chiều');
      expect(loaded.first.mode, TripMergeMode.byDay);

      // Updating existing id moves to front without duplicating
      await storage.saveMergedChain(
        SavedMergedTripChain(
          id: 'c1',
          title: 'Chuỗi sáng (đã sửa)',
          createdAt: DateTime(2026, 11, 16, 10, 0),
          tripIds: const ['t1', 't2', 't5'],
        ),
      );
      final afterUpdate = await storage.loadSavedMergedChains();
      expect(afterUpdate.length, 2);
      expect(afterUpdate.first.id, 'c1');
      expect(afterUpdate.first.title, 'Chuỗi sáng (đã sửa)');

      final afterDelete = await storage.deleteMergedChain('c1');
      expect(afterDelete.map((c) => c.id).toList(), ['c2']);
    });

    test('loadMultipleTripRoutes and buildMergedSession load inline routes and apply cleaner', () async {
      final storage = TripStorageService.instance;
      final t1 = DateTime(2026, 11, 16, 8, 0);
      final t2 = DateTime(2026, 11, 16, 9, 0);

      final trip1 = _trip(
        id: 'inline_1',
        start: t1,
        end: t1.add(const Duration(minutes: 10)),
        distanceKm: 3.0,
        durationSec: 600,
        route: [
          _pt(10.77, 106.71, t1),
          _pt(10.78, 106.71, t1.add(const Duration(minutes: 10))),
        ],
      );
      final trip2 = _trip(
        id: 'inline_2',
        start: t2,
        end: t2.add(const Duration(minutes: 10)),
        distanceKm: 4.0,
        durationSec: 600,
        route: [
          _pt(10.79, 106.71, t2),
        ],
      );

      final session = await storage.buildMergedSession(
        [trip2, trip1],
        mode: TripMergeMode.customChain,
        customTitle: 'Test Session',
        cleaner: (pts) => pts.take(1).toList(),
      );

      expect(session.title, 'Test Session');
      expect(session.segmentCount, 2);
      expect(session.allPoints.length, 2);
      expect(session.segments[0].trip.id, 'inline_1');
      expect(session.segments[0].points.length, 1);
      expect(session.segments[1].trip.id, 'inline_2');
      expect(session.segments[1].points.length, 1);
      expect(session.stopovers.length, 1);
    });
  });

  group('TripRouteScreen merged session widget tests', () {
    testWidgets('renders 2-segment MergedTripSession at 360x780 without overflow, jumps to Chặng 2, and opens P1 stopover details', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final t1Start = DateTime(2026, 11, 16, 8, 0, 0);
      final t1End = DateTime(2026, 11, 16, 8, 25, 0);
      final t2Start = DateTime(2026, 11, 16, 9, 10, 0);
      final t2End = DateTime(2026, 11, 16, 9, 40, 0);

      final trip1 = _trip(
        id: 'w_t1',
        start: t1Start,
        end: t1End,
        distanceKm: 12.0,
        durationSec: 1500,
        avgSpeedKmh: 28.8,
        maxSpeedKmh: 52.0,
        usedPercent: 8,
      );
      final trip2 = _trip(
        id: 'w_t2',
        start: t2Start,
        end: t2End,
        distanceKm: 18.0,
        durationSec: 1800,
        avgSpeedKmh: 36.0,
        maxSpeedKmh: 64.0,
        usedPercent: 12,
      );

      final session = MergedTripSession.fromTrips(
        trips: [trip1, trip2],
        routesByTripId: {
          'w_t1': [
            _pt(10.7700, 106.7100, t1Start, speed: 22.0),
            _pt(10.7720, 106.7110, t1Start.add(const Duration(minutes: 12)), speed: 35.0),
            _pt(10.7740, 106.7120, t1End, speed: 12.0),
          ],
          'w_t2': [
            _pt(10.7780, 106.7140, t2Start, speed: 30.0),
            _pt(10.7800, 106.7150, t2Start.add(const Duration(minutes: 15)), speed: 48.0),
            _pt(10.7820, 106.7160, t2End, speed: 20.0),
          ],
        },
        mode: TripMergeMode.byDay,
        customTitle: 'Ngày 16/11/2026',
      );

      expect(session.segmentCount, 2);
      expect(session.stopovers.length, 1);

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: TripRouteScreen(
              initialMergedSession: session,
              allTrips: [trip2, trip1],
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(tester.takeException(), isNull);

      // Quick-jump chips render and initial segment is Chặng 1/2
      expect(find.text('Chặng 1'), findsOneWidget);
      expect(find.text('Chặng 2'), findsOneWidget);
      expect(find.textContaining('Chặng 1/2'), findsOneWidget);

      // Tap Chặng 2 chip and verify seek to segment 2
      await tester.tap(find.text('Chặng 2'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('Chặng 2/2'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Re-fit bounds so P1 is centered in the clear map area, then tap P1
      await tester.tap(find.byTooltip('Căn toàn bộ lộ trình'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Stopover marker P1 renders and tapping P1 displays stopover details banner
      expect(find.text('P1'), findsOneWidget);
      await tester.tap(find.text('P1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('Điểm nghỉ P1'), findsOneWidget);
      expect(find.textContaining('45 phút'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
