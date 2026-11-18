import 'dart:math';

import '../ble/ble_controller.dart' show TripRecord;
import '../services/gps_route_snapping_service.dart';
import 'trip_gps_point.dart';

/// Chế độ ghép nhiều hành trình thành một phiên xem & phát lại thống nhất.
enum TripMergeMode { single, byDay, customChain }

/// Điểm dừng nghỉ giữa hai chặng liên tiếp trong một phiên hành trình đã ghép.
class TripStopover {
  final int index;
  final TripGpsPoint location;
  final DateTime arrivedAt;
  final DateTime departedAt;
  final Duration duration;
  final double gapDistanceMeters;
  final int afterGlobalPointIndex;

  const TripStopover({
    required this.index,
    required this.location,
    required this.arrivedAt,
    required this.departedAt,
    required this.duration,
    required this.gapDistanceMeters,
    required this.afterGlobalPointIndex,
  });

  String get label => 'P$index';

  String get formattedDuration {
    final totalSec = duration.inSeconds;
    if (totalSec < 60) {
      return '< 1 phút';
    }
    final totalMinutes = duration.inMinutes;
    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes % 60;
    if (hours == 0) {
      return '$minutes phút';
    }
    if (minutes == 0) {
      return '${hours}g';
    }
    return '${hours}g ${minutes}p';
  }
}

/// Một chặng (tương ứng 1 [TripRecord]) nằm bên trong [MergedTripSession].
class TripSegment {
  final int segmentIndex;
  final int displayOrder;
  final TripRecord trip;
  final List<TripGpsPoint> points;
  final int startPointIndex;
  final int endPointIndex;
  final double cumulativeStartKm;
  final double cumulativeEndKm;
  final double? gpsDistanceKm;
  final double cumulativeGpsStartKm;
  final double cumulativeGpsEndKm;
  final int gpsSignalLossCount;
  final Duration gapBefore;
  final double gapDistanceBeforeMeters;

  const TripSegment({
    required this.segmentIndex,
    required this.displayOrder,
    required this.trip,
    required this.points,
    required this.startPointIndex,
    required this.endPointIndex,
    required this.cumulativeStartKm,
    required this.cumulativeEndKm,
    this.gpsDistanceKm,
    this.cumulativeGpsStartKm = 0.0,
    this.cumulativeGpsEndKm = 0.0,
    this.gpsSignalLossCount = 0,
    required this.gapBefore,
    required this.gapDistanceBeforeMeters,
  });

  bool get hasPoints =>
      points.isNotEmpty && startPointIndex >= 0 && endPointIndex >= startPointIndex;
}

/// Phiên hành trình thống nhất (đơn lẻ, theo ngày, hoặc chuỗi tự chọn) dùng cho bản đồ & Live-Back.
class MergedTripSession {
  final String id;
  final String title;
  final TripMergeMode mode;
  final List<TripSegment> segments;
  final List<TripGpsPoint> allPoints;
  final List<int> segmentStartIndices;
  final List<TripStopover> stopovers;

  const MergedTripSession({
    required this.id,
    required this.title,
    required this.mode,
    required this.segments,
    required this.allPoints,
    required this.segmentStartIndices,
    required this.stopovers,
  });

  int get segmentCount => segments.length;

  bool get isMerged => segments.length > 1 || mode != TripMergeMode.single;

  DateTime get startTime =>
      segments.isNotEmpty ? segments.first.trip.startTime : DateTime.fromMillisecondsSinceEpoch(0);

  DateTime get endTime =>
      segments.isNotEmpty ? segments.last.trip.endTime : DateTime.fromMillisecondsSinceEpoch(0);

  double get totalDistanceKm =>
      segments.fold<double>(0.0, (sum, s) => sum + s.trip.distanceKm);

  double get totalGpsDistanceKm =>
      segments.fold<double>(0.0, (sum, s) => sum + (s.gpsDistanceKm ?? 0.0));

  bool get hasGpsDistance => segments.any((s) => s.gpsDistanceKm != null);

  int get totalGpsSignalLossCount =>
      segments.fold<int>(0, (sum, s) => sum + s.gpsSignalLossCount);

  bool get isGpsRoadSnapped =>
      hasGpsDistance &&
      segments.where((s) => s.gpsDistanceKm != null).every((s) => s.trip.isGpsRoadSnapped);

  int get totalMovingDurationSec =>
      segments.fold<int>(0, (sum, s) => sum + s.trip.durationSec);

  int get totalElapsedSpanSec =>
      segments.isEmpty ? 0 : max(0, endTime.difference(startTime).inSeconds);

  int get totalStopDurationSec {
    if (stopovers.isNotEmpty) {
      return stopovers.fold<int>(0, (sum, s) => sum + max(0, s.duration.inSeconds));
    }
    return max(0, totalElapsedSpanSec - totalMovingDurationSec);
  }

