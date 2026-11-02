import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ble/ble_controller.dart' show TripRecord, TripGpsPoint;

/// Dịch vụ quản lý lưu trữ hành trình chuẩn 2 tầng (Two-Tier Storage):
/// - Tầng 1: Metadata tóm tắt (id, thời gian, km, vận tốc, pin) lưu trong SharedPreferences (siêu nhẹ < 30KB).
/// - Tầng 2: File tọa độ GPS chi tiết (.json) lưu riêng từng file theo trip_id trong thư mục documents.
/// Cơ chế này ngăn chặn tuyệt đối lỗi tràn bộ nhớ, đơ UI thread, và chống corrupt dữ liệu khi ngắt app đột ngột.
class TripStorageService {
  TripStorageService._();
  static final TripStorageService instance = TripStorageService._();

  static const String _kTripMetadataKey = 'trip_history_metadata_v2';
  static const String _kLegacyTripKey = 'trip_history_v1';
  static const int _kMaxTrips = 50;

  Directory? _tripsDir;
  Completer<Directory>? _initCompleter;

  /// Lấy thư mục lưu trữ các tệp tọa độ GPS chuyến đi
  Future<Directory> getTripsDirectory() async {
    if (_tripsDir != null) return _tripsDir!;
    if (_initCompleter != null) return _initCompleter!.future;
    _initCompleter = Completer<Directory>();
    try {
      final base = await getApplicationDocumentsDirectory();
      final dir = Directory('${base.path}/trips');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      _tripsDir = dir;
      _initCompleter!.complete(dir);
      return dir;
    } catch (e) {
      _initCompleter!.completeError(e);
      _initCompleter = null;
      rethrow;
    }
  }

  /// Tải toàn bộ danh sách tóm tắt (Metadata) của các chuyến đi
  Future<List<TripRecord>> loadAllTrips() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // 1. Kiểm tra lưu trữ Metadata v2 (Tầng 1)
      final metaJson = prefs.getString(_kTripMetadataKey);
      if (metaJson != null && metaJson.isNotEmpty) {
        final decoded = jsonDecode(metaJson) as List<dynamic>;
        return decoded
            .map((e) => TripRecord.fromJson(e as Map<String, dynamic>))
            .where((e) => e.distanceKm >= 0.1 || e.durationSec >= 30)
            .toList();
      }

