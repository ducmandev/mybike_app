import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mybike_app/core/models/trip_gps_point.dart';
import 'package:mybike_app/core/ble/ble_controller.dart' show TripRecord;
import 'package:mybike_app/core/services/trip_gps_tracker.dart';
import 'package:mybike_app/core/services/trip_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Trip GPS & Route Replay Tests', () {
    test('TripGpsPoint serializes and deserializes properly', () {
      final point = TripGpsPoint(
        lat: 10.771912,
        lng: 106.719543,
        speedKmh: 42.5,
        timestamp: DateTime(2026, 10, 27, 8, 30, 0),
        altitude: 12.4,
        heading: 90.0,
      );

      final json = point.toJson();
      expect(json['lat'], 10.771912);
      expect(json['lng'], 106.719543);
      expect(json['speedKmh'], 42.5);
      expect(json['altitude'], 12.4);
      expect(json['heading'], 90.0);

      final restored = TripGpsPoint.fromJson(json);
      expect(restored.lat, point.lat);
      expect(restored.lng, point.lng);
      expect(restored.speedKmh, point.speedKmh);
      expect(restored.altitude, point.altitude);
      expect(restored.heading, point.heading);
    });

    test('TripRecord preserves GPS route through JSON persistence', () {
      final p1 = TripGpsPoint(
        lat: 10.770,
        lng: 106.710,
        speedKmh: 0.0,
        timestamp: DateTime(2026, 10, 27, 8, 0, 0),
      );
      final p2 = TripGpsPoint(
        lat: 10.775,
        lng: 106.715,
        speedKmh: 35.0,
        timestamp: DateTime(2026, 10, 27, 8, 1, 0),
      );

      final trip = TripRecord(
        startTime: DateTime(2026, 10, 27, 8, 0, 0),
        endTime: DateTime(2026, 10, 27, 8, 15, 0),
        distanceKm: 5.2,
        durationSec: 900,
        avgSpeedKmh: 28.0,
        maxSpeedKmh: 52.0,
        usedPercent: 4,
        route: [p1, p2],
      );

      final json = trip.toJson();
      expect(json['route'], isA<List>());
      expect((json['route'] as List).length, 2);

      final restored = TripRecord.fromJson(json);
      expect(restored.distanceKm, 5.2);
      expect(restored.route.length, 2);
      expect(restored.route.first.speedKmh, 0.0);
      expect(restored.route.last.speedKmh, 35.0);
    });

    test('TripRecord backward compatibility with trips without GPS', () {
      final legacyJson = {
        'startTime': '2026-10-27T08:00:00.000',
        'endTime': '2026-10-27T08:30:00.000',
        'distanceKm': 8.5,
        'durationSec': 1800,
        'avgSpeedKmh': 32.0,
        'maxSpeedKmh': 55.0,
        'usedPercent': 6,
      };

      final trip = TripRecord.fromJson(legacyJson);
      expect(trip.distanceKm, 8.5);
      expect(trip.route, isEmpty);
    });

    test('TripGpsTracker rejects fake sample routes and returns empty', () {
      final sampleRoute = TripGpsTracker.generateSampleRoute(
        distanceKm: 6.8,
        avgSpeedKmh: 30.0,
        maxSpeedKmh: 50.0,
        startTime: DateTime(2026, 10, 27, 8, 0, 0),
        durationSec: 600,
      );

      // Đã tắt hoàn toàn tính năng tạo tọa độ giả, chỉ dùng GPS thật
      expect(sampleRoute, isEmpty);
    });

    test('TripGpsTracker.cleanAndSmoothRoute eliminates teleportation spikes and smooths path', () {
      final t0 = DateTime(2026, 10, 27, 8, 0, 0);
      final rawPoints = [
        TripGpsPoint(lat: 10.7719, lng: 106.7195, speedKmh: 30.0, timestamp: t0),
        // Điểm nhảy teleportation phi lý (nhảy 500m trong 1 giây ~ 1800 km/h)
        TripGpsPoint(lat: 10.7760, lng: 106.7240, speedKmh: 30.0, timestamp: t0.add(const Duration(seconds: 1))),
        // Điểm hợp lý tiếp theo
        TripGpsPoint(lat: 10.7720, lng: 106.7196, speedKmh: 32.0, timestamp: t0.add(const Duration(seconds: 2))),
        TripGpsPoint(lat: 10.7721, lng: 106.7197, speedKmh: 33.0, timestamp: t0.add(const Duration(seconds: 3))),
      ];

      final cleaned = TripGpsTracker.cleanAndSmoothRoute(rawPoints);
      expect(cleaned.length, 3);
      // Điểm nhảy 10.7760 bị loại bỏ
      expect(cleaned.any((p) => p.lat > 10.775), isFalse);
    });

    test('TripGpsTracker calculateBearing correctly calculates direction', () {
      // Đi thẳng về hướng Bắc
      final northBearing = TripGpsTracker.calculateBearing(10.770, 106.710, 10.780, 106.710);
      expect(northBearing, closeTo(0.0, 1.0));

      // Đi thẳng về hướng Đông
      final eastBearing = TripGpsTracker.calculateBearing(10.770, 106.710, 10.770, 106.720);
      expect(eastBearing, closeTo(90.0, 1.0));
    });

    test('GpsKalmanFilter2D smooths coordinates without sharp oscillation', () {
      final kalman = GpsKalmanFilter2D();
      final t = DateTime.now();

      kalman.filter(
        measuredLat: 10.771900,
        measuredLng: 106.719500,
        accuracyMeters: 5.0,
        speedMps: 10.0,
        timestamp: t,
      );

      expect(kalman.lat, 10.771900);
      expect(kalman.lng, 106.719500);

      // Nhiễu đột ngột lệch sang một bên
      kalman.filter(
        measuredLat: 10.771980,
        measuredLng: 106.719580,
        accuracyMeters: 20.0, // Sai số đo lớn
        speedMps: 10.0,
        timestamp: t.add(const Duration(seconds: 1)),
      );

      // Bộ lọc Kalman giữ vị trí không bị giật hoàn toàn sang 10.771980
      expect(kalman.lat!, lessThan(10.771980));
      expect(kalman.lat!, greaterThan(10.771900));
    });

    test('Trips below 2km are rejected from storage', () {
      expect(TripStorageService.kMinTripDistanceKm, 2.0);

      final trips = [
        TripRecord(
          startTime: DateTime(2026, 10, 27, 8, 0, 0),
          endTime: DateTime(2026, 10, 27, 8, 5, 0),
          distanceKm: 0.45, // < 2km
          durationSec: 300,
          avgSpeedKmh: 15.0,
          maxSpeedKmh: 25.0,
          usedPercent: 1,
        ),
        TripRecord(
          startTime: DateTime(2026, 10, 27, 8, 30, 0),
          endTime: DateTime(2026, 10, 27, 8, 36, 0),
          distanceKm: 1.99, // < 2km
          durationSec: 360,
          avgSpeedKmh: 20.0,
          maxSpeedKmh: 30.0,
          usedPercent: 2,
        ),
        TripRecord(
          startTime: DateTime(2026, 10, 27, 9, 0, 0),
          endTime: DateTime(2026, 10, 27, 9, 20, 0),
          distanceKm: 3.8, // >= 2km
          durationSec: 1200,
          avgSpeedKmh: 30.0,
          maxSpeedKmh: 48.0,
          usedPercent: 4,
        ),
      ];

      final filtered = trips
          .where((t) => t.distanceKm >= TripStorageService.kMinTripDistanceKm)
          .toList();
      expect(filtered.length, 1);
      expect(filtered.first.distanceKm, 3.8);
    });

    test('TripStorageService.saveTrip skips trips below 2km (0.0, 0.85, 1.99)', () async {
      SharedPreferences.setMockInitialValues({});
      final t0 = DateTime(2026, 10, 27, 8, 0, 0);
      final nonEmptyRoute = [
        TripGpsPoint(lat: 10.770, lng: 106.710, speedKmh: 20.0, timestamp: t0),
        TripGpsPoint(
          lat: 10.775,
          lng: 106.715,
          speedKmh: 25.0,
          timestamp: t0.add(const Duration(seconds: 60)),
        ),
      ];

      final zeroTrip = TripRecord(
        id: 'trip_zero',
        startTime: t0,
        endTime: t0.add(const Duration(seconds: 300)),
        distanceKm: 0.0,
        durationSec: 300,
        avgSpeedKmh: 0.0,
        maxSpeedKmh: 0.0,
        usedPercent: 0,
        route: nonEmptyRoute,
      );
      final shortTrip850m = TripRecord(
        id: 'trip_085',
        startTime: t0.add(const Duration(hours: 1)),
        endTime: t0.add(const Duration(hours: 1, minutes: 5)),
        distanceKm: 0.85,
        durationSec: 300,
        avgSpeedKmh: 18.0,
        maxSpeedKmh: 28.0,
        usedPercent: 1,
      );
      final shortTrip1990m = TripRecord(
        id: 'trip_199',
        startTime: t0.add(const Duration(hours: 2)),
        endTime: t0.add(const Duration(hours: 2, minutes: 8)),
        distanceKm: 1.99,
        durationSec: 480,
        avgSpeedKmh: 22.0,
        maxSpeedKmh: 35.0,
        usedPercent: 2,
      );

      await TripStorageService.instance.saveTrip(trip: zeroTrip, route: nonEmptyRoute);
      await TripStorageService.instance.saveTrip(trip: shortTrip850m, route: const []);
      await TripStorageService.instance.saveTrip(trip: shortTrip1990m, route: nonEmptyRoute);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('trip_history_metadata_v2'), isNull);
      expect(await TripStorageService.instance.loadAllTrips(), isEmpty);
    });

    test('TripStorageService.loadAllTrips filters and purges pre-existing trips below 2km', () async {
      final t0 = DateTime(2026, 10, 27, 8, 0, 0);
      final storedRecords = [
        TripRecord(
          id: 'short_0',
          startTime: t0,
          endTime: t0.add(const Duration(minutes: 5)),
          distanceKm: 0.0,
          durationSec: 300,
          avgSpeedKmh: 0.0,
          maxSpeedKmh: 0.0,
          usedPercent: 0,
        ),
        TripRecord(
          id: 'short_199',
          startTime: t0.add(const Duration(hours: 1)),
          endTime: t0.add(const Duration(hours: 1, minutes: 10)),
          distanceKm: 1.99,
          durationSec: 600,
          avgSpeedKmh: 20.0,
          maxSpeedKmh: 30.0,
          usedPercent: 2,
        ),
        TripRecord(
          id: 'valid_20',
          startTime: t0.add(const Duration(hours: 2)),
          endTime: t0.add(const Duration(hours: 2, minutes: 12)),
          distanceKm: 2.0,
          durationSec: 720,
          avgSpeedKmh: 25.0,
          maxSpeedKmh: 40.0,
          usedPercent: 2,
        ),
        TripRecord(
          id: 'valid_38',
          startTime: t0.add(const Duration(hours: 3)),
          endTime: t0.add(const Duration(hours: 3, minutes: 20)),
          distanceKm: 3.8,
          durationSec: 1200,
          avgSpeedKmh: 30.0,
          maxSpeedKmh: 48.0,
          usedPercent: 4,
        ),
      ];

      SharedPreferences.setMockInitialValues({
        'trip_history_metadata_v2': jsonEncode(
          storedRecords.map((e) => e.toMetadataJson()).toList(),
        ),
      });

      final loaded = await TripStorageService.instance.loadAllTrips();
      expect(loaded.map((t) => t.id).toList(), ['valid_20', 'valid_38']);
      expect(loaded.map((t) => t.distanceKm).toList(), [2.0, 3.8]);

      final prefs = await SharedPreferences.getInstance();
      final purgedJson = prefs.getString('trip_history_metadata_v2');
      expect(purgedJson, isNotNull);
      final purgedList = (jsonDecode(purgedJson!) as List<dynamic>)
          .map((e) => TripRecord.fromJson(e as Map<String, dynamic>))
          .toList();
      expect(purgedList.map((t) => t.id).toList(), ['valid_20', 'valid_38']);
    });
  });
}
