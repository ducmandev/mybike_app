import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/trip_gps_point.dart';

/// Tiện ích tính toán địa lý thuần Dart dùng chung cho đo quãng đường & hướng đi.
abstract final class GpsGeoMath {
  static const double _earthRadiusMeters = 6371000.0;

  static double _degToRad(double deg) => deg * (math.pi / 180.0);

  /// Khoảng cách Haversine (mét) giữa 2 tọa độ WGS84.
  static double distanceMeters(
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) {
    final dLat = _degToRad(lat2 - lat1);
    final dLng = _degToRad(lng2 - lng1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_degToRad(lat1)) *
            math.cos(_degToRad(lat2)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    final clampedA = a.clamp(0.0, 1.0);
    final c = 2 * math.atan2(math.sqrt(clampedA), math.sqrt(1 - clampedA));
    return _earthRadiusMeters * c;
  }

  /// Góc phương vị (0°..360°) từ `(lat1, lng1)` hướng tới `(lat2, lng2)`.
  static double bearingDegrees(
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) {
    final phi1 = _degToRad(lat1);
    final phi2 = _degToRad(lat2);
    final deltaLambda = _degToRad(lng2 - lng1);

    final y = math.sin(deltaLambda) * math.cos(phi2);
    final x = math.cos(phi1) * math.sin(phi2) -
        math.sin(phi1) * math.cos(phi2) * math.cos(deltaLambda);

    final theta = math.atan2(y, x);
    return (theta * 180.0 / math.pi + 360.0) % 360.0;
  }
}

/// Kết quả đo quãng đường GPS thực tế sau khi xử lý tách đoạn mất sóng / nắn đường.
class GpsRouteMetrics {
  /// Tổng quãng đường GPS thực tế (km) — đã loại bỏ mọi đoạn mất sóng / nhảy nhiễu.
  final double distanceKm;

  /// Tổng độ dài các đoạn chim bay bị loại trừ do mất sóng GPS (km).
  final double excludedGapDistanceKm;

  /// Số lần lộ trình bị gián đoạn sóng GPS.
  final int signalLossCount;

  /// Các chặng con liên tục có tín hiệu GPS ổn định (ngăn cách tại các điểm mất sóng).
  final List<List<TripGpsPoint>> subTracks;

  /// Đã được nắn theo hình học mặt đường (OSRM Map Matching) hay chưa.
  final bool isRoadSnapped;

  const GpsRouteMetrics({
    required this.distanceKm,
    required this.excludedGapDistanceKm,
    required this.signalLossCount,
    required this.subTracks,
    this.isRoadSnapped = false,
  });

  static const GpsRouteMetrics empty = GpsRouteMetrics(
    distanceKm: 0.0,
    excludedGapDistanceKm: 0.0,
    signalLossCount: 0,
    subTracks: [],
    isRoadSnapped: false,
  );
}

/// Kết quả trả về của quá trình nắn đường & tính KM GPS.
class GpsSnapResult {
  final List<TripGpsPoint> points;
  final GpsRouteMetrics metrics;

  const GpsSnapResult({
    required this.points,
    required this.metrics,
  });
}

/// Bộ phân tích lộ trình GPS: tách đoạn mất sóng GPS và đo quãng đường thực tế trên bản đồ.
class GpsRouteAnalyzer {
  GpsRouteAnalyzer._();

  /// Khoảng gián đoạn > 15 giây trong khi dịch chuyển > 45m được xem là mất sóng GPS.
  static const int kSignalLossGapSeconds = 15;
  static const double kSignalLossMinJumpMeters = 45.0;
  static const double kMaxRealisticSpeedKmh = 110.0;

