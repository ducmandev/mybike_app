/// Đại diện cho một xe máy điện Dat Bike trong nhà xe (Garage) của người dùng.
class SavedBike {
  final String id; // BLE remoteId (MAC address trên Android hoặc UUID trên iOS)
  final String name; // Tên hiển thị do người dùng đặt (nickname, vd: "Quantum Của Tôi")
  final String? originalAdvName; // Tên quảng bá BLE gốc từ thiết bị (vd: "Dat Bike Quantum", "dat.bik3")
  final String? model; // Model xe (vd: "Quantum S1", "Quantum", "Weaver++", "Weaver 200")
  final String? licensePlate; // Biển số xe (vd: "29-A1 999.99")
  final String? frameSerial; // Số khung xe (Frame number)
  final String? color; // Màu xe (vd: "Trắng Ngọc", "Đen Nhám", "Cam Thể Thao")
  final String? note; // Ghi chú cá nhân
  final String? password; // Mật khẩu BLE của riêng xe này
  final DateTime? lastConnectedAt; // Thời gian kết nối gần nhất
  final double? lastOdo; // Odo km gần nhất ghi nhận
  final int? lastBatteryPercent; // % pin gần nhất
  final bool isDefault; // Đánh dấu xe mặc định ưu tiên tự kết nối

  const SavedBike({
    required this.id,
    required this.name,
    this.originalAdvName,
    this.model,
    this.licensePlate,
    this.frameSerial,
    this.color,
    this.note,
    this.password,
    this.lastConnectedAt,
    this.lastOdo,
    this.lastBatteryPercent,
    this.isDefault = false,
  });

  SavedBike copyWith({
    String? id,
    String? name,
    String? originalAdvName,
    String? model,
    String? licensePlate,
    String? frameSerial,
    String? color,
    String? note,
    String? password,
    DateTime? lastConnectedAt,
    double? lastOdo,
    int? lastBatteryPercent,
    bool? isDefault,
  }) {
    return SavedBike(
      id: id ?? this.id,
      name: name ?? this.name,
      originalAdvName: originalAdvName ?? this.originalAdvName,
      model: model ?? this.model,
      licensePlate: licensePlate ?? this.licensePlate,
      frameSerial: frameSerial ?? this.frameSerial,
      color: color ?? this.color,
      note: note ?? this.note,
      password: password ?? this.password,
      lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
      lastOdo: lastOdo ?? this.lastOdo,
      lastBatteryPercent: lastBatteryPercent ?? this.lastBatteryPercent,
      isDefault: isDefault ?? this.isDefault,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (originalAdvName != null) 'originalAdvName': originalAdvName,
    if (model != null) 'model': model,
    if (licensePlate != null) 'licensePlate': licensePlate,
    if (frameSerial != null) 'frameSerial': frameSerial,
    if (color != null) 'color': color,
    if (note != null) 'note': note,
    if (password != null) 'password': password,
    if (lastConnectedAt != null) 'lastConnectedAt': lastConnectedAt!.toIso8601String(),
    if (lastOdo != null) 'lastOdo': lastOdo,
    if (lastBatteryPercent != null) 'lastBatteryPercent': lastBatteryPercent,
    'isDefault': isDefault,
  };

  factory SavedBike.fromJson(Map<String, dynamic> json) => SavedBike(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? 'Xe Dat Bike',
    originalAdvName: json['originalAdvName'] as String?,
    model: json['model'] as String?,
    licensePlate: json['licensePlate'] as String?,
    frameSerial: json['frameSerial'] as String?,
    color: json['color'] as String?,
    note: json['note'] as String?,
    password: json['password'] as String?,
    lastConnectedAt: json['lastConnectedAt'] != null
        ? DateTime.tryParse(json['lastConnectedAt'] as String)
        : null,
    lastOdo: (json['lastOdo'] as num?)?.toDouble(),
    lastBatteryPercent: (json['lastBatteryPercent'] as num?)?.toInt(),
    isDefault: json['isDefault'] as bool? ?? false,
  );
}