  double get avgMovingSpeedKmh {
    if (totalMovingDurationSec > 0) {
      return totalDistanceKm / (totalMovingDurationSec / 3600.0);
    }
    final nonZero = segments.where((s) => s.trip.avgSpeedKmh > 0).toList();
    if (nonZero.isEmpty) return 0.0;
    final sum = nonZero.fold<double>(0.0, (acc, s) => acc + s.trip.avgSpeedKmh);
    return sum / nonZero.length;
  }

  double get maxSpeedKmh =>
      segments.isEmpty ? 0.0 : segments.fold<double>(0.0, (m, s) => max(m, s.trip.maxSpeedKmh));

  int get totalUsedPercent =>
      segments.fold<int>(0, (sum, s) => sum + (s.trip.usedPercent > 0 ? s.trip.usedPercent : 0));

  double get totalCo2SavedKg => totalDistanceKm * 0.065;

  /// Tìm chặng đang chứa điểm toàn cục [globalIndex].
  TripSegment? segmentAtPointIndex(int globalIndex) {
    if (globalIndex < 0 || globalIndex >= allPoints.length) {
      return null;
    }
    for (final seg in segments) {
      if (seg.hasPoints &&
          globalIndex >= seg.startPointIndex &&
          globalIndex <= seg.endPointIndex) {
        return seg;
      }
    }
    return null;
  }

  /// Quãng đường ODO tích lũy (km) nội suy tuyến tính tại điểm toàn cục [globalIndex].
  double cumulativeDistanceAtPointIndex(int globalIndex) =>
      _cumulativeMetricAt(globalIndex, useGps: false);

  /// Quãng đường GPS tích lũy (km) nội suy tuyến tính tại điểm toàn cục [globalIndex].
  double cumulativeGpsDistanceAtPointIndex(int globalIndex) =>
      _cumulativeMetricAt(globalIndex, useGps: true);

  double _cumulativeMetricAt(int globalIndex, {required bool useGps}) {
    if (segments.isEmpty) return 0.0;
    if (allPoints.isEmpty) return 0.0;
    if (globalIndex < 0) {
      return useGps
          ? segments.first.cumulativeGpsStartKm
          : segments.first.cumulativeStartKm;
    }
    if (globalIndex >= allPoints.length - 1) {
      return useGps ? totalGpsDistanceKm : totalDistanceKm;
    }

    final seg = segmentAtPointIndex(globalIndex);
    if (seg == null) {
      TripSegment? fallback;
      for (final candidate in segments) {
        if (candidate.hasPoints && candidate.startPointIndex <= globalIndex) {
          fallback = candidate;
        }
      }
      if (fallback == null) return 0.0;
      return useGps ? fallback.cumulativeGpsEndKm : fallback.cumulativeEndKm;
    }

    final segStart = useGps ? seg.cumulativeGpsStartKm : seg.cumulativeStartKm;
    final segEnd = useGps ? seg.cumulativeGpsEndKm : seg.cumulativeEndKm;
    final span = seg.endPointIndex - seg.startPointIndex;
    if (span <= 0) {
      return segEnd;
    }
    final localOffset = (globalIndex - seg.startPointIndex).clamp(0, span);
    final fraction = localOffset / span;
    return segStart + (segEnd - segStart) * fraction;
  }

