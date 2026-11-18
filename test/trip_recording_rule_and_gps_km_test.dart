import 'dart:convert';
import 'dart:io';

import 'package:mybike_app/core/ble/ble_controller.dart';
import 'package:mybike_app/core/models/merged_trip_session.dart';
import 'package:mybike_app/core/proto/bike_log.dart';
import 'package:mybike_app/core/services/gps_route_snapping_service.dart';
import 'package:mybike_app/core/services/trip_analytics_service.dart';
import 'package:mybike_app/core/services/trip_gps_tracker.dart';
import 'package:mybike_app/core/services/trip_recording_gate.dart';
import 'package:mybike_app/core/services/trip_storage_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TestBleController extends BleController {
  @override
  BleState build() => const BleState(phase: BlePhase.connected, isAuthorized: true);
}

Position _makePosition({
  required double lat,
  required double lng,
  required DateTime ts,
  double speedMps = 0.0,
  double accuracy = 6.0,
  double heading = 90.0,
}) {
  return Position(
    latitude: lat,
    longitude: lng,
    timestamp: ts,
    accuracy: accuracy,
    altitude: 10.0,
    altitudeAccuracy: 3.0,
    heading: heading,
    headingAccuracy: 5.0,
    speed: speedMps,
    speedAccuracy: 0.5,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    TripGpsTracker.instance.clear();
    await TripGpsTracker.instance.clearSavedCache();
  });

  tearDown(() {
    TripGpsTracker.instance.stopTracking();
    TripGpsTracker.instance.clear();
  });

  group('ECU Trip Recording Gate (Chống ghi nhầm khi đi ngang xe)', () {
    test('TripRecordingPolicy chỉ cho phép mode chạy tiến, không gạt chân chống và tốc độ ECU > 4 km/h', () {
      final walkingPastOff = BikeLogMsg()
        ..state = BikeState.off
        ..parking = true
        ..speed = 0.0;
      expect(TripRecordingPolicy.isEcuActivelyRiding(walkingPastOff), isFalse);

      final walkUpStandby = BikeLogMsg()
        ..state = BikeState.standBy
        ..parking = true
        ..speed = 12.0; // giả sử chân chống vẫn gạt
      expect(TripRecordingPolicy.isEcuActivelyRiding(walkUpStandby), isFalse);

      final parkingMode = BikeLogMsg()
        ..state = BikeState.parking
        ..parking = false
        ..speed = 8.0;
      expect(TripRecordingPolicy.isEcuActivelyRiding(parkingMode), isFalse);

      final reverseMode = BikeLogMsg()
        ..state = BikeState.reverse
        ..parking = false
        ..speed = 6.0;
      expect(TripRecordingPolicy.isEcuActivelyRiding(reverseMode), isFalse);

      final pushingBikeSlow = BikeLogMsg()
        ..state = BikeState.drive
        ..parking = false
        ..speed = 4.0; // đúng bằng ngưỡng 4 km/h -> chưa vượt > 4
      expect(TripRecordingPolicy.isEcuActivelyRiding(pushingBikeSlow), isFalse);

      for (final mode in [
        BikeState.drive,
        BikeState.super_,
        BikeState.turtle,
        BikeState.cruiseControl,
      ]) {
        final riding = BikeLogMsg()
          ..state = mode
          ..parking = false
          ..speed = 4.5;
        expect(TripRecordingPolicy.isEcuActivelyRiding(riding), isTrue);
      }
    });

    test('Đi bộ ngang xe kết nối BLE (kể cả Walk-Up bật điện & tốc độ GPS đi bộ > 5 km/h) không ghi hành trình hay điểm GPS', () {
      final container = ProviderContainer(
        overrides: [
          bleProvider.overrideWith(() => _TestBleController()),
        ],
      );
      addTearDown(container.dispose);

      final ctrl = container.read(bleProvider.notifier);
      final t0 = DateTime(2026, 11, 18, 9, 0, 0);

      // 1. Vừa kết nối khi đi ngang xe đang tắt
      var trip = ctrl.ingestTripTelemetryForTesting(
        BikeLogMsg()
          ..state = BikeState.off
          ..parking = true
          ..odo = 1200.0
          ..speed = 0.0,
        now: t0,
      );
      expect(trip.duration, Duration.zero);
      expect(trip.distanceKm, 0.0);
      expect(trip.gpsDistanceKm, 0.0);
      expect(TripGpsTracker.instance.hasStartedActiveRide, isFalse);
      expect(TripGpsTracker.instance.isActivelyRecording, isFalse);

      // 2. Walk-Up bật nguồn sang Parking/Standby, user tiếp tục đi bộ xa xe (GPS ~6.5 km/h)
      trip = ctrl.ingestTripTelemetryForTesting(
        BikeLogMsg()
          ..state = BikeState.standBy
          ..parking = true
          ..odo = 1200.0
          ..speed = 0.0,
        now: t0.add(const Duration(seconds: 5)),
      );
      expect(trip.duration, Duration.zero);
      expect(TripGpsTracker.instance.hasStartedActiveRide, isFalse);

      TripGpsTracker.instance.ingestPositionForTesting(
        _makePosition(lat: 10.7700, lng: 106.7100, ts: t0, speedMps: 1.8),
        now: t0,
      );
      TripGpsTracker.instance.ingestPositionForTesting(
        _makePosition(
          lat: 10.7704,
          lng: 106.7100,
          ts: t0.add(const Duration(seconds: 15)),
          speedMps: 1.9, // ~6.8 km/h GPS walking speed
        ),
        now: t0.add(const Duration(seconds: 15)),
      );
      expect(TripGpsTracker.instance.recordedPoints, isEmpty);

      // 3. Thậm chí ở Drive nhưng dắt bộ <= 4.0 km/h (speed ECU = 3.8 km/h), GPS báo 7 km/h -> vẫn KHÔNG ghi
      trip = ctrl.ingestTripTelemetryForTesting(
        BikeLogMsg()
          ..state = BikeState.drive
          ..parking = false
          ..odo = 1200.0
          ..speed = 3.8,
        now: t0.add(const Duration(seconds: 20)),
      );
      expect(trip.duration, Duration.zero);
      expect(TripGpsTracker.instance.hasStartedActiveRide, isFalse);

      TripGpsTracker.instance.ingestPositionForTesting(
        _makePosition(
          lat: 10.7708,
          lng: 106.7100,
          ts: t0.add(const Duration(seconds: 22)),
          speedMps: 2.0, // ~7.2 km/h GPS
        ),
        now: t0.add(const Duration(seconds: 22)),
      );
      expect(TripGpsTracker.instance.recordedPoints, isEmpty);
    });

    test('Chỉ kích hoạt hành trình khi vào mode chạy + ECU > 4 km/h và giữ nguyên chuyến khi dừng đèn đỏ', () async {
      final container = ProviderContainer(
        overrides: [
          bleProvider.overrideWith(() => _TestBleController()),
        ],
      );
      addTearDown(container.dispose);

      final ctrl = container.read(bleProvider.notifier);
      final t0 = DateTime(2026, 11, 18, 9, 10, 0);

      // Xe vào số D, gạt chân chống, tốc độ ECU đạt 14.5 km/h
      var trip = ctrl.ingestTripTelemetryForTesting(
        BikeLogMsg()
          ..state = BikeState.drive
          ..parking = false
          ..odo = 1200.0
          ..percent = 80
          ..speed = 14.5,
        now: t0,
      );
      expect(TripGpsTracker.instance.hasStartedActiveRide, isTrue);
      expect(trip.maxSpeedKmh, 14.5);

      TripGpsTracker.instance.ingestPositionForTesting(
        _makePosition(lat: 10.7700, lng: 106.7100, ts: t0),
        now: t0,
      );
      TripGpsTracker.instance.ingestPositionForTesting(
        _makePosition(
          lat: 10.7710,
          lng: 106.7100,
          ts: t0.add(const Duration(seconds: 10)),
        ),
        now: t0.add(const Duration(seconds: 10)),
      );
      expect(TripGpsTracker.instance.recordedPoints.length, 2);
      // Điểm GPS ghi nhận vận tốc từ ECU chứ không lấy pos.speed = 0
      expect(TripGpsTracker.instance.recordedPoints.last.speedKmh, 14.5);

      // Dừng đèn đỏ 25s (ECU speed = 0), chuyến đi vẫn tiếp tục nhưng không ghi nhiễu đứng yên
      trip = ctrl.ingestTripTelemetryForTesting(
        BikeLogMsg()
          ..state = BikeState.drive
          ..parking = false
          ..odo = 1200.5
          ..percent = 79
          ..speed = 0.0,
        now: t0.add(const Duration(seconds: 35)),
      );
      expect(trip.duration.inSeconds, 35);
      expect(trip.distanceKm, closeTo(0.5, 0.001));
      expect(trip.usedPercent, 1);

      TripGpsTracker.instance.ingestPositionForTesting(
        _makePosition(
          lat: 10.77102,
          lng: 106.71002,
          ts: t0.add(const Duration(seconds: 35)),
          accuracy: 5.0,
        ),
        now: t0.add(const Duration(seconds: 35)),
      );
      // Vẫn giữ đúng 2 điểm, không thêm điểm đứng yên tại đèn đỏ
      expect(TripGpsTracker.instance.recordedPoints.length, 2);

      // Reset Trip khi xe đang đỗ -> xóa về 0 và không tạo đồng hồ đếm giả khi speed = 0
      await ctrl.resetTrip();
      expect(TripGpsTracker.instance.hasStartedActiveRide, isFalse);
      final afterReset = container.read(bleProvider).trip;
      expect(afterReset.duration, Duration.zero);
      expect(afterReset.distanceKm, 0.0);
    });
  });

  group('Đo KM GPS trừ đoạn mất sóng & Nắn đường OSRM', () {
    test('Trừ đúng đoạn mất sóng GPS (>15s không có fix & dịch chuyển >45m) trong cả tracker lẫn cleanAndSmoothRoute', () {
      final t0 = DateTime(2026, 11, 18, 10, 0, 0);
      TripGpsTracker.instance.updateVehicleState(
        isConnected: true,
        isBikeOn: true,
        isSideStandDown: false,
        isDriveMode: true,
        speedKmh: 36.0,
      );

      // Chặng 1: P0 -> P1 (~111m)
      TripGpsTracker.instance.ingestPositionForTesting(
        _makePosition(lat: 10.770000, lng: 106.710000, ts: t0),
        now: t0,
      );
      TripGpsTracker.instance.ingestPositionForTesting(
        _makePosition(
          lat: 10.771000,
          lng: 106.710000,
          ts: t0.add(const Duration(seconds: 10)),
        ),
        now: t0.add(const Duration(seconds: 10)),
      );

      // Mất sóng GPS 40s qua hầm Thủ Thiêm (~555m nhảy thẳng) -> P2
      final afterTunnel = t0.add(const Duration(seconds: 50));
      TripGpsTracker.instance.ingestPositionForTesting(
        _makePosition(lat: 10.776000, lng: 106.710000, ts: afterTunnel),
        now: afterTunnel,
      );
      // Đi tiếp P2 -> P3 (~111m)
      TripGpsTracker.instance.ingestPositionForTesting(
        _makePosition(
          lat: 10.777000,
          lng: 106.710000,
          ts: afterTunnel.add(const Duration(seconds: 10)),
        ),
        now: afterTunnel.add(const Duration(seconds: 10)),
      );

      final pts = TripGpsTracker.instance.recordedPoints;
      expect(pts.length, 4);
      expect(pts[2].isSignalLossRestart, isTrue);
      expect(TripGpsTracker.instance.signalLossCount, 1);

      // Tổng GPS hợp lệ chỉ ~222m (~0.22km), KHÔNG bị cộng 555m chim bay qua hầm
      expect(TripGpsTracker.instance.totalDistanceKm, lessThan(0.30));
      expect(TripGpsTracker.instance.totalDistanceKm, greaterThan(0.15));
      expect(TripGpsTracker.instance.excludedGapDistanceKm, greaterThan(0.45));

      // cleanAndSmoothRoute giữ nguyên ranh giới signalLossRestart và không làm mờ qua hầm
      final smoothed = TripGpsTracker.cleanAndSmoothRoute(pts);
      expect(smoothed[2].isSignalLossRestart, isTrue);
      expect(smoothed[2].lat, closeTo(10.776000, 0.0005));
    });

    test('GpsRouteAnalyzer không cắt nhầm khi dừng đèn đỏ lâu (>15s nhưng dịch chuyển <= 45m)', () {
      final t0 = DateTime(2026, 11, 18, 10, 30, 0);
      final pts = [
        TripGpsPoint(lat: 10.770000, lng: 106.710000, speedKmh: 25.0, timestamp: t0),
        TripGpsPoint(
          lat: 10.770200, // ~22m <= 45m dù dừng đèn đỏ 60s
          lng: 106.710000,
          speedKmh: 10.0,
          timestamp: t0.add(const Duration(seconds: 60)),
        ),
        TripGpsPoint(
          lat: 10.771200,
          lng: 106.710000,
          speedKmh: 30.0,
          timestamp: t0.add(const Duration(seconds: 72)),
        ),
      ];

      final metrics = GpsRouteAnalyzer.measureRoute(pts);
      expect(metrics.signalLossCount, 0);
      expect(metrics.subTracks.length, 1);
      expect(metrics.distanceKm, closeTo(0.133, 0.01));
    });

    test('GpsRouteSnappingService tách riêng các đoạn mất sóng trước khi gọi OSRM Map Matching & fallback an toàn', () async {
      final t0 = DateTime(2026, 11, 18, 11, 0, 0);
      final inputPoints = [
        TripGpsPoint(lat: 10.770000, lng: 106.710000, speedKmh: 20.0, timestamp: t0),
        TripGpsPoint(lat: 10.771000, lng: 106.710000, speedKmh: 36.0, timestamp: t0.add(const Duration(seconds: 10))),
        // Mất sóng GPS 40s & nhảy 600m
        TripGpsPoint(
          lat: 10.776500,
          lng: 106.712000,
          speedKmh: 40.0,
          timestamp: t0.add(const Duration(seconds: 50)),
          isSignalLossRestart: true,
        ),
        TripGpsPoint(
          lat: 10.777500,
          lng: 106.712000,
          speedKmh: 42.0,
          timestamp: t0.add(const Duration(seconds: 60)),
        ),
      ];

      var matchCalls = 0;
      final mockClient = MockClient((request) async {
        matchCalls++;
        expect(request.url.path, contains('/match/v1/driving/'));
        // Mỗi sub-track dài ~111m; giả lập OSRM nắn cong đường dài 140m (trong ngưỡng 0.45..2.2x)
        if (matchCalls == 1) {
          return http.Response(
            jsonEncode({
              'code': 'Ok',
              'matchings': [
                {
                  'distance': 140.0,
                  'geometry': {
                    'type': 'LineString',
                    'coordinates': [
                      [106.710000, 10.770000],
                      [106.710300, 10.770500],
                      [106.710000, 10.771000],
                    ],
                  },
                },
              ],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'code': 'Ok',
            'matchings': [
              {
                'distance': 150.0,
                'geometry': {
                  'type': 'LineString',
                  'coordinates': [
                    [106.712000, 10.776500],
                    [106.712300, 10.777000],
                    [106.712000, 10.777500],
                  ],
                },
              },
            ],
          }),
          200,
        );
      });

      final snapped = await GpsRouteSnappingService.instance.snapRouteToRoads(
        inputPoints,
        httpClient: mockClient,
      );

      // 2 sub-tracks -> 2 OSRM requests riêng biệt, không bao giờ nối đoạn mất sóng
      expect(matchCalls, 2);
      expect(snapped.metrics.isRoadSnapped, isTrue);
      expect(snapped.metrics.signalLossCount, 1);
      expect(snapped.metrics.distanceKm, closeTo((140.0 + 150.0) / 1000.0, 0.01));
      expect(snapped.points.length, 6);
      expect(snapped.points[3].isSignalLossRestart, isTrue);

      // Sanity guard: nếu OSRM trả về đường vòng phi lý (> 2.2x) hoặc lỗi 500 -> tự fallback an toàn
      final badClient = MockClient((_) async => http.Response('Server Error', 500));
      final fallback = await GpsRouteSnappingService.instance.snapRouteToRoads(
        inputPoints,
        httpClient: badClient,
      );
      expect(fallback.metrics.isRoadSnapped, isFalse);
      expect(fallback.metrics.signalLossCount, 1);
      expect(fallback.metrics.distanceKm, closeTo(0.222, 0.01));
    });

    test('TripRecord, TripStorageService.updateTripGpsMetrics, MergedTripSession & Analytics hỗ trợ song song ODO + GPS KM', () async {
      final tmpDir = await Directory.systemTemp.createTemp('datbike_gps_km_test_');
      const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
      TripStorageService.instance.resetDirectoryCacheForTesting();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, (call) async {
        if (call.method == 'getApplicationDocumentsDirectory' ||
            call.method == 'getTemporaryDirectory') {
          return tmpDir.path;
        }
        return null;
      });
      addTearDown(() async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProviderChannel, null);
        TripStorageService.instance.resetDirectoryCacheForTesting();
        if (await tmpDir.exists()) {
          await tmpDir.delete(recursive: true);
        }
      });

      final t0 = DateTime(2026, 11, 18, 8, 0, 0);
      final route1 = [
        TripGpsPoint(lat: 10.7700, lng: 106.7100, speedKmh: 30.0, timestamp: t0),
        TripGpsPoint(lat: 10.7800, lng: 106.7100, speedKmh: 40.0, timestamp: t0.add(const Duration(seconds: 90))),
      ];

      final olderTrip = TripRecord(
        id: 'trip_older',
        startTime: t0.subtract(const Duration(hours: 2)),
        endTime: t0.subtract(const Duration(hours: 1, minutes: 40)),
        distanceKm: 5.0,
        gpsDistanceKm: 4.8,
        isGpsRoadSnapped: true,
        durationSec: 1200,
        avgSpeedKmh: 28.0,
        maxSpeedKmh: 45.0,
        usedPercent: 4,
      );
      final newerTrip = TripRecord(
        id: 'trip_newer',
        startTime: t0,
        endTime: t0.add(const Duration(minutes: 15)),
        distanceKm: 6.0,
        durationSec: 900,
        avgSpeedKmh: 32.0,
        maxSpeedKmh: 50.0,
        usedPercent: 5,
        route: route1,
      );

      await TripStorageService.instance.saveTrip(trip: olderTrip, route: const []);
      await TripStorageService.instance.saveTrip(trip: newerTrip, route: route1);

      // Cập nhật nắn đường cho chuyến đi -> giữ nguyên thứ tự [newerTrip, olderTrip]
      await TripStorageService.instance.updateTripGpsMetrics(
        tripId: 'trip_newer',
        gpsDistanceKm: 5.75,
        isRoadSnapped: true,
        signalLossCount: 1,
        route: route1,
      );

      final loaded = await TripStorageService.instance.loadAllTrips();
      expect(loaded.map((e) => e.id).toList(), ['trip_newer', 'trip_older']);
      expect(loaded.first.gpsDistanceKm, 5.75);
      expect(loaded.first.isGpsRoadSnapped, isTrue);
      expect(loaded.first.gpsSignalLossCount, 1);

      final session = MergedTripSession.fromTrips(
        trips: loaded,
        routesByTripId: {'trip_newer': route1, 'trip_older': const []},
      );
      expect(session.totalDistanceKm, closeTo(11.0, 0.001));
      expect(session.hasGpsDistance, isTrue);
      expect(session.totalGpsDistanceKm, closeTo(10.55, 0.001));

      final summary = TripAnalyticsService.summarize(
        loaded,
        days: 7,
        now: t0.add(const Duration(hours: 1)),
      );
      expect(summary.totalDistanceKm, closeTo(11.0, 0.001));
      expect(summary.hasGpsDistance, isTrue);
      expect(summary.totalGpsDistanceKm, closeTo(10.55, 0.001));
    });
  });

  group('Vòng đời kết thúc hành trình khi xe tắt & Chống lệch ODO vs GPS', () {
    Future<Directory> mountMockTripsDir() async {
      final tmpDir = await Directory.systemTemp.createTemp('datbike_trip_lifecycle_');
      const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
      TripStorageService.instance.resetDirectoryCacheForTesting();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, (call) async {
        if (call.method == 'getApplicationDocumentsDirectory' ||
            call.method == 'getTemporaryDirectory') {
          return tmpDir.path;
        }
        return null;
      });
      addTearDown(() async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProviderChannel, null);
        TripStorageService.instance.resetDirectoryCacheForTesting();
        if (await tmpDir.exists()) {
          await tmpDir.delete(recursive: true);
        }
      });
      return tmpDir;
    }

    test('Xe tắt bằng nút trên xe / NFC (BikeState.off / lock) tự chốt & lưu hành trình sau 5s dù BLE chưa rớt', () async {
      await mountMockTripsDir();
      final container = ProviderContainer(
        overrides: [bleProvider.overrideWith(() => _TestBleController())],
      );
      addTearDown(container.dispose);

      final ctrl = container.read(bleProvider.notifier);
      final t0 = DateTime(2026, 11, 18, 12, 0, 0);

      // Chạy 4.2 km (t0 -> t0 + 600s)
      ctrl.ingestTripTelemetryForTesting(
        BikeLogMsg()
          ..state = BikeState.drive
          ..parking = false
          ..odo = 2000.0
          ..percent = 90
          ..speed = 25.0,
        now: t0,
      );
      var liveTrip = ctrl.ingestTripTelemetryForTesting(
        BikeLogMsg()
          ..state = BikeState.drive
          ..parking = false
          ..odo = 2004.2
          ..percent = 87
          ..speed = 28.0,
        now: t0.add(const Duration(seconds: 600)),
      );
      expect(liveTrip.distanceKm, closeTo(4.2, 0.001));
      expect(liveTrip.duration.inSeconds, 600);

      // Gói MTU cắt cụt giả mạo không được phép tắt hành trình
      ctrl.ingestTripTelemetryForTesting(
        BikeLogMsg()
          ..state = BikeState.off
          ..parking = false
          ..odo = 2004.2
          ..speed = 0.0,
        now: t0.add(const Duration(seconds: 605)),
        hasAuthoritativeState: false,
      );
      expect(ctrl.bikeOffSinceForTesting, isNull);
      expect(container.read(bleProvider).tripHistory, isEmpty);

      // Xe thực sự chuyển sang BikeState.off (tắt nút trên xe) -> đóng băng duration tại giây 610
      final offAt = t0.add(const Duration(seconds: 610));
      liveTrip = ctrl.ingestTripTelemetryForTesting(
        BikeLogMsg()
          ..state = BikeState.off
          ..parking = true
          ..odo = 2004.2
          ..percent = 87
          ..speed = 0.0,
        now: offAt,
        hasAuthoritativeState: true,
      );
      expect(ctrl.bikeOffSinceForTesting, offAt);
      expect(container.read(bleProvider).tripHistory, isEmpty);

      // Sau 3s chưa vội chốt (tránh nhiễu chuyển tiếp); giữ off >= 5s mới tự động chốt & lưu 4.2 km đúng mốc 610s!
      liveTrip = ctrl.ingestTripTelemetryForTesting(
        BikeLogMsg()
          ..state = BikeState.off
          ..parking = true
          ..odo = 2004.2
          ..percent = 87
          ..speed = 0.0,
        now: offAt.add(const Duration(seconds: 3)),
        hasAuthoritativeState: true,
      );
      expect(container.read(bleProvider).tripHistory, isEmpty);

      liveTrip = ctrl.ingestTripTelemetryForTesting(
        BikeLogMsg()
          ..state = BikeState.off
          ..parking = true
          ..odo = 2004.2
          ..percent = 87
          ..speed = 0.0,
        now: offAt.add(const Duration(seconds: 5)),
        hasAuthoritativeState: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final state = container.read(bleProvider);
      expect(state.trip.distanceKm, 0.0);
      expect(state.tripHistory.length, 1);
      expect(state.tripHistory.first.distanceKm, closeTo(4.2, 0.01));
      expect(state.tripHistory.first.durationSec, 610);
      expect(state.tripHistory.first.usedPercent, 3);
      expect(TripGpsTracker.instance.hasStartedActiveRide, isFalse);
    });

    test('Rớt BLE tạm thời rồi reconnect về: nối tiếp nếu xe vẫn ON hoặc chốt ngay nếu reconnect thấy xe đã OFF', () async {
      await mountMockTripsDir();
      final container = ProviderContainer(
        overrides: [bleProvider.overrideWith(() => _TestBleController())],
      );
      addTearDown(container.dispose);

      final ctrl = container.read(bleProvider.notifier);
      final t0 = DateTime(2026, 11, 18, 13, 0, 0);

      ctrl.ingestTripTelemetryForTesting(
        BikeLogMsg()
          ..state = BikeState.drive
          ..parking = false
          ..odo = 3000.0
          ..speed = 22.0,
        now: t0,
      );
      ctrl.ingestTripTelemetryForTesting(
        BikeLogMsg()
          ..state = BikeState.drive
          ..parking = false
          ..odo = 3002.5
          ..speed = 35.0,
        now: t0.add(const Duration(seconds: 300)),
      );

      // Rớt BLE bất ngờ khi đang chạy -> vào grace window thay vì cắt đôi chuyến
      ctrl.simulateConnectionLostForTesting(
        manual: false,
        now: t0.add(const Duration(seconds: 302)),
      );
      expect(ctrl.hasPendingDisconnectArchiveForTesting, isTrue);
      expect(TripGpsTracker.instance.isBikeConnected, isFalse);
      expect(container.read(bleProvider).tripHistory, isEmpty);

      // Reconnect sau 5s và xe vẫn đang ON, ODO liên tục -> nối tiếp liền mạch!
      final resumed = ctrl.ingestTripTelemetryForTesting(
        BikeLogMsg()
          ..state = BikeState.drive
          ..parking = false
          ..odo = 3004.2
          ..speed = 30.0,
        now: t0.add(const Duration(seconds: 307)),
      );
      expect(ctrl.hasPendingDisconnectArchiveForTesting, isFalse);
      expect(resumed.distanceKm, closeTo(4.2, 0.01));
      expect(container.read(bleProvider).tripHistory, isEmpty);

      // Rớt BLE lần nữa, nhưng khi reconnect lại phát hiện xe ĐÃ TẮT -> chốt ngay 4.2 km
      ctrl.simulateConnectionLostForTesting(
        manual: false,
        now: t0.add(const Duration(seconds: 310)),
      );
      ctrl.ingestTripTelemetryForTesting(
        BikeLogMsg()
          ..state = BikeState.off
          ..parking = true
          ..odo = 3004.2
          ..speed = 0.0,
        now: t0.add(const Duration(seconds: 315)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final state = container.read(bleProvider);
      expect(state.tripHistory.length, 1);
      expect(state.tripHistory.first.distanceKm, closeTo(4.2, 0.01));
    });

    test('Chặn triệt để lỗi GPS cache 12.8km cộng nhầm vào ODO 4.2km (cả cache mồ côi lẫn khác phiên)', () async {
      await mountMockTripsDir();
      final t0 = DateTime(2026, 11, 18, 14, 0, 0);

      // 1. Giả lập cache GPS mồ côi liên tục ~12.8 km (không có active_trip_session_state_v1 như bản cũ)
      final orphanPts = List.generate(
        129,
        (i) => TripGpsPoint(
          lat: 10.700000 + i * 0.0009,
          lng: 106.700000,
          speedKmh: 36.0,
          timestamp: t0.add(Duration(seconds: i * 10)),
        ),
      );
      final orphanEnd = orphanPts.last.timestamp;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'active_trip_gps_points_cache',
        jsonEncode(orphanPts.map((p) => p.toJson()).toList()),
      );
      await prefs.setString('active_trip_gps_last_time', orphanEnd.toIso8601String());

      final container = ProviderContainer(
        overrides: [bleProvider.overrideWith(() => _TestBleController())],
      );
      addTearDown(container.dispose);
      final ctrl = container.read(bleProvider.notifier);

      await ctrl.prepareRecoveredTripCacheForTesting(
        now: orphanEnd.add(const Duration(minutes: 2)),
      );
      // Cache mồ côi bị xóa sạch, không bao giờ nạp vào TripGpsTracker
      expect(TripGpsTracker.instance.recordedPoints, isEmpty);

      // Bắt đầu chạy chuyến mới 4.2 km ODO + 2 điểm GPS mới (~111m) -> GPS KHÔNG bị cộng 12.8 km cũ
      final rideStart = orphanEnd.add(const Duration(minutes: 3));
      ctrl.ingestTripTelemetryForTesting(
        BikeLogMsg()
          ..state = BikeState.drive
          ..parking = false
          ..odo = 5000.0
          ..speed = 25.0,
        now: rideStart,
      );
      TripGpsTracker.instance.ingestPositionForTesting(
        _makePosition(lat: 10.770000, lng: 106.710000, ts: rideStart),
        now: rideStart,
      );
      TripGpsTracker.instance.ingestPositionForTesting(
        _makePosition(
          lat: 10.771000,
          lng: 106.710000,
          ts: rideStart.add(const Duration(seconds: 10)),
        ),
        now: rideStart.add(const Duration(seconds: 10)),
      );
      final rideEnd = ctrl.ingestTripTelemetryForTesting(
        BikeLogMsg()
          ..state = BikeState.drive
          ..parking = false
          ..odo = 5004.2
          ..speed = 25.0,
        now: rideStart.add(const Duration(minutes: 8)),
      );
      expect(rideEnd.distanceKm, closeTo(4.2, 0.01));
      expect(rideEnd.gpsDistanceKm, lessThan(0.25)); // Tuyệt đối KHÔNG nhảy lên ~13 km!
    });

    test('Phiên bị ngắt hợp lệ (cùng xe, < 10 phút, xe vẫn bật, ODO khớp) khôi phục đồng bộ CẢ ODO + GPS', () async {
      await mountMockTripsDir();
      final t0 = DateTime(2026, 11, 18, 15, 0, 0);
      final savedPts = List.generate(
        129,
        (i) => TripGpsPoint(
          lat: 10.700000 + i * 0.0009,
          lng: 106.700000,
          speedKmh: 36.0,
          timestamp: t0.add(Duration(seconds: i * 10)),
        ),
      );
      final snapEnd = savedPts.last.timestamp;
      final snap = ActiveTripRecoverySnapshot(
        bikeId: 'BIKE-1',
        startTime: t0,
        lastActiveAt: snapEnd,
        startOdo: 6000.0,
        lastOdo: 6012.8,
        startPercent: 85,
        lastPercent: 79,
        maxSpeedKmh: 55.0,
        speedSum: 120.0,
        speedSamples: 3,
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('active_trip_session_state_v1', jsonEncode(snap.toJson()));
      await prefs.setString(
        'active_trip_gps_points_cache',
        jsonEncode(savedPts.map((p) => p.toJson()).toList()),
      );
      await prefs.setString('active_trip_gps_last_time', snap.lastActiveAt.toIso8601String());

      final container = ProviderContainer(
        overrides: [bleProvider.overrideWith(() => _TestBleController())],
      );
      addTearDown(container.dispose);
      final ctrl = container.read(bleProvider.notifier);

      await ctrl.prepareRecoveredTripCacheForTesting(
        now: snapEnd.add(const Duration(minutes: 2)),
      );

      // Xe vẫn đang bật và ODO tiếp nối hợp lệ (6012.8 -> 6013.2 km), rồi chạy tiếp tới 6017.0 km
      var resumed = ctrl.ingestTripTelemetryForTesting(
        BikeLogMsg()
          ..state = BikeState.drive
          ..parking = false
          ..odo = 6013.2
          ..percent = 78
          ..speed = 28.0,
        now: snapEnd.add(const Duration(minutes: 2)),
      );
      expect(resumed.distanceKm, closeTo(13.2, 0.01));

      resumed = ctrl.ingestTripTelemetryForTesting(
        BikeLogMsg()
          ..state = BikeState.drive
          ..parking = false
          ..odo = 6017.0
          ..percent = 76
          ..speed = 32.0,
        now: snapEnd.add(const Duration(minutes: 7)),
      );
      expect(resumed.distanceKm, closeTo(17.0, 0.01));
      expect(resumed.gpsDistanceKm, greaterThan(12.0));
      expect(resumed.usedPercent, 9);

      // Kiểm tra quy tắc từ chối nối tiếp khi khác xe, > 10 phút, xe đã tắt, hoặc nhảy ODO > 15 km
      final probeMsg = BikeLogMsg()
        ..state = BikeState.drive
        ..parking = false
        ..odo = 6014.0
        ..speed = 25.0;
      expect(
        snap.canResumeWith(msg: probeMsg, bikeId: 'BIKE-2', now: snapEnd.add(const Duration(minutes: 2))),
        isFalse,
      );
      expect(
        snap.canResumeWith(msg: probeMsg, bikeId: 'BIKE-1', now: snapEnd.add(const Duration(minutes: 15))),
        isFalse,
      );
      expect(
        snap.canResumeWith(
          msg: BikeLogMsg()..state = BikeState.off..odo = 6012.8,
          bikeId: 'BIKE-1',
          now: snapEnd.add(const Duration(minutes: 2)),
        ),
        isFalse,
      );
      expect(
        snap.canResumeWith(
          msg: BikeLogMsg()..state = BikeState.drive..odo = 6035.0,
          bikeId: 'BIKE-1',
          now: snapEnd.add(const Duration(minutes: 2)),
        ),
        isFalse,
      );
    });

    test('GpsRouteSnappingService từ chối đường vòng ô tô OSRM thổi phồng > 1.40x', () async {
      final t0 = DateTime(2026, 11, 18, 16, 0, 0);
      // Lộ trình liên tục gồm các điểm cách nhau 10s (~555m tổng)
      final rawPts = [
        TripGpsPoint(lat: 10.770000, lng: 106.710000, speedKmh: 30.0, timestamp: t0),
        TripGpsPoint(lat: 10.771250, lng: 106.710000, speedKmh: 30.0, timestamp: t0.add(const Duration(seconds: 10))),
        TripGpsPoint(lat: 10.772500, lng: 106.710000, speedKmh: 30.0, timestamp: t0.add(const Duration(seconds: 20))),
        TripGpsPoint(lat: 10.773750, lng: 106.710000, speedKmh: 30.0, timestamp: t0.add(const Duration(seconds: 30))),
        TripGpsPoint(lat: 10.775000, lng: 106.710000, speedKmh: 30.0, timestamp: t0.add(const Duration(seconds: 40))),
      ];

      // Giả lập OSRM /driving/ bắt đi vòng 1000m (~1.8x > 1.40x)
      var osrmCalled = 0;
      final detourClient = MockClient((_) async {
        osrmCalled++;
        return http.Response(
          jsonEncode({
            'code': 'Ok',
            'matchings': [
              {
                'distance': 1000.0,
                'geometry': {
                  'type': 'LineString',
                  'coordinates': [
                    [106.710000, 10.770000],
                    [106.714500, 10.772500],
                    [106.710000, 10.775000],
                  ],
                },
              },
            ],
          }),
          200,
        );
      });

      final snapped = await GpsRouteSnappingService.instance.snapRouteToRoads(
        rawPts,
        httpClient: detourClient,
      );
      expect(osrmCalled, greaterThanOrEqualTo(1));
      expect(snapped.metrics.isRoadSnapped, isFalse);
      expect(snapped.metrics.distanceKm, closeTo(0.555, 0.02));
    });

    test('TripGpsTracker không giữ ấm _lastValidFixAt khi xe đã tắt / hạ chân chống', () {
      final t0 = DateTime(2026, 11, 18, 16, 30, 0);
      TripGpsTracker.instance.updateVehicleState(
        isConnected: true,
        isBikeOn: true,
        isSideStandDown: false,
        isDriveMode: true,
        speedKmh: 30.0,
      );
      TripGpsTracker.instance.ingestPositionForTesting(
        _makePosition(lat: 10.770000, lng: 106.710000, ts: t0),
        now: t0,
      );

      // Xe tạm chuyển Parking / tắt máy khi vẫn nhận GPS (đi phà / dắt xa > 45m)
      TripGpsTracker.instance.updateVehicleState(
        isConnected: true,
        isBikeOn: false,
        isSideStandDown: true,
        isDriveMode: false,
        speedKmh: 0.0,
      );
      TripGpsTracker.instance.ingestPositionForTesting(
        _makePosition(lat: 10.772000, lng: 106.710000, ts: t0.add(const Duration(seconds: 30))),
        now: t0.add(const Duration(seconds: 30)),
      );

      // Bật xe đi lại ở vị trí cách 300m sau 40s
      TripGpsTracker.instance.updateVehicleState(
        isConnected: true,
        isBikeOn: true,
        isSideStandDown: false,
        isDriveMode: true,
        speedKmh: 28.0,
      );
      TripGpsTracker.instance.ingestPositionForTesting(
        _makePosition(lat: 10.773000, lng: 106.710000, ts: t0.add(const Duration(seconds: 40))),
        now: t0.add(const Duration(seconds: 40)),
      );

      final pts = TripGpsTracker.instance.recordedPoints;
      expect(pts.length, 2);
      expect(pts.last.isSignalLossRestart, isTrue);
      expect(TripGpsTracker.instance.totalDistanceKm, lessThan(0.05));
    });

    test('Dừng đèn đỏ quá lâu (> 3 phút) khi CHƯA về P mode vẫn giữ nguyên hành trình & KHÔNG reset', () async {
      await mountMockTripsDir();
      final container = ProviderContainer(
        overrides: [bleProvider.overrideWith(() => _TestBleController())],
      );
      addTearDown(container.dispose);

      final ctrl = container.read(bleProvider.notifier);
      final t0 = DateTime(2026, 11, 18, 17, 0, 0);

      // Chạy 0.6 km (< 1.0 km) rồi dừng đèn đỏ ở mode Drive/Super, chân chống lên (!parking)
      ctrl.ingestTripTelemetryForTesting(
        BikeLogMsg()
          ..state = BikeState.drive
          ..parking = false
          ..odo = 7000.0
          ..speed = 25.0,
        now: t0,
      );
      var liveTrip = ctrl.ingestTripTelemetryForTesting(
        BikeLogMsg()
          ..state = BikeState.drive
          ..parking = false
          ..odo = 7000.6
          ..speed = 22.0,
        now: t0.add(const Duration(seconds: 70)),
      );
      expect(liveTrip.distanceKm, closeTo(0.6, 0.01));

      // Đứng im speed = 0.0 tại đèn đỏ suốt 180 giây (3 phút), vẫn giữ mode Drive (!parking)
      for (var s = 90; s <= 250; s += 20) {
        liveTrip = ctrl.ingestTripTelemetryForTesting(
          BikeLogMsg()
            ..state = BikeState.drive
            ..parking = false
            ..odo = 7000.6
            ..speed = 0.0,
          now: t0.add(Duration(seconds: s)),
        );
      }
      expect(TripGpsTracker.instance.hasStartedActiveRide, isTrue);
      expect(liveTrip.distanceKm, closeTo(0.6, 0.01));
      expect(liveTrip.duration.inSeconds, 250);
      expect(container.read(bleProvider).tripHistory, isEmpty);

      // Đèn xanh chạy tiếp tới +2.1 km -> toàn bộ hành trình 2.1 km được nối liền
      liveTrip = ctrl.ingestTripTelemetryForTesting(
        BikeLogMsg()
          ..state = BikeState.drive
          ..parking = false
          ..odo = 7002.1
          ..speed = 34.0,
        now: t0.add(const Duration(seconds: 400)),
      );
      expect(liveTrip.distanceKm, closeTo(2.1, 0.01));
    });

    test('Rớt BLE khi đang dừng đèn đỏ (speed = 0, chưa về P mode) giữ grace 10 phút thay vì ngắt ở 20s', () {
      final redLightDrive = BikeLogMsg()
        ..state = BikeState.drive
        ..parking = false
        ..speed = 0.0;
      final parkedP = BikeLogMsg()
        ..state = BikeState.parking
        ..parking = true
        ..speed = 0.0;
      final bikeOff = BikeLogMsg()
        ..state = BikeState.off
        ..parking = true
        ..speed = 0.0;

      expect(
        TripRecordingPolicy.selectReconnectGrace(redLightDrive),
        TripRecordingPolicy.kBleReconnectGraceRideMode,
      );
      expect(
        TripRecordingPolicy.selectReconnectGrace(parkedP),
        TripRecordingPolicy.kBleReconnectGraceParked,
      );
      expect(TripRecordingPolicy.selectReconnectGrace(bikeOff), isNull);

      final container = ProviderContainer(
        overrides: [bleProvider.overrideWith(() => _TestBleController())],
      );
      addTearDown(container.dispose);

      final ctrl = container.read(bleProvider.notifier);
      final t0 = DateTime(2026, 11, 18, 17, 15, 0);

      ctrl.ingestTripTelemetryForTesting(
        BikeLogMsg()
          ..state = BikeState.super_
          ..parking = false
          ..odo = 8000.0
          ..speed = 30.0,
        now: t0,
      );
      ctrl.ingestTripTelemetryForTesting(
        BikeLogMsg()
          ..state = BikeState.super_
          ..parking = false
          ..odo = 8000.8
          ..speed = 0.0, // dừng đèn đỏ trước khi rớt BLE
        now: t0.add(const Duration(seconds: 90)),
      );

      ctrl.simulateConnectionLostForTesting(
        manual: false,
        now: t0.add(const Duration(seconds: 95)),
      );
      expect(ctrl.hasPendingDisconnectArchiveForTesting, isTrue);
      // Cửa sổ chờ là 10 phút (KHÔNG phải 20s), trip vẫn giữ nguyên 0.8 km
      expect(
        ctrl.pendingDisconnectGraceForTesting,
        TripRecordingPolicy.kBleReconnectGraceRideMode,
      );
      expect(container.read(bleProvider).trip.distanceKm, closeTo(0.8, 0.01));

      // Sau 150s đèn đỏ + reconnect lại khi đèn xanh -> nối tiếp mượt lên 2.5 km
      final resumed = ctrl.ingestTripTelemetryForTesting(
        BikeLogMsg()
          ..state = BikeState.super_
          ..parking = false
          ..odo = 8002.5
          ..speed = 32.0,
        now: t0.add(const Duration(seconds: 245)),
      );
      expect(ctrl.hasPendingDisconnectArchiveForTesting, isFalse);
      expect(resumed.distanceKm, closeTo(2.5, 0.01));
    });
  });
}
