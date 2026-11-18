/// Điểm tọa độ GPS và vận tốc xe máy điện Dat Bike tại từng mốc thời gian của hành trình.
class TripGpsPoint {
  final double lat;
  final double lng;
  final double speedKmh;
  final DateTime timestamp;
  final double? altitude;
  final double? heading;

  /// Đánh dấu điểm đầu tiên ghi nhận lại ngay sau một khoảng mất sóng GPS
  /// (ví dụ đi qua hầm, tầng hầm hoặc tắt định vị). Không nối đường thẳng
  /// và không cộng đoạn nhảy qua khoảng mất sóng này vào quãng đường GPS.
  final bool isSignalLossRestart;

  const TripGpsPoint({
    required this.lat,
    required this.lng,
    required this.speedKmh,
    required this.timestamp,
    this.altitude,
    this.heading,
    this.isSignalLossRestart = false,
  });

  TripGpsPoint copyWith({
    double? lat,
    double? lng,
    double? speedKmh,
    DateTime? timestamp,
    double? altitude,
    double? heading,
    bool? isSignalLossRestart,
  }) {
    return TripGpsPoint(
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      speedKmh: speedKmh ?? this.speedKmh,
      timestamp: timestamp ?? this.timestamp,
      altitude: altitude ?? this.altitude,
      heading: heading ?? this.heading,
      isSignalLossRestart: isSignalLossRestart ?? this.isSignalLossRestart,
    );
  }

  Map<String, dynamic> toJson() => {
    'lat': lat,
    'lng': lng,
    'speedKmh': speedKmh,
    'timestamp': timestamp.toIso8601String(),
    if (altitude != null) 'altitude': altitude,
    if (heading != null) 'heading': heading,
    if (isSignalLossRestart) 'signalLossRestart': true,
  };

  factory TripGpsPoint.fromJson(Map<String, dynamic> json) => TripGpsPoint(
    lat: (json['lat'] as num?)?.toDouble() ?? 0.0,
    lng: (json['lng'] as num?)?.toDouble() ?? 0.0,
    speedKmh: (json['speedKmh'] as num?)?.toDouble() ?? 0.0,
    timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ?? DateTime.now(),
    altitude: (json['altitude'] as num?)?.toDouble(),
    heading: (json['heading'] as num?)?.toDouble(),
    isSignalLossRestart: json['signalLossRestart'] == true,
  );
}
