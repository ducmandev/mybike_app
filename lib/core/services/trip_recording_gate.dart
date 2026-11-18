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

  /// Thời gian xác nhận xe đã thực sự TẮT (`off` / `lock`) trước khi tự động chốt hành trình.
  static const Duration kBikeOffConfirmDuration = Duration(seconds: 5);

  /// Cửa sổ chờ tự kết nối lại khi BLE đứt lúc xe CHƯA chuyển về P mode (`D`/`S`/`E`/`Cruise`, `!parking`)
  /// — bao gồm trường hợp dừng đèn đỏ lâu đứng im 0 km/h với màn hình tắt hoặc mất BLE tạm thời.
  static const Duration kBleReconnectGraceRideMode = Duration(minutes: 10);

  /// Cửa sổ chờ tự kết nối lại khi BLE đứt lúc xe đã về P mode / hạ chân chống / StandBy.
  static const Duration kBleReconnectGraceParked = Duration(seconds: 90);

  /// Ngưỡng tối đa cho phép nối tiếp phiên hành trình nếu app bị đóng/kill đột ngột.
  static const Duration kMaxCrashResumeGap = Duration(minutes: 10);

  /// Sai lệch ODO tối đa (km) giữa phiên lưu đệm và telemetry mới để coi là cùng một chuyến.
  static const double kMaxOdoContinuityJumpKm = 15.0;

  /// Xe có đang ở trạng thái tắt nguồn hoặc khóa an toàn hay không.
  static bool isEcuPoweredOff(BikeLogMsg msg) {
    return msg.state == BikeState.off || msg.state == BikeState.lock;
  }

  /// Xe chưa chuyển về P mode (`D`, `S`, `E`, `Cruise` và chân chống gạt lên),
  /// vẫn đang trong hành trình kể cả khi đứng im `speed == 0` chờ đèn đỏ.
  static bool isInActiveRideGear(BikeLogMsg msg) {
    return isEcuDriveMode(msg.state) && !msg.parking;
  }

  /// Chọn thời gian chờ tự kết nối lại khi BLE đứt đột ngột dựa trên trạng thái ECU cuối cùng:
  /// - Xe đã tắt (`off` / `lock`) -> `null` (chốt ngay lập tức).
  /// - Xe chưa về P mode (`D`/`S`/`E`/`Cruise`, `!parking`, kể cả đứng im đèn đỏ) -> 10 phút.
  /// - Xe đã về P mode / hạ chân chống / StandBy -> 90 giây.
  static Duration? selectReconnectGrace(BikeLogMsg? lastTelemetry) {
    if (lastTelemetry != null && isEcuPoweredOff(lastTelemetry)) {
      return null;
    }
    if (lastTelemetry != null && isInActiveRideGear(lastTelemetry)) {
      return kBleReconnectGraceRideMode;
    }
    return kBleReconnectGraceParked;
  }

  /// Kiểm tra telemetry [msg] có liên tục hợp lệ với chuyến đi đang mở hay không.
  static bool canContinueWithTelemetry({
    required BikeLogMsg msg,
    required double? startOdo,
    double? lastOdo,
  }) {
    if (isEcuPoweredOff(msg)) return false;
    if (startOdo != null && msg.odo > 0) {
      if (msg.odo < startOdo - 0.05) return false;
      if (lastOdo != null &&
          (msg.odo - lastOdo).abs() > kMaxOdoContinuityJumpKm) {
        return false;
      }
    }
    return true;
  }

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

/// Trạng thái hành trình đang mở được lưu kèm bộ đệm GPS để chống lệch ODO - GPS
/// khi app bị đóng đột ngột hoặc mất kết nối tạm thời.
class ActiveTripRecoverySnapshot {
  final String? bikeId;
  final DateTime startTime;
  final DateTime lastActiveAt;
  final double? startOdo;
  final double? lastOdo;
  final int? startPercent;
  final int? lastPercent;
  final double maxSpeedKmh;
  final double speedSum;
  final int speedSamples;

  const ActiveTripRecoverySnapshot({
    this.bikeId,
    required this.startTime,
    required this.lastActiveAt,
    this.startOdo,
    this.lastOdo,
    this.startPercent,
    this.lastPercent,
    this.maxSpeedKmh = 0.0,
    this.speedSum = 0.0,
    this.speedSamples = 0,
  });

  double get odoDistanceKm =>
      (lastOdo != null && startOdo != null) ? max(0.0, lastOdo! - startOdo!) : 0.0;

  double get avgSpeedKmh => speedSamples > 0 ? (speedSum / speedSamples) : 0.0;

  int get usedPercent => (startPercent != null && lastPercent != null)
      ? max(0, startPercent! - lastPercent!)
      : 0;

  int get durationSec => max(0, lastActiveAt.difference(startTime).inSeconds);

