/// Hạng mục bảo dưỡng định kỳ cho xe máy điện Dat Bike.
class MaintenanceItem {
  final String id;
  final String bikeId;
  final String title;
  final String category;
  final double intervalKm;
  final double lastServiceOdo;
  final DateTime? lastServiceAt;
  final String? notes;
  final bool isDefault;

  const MaintenanceItem({
    required this.id,
    required this.bikeId,
    required this.title,
    required this.category,
    required this.intervalKm,
    this.lastServiceOdo = 0.0,
    this.lastServiceAt,
    this.notes,
    this.isDefault = false,
  });

  /// Mốc ODO cần bảo dưỡng tiếp theo (km).
  double get nextDueOdo => lastServiceOdo + intervalKm;

  /// Quãng đường còn lại đến mốc bảo dưỡng (km). Giá trị <= 0 là đã quá hạn.
  double remainingKm(double currentOdo) => nextDueOdo - currentOdo;

  /// Tiến độ chu kỳ bảo dưỡng hiện tại trong khoảng [0.0, 1.0].
  double progress(double currentOdo) {
    if (intervalKm <= 0) {
      return currentOdo >= nextDueOdo ? 1.0 : 0.0;
    }
    return ((currentOdo - lastServiceOdo) / intervalKm).clamp(0.0, 1.0).toDouble();
  }

  /// Trả về true nếu đã đến hạn hoặc quá hạn bảo dưỡng.
  bool isOverdue(double currentOdo) => remainingKm(currentOdo) <= 0.0;

  /// Trả về true nếu sắp đến hạn (còn lại trong khoảng (0, 200] km).
  bool isDueSoon(double currentOdo) {
    final rem = remainingKm(currentOdo);
    return rem > 0.0 && rem <= 200.0;
  }

  MaintenanceItem copyWith({
    String? id,
    String? bikeId,
    String? title,
    String? category,
    double? intervalKm,
    double? lastServiceOdo,
    DateTime? lastServiceAt,
    bool clearLastServiceAt = false,
    String? notes,
    bool clearNotes = false,
    bool? isDefault,
  }) {
    return MaintenanceItem(
      id: id ?? this.id,
      bikeId: bikeId ?? this.bikeId,
      title: title ?? this.title,
      category: category ?? this.category,
      intervalKm: intervalKm ?? this.intervalKm,
      lastServiceOdo: lastServiceOdo ?? this.lastServiceOdo,
      lastServiceAt: clearLastServiceAt ? null : (lastServiceAt ?? this.lastServiceAt),
      notes: clearNotes ? null : (notes ?? this.notes),
      isDefault: isDefault ?? this.isDefault,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'bikeId': bikeId,
        'title': title,
        'category': category,
        'intervalKm': intervalKm,
        'lastServiceOdo': lastServiceOdo,
        if (lastServiceAt != null) 'lastServiceAt': lastServiceAt!.toIso8601String(),
        if (notes != null) 'notes': notes,
        'isDefault': isDefault,
      };

  factory MaintenanceItem.fromJson(Map<String, dynamic> json) {
    return MaintenanceItem(
      id: json['id'] as String? ?? '',
      bikeId: json['bikeId'] as String? ?? 'default_bike',
      title: json['title'] as String? ?? '',
      category: json['category'] as String? ?? 'Chung',
      intervalKm: (json['intervalKm'] as num?)?.toDouble() ?? 1000.0,
      lastServiceOdo: (json['lastServiceOdo'] as num?)?.toDouble() ?? 0.0,
      lastServiceAt: json['lastServiceAt'] != null
          ? DateTime.tryParse(json['lastServiceAt'] as String)
          : null,
      notes: json['notes'] as String?,
      isDefault: json['isDefault'] as bool? ?? false,
    );
  }
}
