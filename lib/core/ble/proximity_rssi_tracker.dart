import '../utils/kalman_filter.dart';
import '../utils/rssi_distance_helper.dart';

/// Bộ theo dõi và làm mượt tín hiệu RSSI BLE bằng Kalman 1D kèm fast-track
/// theo chuỗi mẫu gần/xa và tự reset khi mất tín hiệu quá ngưỡng thời gian.
class ProximityRssiTracker {
  final KalmanFilter1D kalman;
  double? smoothedRssi;
  DateTime? lastRssiAt;
  int nearRawStreak = 0;
  int farRawStreak = 0;
  int approachStrongStreak = 0;

  ProximityRssiTracker({
    double processNoise = 0.05,
    double measurementNoise = 3.0,
  }) : kalman = KalmanFilter1D(
          processNoise: processNoise,
          measurementNoise: measurementNoise,
        );

  /// Trả về `true` nếu chưa có mẫu RSSI hoặc mẫu cuối cũ hơn [threshold].
  bool isStaleAt(
    DateTime now, {
    Duration threshold = const Duration(seconds: 4),
  }) {
    return lastRssiAt == null || now.difference(lastRssiAt!) > threshold;
  }

  /// Đặt lại toàn bộ trạng thái lọc và bộ đếm chuỗi RSSI.
  void reset() {
    smoothedRssi = null;
    kalman.reset();
    lastRssiAt = null;
    nearRawStreak = 0;
    farRawStreak = 0;
    approachStrongStreak = 0;
  }

  /// Nạp một mẫu RSSI thô mới, trả về giá trị RSSI đã làm mượt (hoặc `null` nếu mẫu không hợp lệ).
  double? ingest(
    int curRssi, {
    required double nearThreshold,
    required double farThreshold,
    DateTime? now,
  }) {
    if (!RssiDistanceHelper.isValidRssi(curRssi)) return null;

    final sampleTime = now ?? DateTime.now();
    final hadTimeGap = lastRssiAt != null &&
        sampleTime.difference(lastRssiAt!) > const Duration(seconds: 4);
    lastRssiAt = sampleTime;

    if (hadTimeGap) {
      nearRawStreak = 0;
      farRawStreak = 0;
    }

    nearRawStreak = curRssi >= nearThreshold ? nearRawStreak + 1 : 0;
    farRawStreak = curRssi <= farThreshold ? farRawStreak + 1 : 0;

    final prev = smoothedRssi;
    final rawDouble = curRssi.toDouble();
    if (hadTimeGap || prev == null) {
      kalman.reset(rawDouble);
      smoothedRssi = rawDouble;
      approachStrongStreak = 0;
      return smoothedRssi;
    }

    if ((curRssi - prev) >= 6.0) {
      approachStrongStreak++;
    } else {
      approachStrongStreak = 0;
    }

    if (curRssi >= nearThreshold &&
        ((curRssi - prev) >= 5.0 || nearRawStreak >= 2)) {
      kalman.reset(rawDouble);
      smoothedRssi = rawDouble;
      approachStrongStreak = 0;
    } else if (approachStrongStreak >= 2) {
      final snapped = ((curRssi - prev) >= 10.0)
          ? rawDouble
          : (prev + curRssi * 2.0) / 3.0;
      kalman.reset(snapped);
      smoothedRssi = snapped;
    } else if (farRawStreak >= 3) {
      kalman.reset(rawDouble);
      smoothedRssi = rawDouble;
    } else if (farRawStreak == 2 && (prev - curRssi) >= 6.0) {
      final blended = (prev + curRssi) / 2.0;
      kalman.reset(blended);
      smoothedRssi = blended;
    } else {
      smoothedRssi = kalman.filter(rawDouble);
    }

    return smoothedRssi;
  }
}
