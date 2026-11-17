import 'dart:convert';
import 'dart:io';

import 'package:mybike_app/core/ble/ble_controller.dart' show TripRecord;
import 'package:mybike_app/core/models/merged_trip_session.dart';
import 'package:mybike_app/core/models/trip_gps_point.dart';
import 'package:mybike_app/core/services/trip_analytics_service.dart';
import 'package:mybike_app/core/services/trip_export_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

TripGpsPoint _pt(
  double lat,
  double lng,
  DateTime ts, {
  double speed = 36.0,
  double? altitude,
  double? heading,
}) {
  return TripGpsPoint(
    lat: lat,
    lng: lng,
    speedKmh: speed,
    timestamp: ts,
    altitude: altitude,
    heading: heading,
  );
}

TripRecord _trip({
  required String id,
  required DateTime start,
  required DateTime end,
  required double distanceKm,
  required int durationSec,
  double avgSpeedKmh = 30.0,
  double maxSpeedKmh = 54.0,
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

  group('TripExportService', () {
    test('sessionFromSingleTrip builds single-mode session with optional tripNumber', () {
      final t0 = DateTime.utc(2026, 11, 17, 1, 0, 0);
      final t1 = DateTime.utc(2026, 11, 17, 1, 15, 0);
      final pts = [
        _pt(10.770000, 106.710000, t0, speed: 36.0),
        _pt(10.780000, 106.720000, t1, speed: 54.0),
      ];
      final trip = _trip(
        id: 'trip_single',
        start: t0,
        end: t1,
        distanceKm: 4.5,
        durationSec: 900,
      );

      final numbered = TripExportService.instance.sessionFromSingleTrip(
        trip,
        pts,
        tripNumber: 7,
      );
      expect(numbered.mode, TripMergeMode.single);
      expect(numbered.title, 'Hành trình #7');
      expect(numbered.segmentCount, 1);
      expect(numbered.allPoints.length, 2);

      final unnumbered = TripExportService.instance.sessionFromSingleTrip(
        trip.copyWith(route: pts),
        const [],
      );
      expect(unnumbered.title, 'Hành trình');
      expect(unnumbered.allPoints.length, 2);
    });

    test('buildGpx outputs valid GPX 1.1 with multiple trkseg, XML escaping, ele, UTC time, and speed in m/s', () {
      final s1Start = DateTime.utc(2026, 11, 17, 1, 0, 0);
      final s1End = DateTime.utc(2026, 11, 17, 1, 10, 0);
      final s2Start = DateTime.utc(2026, 11, 17, 2, 0, 0);
      final s2End = DateTime.utc(2026, 11, 17, 2, 20, 0);

      final seg1Pts = [
        _pt(10.771234, 106.701234, s1Start, speed: 36.0, altitude: 12.4),
        _pt(10.775000, 106.705000, s1End, speed: 54.0),
      ];
      final seg2Pts = [
        _pt(10.790000, 106.720000, s2Start, speed: 72.0, altitude: 18.0),
      ];

      final t1 = _trip(
        id: 't1',
        start: s1Start,
        end: s1End,
        distanceKm: 3.0,
        durationSec: 600,
      );
      final tEmpty = _trip(
        id: 't_empty',
        start: s1End.add(const Duration(minutes: 5)),
        end: s1End.add(const Duration(minutes: 10)),
        distanceKm: 0.0,
        durationSec: 300,
      );
      final t2 = _trip(
        id: 't2',
        start: s2Start,
        end: s2End,
        distanceKm: 5.0,
        durationSec: 1200,
      );

      final session = MergedTripSession.fromTrips(
        trips: [t1, tEmpty, t2],
        routesByTripId: {
          't1': seg1Pts,
          't_empty': const [],
          't2': seg2Pts,
        },
        customTitle: 'Sài Gòn & Thủ Đức <Test> "1" \'2\'',
      );

      final gpx = TripExportService.instance.buildGpx(session);

      expect(gpx, contains('<?xml version="1.0" encoding="UTF-8"?>'));
      expect(
        gpx,
        contains(
          '<gpx version="1.1" creator="Dat Bike Companion" '
          'xmlns="http://www.topografix.com/GPX/1/1" '
          'xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">',
        ),
      );
      expect(
        gpx,
        contains(
          '<name>Sài Gòn &amp; Thủ Đức &lt;Test&gt; &quot;1&quot; &apos;2&apos;</name>',
        ),
      );
      expect(gpx, contains('<time>2026-11-17T01:00:00.000Z</time>'));

      // Only 2 segments have points -> exactly 2 <trkseg> blocks (never connects across stops or empty segment)
      expect(RegExp(r'<trkseg>').allMatches(gpx).length, 2);
      expect(RegExp(r'</trkseg>').allMatches(gpx).length, 2);
      expect(RegExp(r'<trkpt ').allMatches(gpx).length, 3);

      // Altitude only emitted when non-null
      expect(RegExp(r'<ele>').allMatches(gpx).length, 2);
      expect(gpx, contains('<ele>12.4</ele>'));
      expect(gpx, contains('<ele>18.0</ele>'));

      // Speed in m/s: 36 km/h -> 10.000, 54 km/h -> 15.000, 72 km/h -> 20.000
      expect(gpx, contains('<gpxtpx:speed>10.000</gpxtpx:speed>'));
      expect(gpx, contains('<gpxtpx:speed>15.000</gpxtpx:speed>'));
      expect(gpx, contains('<gpxtpx:speed>20.000</gpxtpx:speed>'));
    });

    test('buildCsv outputs header, chronological rows across segments, and interpolated cumulative_km', () {
      final t0 = DateTime.utc(2026, 11, 17, 1, 0, 0);
      final t1 = DateTime.utc(2026, 11, 17, 1, 1, 0);
      final t2 = DateTime.utc(2026, 11, 17, 1, 2, 0);
      final t3 = DateTime.utc(2026, 11, 17, 1, 12, 0);
      final t4 = DateTime.utc(2026, 11, 17, 1, 14, 0);

      final trip1 = _trip(
        id: 'csv_1',
        start: t0,
        end: t2,
        distanceKm: 4.0,
        durationSec: 120,
      );
      final trip2 = _trip(
        id: 'csv_2',
        start: t3,
        end: t4,
        distanceKm: 6.0,
        durationSec: 120,
      );

      final session = MergedTripSession.fromTrips(
        trips: [trip2, trip1], // out of order -> sorted chronologically
        routesByTripId: {
          'csv_1': [
            _pt(10.77, 106.70, t0, speed: 30.0, heading: 90.0, altitude: 10.0),
            _pt(10.78, 106.71, t1, speed: 40.0),
            _pt(10.79, 106.72, t2, speed: 50.0, heading: 180.0),
          ],
          'csv_2': [
            _pt(10.80, 106.73, t3, speed: 45.0, altitude: 15.5),
            _pt(10.81, 106.74, t4, speed: 55.0),
          ],
        },
      );

      final csv = TripExportService.instance.buildCsv(session);
      final lines = const LineSplitter().convert(csv);

      expect(lines.length, 6);
      expect(
        lines[0],
        'timestamp_iso,elapsed_sec,segment,lat,lng,speed_kmh,heading,altitude,cumulative_km',
      );
      expect(
        lines[1],
        '2026-11-17T01:00:00.000Z,0,1,10.770000,106.700000,30.00,90.0,10.0,0.000',
      );
      expect(
        lines[2],
        '2026-11-17T01:01:00.000Z,60,1,10.780000,106.710000,40.00,,,2.000',
      );
      expect(
        lines[3],
        '2026-11-17T01:02:00.000Z,120,1,10.790000,106.720000,50.00,180.0,,4.000',
      );
      expect(
        lines[4],
        '2026-11-17T01:12:00.000Z,720,2,10.800000,106.730000,45.00,,15.5,4.000',
      );
      expect(
        lines[5],
        '2026-11-17T01:14:00.000Z,840,2,10.810000,106.740000,55.00,,,10.000',
      );

      final emptySession = MergedTripSession.fromTrips(
        trips: const [],
        routesByTripId: const {},
      );
      expect(
        TripExportService.instance.buildCsv(emptySession),
        'timestamp_iso,elapsed_sec,segment,lat,lng,speed_kmh,heading,altitude,cumulative_km',
      );
    });

    test('buildKml outputs valid KML 2.2 with Document, LineString per segment, start/end pins, and stopovers', () {
      final t0 = DateTime.utc(2026, 11, 17, 1, 0, 0);
      final t1 = DateTime.utc(2026, 11, 17, 1, 10, 0);
      final t2 = DateTime.utc(2026, 11, 17, 1, 35, 0);
      final t3 = DateTime.utc(2026, 11, 17, 1, 50, 0);

      final session = MergedTripSession.fromTrips(
        trips: [
          _trip(id: 'k1', start: t0, end: t1, distanceKm: 2.5, durationSec: 600),
          _trip(id: 'k2', start: t2, end: t3, distanceKm: 3.5, durationSec: 900),
        ],
        routesByTripId: {
          'k1': [
            _pt(10.77, 106.70, t0, altitude: 5.0),
            _pt(10.78, 106.71, t1),
          ],
          'k2': [
            _pt(10.785, 106.715, t2),
            _pt(10.795, 106.725, t3, altitude: 12.0),
          ],
        },
        customTitle: 'KML <Route> & Pins',
      );

      final kml = TripExportService.instance.buildKml(session);

      expect(kml, contains('<?xml version="1.0" encoding="UTF-8"?>'));
      expect(kml, contains('<kml xmlns="http://www.opengis.net/kml/2.2">'));
      expect(kml, contains('<Document>'));
      expect(kml, contains('<name>KML &lt;Route&gt; &amp; Pins</name>'));
      expect(kml, contains('<Style id="routeLineStyle">'));
      expect(kml, contains('<Style id="stopoverPinStyle">'));

      // 2 LineString segments
      expect(RegExp(r'<LineString>').allMatches(kml).length, 2);
      expect(kml, contains('106.700000,10.770000,5.0 106.710000,10.780000'));
      expect(kml, contains('106.715000,10.785000 106.725000,10.795000,12.0'));

      // Start, End, and P1 stopover Point placemarks (total 3 Points)
      expect(RegExp(r'<Point>').allMatches(kml).length, 3);
      expect(kml, contains('<name>Điểm xuất phát</name>'));
      expect(kml, contains('<name>Điểm kết thúc</name>'));
      expect(kml, contains('<name>P1</name>'));
      expect(kml, contains('Điểm dừng P1 · 25 phút'));
    });

    test('buildContent, fileExtension, writeTempExportFile, and shareSessionExport work cleanly', () async {
      final tempRoot = await Directory.systemTemp.createTemp('datbike_export_test_');
      addTearDown(() async {
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });

      const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
      const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
      final recordedShareCalls = <MethodCall>[];

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, (call) async {
        if (call.method == 'getTemporaryDirectory') {
          return tempRoot.path;
        }
        return null;
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(shareChannel, (call) async {
        recordedShareCalls.add(call);
        return 'dev.fluttercommunity.plus/share/success';
      });

      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProviderChannel, null);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(shareChannel, null);
      });

      expect(TripExportService.instance.fileExtension(TripExportFormat.gpx), 'gpx');
      expect(TripExportService.instance.fileExtension(TripExportFormat.csv), 'csv');
      expect(TripExportService.instance.fileExtension(TripExportFormat.kml), 'kml');

      final t0 = DateTime.utc(2026, 11, 17, 3, 0, 0);
      final t1 = DateTime.utc(2026, 11, 17, 3, 10, 0);
      final trip = _trip(
        id: 'share_1',
        start: t0,
        end: t1,
        distanceKm: 5.2,
        durationSec: 600,
      );
      final session = TripExportService.instance.sessionFromSingleTrip(
        trip,
        [_pt(10.77, 106.70, t0), _pt(10.78, 106.71, t1)],
        tripNumber: 9,
      );

      final customTitled = MergedTripSession(
        id: session.id,
        title: 'Ngày 17/11: Sài Gòn / Quận 1 *?<>|',
        mode: session.mode,
        segments: session.segments,
        allPoints: session.allPoints,
        segmentStartIndices: session.segmentStartIndices,
        stopovers: session.stopovers,
      );

      expect(
        TripExportService.instance.buildContent(customTitled, TripExportFormat.gpx),
        TripExportService.instance.buildGpx(customTitled),
      );
      expect(
        TripExportService.instance.buildContent(customTitled, TripExportFormat.csv),
        TripExportService.instance.buildCsv(customTitled),
      );
      expect(
        TripExportService.instance.buildContent(customTitled, TripExportFormat.kml),
        TripExportService.instance.buildKml(customTitled),
      );

      final exportedFile = await TripExportService.instance.writeTempExportFile(
        customTitled,
        TripExportFormat.gpx,
      );
      expect(await exportedFile.exists(), isTrue);
      expect(exportedFile.path.endsWith('.gpx'), isTrue);
      expect(
        exportedFile.uri.pathSegments.last,
        startsWith('Ngay_17_11_Sai_Gon_Quan_1_'),
      );
      expect(
        await exportedFile.readAsString(),
        TripExportService.instance.buildGpx(customTitled),
      );

      await TripExportService.instance.shareSessionExport(
        customTitled,
        TripExportFormat.kml,
      );
      expect(recordedShareCalls.length, 1);
      expect(recordedShareCalls.first.method, 'share');
      final args = Map<String, dynamic>.from(
        recordedShareCalls.first.arguments as Map,
      );
      expect(args['subject'], customTitled.title);
      expect(args['text'], contains('5.2 km'));
      final paths = List<String>.from(args['paths'] as List);
      expect(paths.single.endsWith('.kml'), isTrue);
      expect(File(paths.single).existsSync(), isTrue);
    });
  });

  group('TripAnalyticsService', () {
    test('summarizes 7-day window with continuous ordered buckets and accurate savings', () {
      final now = DateTime(2026, 11, 17, 18, 30);

      final trips = [
        // Outside 7-day window (8 days ago: Nov 9) -> excluded
        _trip(
          id: 'old',
          start: DateTime(2026, 11, 9, 8, 0),
          end: DateTime(2026, 11, 9, 8, 30),
          distanceKm: 99.0,
          durationSec: 1800,
          maxSpeedKmh: 90.0,
          usedPercent: 40,
        ),
        // Exactly at startDay (6 days ago: Nov 11) -> included
        _trip(
          id: 'd1',
          start: DateTime(2026, 11, 11, 7, 30),
          end: DateTime(2026, 11, 11, 8, 0),
          distanceKm: 12.0,
          durationSec: 1800,
          maxSpeedKmh: 52.0,
          usedPercent: 10,
        ),
        // Nov 15: two trips on the same day
        _trip(
          id: 'd5_a',
          start: DateTime(2026, 11, 15, 9, 0),
          end: DateTime(2026, 11, 15, 9, 20),
          distanceKm: 8.0,
          durationSec: 1200,
          maxSpeedKmh: 48.0,
          usedPercent: 6,
        ),
        _trip(
          id: 'd5_b',
          start: DateTime(2026, 11, 15, 17, 0),
          end: DateTime(2026, 11, 15, 17, 40),
          distanceKm: 16.0,
          durationSec: 2400,
          maxSpeedKmh: 65.0,
          usedPercent: 14,
        ),
        // Today (Nov 17)
        _trip(
          id: 'today',
          start: DateTime(2026, 11, 17, 10, 0),
          end: DateTime(2026, 11, 17, 10, 30),
          distanceKm: 14.0,
          durationSec: 1800,
          maxSpeedKmh: 58.0,
          usedPercent: 12,
        ),
        // Future day (Nov 18) -> excluded
        _trip(
          id: 'future',
          start: DateTime(2026, 11, 18, 8, 0),
          end: DateTime(2026, 11, 18, 8, 10),
          distanceKm: 20.0,
          durationSec: 600,
          maxSpeedKmh: 80.0,
          usedPercent: 15,
        ),
      ];

      final summary = TripAnalyticsService.summarize(
        trips,
        days: 7,
        now: now,
      );

      expect(summary.days, 7);
      expect(summary.tripCount, 4);
      expect(summary.totalDistanceKm, closeTo(50.0, 1e-6));
      expect(summary.totalMovingDurationSec, 7200); // 2 hours
      expect(summary.totalUsedPercent, 42);
      expect(summary.maxSpeedKmh, 65.0);
      expect(summary.avgSpeedKmh, closeTo(25.0, 1e-6)); // 50 km / 2 h
      expect(summary.avgDistancePerTripKm, closeTo(12.5, 1e-6));
      expect(summary.co2SavedKg, closeTo(50.0 * 0.065, 1e-6));
      expect(summary.estimatedFuelSavedVnd, closeTo(25000.0, 1e-6));

      expect(summary.dailyBuckets.length, 7);
      expect(summary.dailyBuckets.first.day, DateTime(2026, 11, 11));
      expect(summary.dailyBuckets.first.shortDayLabel, '11/11');
      expect(summary.dailyBuckets.first.distanceKm, closeTo(12.0, 1e-6));
      expect(summary.dailyBuckets.first.tripCount, 1);

      // Days with zero trips have continuous 0-valued buckets
      expect(summary.dailyBuckets[1].day, DateTime(2026, 11, 12));
      expect(summary.dailyBuckets[1].distanceKm, 0.0);
      expect(summary.dailyBuckets[1].tripCount, 0);
      expect(summary.dailyBuckets[1].movingDurationSec, 0);

      // Nov 15 bucket aggregates both trips
      final nov15 = summary.dailyBuckets[4];
      expect(nov15.day, DateTime(2026, 11, 15));
      expect(nov15.tripCount, 2);
      expect(nov15.distanceKm, closeTo(24.0, 1e-6));
      expect(nov15.movingDurationSec, 3600);

      // Last bucket is today
      expect(summary.dailyBuckets.last.day, DateTime(2026, 11, 17));
      expect(summary.dailyBuckets.last.shortDayLabel, '17/11');
      expect(summary.dailyBuckets.last.distanceKm, closeTo(14.0, 1e-6));
    });

    test('summarizes 30-day window across month boundary and supports custom fuelCostPerKmVnd', () {
      final now = DateTime(2026, 11, 17, 12, 0);
      // 30 days inclusive: [2026-10-19 .. 2026-11-17]
      final trips = [
        _trip(
          id: 'too_old',
          start: DateTime(2026, 10, 18, 23, 50),
          end: DateTime(2026, 10, 18, 23, 59),
          distanceKm: 5.0,
          durationSec: 540,
        ),
        _trip(
          id: 'start_edge',
          start: DateTime(2026, 10, 19, 6, 0),
          end: DateTime(2026, 10, 19, 6, 30),
          distanceKm: 10.0,
          durationSec: 1800,
          usedPercent: -3, // negative ignored
        ),
        _trip(
          id: 'nov_trip',
          start: DateTime(2026, 11, 1, 9, 0),
          end: DateTime(2026, 11, 1, 9, 30),
          distanceKm: 20.0,
          durationSec: 1800,
          usedPercent: 18,
        ),
      ];

      final summary = TripAnalyticsService.summarize(
        trips,
        days: 30,
        now: now,
        fuelCostPerKmVnd: 650.0,
      );

      expect(summary.dailyBuckets.length, 30);
      expect(summary.dailyBuckets.first.day, DateTime(2026, 10, 19));
      expect(summary.dailyBuckets.first.shortDayLabel, '19/10');
      expect(summary.dailyBuckets.last.day, DateTime(2026, 11, 17));
      expect(summary.tripCount, 2);
      expect(summary.totalDistanceKm, closeTo(30.0, 1e-6));
      expect(summary.totalUsedPercent, 18);
      expect(summary.estimatedFuelSavedVnd, closeTo(19500.0, 1e-6));
      expect(summary.co2SavedKg, closeTo(30.0 * 0.065, 1e-6));

      final empty = TripAnalyticsService.summarize(const [], days: 7, now: now);
      expect(empty.tripCount, 0);
      expect(empty.totalDistanceKm, 0.0);
      expect(empty.avgSpeedKmh, 0.0);
      expect(empty.avgDistancePerTripKm, 0.0);
      expect(empty.dailyBuckets.length, 7);
    });
  });
}
