import 'dart:convert';

/// Mô hình lưu trữ vị trí đỗ xe thông minh (Smart Parking Location)
class ParkedLocation {
  final double latitude;
  final double longitude;
  final double? accuracy;
  final DateTime timestamp;
  final String bikeId;
  final String bikeName;
  final int? batteryPercent;
  final double? voltage;
  final String? address;
  final String? note;
  final String? photoPath;
  final bool isLocked;

  const ParkedLocation({
    required this.latitude,
    required this.longitude,
    this.accuracy,
    required this.timestamp,
    required this.bikeId,
    required this.bikeName,
    this.batteryPercent,
    this.voltage,
    this.address,
    this.note,
    this.photoPath,
    this.isLocked = true,
  });

  ParkedLocation copyWith({
    double? latitude,
    double? longitude,
    double? accuracy,
    DateTime? timestamp,
    String? bikeId,
    String? bikeName,
    int? batteryPercent,
    double? voltage,
    String? address,
    String? note,
    String? photoPath,
    bool? isLocked,
  }) {
    return ParkedLocation(
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      accuracy: accuracy ?? this.accuracy,
      timestamp: timestamp ?? this.timestamp,
      bikeId: bikeId ?? this.bikeId,
      bikeName: bikeName ?? this.bikeName,
      batteryPercent: batteryPercent ?? this.batteryPercent,
      voltage: voltage ?? this.voltage,
      address: address ?? this.address,
      note: note ?? this.note,
      photoPath: photoPath ?? this.photoPath,
      isLocked: isLocked ?? this.isLocked,
    );
  }

  Map<String, dynamic> toJson() => {
        'latitude': latitude,
        'longitude': longitude,
        'accuracy': accuracy,
        'timestamp': timestamp.toIso8601String(),
        'bikeId': bikeId,
        'bikeName': bikeName,
        'batteryPercent': batteryPercent,
        'voltage': voltage,
        'address': address,
        'note': note,
        'photoPath': photoPath,
        'isLocked': isLocked,
      };

  factory ParkedLocation.fromJson(Map<String, dynamic> json) {
    return ParkedLocation(
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      accuracy: (json['accuracy'] as num?)?.toDouble(),
      timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ?? DateTime.now(),
      bikeId: json['bikeId'] as String? ?? '',
      bikeName: json['bikeName'] as String? ?? 'Dat Bike',
      batteryPercent: json['batteryPercent'] as int?,
      voltage: (json['voltage'] as num?)?.toDouble(),
      address: json['address'] as String?,
      note: json['note'] as String?,
      photoPath: json['photoPath'] as String?,
      isLocked: json['isLocked'] as bool? ?? true,
    );
  }

  String encode() => jsonEncode(toJson());

  static ParkedLocation? decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return ParkedLocation.fromJson(map);
    } catch (_) {
      return null;
    }
  }
}
