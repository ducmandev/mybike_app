import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Lớp nền OOP tái sử dụng cho các dịch vụ lưu trữ đối tượng và danh sách JSON
/// trong [SharedPreferences].
abstract class JsonPrefsStore<T> {
  @protected
  Future<SharedPreferences> get prefs => SharedPreferences.getInstance();

  /// Chuẩn hóa chuỗi định danh thành phần khóa [SharedPreferences] an toàn.
  static String sanitizeKeyPart(
    String rawId, {
    String fallback = 'default_bike',
  }) {
    final trimmed = rawId.trim();
    if (trimmed.isEmpty) return fallback;
    final sanitized = trimmed.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    if (sanitized.replaceAll('_', '').isEmpty) return fallback;
    return sanitized;
  }

  /// Giải mã một đối tượng JSON từ chuỗi thô; trả về `null` nếu lỗi hoặc không hợp lệ.
  @protected
  T? decodeObject(
    String raw,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    if (raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return fromJson(decoded);
      }
      if (decoded is Map) {
        return fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {}
    return null;
  }

  /// Đọc đối tượng JSON từ [key]; nếu chưa có hoặc lỗi thì kiểm tra lần lượt [fallbackKeys].
  @protected
  Future<T?> readObject(
    String key,
    T Function(Map<String, dynamic>) fromJson, {
    List<String> fallbackKeys = const [],
  }) async {
    try {
      final store = await prefs;
      final candidates = <String>[key, ...fallbackKeys];
      for (final candidateKey in candidates) {
        final raw = store.getString(candidateKey);
        if (raw == null || raw.trim().isEmpty) continue;
        final decoded = decodeObject(raw, fromJson);
        if (decoded != null) return decoded;
      }
    } catch (_) {}
    return null;
  }

  /// Ghi đối tượng JSON vào [key].
  @protected
  Future<void> writeObject(
    String key,
    T item,
    Map<String, dynamic> Function(T) toJson,
  ) async {
    final store = await prefs;
    await store.setString(key, jsonEncode(toJson(item)));
  }

  /// Đọc danh sách JSON từ [key].
  /// Trả về `null` nếu khóa chưa tồn tại (hoặc lỗi decode) để caller biết cần seed/migrate,
  /// phân biệt rõ với danh sách rỗng `[]` đã được lưu tường minh (`'[]'`).
  @protected
  Future<List<T>?> readList(
    String key,
    T Function(Map<String, dynamic>) fromJson, {
    bool Function(T)? where,
  }) async {
    try {
      final store = await prefs;
      final raw = store.getString(key);
      if (raw == null) return null;
      if (raw.trim().isEmpty) return <T>[];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      final items = <T>[];
      for (final entry in decoded) {
        final map = entry is Map<String, dynamic>
            ? entry
            : (entry is Map ? Map<String, dynamic>.from(entry) : null);
        if (map == null) continue;
        final item = fromJson(map);
        if (where == null || where(item)) {
          items.add(item);
        }
      }
      return items;
    } catch (_) {
      return null;
    }
  }

  /// Ghi danh sách đối tượng JSON vào [key].
  @protected
  Future<void> writeList(
    String key,
    List<T> items,
    Map<String, dynamic> Function(T) toJson,
  ) async {
    final store = await prefs;
    await store.setString(key, jsonEncode(items.map(toJson).toList()));
  }

  /// Xóa các khóa được chỉ định khỏi [SharedPreferences].
  @protected
  Future<void> removeKeys(Iterable<String> keys) async {
    final store = await prefs;
    for (final key in keys) {
      await store.remove(key);
    }
  }
}