      // 2. Tự động di chuyển từ lưu trữ legacy v1 nếu có
      final legacyJson = prefs.getString(_kLegacyTripKey);
      if (legacyJson != null && legacyJson.isNotEmpty) {
        final decoded = jsonDecode(legacyJson) as List<dynamic>;
        final legacyTrips = decoded
            .map((e) => TripRecord.fromJson(e as Map<String, dynamic>))
            .where((e) => e.distanceKm >= 0.1 || e.route.isNotEmpty)
            .toList();

        // Tách file lộ trình chi tiết cho từng chuyến legacy sang Tầng 2
        final dir = await getTripsDirectory();
        final metadataList = <TripRecord>[];

        for (final trip in legacyTrips) {
          if (trip.route.isNotEmpty) {
            try {
              final file = File('${dir.path}/${trip.id}.json');
              final routeJson = jsonEncode(trip.route.map((p) => p.toJson()).toList());
              await file.writeAsString(routeJson);
            } catch (e) {
              debugPrint('[TripStorageService] Lỗi di trú chuyến ${trip.id}: $e');
            }
          }
          metadataList.add(trip.copyWith(route: const []));
        }

        // Lưu Metadata v2
        final newMetaStr = jsonEncode(metadataList.map((e) => e.toMetadataJson()).toList());
        await prefs.setString(_kTripMetadataKey, newMetaStr);
        return metadataList;
      }
    } catch (e) {
      debugPrint('[TripStorageService] Lỗi nạp lịch sử chuyến đi: $e');
    }
    return [];
  }

  /// Tải lười (Lazy load) tọa độ GPS chi tiết của 1 chuyến đi cụ thể
  Future<List<TripGpsPoint>> loadTripRoute(TripRecord trip) async {
    if (trip.route.isNotEmpty) return trip.route;
    try {
      final dir = await getTripsDirectory();
      final file = File('${dir.path}/${trip.id}.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.isNotEmpty) {
          final decoded = jsonDecode(content) as List<dynamic>;
          return decoded
              .map((e) => TripGpsPoint.fromJson(e as Map<String, dynamic>))
              .toList();
        }
      }
    } catch (e) {
      debugPrint('[TripStorageService] Lỗi nạp lộ trình chuyến ${trip.id}: $e');
    }
    return [];
  }

  /// Lưu một chuyến đi mới: Tách riêng file tọa độ GPS và lưu tóm tắt vào metadata
  Future<void> saveTrip({
    required TripRecord trip,
    required List<TripGpsPoint> route,
  }) async {
    try {
      // 1. Lưu file tọa độ GPS chi tiết (Atomic write)
      if (route.isNotEmpty) {
        final dir = await getTripsDirectory();
        final tmpFile = File('${dir.path}/${trip.id}.json.tmp');
        final targetFile = File('${dir.path}/${trip.id}.json');
        final routeJson = jsonEncode(route.map((p) => p.toJson()).toList());
        await tmpFile.writeAsString(routeJson, flush: true);
        if (await targetFile.exists()) {
          await targetFile.delete();
        }
        await tmpFile.rename(targetFile.path);
      }

      // 2. Cập nhật Metadata danh bạ (Tầng 1)
      final existing = await loadAllTrips();
      final metaRecord = trip.copyWith(route: const []);
      final updated = [metaRecord, ...existing.where((t) => t.id != trip.id)].take(_kMaxTrips).toList();

      final prefs = await SharedPreferences.getInstance();
      final metaStr = jsonEncode(updated.map((e) => e.toMetadataJson()).toList());
      await prefs.setString(_kTripMetadataKey, metaStr);
      await prefs.remove(_kLegacyTripKey);
    } catch (e) {
      debugPrint('[TripStorageService] Lỗi lưu chuyến đi: $e');
    }
  }

  /// Xóa 1 chuyến đi: xóa file tọa độ và xóa khỏi metadata
  Future<void> deleteTrip(TripRecord trip) async {
    try {
      // 1. Xóa file tọa độ
      final dir = await getTripsDirectory();
      final file = File('${dir.path}/${trip.id}.json');
      if (await file.exists()) {
        await file.delete();
      }

      // 2. Cập nhật metadata
      final existing = await loadAllTrips();
      final updated = existing.where((t) =>
        t.id != trip.id &&
        !(t.startTime.millisecondsSinceEpoch == trip.startTime.millisecondsSinceEpoch &&
          (t.distanceKm - trip.distanceKm).abs() < 0.001)
      ).toList();

      final prefs = await SharedPreferences.getInstance();
      final metaStr = jsonEncode(updated.map((e) => e.toMetadataJson()).toList());
      await prefs.setString(_kTripMetadataKey, metaStr);
      await prefs.remove(_kLegacyTripKey);
    } catch (e) {
      debugPrint('[TripStorageService] Lỗi xóa chuyến đi: $e');
    }
  }

  /// Xóa toàn bộ lịch sử chuyến đi
  Future<void> clearAll() async {
    try {
      final dir = await getTripsDirectory();
      if (await dir.exists()) {
        final files = dir.listSync();
        for (final f in files) {
          if (f is File) {
            try {
              f.deleteSync();
            } catch (_) {}
          }
        }
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kTripMetadataKey);
      await prefs.remove(_kLegacyTripKey);
    } catch (e) {
      debugPrint('[TripStorageService] Lỗi xóa toàn bộ lịch sử: $e');
    }
  }
}
