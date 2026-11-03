import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/saved_bike.dart';

/// Dịch vụ quản lý lưu trữ danh sách xe (Garage) và mật khẩu từng xe.
class VehicleStorageService {
  VehicleStorageService._();
  static final VehicleStorageService instance = VehicleStorageService._();

  static const String _kSavedBikesKey = 'saved_bikes_garage_v1';
  static const String _kLegacyLastBikeId = 'last_bike_id';
  static const String _kLegacyLastBikeName = 'last_bike_name';
  static const String _kLegacyPassword = 'bike_password';
  static const String _kPerBikePasswordPrefix = 'bike_pwd_';

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  /// Tải danh sách tất cả các xe trong nhà xe (Garage)
  Future<List<SavedBike>> loadSavedBikes() async {
    try {
      final prefs = await _prefs;
      final raw = prefs.getString(_kSavedBikesKey);
      if (raw != null && raw.trim().isNotEmpty) {
        final decoded = jsonDecode(raw) as List<dynamic>;
        final bikes = decoded
            .map((e) => SavedBike.fromJson(e as Map<String, dynamic>))
            .where((b) => b.id.trim().isNotEmpty)
            .toList();
        if (bikes.isNotEmpty) {
          return bikes;
        }
      }

      // Tự động chuyển đổi từ dữ liệu cũ nếu chưa có danh sách
      final legacyId = prefs.getString(_kLegacyLastBikeId);
      if (legacyId != null && legacyId.trim().isNotEmpty) {
        final legacyName = prefs.getString(_kLegacyLastBikeName) ?? 'Xe Dat Bike';
        final legacyPw = prefs.getString(_kLegacyPassword);
        final initialBike = SavedBike(
          id: legacyId.trim(),
          name: legacyName.trim(),
          originalAdvName: legacyName.trim(),
          password: legacyPw,
          isDefault: true,
          lastConnectedAt: DateTime.now(),
        );
        final list = [initialBike];
        await saveBikes(list);
        if (legacyPw != null && legacyPw.isNotEmpty) {
          await setBikePassword(legacyId.trim(), legacyPw);
        }
        return list;
      }
    } catch (_) {}
    return <SavedBike>[];
  }

  /// Lưu toàn bộ danh sách xe
  Future<void> saveBikes(List<SavedBike> bikes) async {
    try {
      final prefs = await _prefs;
      final jsonList = bikes.map((b) => b.toJson()).toList();
      await prefs.setString(_kSavedBikesKey, jsonEncode(jsonList));

      // Đồng bộ xe mặc định / đầu tiên sang legacy key để tương thích ngược
      final defaultBike = bikes.firstWhere((b) => b.isDefault, orElse: () => bikes.isNotEmpty ? bikes.first : const SavedBike(id: '', name: ''));
      if (defaultBike.id.isNotEmpty) {
        await prefs.setString(_kLegacyLastBikeId, defaultBike.id);
        await prefs.setString(_kLegacyLastBikeName, defaultBike.name);
      }
    } catch (_) {}
  }

  /// Thêm hoặc cập nhật một xe trong danh sách
  Future<List<SavedBike>> addOrUpdateBike(SavedBike bike) async {
    final list = await loadSavedBikes();
    final idx = list.indexWhere((b) => b.id.toLowerCase() == bike.id.toLowerCase());

    bool shouldBeDefault = bike.isDefault || list.isEmpty;
    List<SavedBike> updated;

    if (idx >= 0) {
      final existing = list[idx];
      final merged = existing.copyWith(
        name: bike.name.isNotEmpty ? bike.name : existing.name,
        originalAdvName: bike.originalAdvName ?? existing.originalAdvName,
        model: bike.model ?? existing.model,
        licensePlate: bike.licensePlate ?? existing.licensePlate,
        frameSerial: bike.frameSerial ?? existing.frameSerial,
        color: bike.color ?? existing.color,
        note: bike.note ?? existing.note,
        password: bike.password ?? existing.password,
        lastConnectedAt: bike.lastConnectedAt ?? existing.lastConnectedAt,
        lastOdo: bike.lastOdo ?? existing.lastOdo,
        lastBatteryPercent: bike.lastBatteryPercent ?? existing.lastBatteryPercent,
        isDefault: shouldBeDefault,
      );
      updated = List<SavedBike>.from(list);
      updated[idx] = merged;
    } else {
      updated = List<SavedBike>.from(list)..add(bike.copyWith(isDefault: shouldBeDefault));
    }

    if (shouldBeDefault) {
      updated = updated.map((b) {
        if (b.id.toLowerCase() == bike.id.toLowerCase()) {
          return b.copyWith(isDefault: true);
        } else {
          return b.copyWith(isDefault: false);
        }
      }).toList();
    }

    await saveBikes(updated);

    if (bike.password != null && bike.password!.isNotEmpty) {
      await setBikePassword(bike.id, bike.password!);
    }

    return updated;
  }

  /// Xóa một xe khỏi danh sách theo ID
  Future<List<SavedBike>> removeBike(String bikeId) async {
    final list = await loadSavedBikes();
    final updated = list.where((b) => b.id.toLowerCase() != bikeId.toLowerCase()).toList();

    // Nếu xe vừa xóa là mặc định và vẫn còn xe khác, đặt xe đầu tiên làm mặc định
    if (updated.isNotEmpty && !updated.any((b) => b.isDefault)) {
      updated[0] = updated[0].copyWith(isDefault: true);
    }

    await saveBikes(updated);
    await removeBikePassword(bikeId);
    return updated;
  }

  /// Đặt xe làm mặc định (ưu tiên tự kết nối khi mở app)
  Future<List<SavedBike>> setDefaultBike(String bikeId) async {
    final list = await loadSavedBikes();
    final updated = list.map((b) {
      return b.copyWith(isDefault: b.id.toLowerCase() == bikeId.toLowerCase());
    }).toList();
    await saveBikes(updated);
    return updated;
  }

  /// Lấy mật khẩu Bluetooth của từng xe cụ thể
  Future<String?> getBikePassword(String bikeId) async {
    try {
      final prefs = await _prefs;
      final key = '$_kPerBikePasswordPrefix${bikeId.replaceAll(":", "_")}';
      final pwd = prefs.getString(key);
      if (pwd != null && pwd.isNotEmpty) return pwd;

      // Fallback về legacy password chung nếu chưa có per-bike
      return prefs.getString(_kLegacyPassword);
    } catch (_) {
      return null;
    }
  }

  /// Lưu mật khẩu Bluetooth cho từng xe cụ thể
  Future<void> setBikePassword(String bikeId, String password) async {
    try {
      final prefs = await _prefs;
      final key = '$_kPerBikePasswordPrefix${bikeId.replaceAll(":", "_")}';
      await prefs.setString(key, password);
      await prefs.setString(_kLegacyPassword, password); // Cập nhật cả legacy
    } catch (_) {}
  }

  /// Xóa mật khẩu của xe
  Future<void> removeBikePassword(String bikeId) async {
    try {
      final prefs = await _prefs;
      final key = '$_kPerBikePasswordPrefix${bikeId.replaceAll(":", "_")}';
      await prefs.remove(key);
    } catch (_) {}
  }
}
