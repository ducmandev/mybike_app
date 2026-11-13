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
  Future<void> _opLock = Future.value();

  Future<T> _synchronized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _opLock = _opLock.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// Kiểm tra 2 bản ghi chuyến đi có phải là bản trùng lặp của cùng 1 chuyến hay không
  static bool isDuplicateTrip(TripRecord a, TripRecord b) {
    if (a.id == b.id) return true;

    final sameDistance = (a.distanceKm - b.distanceKm).abs() <= 0.05;
    if (!sameDistance) return false;

    final sameStartTime = a.startTime.difference(b.startTime).inSeconds.abs() <= 5;
    if (sameStartTime) return true;

    final sameEndTime = a.endTime.difference(b.endTime).inSeconds.abs() <= 5;
    final sameDuration = (a.durationSec - b.durationSec).abs() <= 15;
    final sameStartOdo = a.startOdo != null &&
        b.startOdo != null &&
        (a.startOdo! - b.startOdo!).abs() <= 0.05;
    final sameEndOdo = a.endOdo != null &&
        b.endOdo != null &&
        (a.endOdo! - b.endOdo!).abs() <= 0.05;

    if (sameEndTime && (sameDuration || sameStartOdo || sameEndOdo)) {
      return true;
    }

    return false;
  }

  /// Khử trùng lặp danh sách chuyến đi, ưu tiên giữ bản ghi đầy đủ hơn (durationSec lớn hơn hoặc nằm trước)
  static List<TripRecord> _deduplicateTrips(List<TripRecord> trips) {
    final result = <TripRecord>[];
    for (final candidate in trips) {
      final dupIndex = result.indexWhere((existing) => isDuplicateTrip(existing, candidate));
      if (dupIndex == -1) {
        result.add(candidate);
      } else if (candidate.durationSec > result[dupIndex].durationSec) {
        result[dupIndex] = candidate;
      }
    }
    return result;
  }

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

  /// Tải toàn bộ danh sách tóm tắt (Metadata) của các chuyến đi (không khóa)
  Future<List<TripRecord>> _loadAllTripsUnsafe() async {
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

  /// Tải toàn bộ danh sách tóm tắt (Metadata) của các chuyến đi
  Future<List<TripRecord>> loadAllTrips() {
    return _synchronized(() async {
      final loaded = await _loadAllTripsUnsafe();
      final deduped = _deduplicateTrips(loaded);
      if (deduped.length < loaded.length) {
        try {
          final prefs = await SharedPreferences.getInstance();
          final metaStr = jsonEncode(deduped.map((e) => e.toMetadataJson()).toList());
          await prefs.setString(_kTripMetadataKey, metaStr);
        } catch (e) {
          debugPrint('[TripStorageService] Lỗi dọn dẹp chuyến đi trùng lặp: $e');
        }
      }
      return deduped;
    });
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
  }) {
    return _synchronized(() async {
      try {
        final dir = await getTripsDirectory();

        // 1. Lưu file tọa độ GPS chi tiết (Atomic write)
        if (route.isNotEmpty) {
          final tmpFile = File('${dir.path}/${trip.id}.json.tmp');
          final targetFile = File('${dir.path}/${trip.id}.json');
          final routeJson = jsonEncode(route.map((p) => p.toJson()).toList());
          await tmpFile.writeAsString(routeJson, flush: true);
          if (await targetFile.exists()) {
            await targetFile.delete();
          }
          await tmpFile.rename(targetFile.path);
        }

        // 2. Cập nhật Metadata danh bạ (Tầng 1) & khử trùng lặp
        final existing = await _loadAllTripsUnsafe();
        final filteredExisting = <TripRecord>[];
        for (final t in existing) {
          if (isDuplicateTrip(t, trip)) {
            if (t.id != trip.id) {
              try {
                final oldFile = File('${dir.path}/${t.id}.json');
                if (await oldFile.exists()) {
                  await oldFile.delete();
                }
              } catch (e) {
                debugPrint('[TripStorageService] Lỗi xóa file lộ trình trùng ${t.id}: $e');
              }
            }
          } else {
            filteredExisting.add(t);
          }
        }

        final metaRecord = trip.copyWith(route: const []);
        final updated = [metaRecord, ...filteredExisting].take(_kMaxTrips).toList();

        final prefs = await SharedPreferences.getInstance();
        final metaStr = jsonEncode(updated.map((e) => e.toMetadataJson()).toList());
        await prefs.setString(_kTripMetadataKey, metaStr);
        await prefs.remove(_kLegacyTripKey);
      } catch (e) {
        debugPrint('[TripStorageService] Lỗi lưu chuyến đi: $e');
      }
    });
  }

  /// Xóa 1 chuyến đi: xóa file tọa độ và xóa khỏi metadata
  Future<void> deleteTrip(TripRecord trip) {
    return _synchronized(() async {
      try {
        final existing = await _loadAllTripsUnsafe();
        final idsToDelete = <String>{
          trip.id,
          ...existing.where((t) => isDuplicateTrip(t, trip)).map((t) => t.id),
        };

        // 1. Xóa file tọa độ
        final dir = await getTripsDirectory();
        for (final id in idsToDelete) {
          final file = File('${dir.path}/$id.json');
          if (await file.exists()) {
            await file.delete();
          }
        }

        // 2. Cập nhật metadata
        final updated = existing.where((t) => !isDuplicateTrip(t, trip)).toList();

        final prefs = await SharedPreferences.getInstance();
        final metaStr = jsonEncode(updated.map((e) => e.toMetadataJson()).toList());
        await prefs.setString(_kTripMetadataKey, metaStr);
        await prefs.remove(_kLegacyTripKey);
      } catch (e) {
        debugPrint('[TripStorageService] Lỗi xóa chuyến đi: $e');
      }
    });
  }

  /// Xóa toàn bộ lịch sử chuyến đi
  Future<void> clearAll() {
    return _synchronized(() async {
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
    });
  }
}