  /// Chỉ cho phép khôi phục & nối tiếp vào chuyến đang mở nếu CÙNG XE, xe VẪN BẬT,
  /// thời gian gián đoạn <= 10 phút và ODO liên tục (chống ghép GPS chuyến cũ vào ODO mới).
  bool canResumeWith({
    required BikeLogMsg msg,
    required String? bikeId,
    required DateTime now,
  }) {
    if (startOdo == null) return false;
    if (this.bikeId != null &&
        this.bikeId!.trim().isNotEmpty &&
        bikeId != null &&
        bikeId.trim().isNotEmpty &&
        this.bikeId!.toLowerCase() != bikeId.toLowerCase()) {
      return false;
    }

    final elapsedGap = now.difference(lastActiveAt);
    if (elapsedGap.isNegative ||
        elapsedGap > TripRecordingPolicy.kMaxCrashResumeGap) {
      return false;
    }

    return TripRecordingPolicy.canContinueWithTelemetry(
      msg: msg,
      startOdo: startOdo,
      lastOdo: lastOdo,
    );
  }

  Map<String, dynamic> toJson() => {
        if (bikeId != null) 'bikeId': bikeId,
        'startTime': startTime.toIso8601String(),
        'lastActiveAt': lastActiveAt.toIso8601String(),
        if (startOdo != null) 'startOdo': startOdo,
        if (lastOdo != null) 'lastOdo': lastOdo,
        if (startPercent != null) 'startPercent': startPercent,
        if (lastPercent != null) 'lastPercent': lastPercent,
        'maxSpeedKmh': maxSpeedKmh,
        'speedSum': speedSum,
        'speedSamples': speedSamples,
      };