  /// Kiểm tra giữa 2 điểm GPS liên tiếp [prev] và [cur] có xảy ra đứt quãng / mất sóng hay không.
  ///
  /// Lưu ý: Nếu xe đứng chờ đèn đỏ lâu (> 15s) tại cùng một ngã tư (dịch chuyển <= 45m)
  /// và không có cờ [TripGpsPoint.isSignalLossRestart], hàm vẫn coi là lộ trình liên tục.
  static bool isSignalGap(TripGpsPoint prev, TripGpsPoint cur) {
    if (cur.isSignalLossRestart) return true;

    final dtSec = cur.timestamp.difference(prev.timestamp).inMilliseconds / 1000.0;
    final distMeters = GpsGeoMath.distanceMeters(prev.lat, prev.lng, cur.lat, cur.lng);

    if (dtSec > kSignalLossGapSeconds && distMeters > kSignalLossMinJumpMeters) {
      return true;
    }

    if (dtSec > 0.05 && dtSec <= kSignalLossGapSeconds) {
      final impliedSpeedKmh = (distMeters / dtSec) * 3.6;
      if (impliedSpeedKmh > kMaxRealisticSpeedKmh) {
        return true;
      }
    }
    return false;
  }

  /// Tách danh sách [points] thành từng chặng con liên tục tại các ranh giới mất sóng GPS.
  static List<List<TripGpsPoint>> splitContinuousSubTracks(List<TripGpsPoint> points) {
    if (points.isEmpty) return const [];

    final subTracks = <List<TripGpsPoint>>[];
    var current = <TripGpsPoint>[points.first];

    for (var i = 1; i < points.length; i++) {
      final prev = points[i - 1];
      final cur = points[i];
      if (isSignalGap(prev, cur)) {
        subTracks.add(List<TripGpsPoint>.unmodifiable(current));
        current = <TripGpsPoint>[cur];
      } else {
        current.add(cur);
      }
    }
    if (current.isNotEmpty) {
      subTracks.add(List<TripGpsPoint>.unmodifiable(current));
    }
    return List<List<TripGpsPoint>>.unmodifiable(subTracks);
  }

  /// Tính tổng chiều dài (mét) bên trong một chặng liên tục.
  static double measureSubTrackDistanceMeters(List<TripGpsPoint> subTrack) {
    if (subTrack.length < 2) return 0.0;
    var meters = 0.0;
    for (var i = 0; i < subTrack.length - 1; i++) {
      meters += GpsGeoMath.distanceMeters(
        subTrack[i].lat,
        subTrack[i].lng,
        subTrack[i + 1].lat,
        subTrack[i + 1].lng,
      );
    }
    return meters;
  }

  /// Đo toàn bộ chỉ số lộ trình GPS, tự động trừ mọi đoạn bị mất sóng GPS.
  static GpsRouteMetrics measureRoute(
    List<TripGpsPoint> points, {
    bool isRoadSnapped = false,
  }) {
    if (points.length < 2) {
      return points.isEmpty
          ? GpsRouteMetrics.empty
          : GpsRouteMetrics(
              distanceKm: 0.0,
              excludedGapDistanceKm: 0.0,
              signalLossCount: 0,
              subTracks: [List<TripGpsPoint>.unmodifiable(points)],
              isRoadSnapped: isRoadSnapped,
            );
    }

    final subTracks = splitContinuousSubTracks(points);
    var totalMeters = 0.0;
    for (final sub in subTracks) {
      totalMeters += measureSubTrackDistanceMeters(sub);
    }

    var excludedGapMeters = 0.0;
    for (var i = 0; i < subTracks.length - 1; i++) {
      final prevLast = subTracks[i].last;
      final nextFirst = subTracks[i + 1].first;
      excludedGapMeters += GpsGeoMath.distanceMeters(
        prevLast.lat,
        prevLast.lng,
        nextFirst.lat,
        nextFirst.lng,
      );
    }

    return GpsRouteMetrics(
      distanceKm: totalMeters / 1000.0,
      excludedGapDistanceKm: excludedGapMeters / 1000.0,
      signalLossCount: math.max(0, subTracks.length - 1),
      subTracks: subTracks,
      isRoadSnapped: isRoadSnapped,
    );
  }
}

/// Dịch vụ tự động nắn lộ trình GPS bám theo mạng lưới đường thực tế (OSRM Map Matching).
///
/// Thiết kế an toàn hai tầng:
/// - Trước khi nắn đường, luôn tách lộ trình thành các chặng liên tục tại điểm mất sóng GPS
///   để không bao giờ bắc cầu đường thẳng qua hầm / vùng mất tín hiệu.
/// - Nếu có mạng & OSRM `/match/v1/driving/` phản hồi hợp lệ (đạt sanity bounds), trả về
///   tọa độ đã nắn đường (giữ nguyên mốc thời gian và tốc độ thực tế theo tỷ lệ chiều dài)
///   cùng chỉ số `distanceKm` chính xác theo mặt đường.
/// - Nếu mất mạng hoặc API lỗi: fallback an toàn sang quãng đường GPS thực tế đã trừ đoạn mất sóng.
class GpsRouteSnappingService {
  GpsRouteSnappingService._();
  static final GpsRouteSnappingService instance = GpsRouteSnappingService._();

