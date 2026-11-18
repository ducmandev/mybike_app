import 'dart:math' show max;

import '../proto/bike_log.dart';

/// Quy tắc nghiệp vụ chuẩn xác định khi nào xe thực sự đang vận hành hành trình.
///
/// Chống triệt để hiện tượng đi bộ ngang qua xe làm app tự kết nối BLE rồi ghi
/// nhận nhầm hành trình:
/// - CHỈ tin cậy trạng thái và tốc độ do ECU trả về (tuyệt đối KHÔNG dùng tốc độ GPS).
/// - Xe phải đang ở chế độ chạy tiến (`D`, `S`, `E`, `CRUISE`), chân chống đã gạt lên
///   (`!parking`), và tốc độ ECU lớn hơn `4.0 km/h`.
abstract final class TripRecordingPolicy {
  /// Tốc độ ECU tối thiểu (> 4 km/h) để bắt đầu kích hoạt ghi nhận hành trình mới.
  static const double kMinEcuRideSpeedKmh = 4.0;

  /// Tốc độ ECU tối thiểu (> 0.5 km/h) để ghi điểm GPS khi hành trình đã kích hoạt.
  static const double kActiveContinueSpeedKmh = 0.5;

  /// Các mode lái thực sự (không bao gồm off, lock, standBy, parking, reverse).
  static bool isEcuDriveMode(BikeState state) {
    return state == BikeState.drive ||
        state == BikeState.super_ ||
        state == BikeState.turtle ||
        state == BikeState.cruiseControl;
  }

  /// Xe có đang ở mode chạy + gạt chân chống lên + đạt tốc độ ECU > 4 km/h hay không.
  static bool isEcuActivelyRiding(BikeLogMsg msg) {
    return isEcuDriveMode(msg.state) &&
        !msg.parking &&
        msg.speed > kMinEcuRideSpeedKmh;
  }

  /// Điều kiện ghi thêm điểm tọa độ GPS khi chuyến đi đang diễn ra.
  /// - Sau khi đã kích hoạt hành trình thật (`hasActiveRide == true`),
  ///   chỉ ghi khi xe vẫn ở mode chạy, chân chống lên và tốc độ ECU > 0.5 km/h.
  /// - Nếu chưa kích hoạt hành trình (`hasActiveRide == false`), bắt buộc phải đạt
  ///   đầy đủ điều kiện [isEcuActivelyRiding] (tức tốc độ ECU > 4.0 km/h).
  static bool canRecordGpsBreadcrumb({
    required bool hasActiveRide,
    required BikeLogMsg msg,
  }) {
    if (!hasActiveRide) {
      return isEcuActivelyRiding(msg);
    }
    return isEcuDriveMode(msg.state) &&
        !msg.parking &&
        msg.speed > kActiveContinueSpeedKmh;
  }
}

/// Snapshot bất biến các chỉ số hành trình hiện tại do [TripSessionCoordinator] tính toán.
class TripSessionSnapshot {
  final bool hasActiveRide;
  final bool justStartedRide;
  final DateTime? startTime;
  final double? startOdo;
  final double distanceKm;
  final double gpsDistanceKm;
  final int gpsSignalLossCount;
  final Duration duration;
  final double avgSpeedKmh;
  final double maxSpeedKmh;
  final int usedPercent;
  final double powerKw;

  const TripSessionSnapshot({
    this.hasActiveRide = false,
    this.justStartedRide = false,
    this.startTime,
    this.startOdo,
    this.distanceKm = 0.0,
    this.gpsDistanceKm = 0.0,
    this.gpsSignalLossCount = 0,
    this.duration = Duration.zero,
    this.avgSpeedKmh = 0.0,
    this.maxSpeedKmh = 0.0,
    this.usedPercent = 0,
    this.powerKw = 0.0,
  });
}

