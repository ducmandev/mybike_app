import 'package:flutter_test/flutter_test.dart';
import 'package:mybike_app/core/models/trip_gps_point.dart';
import 'package:mybike_app/core/ble/ble_controller.dart' show TripRecord;
import 'package:mybike_app/core/services/trip_gps_tracker.dart';

void main() {
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

    test('Trips below 1km are rejected from storage', () {
      final trips = [
        TripRecord(
          startTime: DateTime(2026, 10, 27, 8, 0, 0),
          endTime: DateTime(2026, 10, 27, 8, 5, 0),
          distanceKm: 0.45, // < 1km
          durationSec: 300,
          avgSpeedKmh: 15.0,
          maxSpeedKmh: 25.0,
          usedPercent: 1,
        ),
        TripRecord(
          startTime: DateTime(2026, 10, 27, 9, 0, 0),
          endTime: DateTime(2026, 10, 27, 9, 20, 0),
          distanceKm: 3.8, // >= 1km
          durationSec: 1200,
          avgSpeedKmh: 30.0,
          maxSpeedKmh: 48.0,
          usedPercent: 4,
        ),
      ];

      final filtered = trips.where((t) => t.distanceKm >= 1.0).toList();
      expect(filtered.length, 1);
      expect(filtered.first.distanceKm, 3.8);
    });
  });
}