  static const int _maxChunkPoints = 75;
  static const List<String> _osrmMatchBases = [
    'https://router.project-osrm.org/match/v1/driving',
    'https://routing.openstreetmap.de/routed-car/match/v1/driving',
  ];

  /// Nắn toàn bộ lộ trình [points] bám đường bộ (nếu online) và luôn trừ đoạn mất sóng GPS.
  ///
  /// Có thể truyền [httpClient] tùy chọn để kiểm thử đơn vị deterministically.
  Future<GpsSnapResult> snapRouteToRoads(
    List<TripGpsPoint> points, {
    http.Client? httpClient,
  }) async {
    if (points.length < 2) {
      return GpsSnapResult(
        points: List<TripGpsPoint>.from(points),
        metrics: GpsRouteAnalyzer.measureRoute(points),
      );
    }

    final rawMetrics = GpsRouteAnalyzer.measureRoute(points);
    final isTestEnv = Platform.environment.containsKey('FLUTTER_TEST');
    if (isTestEnv && httpClient == null) {
      return GpsSnapResult(
        points: List<TripGpsPoint>.from(points),
        metrics: rawMetrics,
      );
    }

    final ownsClient = httpClient == null;
    final client = httpClient ?? http.Client();
    try {
      final resultSubTracks = <List<TripGpsPoint>>[];
      var anySubTrackSnapped = false;
      var snappedMetersTotal = 0.0;

      for (var subIdx = 0; subIdx < rawMetrics.subTracks.length; subIdx++) {
        final subTrack = rawMetrics.subTracks[subIdx];
        final rawSubMeters = GpsRouteAnalyzer.measureSubTrackDistanceMeters(subTrack);

        List<TripGpsPoint>? matchedSub;
        double? matchedSubMeters;

        if (subTrack.length >= 2 && rawSubMeters >= 25.0) {
          final matched = await _matchSubTrackWithChunking(
            subTrack,
            rawSubMeters: rawSubMeters,
            client: client,
          );
          if (matched != null && matched.points.length >= 2) {
            matchedSub = matched.points;
            matchedSubMeters = matched.distanceMeters;
            anySubTrackSnapped = true;
          }
        }

        final chosenPoints = (matchedSub ?? subTrack).toList();
        if (subIdx > 0 && chosenPoints.isNotEmpty) {
          chosenPoints[0] = chosenPoints[0].copyWith(isSignalLossRestart: true);
        } else if (subIdx == 0 && chosenPoints.isNotEmpty) {
          chosenPoints[0] = chosenPoints[0].copyWith(isSignalLossRestart: false);
        }

        resultSubTracks.add(List<TripGpsPoint>.unmodifiable(chosenPoints));
        snappedMetersTotal += matchedSubMeters ?? rawSubMeters;
      }

      final flattened = resultSubTracks.expand((s) => s).toList();
      final finalMetrics = GpsRouteMetrics(
        distanceKm: snappedMetersTotal / 1000.0,
        excludedGapDistanceKm: rawMetrics.excludedGapDistanceKm,
        signalLossCount: rawMetrics.signalLossCount,
        subTracks: List<List<TripGpsPoint>>.unmodifiable(resultSubTracks),
        isRoadSnapped: anySubTrackSnapped,
      );

      return GpsSnapResult(
        points: flattened,
        metrics: finalMetrics,
      );
    } catch (e) {
      debugPrint('[GpsRouteSnappingService] Lỗi nắn đường OSRM (dùng GPS đã trừ mất sóng): $e');
      return GpsSnapResult(
        points: List<TripGpsPoint>.from(points),
        metrics: rawMetrics,
      );
    } finally {
      if (ownsClient) {
        client.close();
      }
    }
  }