  static ActiveTripRecoverySnapshot? tryFromJson(dynamic raw) {
    if (raw is! Map<String, dynamic>) return null;
    final start = DateTime.tryParse(raw['startTime'] as String? ?? '');
    final last = DateTime.tryParse(raw['lastActiveAt'] as String? ?? '');
    if (start == null || last == null) return null;
    return ActiveTripRecoverySnapshot(
      bikeId: raw['bikeId'] as String?,
      startTime: start,
      lastActiveAt: last,
      startOdo: (raw['startOdo'] as num?)?.toDouble(),
      lastOdo: (raw['lastOdo'] as num?)?.toDouble(),
      startPercent: (raw['startPercent'] as num?)?.toInt(),
      lastPercent: (raw['lastPercent'] as num?)?.toInt(),
      maxSpeedKmh: (raw['maxSpeedKmh'] as num?)?.toDouble() ?? 0.0,
      speedSum: (raw['speedSum'] as num?)?.toDouble() ?? 0.0,
      speedSamples: (raw['speedSamples'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Snapshot bất biến các chỉ số hành trình hiện tại do [TripSessionCoordinator] tính toán.
class TripSessionSnapshot {
  final bool hasActiveRide;
  final bool justStartedRide;
  final bool shouldAutoFinalize;
  final DateTime? suggestedEndTime;
  final DateTime? startTime;
  final DateTime? lastActiveAt;
  final double? startOdo;
  final double? lastOdo;
  final int? lastPercent;
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
    this.shouldAutoFinalize = false,
    this.suggestedEndTime,
    this.startTime,
    this.lastActiveAt,
    this.startOdo,
    this.lastOdo,
    this.lastPercent,
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
/// Đảm bảo:
/// - Khi người dùng chỉ đi bộ ngang xe hoặc mở khóa rồi tắt mà chưa vào
///   mode chạy & vượt 4 km/h theo ECU, mọi bộ đếm hành trình giữ nguyên trạng thái chờ.
/// - Khi xe tắt nguồn thực sự (`off` / `lock`) trong lúc đứng yên >= 3s, tự động
///   đóng băng đồng hồ và phát tín hiệu chốt hành trình (`shouldAutoFinalize`).
class TripSessionCoordinator {
  bool _hasActiveRide = false;
  DateTime? _startTime;
  DateTime? _lastActiveTime;
  DateTime? _bikeOffConfirmedSince;
  double? _startOdo;
  double? _lastOdo;
  int? _startPercent;
  int? _lastPercent;
  double _maxSpeedKmh = 0.0;
  double _speedSum = 0.0;
  int _speedSamples = 0;
  double _lastOdoDistanceKm = 0.0;

  bool get hasActiveRide => _hasActiveRide;
  DateTime? get startTime => _startTime;
  DateTime? get lastActiveTime => _lastActiveTime;
  DateTime? get bikeOffConfirmedSince => _bikeOffConfirmedSince;
  double? get startOdo => _startOdo;
  double? get lastOdo => _lastOdo;
  int? get startPercent => _startPercent;
  int? get lastPercent => _lastPercent;
  double get maxSpeedKmh => _maxSpeedKmh;
  double get avgSpeedKmh =>
      _speedSamples > 0 ? (_speedSum / _speedSamples) : 0.0;
  double get odoDistanceKm => _lastOdoDistanceKm;
  int get usedPercent => (_startPercent != null &&
          _lastPercent != null &&
          _lastPercent! > 0)
      ? max(0, _startPercent! - _lastPercent!)
      : 0;

  bool canContinueWith(BikeLogMsg msg) =>
      TripRecordingPolicy.canContinueWithTelemetry(
        msg: msg,
        startOdo: _startOdo,
        lastOdo: _lastOdo,
      );

  /// Khôi phục đồng bộ đầy đủ bộ đếm ODO + thời gian từ bản lưu đệm khớp với điểm GPS.
  void restoreFromSnapshot(ActiveTripRecoverySnapshot snapshot) {
    _hasActiveRide = true;
    _startTime = snapshot.startTime;
    _lastActiveTime = snapshot.lastActiveAt;
    _bikeOffConfirmedSince = null;
    _startOdo = snapshot.startOdo;
    _lastOdo = snapshot.lastOdo;
    _startPercent = snapshot.startPercent;
    _lastPercent = snapshot.lastPercent;
    _maxSpeedKmh = snapshot.maxSpeedKmh;
    _speedSum = snapshot.speedSum;
    _speedSamples = snapshot.speedSamples;
    _lastOdoDistanceKm = snapshot.odoDistanceKm;
  }

  /// Xuất bản chụp trạng thái hành trình đang mở để đồng bộ lưu đệm an toàn.
  ActiveTripRecoverySnapshot? toRecoverySnapshot({
    required String? bikeId,
    DateTime? now,
  }) {
    if (!_hasActiveRide || _startTime == null) return null;
    return ActiveTripRecoverySnapshot(
      bikeId: bikeId,
      startTime: _startTime!,
      lastActiveAt: _bikeOffConfirmedSince ?? _lastActiveTime ?? (now ?? DateTime.now()),
      startOdo: _startOdo,
      lastOdo: _lastOdo,
      startPercent: _startPercent,
      lastPercent: _lastPercent,
      maxSpeedKmh: _maxSpeedKmh,
      speedSum: _speedSum,
      speedSamples: _speedSamples,
    );
  }

  /// Tiếp nhận bản tin telemetry từ ECU và cập nhật trạng thái chuyến đi hiện tại.
  TripSessionSnapshot ingestTelemetry(
    BikeLogMsg msg, {
    required double gpsDistanceKm,
    int gpsSignalLossCount = 0,
    DateTime? now,
    DateTime? restoredStartTime,
    bool hasAuthoritativeState = true,
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
      _lastActiveTime = currentNow;
      _bikeOffConfirmedSince = null;
      _startOdo = msg.odo > 0 ? msg.odo : null;
      _lastOdo = _startOdo;
      _startPercent = msg.percent > 0 ? msg.percent : null;
      _lastPercent = _startPercent;
      _lastOdoDistanceKm = 0.0;
    }

    if (_startOdo == null && msg.odo > 0) {
      _startOdo = msg.odo;
    }
    if (_startPercent == null && msg.percent > 0) {
      _startPercent = msg.percent;
    }

    final isBikeOffNow = hasAuthoritativeState &&
        TripRecordingPolicy.isEcuPoweredOff(msg) &&
        msg.speed <= 0.5;
    final isKeepingPendingOff =
        !hasAuthoritativeState && _bikeOffConfirmedSince != null && msg.speed <= 0.5;

    var shouldAutoFinalize = false;
    DateTime? suggestedEndTime;

    if (isBikeOffNow || isKeepingPendingOff) {
      _bikeOffConfirmedSince ??= currentNow;
      suggestedEndTime = _bikeOffConfirmedSince;
      if (currentNow.difference(_bikeOffConfirmedSince!) >=
          TripRecordingPolicy.kBikeOffConfirmDuration) {
        shouldAutoFinalize = true;
      }
    } else {
      if (msg.isBikeOn || msg.speed > 0.5) {
        _bikeOffConfirmedSince = null;
        _lastActiveTime = currentNow;
      }

      if (msg.odo > 0) {
        _lastOdo = msg.odo;
        if (_startOdo != null) {
          _lastOdoDistanceKm = max(0.0, msg.odo - _startOdo!);
        }
      }
      if (msg.percent > 0) {
        _lastPercent = msg.percent;
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
    }

    final effectivePercent = (_lastPercent != null && _lastPercent! > 0)
        ? _lastPercent!
        : msg.percent;
    final usedPct = (_startPercent != null && effectivePercent > 0)
        ? max(0, _startPercent! - effectivePercent)
        : 0;
    final clockEnd = _bikeOffConfirmedSince ?? currentNow;
    final rawDuration =
        _startTime != null ? clockEnd.difference(_startTime!) : Duration.zero;
    final duration = rawDuration.isNegative ? Duration.zero : rawDuration;

    return TripSessionSnapshot(
      hasActiveRide: true,
      justStartedRide: justStarted,
      shouldAutoFinalize: shouldAutoFinalize,
      suggestedEndTime: suggestedEndTime,
      startTime: _startTime,
      lastActiveAt: _lastActiveTime,
      startOdo: _startOdo,
      lastOdo: _lastOdo,
      lastPercent: _lastPercent,
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
    _lastActiveTime = null;
    _bikeOffConfirmedSince = null;
    _startOdo = null;
    _lastOdo = null;
    _startPercent = null;
    _lastPercent = null;
    _maxSpeedKmh = 0.0;
    _speedSum = 0.0;
    _speedSamples = 0;
    _lastOdoDistanceKm = 0.0;
  }
}