  /// Tạo [MergedTripSession] từ danh sách [trips] (tự sắp xếp theo thứ tự thời gian tăng dần).
  factory MergedTripSession.fromTrips({
    required List<TripRecord> trips,
    required Map<String, List<TripGpsPoint>> routesByTripId,
    TripMergeMode mode = TripMergeMode.customChain,
    String? customTitle,
  }) {
    if (trips.isEmpty) {
      return MergedTripSession(
        id: 'merged_${mode.name}_empty',
        title: (customTitle != null && customTitle.trim().isNotEmpty)
            ? customTitle.trim()
            : _defaultTitle(mode, const []),
        mode: mode,
        segments: const [],
        allPoints: const [],
        segmentStartIndices: const [],
        stopovers: const [],
      );
    }

    final sortedTrips = List<TripRecord>.from(trips)
      ..sort((a, b) {
        final cmp = a.startTime.compareTo(b.startTime);
        if (cmp != 0) return cmp;
        return a.endTime.compareTo(b.endTime);
      });

    final segments = <TripSegment>[];
    final allPoints = <TripGpsPoint>[];
    final segmentStartIndices = <int>[];
    final stopovers = <TripStopover>[];

    double cumulativeKm = 0.0;
    double cumulativeGpsKm = 0.0;
    TripSegment? lastSegmentWithPoints;
    TripSegment? prevSegment;

    for (var i = 0; i < sortedTrips.length; i++) {
      final trip = sortedTrips[i];
      final rawPoints = routesByTripId[trip.id] ?? trip.route;
      final points = List<TripGpsPoint>.unmodifiable(rawPoints);
      final segGpsKm = trip.effectiveGpsDistanceKm(points);
      final segLossCount = points.length >= 2
          ? max(trip.gpsSignalLossCount, GpsRouteAnalyzer.measureRoute(points).signalLossCount)
          : trip.gpsSignalLossCount;

      final int startIdx;
      final int endIdx;
      if (points.isNotEmpty) {
        startIdx = allPoints.length;
        allPoints.addAll(points);
        endIdx = allPoints.length - 1;
      } else {
        startIdx = -1;
        endIdx = -1;
      }
      segmentStartIndices.add(startIdx);

      final cumStart = cumulativeKm;
      final cumEnd = cumulativeKm + trip.distanceKm;
      cumulativeKm = cumEnd;

      final cumGpsStart = cumulativeGpsKm;
      final cumGpsEnd = cumulativeGpsKm + (segGpsKm ?? 0.0);
      cumulativeGpsKm = cumGpsEnd;

      Duration gapBefore = Duration.zero;
      double gapDistanceBeforeMeters = 0.0;

      if (i > 0 && prevSegment != null) {
        final arrivedAt = prevSegment.trip.endTime;
        final departedAt = trip.startTime;
        final rawGap = departedAt.difference(arrivedAt);
        gapBefore = rawGap.isNegative ? Duration.zero : rawGap;

        if (lastSegmentWithPoints != null && points.isNotEmpty) {
          final p1 = lastSegmentWithPoints.points.last;
          final p2 = points.first;
          gapDistanceBeforeMeters = GpsGeoMath.distanceMeters(p1.lat, p1.lng, p2.lat, p2.lng);
        }

        final hasTimeGap = gapBefore > Duration.zero;
        final hasSpaceGap = gapDistanceBeforeMeters > 0.0;
        if (hasTimeGap || hasSpaceGap) {
          TripGpsPoint? stopLocation;
          int afterGlobalIdx = -1;

          if (prevSegment.hasPoints) {
            stopLocation = prevSegment.points.last;
            afterGlobalIdx = prevSegment.endPointIndex;
          } else if (lastSegmentWithPoints != null) {
            stopLocation = lastSegmentWithPoints.points.last;
            afterGlobalIdx = lastSegmentWithPoints.endPointIndex;
          } else if (points.isNotEmpty) {
            stopLocation = points.first;
            afterGlobalIdx = startIdx;
          }

          if (stopLocation != null) {
            stopovers.add(
              TripStopover(
                index: stopovers.length + 1,
                location: stopLocation,
                arrivedAt: arrivedAt,
                departedAt: departedAt,
                duration: gapBefore,
                gapDistanceMeters: gapDistanceBeforeMeters,
                afterGlobalPointIndex: afterGlobalIdx,
              ),
            );
          }
        }
      }

      final segment = TripSegment(
        segmentIndex: i,
        displayOrder: i + 1,
        trip: trip,
        points: points,
        startPointIndex: startIdx,
        endPointIndex: endIdx,
        cumulativeStartKm: cumStart,
        cumulativeEndKm: cumEnd,
        gpsDistanceKm: segGpsKm,
        cumulativeGpsStartKm: cumGpsStart,
        cumulativeGpsEndKm: cumGpsEnd,
        gpsSignalLossCount: segLossCount,
        gapBefore: gapBefore,
        gapDistanceBeforeMeters: gapDistanceBeforeMeters,
      );

      segments.add(segment);
      prevSegment = segment;
      if (segment.hasPoints) {
        lastSegmentWithPoints = segment;
      }
    }

    final resolvedTitle = (customTitle != null && customTitle.trim().isNotEmpty)
        ? customTitle.trim()
        : _defaultTitle(mode, sortedTrips);

    final sessionId = sortedTrips.length == 1
        ? sortedTrips.first.id
        : 'merged_${mode.name}_${sortedTrips.first.startTime.millisecondsSinceEpoch}_${sortedTrips.last.endTime.millisecondsSinceEpoch}_${sortedTrips.length}';

    return MergedTripSession(
      id: sessionId,
      title: resolvedTitle,
      mode: mode,
      segments: List<TripSegment>.unmodifiable(segments),
      allPoints: List<TripGpsPoint>.unmodifiable(allPoints),
      segmentStartIndices: List<int>.unmodifiable(segmentStartIndices),
      stopovers: List<TripStopover>.unmodifiable(stopovers),
    );
  }