  Future<({List<TripGpsPoint> points, double distanceMeters})?> _matchSubTrackWithChunking(
    List<TripGpsPoint> subTrack, {
    required double rawSubMeters,
    required http.Client client,
  }) async {
    if (subTrack.length <= _maxChunkPoints) {
      return _matchSingleChunk(
        subTrack,
        rawChunkMeters: rawSubMeters,
        client: client,
      );
    }

    final mergedPoints = <TripGpsPoint>[];
    var totalMatchedMeters = 0.0;
    var start = 0;

    while (start < subTrack.length) {
      final end = math.min(start + _maxChunkPoints, subTrack.length);
      final chunk = subTrack.sublist(start, end);
      if (chunk.length < 2) break;

      final rawChunkMeters = GpsRouteAnalyzer.measureSubTrackDistanceMeters(chunk);
      final matched = await _matchSingleChunk(
        chunk,
        rawChunkMeters: rawChunkMeters,
        client: client,
      );

      final chunkResultPts = matched?.points ?? chunk;
      final chunkMeters = matched?.distanceMeters ?? rawChunkMeters;

      if (mergedPoints.isEmpty) {
        mergedPoints.addAll(chunkResultPts);
        totalMatchedMeters += chunkMeters;
      } else {
        // Loại điểm nối trùng ở biên giữa 2 chunk gối đầu
        final tail = mergedPoints.last;
        var skipIdx = 0;
        if (chunkResultPts.isNotEmpty) {
          final joinDist = GpsGeoMath.distanceMeters(
            tail.lat,
            tail.lng,
            chunkResultPts.first.lat,
            chunkResultPts.first.lng,
          );
          if (joinDist < 3.0) {
            skipIdx = 1;
          }
        }
        final tailSlice = chunkResultPts.sublist(skipIdx);
        mergedPoints.addAll(tailSlice);
        totalMatchedMeters += chunkMeters;
      }

      if (end >= subTrack.length) break;
      start = end - 1; // Gối 1 điểm liên kết
    }

    if (mergedPoints.length < 2) return null;
    final stitchedMeters = GpsRouteAnalyzer.measureSubTrackDistanceMeters(mergedPoints);
    final finalMeters = (stitchedMeters > 0 && stitchedMeters.isFinite)
        ? stitchedMeters
        : totalMatchedMeters;

    if (!_passesDistanceSanity(rawSubMeters, finalMeters)) {
      return null;
    }

    return (points: mergedPoints, distanceMeters: finalMeters);
  }

