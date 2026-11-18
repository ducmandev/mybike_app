import '../models/maintenance_item.dart';
import 'json_prefs_store.dart';

/// Dịch vụ lưu trữ lịch bảo dưỡng định kỳ theo từng xe trong SharedPreferences.
class MaintenanceStorageService extends JsonPrefsStore<MaintenanceItem> {
  MaintenanceStorageService._();
  static final MaintenanceStorageService instance = MaintenanceStorageService._();

  static const String defaultBikeId = 'default_bike';
  static const String _keyPrefix = 'maintenance_items_v1_';

  /// Chuẩn hóa bikeId để làm khóa SharedPreferences an toàn.
  static String sanitizeBikeId(String bikeId) =>
      JsonPrefsStore.sanitizeKeyPart(bikeId, fallback: defaultBikeId);

  /// Khóa lưu trữ SharedPreferences cho một xe cụ thể.
  static String storageKeyForBike(String bikeId) =>
      '$_keyPrefix${sanitizeBikeId(bikeId)}';

  List<MaintenanceItem> _buildDefaultItems(
    String resolvedBikeId,
    double initialOdo,
  ) {
    final safeOdo = initialOdo.isFinite && initialOdo >= 0.0 ? initialOdo : 0.0;
    return [
      MaintenanceItem(
        id: 'default_tires',
        bikeId: resolvedBikeId,
        title: 'Kiểm tra áp suất & gai lốp',
        category: 'Lốp & Bánh',
        intervalKm: 1000.0,
        lastServiceOdo: safeOdo,
        isDefault: true,
      ),
      MaintenanceItem(
        id: 'default_brakes_drive',
        bikeId: resolvedBikeId,
        title: 'Vệ sinh má phanh & kiểm tra truyền động',
        category: 'Phanh & Truyền động',
        intervalKm: 3000.0,
        lastServiceOdo: safeOdo,
        isDefault: true,
      ),
      MaintenanceItem(
        id: 'default_general_steering',
        bikeId: resolvedBikeId,
        title: 'Bảo dưỡng tổng quát & cổ lái',
        category: 'Khung & Lái',
        intervalKm: 5000.0,
        lastServiceOdo: safeOdo,
        isDefault: true,
      ),
      MaintenanceItem(
        id: 'default_suspension_fluid',
        bikeId: resolvedBikeId,
        title: 'Kiểm tra giảm xóc & dầu phanh',
        category: 'Hệ thống treo & Phanh',
        intervalKm: 10000.0,
        lastServiceOdo: safeOdo,
        isDefault: true,
      ),
    ];
  }

  Future<void> _saveItems(String bikeId, List<MaintenanceItem> items) =>
      writeList(storageKeyForBike(bikeId), items, (e) => e.toJson());

  /// Tải danh sách hạng mục bảo dưỡng của xe.
  /// Nếu là lần đầu tải (chưa có dữ liệu), tự động khởi tạo 4 lịch mặc định Dat Bike EV.
  Future<List<MaintenanceItem>> loadItems(
    String bikeId, {
    double initialOdo = 0.0,
  }) async {
    final resolvedBikeId = sanitizeBikeId(bikeId);
    final key = storageKeyForBike(bikeId);
    final existing = await readList(
      key,
      MaintenanceItem.fromJson,
      where: (item) => item.id.trim().isNotEmpty,
    );
    if (existing != null) {
      return existing;
    }

    final seeded = _buildDefaultItems(resolvedBikeId, initialOdo);
    try {
      await _saveItems(bikeId, seeded);
    } catch (_) {}
    return seeded;
  }

  /// Đánh dấu một hạng mục đã được bảo dưỡng tại [currentOdo], đặt lại chu kỳ mới.
  Future<List<MaintenanceItem>> markServiced(
    String bikeId,
    String itemId,
    double currentOdo, {
    DateTime? now,
  }) async {
    final safeOdo = currentOdo.isFinite && currentOdo >= 0.0 ? currentOdo : 0.0;
    final timestamp = now ?? DateTime.now();
    final items = await loadItems(bikeId, initialOdo: safeOdo);
    final updated = items.map((item) {
      if (item.id != itemId) return item;
      return item.copyWith(
        lastServiceOdo: safeOdo,
        lastServiceAt: timestamp,
      );
    }).toList();
    await _saveItems(bikeId, updated);
    return updated;
  }

  /// Thêm hạng mục bảo dưỡng tùy chỉnh mới cho xe.
  Future<List<MaintenanceItem>> addItem(
    String bikeId,
    MaintenanceItem item, {
    double initialOdo = 0.0,
  }) async {
    final resolvedBikeId = sanitizeBikeId(bikeId);
    final items = await loadItems(bikeId, initialOdo: initialOdo);
    final normalizedItem = item.copyWith(
      bikeId: item.bikeId.trim().isEmpty ? resolvedBikeId : item.bikeId,
    );
    final updated = [...items, normalizedItem];
    await _saveItems(bikeId, updated);
    return updated;
  }

  /// Xóa một hạng mục bảo dưỡng theo [itemId].
  Future<List<MaintenanceItem>> deleteItem(
    String bikeId,
    String itemId, {
    double initialOdo = 0.0,
  }) async {
    final items = await loadItems(bikeId, initialOdo: initialOdo);
    final updated = items.where((item) => item.id != itemId).toList();
    await _saveItems(bikeId, updated);
    return updated;
  }
}