  static String _defaultTitle(TripMergeMode mode, List<TripRecord> sortedTrips) {
    switch (mode) {
      case TripMergeMode.single:
        return 'Hành trình';
      case TripMergeMode.byDay:
        if (sortedTrips.isEmpty) return 'Hành trình theo ngày';
        final local = sortedTrips.first.startTime.toLocal();
        final dd = local.day.toString().padLeft(2, '0');
        final mm = local.month.toString().padLeft(2, '0');
        final yyyy = local.year.toString().padLeft(4, '0');
        return 'Ngày $dd/$mm/$yyyy (${sortedTrips.length} chặng)';
      case TripMergeMode.customChain:
        return 'Chuỗi ${sortedTrips.length} hành trình';
    }
  }
}

/// Nhóm các chuyến đi diễn ra trong cùng một ngày (theo giờ địa phương).
class TripDayGroup {
  final DateTime day;
  final List<TripRecord> trips;

  const TripDayGroup({
    required this.day,
    required this.trips,
  });

  List<TripRecord> get chronologicalTrips {
    final sorted = List<TripRecord>.from(trips)
      ..sort((a, b) {
        final cmp = a.startTime.compareTo(b.startTime);
        if (cmp != 0) return cmp;
        return a.endTime.compareTo(b.endTime);
      });
    return sorted;
  }

  int get tripCount => trips.length;

  double get totalDistanceKm =>
      trips.fold<double>(0.0, (sum, t) => sum + t.distanceKm);

  double get totalGpsDistanceKm =>
      trips.fold<double>(0.0, (sum, t) => sum + (t.effectiveGpsDistanceKm() ?? 0.0));

  bool get hasGpsDistance =>
      trips.any((t) => t.effectiveGpsDistanceKm() != null);

  int get totalMovingDurationSec =>
      trips.fold<int>(0, (sum, t) => sum + t.durationSec);

  int get totalUsedPercent =>
      trips.fold<int>(0, (sum, t) => sum + (t.usedPercent > 0 ? t.usedPercent : 0));

  double get maxSpeedKmh =>
      trips.isEmpty ? 0.0 : trips.fold<double>(0.0, (m, t) => max(m, t.maxSpeedKmh));

  String get dateKey {
    final yyyy = day.year.toString().padLeft(4, '0');
    final mm = day.month.toString().padLeft(2, '0');
    final dd = day.day.toString().padLeft(2, '0');
    return '$yyyy-$mm-$dd';
  }

  String formatDateLabel({DateTime? now}) {
    final ref = (now ?? DateTime.now()).toLocal();
    final today = DateTime(ref.year, ref.month, ref.day);
    final yesterday = DateTime(today.year, today.month, today.day - 1);
    final localDay = DateTime(day.year, day.month, day.day);

    final dd = localDay.day.toString().padLeft(2, '0');
    final mm = localDay.month.toString().padLeft(2, '0');
    final yyyy = localDay.year.toString().padLeft(4, '0');
    final dateStr = '$dd/$mm/$yyyy';

    if (localDay == today) return 'Hôm nay · $dateStr';
    if (localDay == yesterday) return 'Hôm qua · $dateStr';
    return dateStr;
  }

  /// Nhóm danh sách chuyến đi theo ngày (ngày mới nhất đứng đầu).
  static List<TripDayGroup> groupTripsByDay(List<TripRecord> allTrips) {
    if (allTrips.isEmpty) return const [];

    final grouped = <DateTime, List<TripRecord>>{};
    for (final trip in allTrips) {
      final local = trip.startTime.toLocal();
      final normalized = DateTime(local.year, local.month, local.day);
      grouped.putIfAbsent(normalized, () => <TripRecord>[]).add(trip);
    }

    final result = grouped.entries
        .map((entry) => TripDayGroup(day: entry.key, trips: entry.value))
        .toList()
      ..sort((a, b) => b.day.compareTo(a.day));

    return result;
  }
}

/// Chuỗi ghép hành trình đã lưu để người dùng mở lại nhanh từ lịch sử.
class SavedMergedTripChain {
  final String id;
  final String title;
  final DateTime createdAt;
  final List<String> tripIds;
  final TripMergeMode mode;

  const SavedMergedTripChain({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.tripIds,
    this.mode = TripMergeMode.customChain,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'tripIds': tripIds,
        'mode': mode.name,
      };

  factory SavedMergedTripChain.fromJson(Map<String, dynamic> json) {
    final modeName = json['mode'] as String?;
    final parsedMode = TripMergeMode.values.firstWhere(
      (m) => m.name == modeName,
      orElse: () => TripMergeMode.customChain,
    );
    final rawIds = (json['tripIds'] as List<dynamic>?) ?? const [];
    return SavedMergedTripChain(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? 'Chuỗi hành trình',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
      tripIds: rawIds.map((e) => e.toString()).toList(),
      mode: parsedMode,
    );
  }
}