  Future<({List<TripGpsPoint> points, double distanceMeters})?> _matchSingleChunk(
    List<TripGpsPoint> chunk, {
    required double rawChunkMeters,
    required http.Client client,
  }) async {
    final coordStr = chunk.map((p) => '${p.lng.toStringAsFixed(6)},${p.lat.toStringAsFixed(6)}').join(';');
    final radiiStr = List<String>.filled(chunk.length, '25').join(';');

    // Đảm bảo timestamps tăng chặt cho OSRM Map Matching
    final tsSeconds = <int>[];
    for (final pt in chunk) {
      var sec = pt.timestamp.millisecondsSinceEpoch ~/ 1000;
      if (tsSeconds.isNotEmpty && sec <= tsSeconds.last) {
        sec = tsSeconds.last + 1;
      }
      tsSeconds.add(sec);
    }
    final tsStr = tsSeconds.join(';');

    for (final base in _osrmMatchBases) {
      try {
        final uri = Uri.parse(
          '$base/$coordStr?geometries=geojson&overview=full&tidy=true&gaps=ignore&timestamps=$tsStr&radiuses=$radiiStr',
        );
        final res = await client.get(uri, headers: const {
          'User-Agent': 'DatBikeApp/2.6.50 (mobile-app; contact@dat.bike)',
        }).timeout(const Duration(seconds: 4));

        if (res.statusCode != 200) continue;

        final decoded = jsonDecode(res.body);
        if (decoded is! Map<String, dynamic>) continue;
        if (decoded['code'] != 'Ok') continue;

        final matchings = decoded['matchings'] as List<dynamic>?;
        if (matchings == null || matchings.isEmpty) continue;

        final rawSnappedLatLngs = <({double lat, double lng})>[];
        var apiDistanceSum = 0.0;

        for (final m in matchings) {
          if (m is! Map<String, dynamic>) continue;
          final dist = (m['distance'] as num?)?.toDouble() ?? 0.0;
          final geom = m['geometry'] as Map<String, dynamic>?;
          final coords = geom?['coordinates'] as List<dynamic>?;
          if (coords == null || coords.length < 2) continue;

          if (dist > 0) apiDistanceSum += dist;

          for (var k = 0; k < coords.length; k++) {
            final pair = coords[k] as List<dynamic>;
            if (pair.length < 2) continue;
            final lng = (pair[0] as num).toDouble();
            final lat = (pair[1] as num).toDouble();
            if (rawSnappedLatLngs.isNotEmpty) {
              final prev = rawSnappedLatLngs.last;
              final d = GpsGeoMath.distanceMeters(prev.lat, prev.lng, lat, lng);
              if (d < 0.5) continue;
            }
            rawSnappedLatLngs.add((lat: lat, lng: lng));
          }
        }

        if (rawSnappedLatLngs.length < 2) continue;

        final snappedPoints = _projectSpeedAndTimeAlongPath(
          source: chunk,
          targetLatLngs: rawSnappedLatLngs,
        );
        final geoMeters = GpsRouteAnalyzer.measureSubTrackDistanceMeters(snappedPoints);
        final chosenMeters = apiDistanceSum > 0 ? apiDistanceSum : geoMeters;

        if (!_passesDistanceSanity(rawChunkMeters, chosenMeters)) {
          continue;
        }
        // Chống OSRM cộng gộp nhiều matchings bị đứt gãy vượt xa hình học đường vẽ thực tế
        if (apiDistanceSum > 0 && geoMeters > 0 && apiDistanceSum > geoMeters * 1.35) {
          continue;
        }

        return (points: snappedPoints, distanceMeters: chosenMeters);
      } catch (_) {
        // Thử endpoint OSRM dự phòng tiếp theo
      }
    }

    return null;
  }

  static bool _passesDistanceSanity(double rawMeters, double matchedMeters) {
    if (!matchedMeters.isFinite || matchedMeters <= 0) return false;
    if (rawMeters < 50.0) return matchedMeters <= rawMeters * 1.45 + 25.0;
    return matchedMeters >= rawMeters * 0.65 && matchedMeters <= rawMeters * 1.40;
  }

