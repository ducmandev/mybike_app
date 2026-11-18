import 'dart:math' show max;

import '../ble/ble_controller.dart' show TripRecord;

/// Dữ liệu tổng hợp chuyến đi của một ngày dương lịch (dùng cho biểu đồ cột 7/30 ngày).
class DailyTripBucket {
  final DateTime day;
  final double distanceKm;
  final double gpsDistanceKm;
  final bool hasGpsDistance;
  final int tripCount;
  final int movingDurationSec;

  const DailyTripBucket({
    required this.day,
    required this.distanceKm,
    this.gpsDistanceKm = 0.0,
    this.hasGpsDistance = false,
    required this.tripCount,
    required this.movingDurationSec,
  });

  /// Nhãn ngày ngắn gọn dạng `dd/MM` hiển thị trên trục hoành biểu đồ.
  String get shortDayLabel {
    final dd = day.day.toString().padLeft(2, '0');
    final mm = day.month.toString().padLeft(2, '0');
    return '$dd/$mm';
  }
}

/// Thống kê tổng hợp hành trình theo chu kỳ (7 ngày, 30 ngày, ...).
class TripPeriodSummary {
  final int days;
  final int tripCount;
  final double totalDistanceKm;
  final double totalGpsDistanceKm;
  final bool hasGpsDistance;
  final int totalMovingDurationSec;
  final int totalUsedPercent;
  final double maxSpeedKmh;
  final double co2SavedKg;
  final double estimatedFuelSavedVnd;
  final List<DailyTripBucket> dailyBuckets;

  const TripPeriodSummary({
    required this.days,
    required this.tripCount,
    required this.totalDistanceKm,
    this.totalGpsDistanceKm = 0.0,
    this.hasGpsDistance = false,
    required this.totalMovingDurationSec,
    required this.totalUsedPercent,
    required this.maxSpeedKmh,
    required this.co2SavedKg,
    required this.estimatedFuelSavedVnd,
    required this.dailyBuckets,
  });

  /// Tốc độ trung bình di chuyển thực tế (km/h) trong kỳ.
  double get avgSpeedKmh {
    if (totalMovingDurationSec <= 0) return 0.0;
    return totalDistanceKm / (totalMovingDurationSec / 3600.0);
  }

  /// Quãng đường ODO trung bình mỗi chuyến đi (km).
  double get avgDistancePerTripKm {
    if (tripCount <= 0) return 0.0;
    return totalDistanceKm / tripCount;
  }

  /// Quãng đường GPS trung bình mỗi chuyến đi (km).
  double get avgGpsDistancePerTripKm {
    if (tripCount <= 0) return 0.0;
    return totalGpsDistanceKm / tripCount;
  }
}

/// Dịch vụ phân tích và tổng hợp chỉ số hành trình theo khoảng ngày.
class TripAnalyticsService {
  TripAnalyticsService._();

  static const double _co2SavedKgPerKm = 0.065;

  /// Tổng hợp thống kê trong `[today - (days - 1) .. today]` (bao gồm cả hai đầu),
  /// đồng thời dựng chuỗi [DailyTripBucket] liên tục từ ngày cũ nhất đến hôm nay.
  static TripPeriodSummary summarize(
    List<TripRecord> trips, {
    required int days,
    DateTime? now,
    double fuelCostPerKmVnd = 500.0,
  }) {
    final safeDays = days < 1 ? 1 : days;
    final refLocal = (now ?? DateTime.now()).toLocal();
    final today = DateTime(refLocal.year, refLocal.month, refLocal.day);
    final startDay = DateTime(today.year, today.month, today.day - (safeDays - 1));

    final dayDistances = <DateTime, double>{};
    final dayGpsDistances = <DateTime, double>{};
    final dayHasGps = <DateTime, bool>{};
    final dayCounts = <DateTime, int>{};
    final dayDurations = <DateTime, int>{};

    var tripCount = 0;
    var totalDistanceKm = 0.0;
    var totalGpsDistanceKm = 0.0;
    var anyGpsDistance = false;
    var totalMovingDurationSec = 0;
    var totalUsedPercent = 0;
    var maxSpeedKmh = 0.0;

    for (final trip in trips) {
      final localStart = trip.startTime.toLocal();
      final tripDay = DateTime(localStart.year, localStart.month, localStart.day);
      if (tripDay.isBefore(startDay) || tripDay.isAfter(today)) {
        continue;
      }

      final distance = trip.distanceKm > 0 ? trip.distanceKm : 0.0;
      final gpsDist = trip.effectiveGpsDistanceKm();
      final duration = trip.durationSec > 0 ? trip.durationSec : 0;
      final usedPct = trip.usedPercent > 0 ? trip.usedPercent : 0;

      tripCount += 1;
      totalDistanceKm += distance;
      if (gpsDist != null && gpsDist >= 0) {
        totalGpsDistanceKm += gpsDist;
        anyGpsDistance = true;
        dayGpsDistances[tripDay] = (dayGpsDistances[tripDay] ?? 0.0) + gpsDist;
        dayHasGps[tripDay] = true;
      }
      totalMovingDurationSec += duration;
      totalUsedPercent += usedPct;
      maxSpeedKmh = max(maxSpeedKmh, trip.maxSpeedKmh);

      dayDistances[tripDay] = (dayDistances[tripDay] ?? 0.0) + distance;
      dayCounts[tripDay] = (dayCounts[tripDay] ?? 0) + 1;
      dayDurations[tripDay] = (dayDurations[tripDay] ?? 0) + duration;
    }

    final buckets = <DailyTripBucket>[];
    for (var i = 0; i < safeDays; i++) {
      final day = DateTime(startDay.year, startDay.month, startDay.day + i);
      buckets.add(
        DailyTripBucket(
          day: day,
          distanceKm: dayDistances[day] ?? 0.0,
          gpsDistanceKm: dayGpsDistances[day] ?? 0.0,
          hasGpsDistance: dayHasGps[day] ?? false,
          tripCount: dayCounts[day] ?? 0,
          movingDurationSec: dayDurations[day] ?? 0,
        ),
      );
    }

    final co2SavedKg = totalDistanceKm * _co2SavedKgPerKm;
    final estimatedFuelSavedVnd =
        totalDistanceKm * (fuelCostPerKmVnd > 0 ? fuelCostPerKmVnd : 0.0);

    return TripPeriodSummary(
      days: safeDays,
      tripCount: tripCount,
      totalDistanceKm: totalDistanceKm,
      totalGpsDistanceKm: totalGpsDistanceKm,
      hasGpsDistance: anyGpsDistance,
      totalMovingDurationSec: totalMovingDurationSec,
      totalUsedPercent: totalUsedPercent,
      maxSpeedKmh: maxSpeedKmh,
      co2SavedKg: co2SavedKg,
      estimatedFuelSavedVnd: estimatedFuelSavedVnd,
      dailyBuckets: List<DailyTripBucket>.unmodifiable(buckets),
    );
  }
}
