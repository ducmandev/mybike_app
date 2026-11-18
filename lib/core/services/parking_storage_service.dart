import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import '../models/parked_location.dart';
import 'json_prefs_store.dart';
import 'trip_gps_tracker.dart';

/// Dịch vụ quản lý ghi nhớ và truy xuất vị trí đỗ xe thông minh (Smart Parking Service)
class ParkingStorageService extends JsonPrefsStore<ParkedLocation> {
  ParkingStorageService._();
  static final ParkingStorageService instance = ParkingStorageService._();

  static const String _kParkingPrefix = 'smart_parking_bike_';
  static const String _kDefaultParkingKey = 'smart_parking_last_default_v1';

  static String _sanitizedBikeKey(String bikeId) =>
      '$_kParkingPrefix${JsonPrefsStore.sanitizeKeyPart(bikeId)}';

  static String _legacyBikeKey(String bikeId) => '$_kParkingPrefix$bikeId';

  /// Tải vị trí đỗ xe gần nhất
  Future<ParkedLocation?> loadParkedLocation({String? bikeId}) async {
    try {
      if (bikeId != null && bikeId.isNotEmpty) {
        return await readObject(
          _sanitizedBikeKey(bikeId),
          ParkedLocation.fromJson,
          fallbackKeys: [_legacyBikeKey(bikeId), _kDefaultParkingKey],
        );
      }
      return await readObject(_kDefaultParkingKey, ParkedLocation.fromJson);
    } catch (e) {
      debugPrint('[ParkingStorageService] Lỗi khi load vị trí đỗ: $e');
    }
    return null;
  }

  /// Lưu vị trí đỗ xe
  Future<void> saveParkedLocation(ParkedLocation location) async {
    try {
      if (location.bikeId.isNotEmpty) {
        await writeObject(
          _sanitizedBikeKey(location.bikeId),
          location,
          (loc) => loc.toJson(),
        );
      }
      await writeObject(
        _kDefaultParkingKey,
        location,
        (loc) => loc.toJson(),
      );
      debugPrint('[ParkingStorageService] Đã lưu vị trí đỗ: ${location.latitude}, ${location.longitude} lúc ${location.timestamp}');
    } catch (e) {
      debugPrint('[ParkingStorageService] Lỗi khi lưu vị trí đỗ: $e');
    }
  }

  /// Tự động ghi nhận vị trí đỗ khi ngắt kết nối BLE hoặc khóa xe
  Future<ParkedLocation?> recordParkedLocationOnDisconnect({
    required String bikeId,
    required String bikeName,
    int? batteryPercent,
    double? voltage,
    bool isLocked = true,
  }) async {
    try {
      // 1. Thử lấy vị trí từ TripGpsTracker (đã lọc Kalman)
      double? lat;
      double? lng;
      double? accuracy;

      final lastTripPt = TripGpsTracker.instance.currentPoint;
      if (lastTripPt != null) {
        lat = lastTripPt.lat;
        lng = lastTripPt.lng;
        accuracy = 5.0;
      } else {
        final lastPos = TripGpsTracker.instance.lastPosition;
        if (lastPos != null) {
          lat = lastPos.latitude;
          lng = lastPos.longitude;
          accuracy = lastPos.accuracy;
        }
      }

      // 2. Nếu chưa có, gọi nhanh vị trí gần nhất từ hệ thống
      if (lat == null || lng == null) {
        try {
          final pos = await Geolocator.getLastKnownPosition() ??
              await Geolocator.getCurrentPosition(
                locationSettings: const LocationSettings(
                  accuracy: LocationAccuracy.medium,
                  timeLimit: Duration(seconds: 4),
                ),
              );
          lat = pos.latitude;
          lng = pos.longitude;
          accuracy = pos.accuracy;
        } catch (_) {}
      }

      if (lat != null && lng != null) {
        // Lấy ghi chú cũ nếu có để không bị ghi đè mất note
        final old = await loadParkedLocation(bikeId: bikeId);

        final parked = ParkedLocation(
          latitude: lat,
          longitude: lng,
          accuracy: accuracy,
          timestamp: DateTime.now(),
          bikeId: bikeId,
          bikeName: bikeName,
          batteryPercent: batteryPercent,
          voltage: voltage,
          address: old?.address ?? 'Vị trí đỗ xe gần nhất',
          note: old?.note,
          photoPath: old?.photoPath,
          isLocked: isLocked,
        );

        await saveParkedLocation(parked);
        return parked;
      }
    } catch (e) {
      debugPrint('[ParkingStorageService] Lỗi khi ghi nhận tọa độ tự động: $e');
    }
    return null;
  }

  /// Cập nhật ghi chú vị trí đỗ xe (ví dụ: "Cột K12 - Hầm B2 Vincom")
  Future<void> updateNote({String? bikeId, required String note}) async {
    try {
      final old = await loadParkedLocation(bikeId: bikeId);
      if (old != null) {
        final updated = old.copyWith(note: note);
        await saveParkedLocation(updated);
      }
    } catch (e) {
      debugPrint('[ParkingStorageService] Lỗi khi cập nhật ghi chú: $e');
    }
  }

  /// Cập nhật ảnh chụp cột hầm đỗ xe
  Future<void> updatePhoto({String? bikeId, required String photoPath}) async {
    try {
      final old = await loadParkedLocation(bikeId: bikeId);
      if (old != null) {
        final updated = old.copyWith(photoPath: photoPath);
        await saveParkedLocation(updated);
      }
    } catch (e) {
      debugPrint('[ParkingStorageService] Lỗi khi cập nhật ảnh: $e');
    }
  }

  /// Xóa vị trí đỗ khi người dùng đã lấy xe khởi hành hoặc xóa xe khỏi nhà xe
  Future<void> clearParkedLocation({String? bikeId}) async {
    try {
      if (bikeId != null && bikeId.isNotEmpty) {
        await removeKeys([
          _sanitizedBikeKey(bikeId),
          _legacyBikeKey(bikeId),
          _kDefaultParkingKey,
        ]);
      } else {
        final store = await prefs;
        final bikeKeys = store.getKeys().where(
          (k) => k.startsWith(_kParkingPrefix),
        );
        await removeKeys([...bikeKeys, _kDefaultParkingKey]);
      }
    } catch (_) {}
  }
}