  /// Nội suy tốc độ, độ cao và timestamp giữ nguyên thứ tự thời gian từ [source]
  /// dọc theo tỷ lệ cung tích lũy của chuỗi đỉnh đã nắn [targetLatLngs].
  static List<TripGpsPoint> _projectSpeedAndTimeAlongPath({
    required List<TripGpsPoint> source,
    required List<({double lat, double lng})> targetLatLngs,
  }) {
    if (source.isEmpty || targetLatLngs.isEmpty) return const [];
    if (targetLatLngs.length == 1) {
      return [
        source.first.copyWith(
          lat: double.parse(targetLatLngs.first.lat.toStringAsFixed(6)),
          lng: double.parse(targetLatLngs.first.lng.toStringAsFixed(6)),
        ),
      ];
    }

    final srcFractions = _cumulativeFractions(
      source.map((p) => (lat: p.lat, lng: p.lng)).toList(),
    );
    final dstFractions = _cumulativeFractions(targetLatLngs);

    final out = <TripGpsPoint>[];
    var srcCursor = 0;

    for (var i = 0; i < targetLatLngs.length; i++) {
      final f = dstFractions[i];
      while (srcCursor < srcFractions.length - 2 && srcFractions[srcCursor + 1] < f) {
        srcCursor++;
      }

      final a = source[srcCursor];
      final b = source[math.min(srcCursor + 1, source.length - 1)];
      final span = srcFractions[math.min(srcCursor + 1, srcFractions.length - 1)] -
          srcFractions[srcCursor];
      final localT = span > 1e-6 ? ((f - srcFractions[srcCursor]) / span).clamp(0.0, 1.0) : 0.0;

      final speed = a.speedKmh + (b.speedKmh - a.speedKmh) * localT;
      final tsMsA = a.timestamp.millisecondsSinceEpoch;
      final tsMsB = b.timestamp.millisecondsSinceEpoch;
      var interpMs = (tsMsA + ((tsMsB - tsMsA) * localT)).round();
      if (out.isNotEmpty && interpMs < out.last.timestamp.millisecondsSinceEpoch) {
        interpMs = out.last.timestamp.millisecondsSinceEpoch;
      }

      double? altitude;
      if (a.altitude != null && b.altitude != null) {
        altitude = double.parse(
          (a.altitude! + (b.altitude! - a.altitude!) * localT).toStringAsFixed(1),
        );
      } else {
        altitude = a.altitude ?? b.altitude;
      }

      double? heading;
      if (i > 0) {
        heading = double.parse(
          GpsGeoMath.bearingDegrees(
            targetLatLngs[i - 1].lat,
            targetLatLngs[i - 1].lng,
            targetLatLngs[i].lat,
            targetLatLngs[i].lng,
          ).toStringAsFixed(1),
        );
      } else {
        heading = double.parse(
          GpsGeoMath.bearingDegrees(
            targetLatLngs[0].lat,
            targetLatLngs[0].lng,
            targetLatLngs[1].lat,
            targetLatLngs[1].lng,
          ).toStringAsFixed(1),
        );
      }

      out.add(
        TripGpsPoint(
          lat: double.parse(targetLatLngs[i].lat.toStringAsFixed(6)),
          lng: double.parse(targetLatLngs[i].lng.toStringAsFixed(6)),
          speedKmh: double.parse(speed.toStringAsFixed(1)),
          timestamp: DateTime.fromMillisecondsSinceEpoch(
            interpMs,
            isUtc: a.timestamp.isUtc,
          ),
          altitude: altitude,
          heading: heading,
          isSignalLossRestart: i == 0 && source.first.isSignalLossRestart,
        ),
      );
    }

    return out;
  }

  static List<double> _cumulativeFractions(
    List<({double lat, double lng})> coords,
  ) {
    final n = coords.length;
    if (n <= 1) return const [0.0];
    final cum = List<double>.filled(n, 0.0);
    for (var i = 1; i < n; i++) {
      cum[i] = cum[i - 1] +
          GpsGeoMath.distanceMeters(
            coords[i - 1].lat,
            coords[i - 1].lng,
            coords[i].lat,
            coords[i].lng,
          );
    }
    final total = cum.last;
    if (total <= 1e-6) {
      return List<double>.generate(n, (i) => i / (n - 1));
    }
    return cum.map((d) => (d / total).clamp(0.0, 1.0)).toList();
  }
}