/// Bộ điều phối vòng đời một chuyến đi hiện tại dựa thuần túy trên telemetry ECU.
///
/// Đảm bảo khi người dùng chỉ đi bộ ngang xe hoặc mở khóa rồi tắt mà chưa vào
/// mode chạy & vượt 4 km/h theo ECU, mọi bộ đếm hành trình (`startTime`,
/// `distanceKm`, `duration`, `TripGpsTracker`) đều giữ nguyên ở trạng thái chờ.
class TripSessionCoordinator {
  bool _hasActiveRide = false;
  DateTime? _startTime;
  double? _startOdo;
  int? _startPercent;
  double _maxSpeedKmh = 0.0;
  double _speedSum = 0.0;
  int _speedSamples = 0;
  double _lastOdoDistanceKm = 0.0;

  bool get hasActiveRide => _hasActiveRide;
  DateTime? get startTime => _startTime;
  double? get startOdo => _startOdo;
  int? get startPercent => _startPercent;
  double get maxSpeedKmh => _maxSpeedKmh;
  double get avgSpeedKmh =>
      _speedSamples > 0 ? (_speedSum / _speedSamples) : 0.0;
  double get odoDistanceKm => _lastOdoDistanceKm;

  /// Tiếp nhận bản tin telemetry từ ECU và cập nhật trạng thái chuyến đi hiện tại.
  TripSessionSnapshot ingestTelemetry(
    BikeLogMsg msg, {
    required double gpsDistanceKm,
    int gpsSignalLossCount = 0,
    DateTime? now,
    DateTime? restoredStartTime,
  }) {
    final currentNow = now ?? DateTime.now();
    final pKw = (msg.voltage > 0) ? ((msg.voltage * msg.phase) / 1000.0) : 0.0;

    var justStarted = false;
    if (!_hasActiveRide) {
      if (!TripRecordingPolicy.isEcuActivelyRiding(msg)) {
        return TripSessionSnapshot(
          hasActiveRide: false,
          justStartedRide: false,
          powerKw: pKw,
        );
      }

      _hasActiveRide = true;
      justStarted = true;
      _startTime = restoredStartTime ?? currentNow;
      _startOdo = msg.odo > 0 ? msg.odo : null;
      _startPercent = msg.percent > 0 ? msg.percent : null;
      _lastOdoDistanceKm = 0.0;
    }

    if (_startOdo == null && msg.odo > 0) {
      _startOdo = msg.odo;
    }
    if (_startPercent == null && msg.percent > 0) {
      _startPercent = msg.percent;
    }

    if (msg.odo > 0 && _startOdo != null) {
      _lastOdoDistanceKm = max(0.0, msg.odo - _startOdo!);
    }

    final isForwardMoving =
        TripRecordingPolicy.isEcuDriveMode(msg.state) && !msg.parking;
    if (isForwardMoving && msg.speed > _maxSpeedKmh) {
      _maxSpeedKmh = msg.speed;
    }
    if (isForwardMoving &&
        msg.speed > TripRecordingPolicy.kActiveContinueSpeedKmh) {
      _speedSum += msg.speed;
      _speedSamples++;
    }

    final usedPct = (_startPercent != null && msg.percent > 0)
        ? max(0, _startPercent! - msg.percent)
        : 0;
    final rawDuration = _startTime != null
        ? currentNow.difference(_startTime!)
        : Duration.zero;
    final duration = rawDuration.isNegative ? Duration.zero : rawDuration;

    return TripSessionSnapshot(
      hasActiveRide: true,
      justStartedRide: justStarted,
      startTime: _startTime,
      startOdo: _startOdo,
      distanceKm: _lastOdoDistanceKm,
      gpsDistanceKm: gpsDistanceKm,
      gpsSignalLossCount: gpsSignalLossCount,
      duration: duration,
      avgSpeedKmh: avgSpeedKmh,
      maxSpeedKmh: _maxSpeedKmh,
      usedPercent: usedPct,
      powerKw: pKw,
    );
  }

  /// Đặt lại toàn bộ bộ đếm chuyến đi về trạng thái chờ hành trình mới.
  void reset() {
    _hasActiveRide = false;
    _startTime = null;
    _startOdo = null;
    _startPercent = null;
    _maxSpeedKmh = 0.0;
    _speedSum = 0.0;
    _speedSamples = 0;
    _lastOdoDistanceKm = 0.0;
  }
}
