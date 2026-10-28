import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/trip_gps_point.dart';

/// Bộ lọc Kalman 2D tối ưu hóa cho định vị GPS xe máy điện Dat Bike.
/// Khử triệt để hiện tượng trôi vị trí (GPS drift), nhiễu đa đường (multipath),
/// và làm mượt tọa độ di chuyển theo thời gian thực.
class GpsKalmanFilter2D {
  double? _lat;
  double? _lng;
  double _variance = -1.0;
  DateTime? _lastTimestamp;

  bool get isInitialized => _lat != null && _lng != null;
  double? get lat => _lat;
  double? get lng => _lng;

  void reset() {
    _lat = null;
    _lng = null;
    _variance = -1.0;
    _lastTimestamp = null;
  }

  /// Lọc mượt tọa độ GPS dựa trên độ chính xác đo lường (accuracy tính theo mét) và vận tốc xe
  void filter({
    required double measuredLat,
    required double measuredLng,
    required double accuracyMeters,
    required double speedMps,
    required DateTime timestamp,
  }) {
    final safeAccuracy = accuracyMeters > 0 ? accuracyMeters : 10.0;
    final measurementNoise = safeAccuracy * safeAccuracy; // R (hiệp phương sai đo lường)

    if (!isInitialized || _lastTimestamp == null) {
      _lat = measuredLat;
      _lng = measuredLng;
      _variance = measurementNoise;
      _lastTimestamp = timestamp;
      return;
    }

    final dtSec = timestamp.difference(_lastTimestamp!).inMilliseconds / 1000.0;
    _lastTimestamp = timestamp;
    if (dtSec <= 0) return;

    // 1. Dự đoán (Predict step)
    // Q = (v * dt)^2: Sai số quá trình tỷ lệ với quãng đường xe có thể di chuyển
    final effectiveSpeed = speedMps > 0.5 ? speedMps : 0.5;
    final processNoise = (effectiveSpeed * dtSec) * (effectiveSpeed * dtSec);
    final pPredicted = _variance + processNoise;

    // 2. Hiệu chỉnh (Update step qua Kalman Gain)
    final kalmanGain = pPredicted / (pPredicted + measurementNoise);

    _lat = _lat! + kalmanGain * (measuredLat - _lat!);
    _lng = _lng! + kalmanGain * (measuredLng - _lng!);
    _variance = (1.0 - kalmanGain) * pPredicted;
  }
}

/// Quản lý việc ghi lại lộ trình GPS trong suốt chuyến đi xe máy điện Dat Bike.
/// Tích hợp hệ thống lọc đa tầng:
/// 1. Lọc ngưỡng độ chính xác (Accuracy Gate): Loại bỏ các vị trí sai số > 25m
/// 2. Lọc đột biến vận tốc (Speed Spike Filter): Loại bỏ các điểm nhảy teleportation > 110 km/h
/// 3. Khử nhiễu khi xe đứng yên (Stationary Jitter Suppression): Chống vẽ hình tổ quạ ziczac tại đèn đỏ
/// 4. Bộ lọc Kalman 2D: Làm mượt tọa độ mượt mà theo mặt đường
/// 5. Tính toán hướng di chuyển (Geodesic Heading Calculation)
class TripGpsTracker {
  TripGpsTracker._();
  static final TripGpsTracker instance = TripGpsTracker._();

  StreamSubscription<Position>? _positionSub;
  final List<TripGpsPoint> _recordedPoints = [];
  final StreamController<TripGpsPoint> _pointController = StreamController<TripGpsPoint>.broadcast();

  bool _isTracking = false;
  bool _isDriveMode = false;
  double _lastKnownBikeSpeed = 0.0;
  DateTime? _lastPointTime;
  Position? _lastPosition;
  TripGpsPoint? _lastFilteredPoint;
  DateTime? _lastPersistTime;

  static const String _kActiveGpsPointsKey = 'active_trip_gps_points_cache';
  static const String _kActiveGpsTimeKey = 'active_trip_gps_last_time';

  final GpsKalmanFilter2D _kalmanFilter = GpsKalmanFilter2D();

  // Ngưỡng cấu hình an toàn cho xe máy Dat Bike
  static const double kMaxAcceptableAccuracyMeters = 25.0; // Bỏ qua nếu sai số > 25m
  static const double kMaxRealisticSpeedKmh = 110.0;       // Vận tốc vật lý tối đa của xe
  static const double kStationarySpeedKmh = 1.0;           // Ngưỡng xem là đang đứng yên
  static const double kStationaryMinDistanceMeters = 6.0;  // Bán kính nhiễu khi đứng yên
  static const double kMovingMinDistanceMeters = 2.5;      // Khoảng cách tối thiểu giữa 2 điểm khi chạy
  static const int kMinIntervalMs = 1200;                  // Tần suất lấy điểm tối đa ~1.2s

  bool get isTracking => _isTracking;
  bool get isDriveMode => _isDriveMode;
  List<TripGpsPoint> get recordedPoints => List.unmodifiable(_recordedPoints);
  Stream<TripGpsPoint> get onPointRecorded => _pointController.stream;
  Position? get lastPosition => _lastPosition;
  TripGpsPoint? get currentPoint => _recordedPoints.isNotEmpty ? _recordedPoints.last : null;

  /// Cập nhật chế độ lái xe (D hoặc S và không gạt chân chống)
  void setDriveMode(bool active) {
    if (_isDriveMode != active) {
      _isDriveMode = active;
      debugPrint('[TripGpsTracker] Trạng thái ghi nhận chế độ lái D/S: $active');
    }
  }

  /// Tự động lưu bộ nhớ đệm GPS định kỳ vào SharedPreferences để chống mất lộ trình khi vuốt/kill app
  Future<void> _persistPointsDebounced() async {
    final now = DateTime.now();
    if (_lastPersistTime != null && now.difference(_lastPersistTime!).inSeconds < 4) {
      return;
    }
    _lastPersistTime = now;
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawList = _recordedPoints.map((p) => p.toJson()).toList();
      await prefs.setString(_kActiveGpsPointsKey, jsonEncode(rawList));
      await prefs.setString(_kActiveGpsTimeKey, now.toIso8601String());
    } catch (e) {
      debugPrint('[TripGpsTracker] Lỗi lưu đệm GPS vào SharedPreferences: $e');
    }
  }

  /// Khôi phục các điểm GPS đang ghi dở dang nếu người dùng lỡ vuốt tắt app
  Future<void> restoreUnsavedPoints() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedJson = prefs.getString(_kActiveGpsPointsKey);
      final cachedTimeStr = prefs.getString(_kActiveGpsTimeKey);

      if (cachedJson != null && cachedJson.isNotEmpty && cachedTimeStr != null) {
        final lastTime = DateTime.tryParse(cachedTimeStr);
        // Nếu chuyến đi trong vòng 12 tiếng qua thì nạp lại
        if (lastTime != null && DateTime.now().difference(lastTime).inHours < 12) {
          final decoded = jsonDecode(cachedJson) as List<dynamic>;
          final restored = decoded
              .map((item) => TripGpsPoint.fromJson(item as Map<String, dynamic>))
              .toList();
          if (restored.isNotEmpty) {
            _recordedPoints.clear();
            _recordedPoints.addAll(restored);
            _lastFilteredPoint = restored.last;
            debugPrint('[TripGpsTracker] Đã khôi phục thành công ${restored.length} điểm GPS từ bộ nhớ đệm!');
          }
        } else {
          await clearSavedCache();
        }
      }
    } catch (e) {
      debugPrint('[TripGpsTracker] Lỗi khôi phục điểm GPS: $e');
    }
  }

  /// Xóa sạch bộ nhớ đệm điểm GPS dở dang
  Future<void> clearSavedCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kActiveGpsPointsKey);
      await prefs.remove(_kActiveGpsTimeKey);
    } catch (_) {}
  }

  /// Tính tổng quãng đường GPS đã tích lũy của chuyến đi hiện tại (km)
  double get totalDistanceKm {
    if (_recordedPoints.length < 2) return 0.0;
    double totalMeters = 0.0;
    for (int i = 0; i < _recordedPoints.length - 1; i++) {
      totalMeters += Geolocator.distanceBetween(
        _recordedPoints[i].lat,
        _recordedPoints[i].lng,
        _recordedPoints[i + 1].lat,
        _recordedPoints[i + 1].lng,
      );
    }
    return totalMeters / 1000.0;
  }

  /// Cập nhật vận tốc thực tế từ đồng hồ xe (BLE telemetry)
  void updateBikeSpeed(double speedKmh) {
    _lastKnownBikeSpeed = speedKmh >= 0 ? speedKmh : 0.0;
  }

  /// Lấy vị trí GPS hiện tại của người dùng (dùng cho nút "Vị trí của tôi")
  Future<Position?> getCurrentLocation() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return null;

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) return null;
      }
      if (permission == LocationPermission.deniedForever) return null;

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 5),
        ),
      );
      _lastPosition = pos;
      return pos;
    } catch (e) {
      debugPrint('[TripGpsTracker] Lỗi lấy vị trí hiện tại: $e');
      return null;
    }
  }

  /// Bắt đầu ghi GPS cho chuyến đi
  Future<bool> startTracking() async {
    if (_isTracking) return true;

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        debugPrint('[TripGpsTracker] Dịch vụ GPS chưa bật');
        return false;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          debugPrint('[TripGpsTracker] Quyền vị trí bị từ chối');
          return false;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        debugPrint('[TripGpsTracker] Quyền vị trí bị từ chối vĩnh viễn');
        return false;
      }

      _isTracking = true;
      _recordedPoints.clear();
      _lastPointTime = null;
      _lastFilteredPoint = null;
      _kalmanFilter.reset();

      // Lấy ngay vị trí ban đầu (chỉ lấy nếu độ chính xác cao)
      try {
        final initialPos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
        );
        if (initialPos.accuracy <= kMaxAcceptableAccuracyMeters && initialPos.accuracy > 0) {
          _handleNewPosition(initialPos);
        }
      } catch (_) {}

      // Cấu hình tần suất lấy GPS theo từng hệ điều hành
      LocationSettings locationSettings;
      if (defaultTargetPlatform == TargetPlatform.android) {
        locationSettings = AndroidSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 2,
          intervalDuration: const Duration(milliseconds: 1000),
          foregroundNotificationConfig: const ForegroundNotificationConfig(
            notificationTitle: 'My Bike - Theo dõi hành trình',
            notificationText: 'Hệ thống đang ghi nhận lộ trình GPS chuyến đi của bạn liên tục...',
            enableWakeLock: true,
          ),
        );
      } else if (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS) {
        locationSettings = AppleSettings(
          accuracy: LocationAccuracy.high,
          activityType: ActivityType.automotiveNavigation,
          distanceFilter: 2,
          pauseLocationUpdatesAutomatically: true,
        );
      } else {
        locationSettings = const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 2,
        );
      }

      _positionSub = Geolocator.getPositionStream(
        locationSettings: locationSettings,
      ).listen(
        (Position position) {
          _handleNewPosition(position);
        },
        onError: (err) {
          debugPrint('[TripGpsTracker] Lỗi stream GPS: $err');
        },
      );

      debugPrint('[TripGpsTracker] Đã khởi động ghi GPS chuyến đi với bộ lọc Kalman');
      return true;
    } catch (e) {
      debugPrint('[TripGpsTracker] Lỗi khởi động GPS: $e');
      _isTracking = false;
      return false;
    }
  }

  void _handleNewPosition(Position pos) {
    _lastPosition = pos;

    // 0. BỘ LỌC CHẾ ĐỘ LÁI (DRIVE/SUPER MODE GATE)
    // Chỉ ghi nhận GPS khi xe ở chế độ lái D (Drive) hoặc S (Sport/Super) và không gạt chân chống.
    // Khi về P (Parking), tắt máy, hoặc dừng hạ chân chống, ngưng/tạm dừng ghi điểm GPS rác.
    if (!_isDriveMode) {
      return;
    }

    final now = DateTime.now();

    // 1. BỘ LỌC ĐỘ CHÍNH XÁC (Accuracy Filter)
    // Bỏ qua các điểm có sai số lớn (> 25m hoặc âm) do phản xạ nhà cao tầng / cột sóng BTS
    if (pos.accuracy > kMaxAcceptableAccuracyMeters || pos.accuracy <= 0) {
      return;
    }

    // 2. GIỚI HẠN TẦN SUẤT GHI (Time Filter)
    if (_lastPointTime != null && now.difference(_lastPointTime!).inMilliseconds < kMinIntervalMs) {
      return;
    }

    // 3. TÍNH KHOẢNG CÁCH VÀ VẬN TỐC THỰC TẾ
    double distFromLast = 0.0;
    double dtSec = 0.0;
    if (_lastFilteredPoint != null) {
      distFromLast = Geolocator.distanceBetween(
        _lastFilteredPoint!.lat,
        _lastFilteredPoint!.lng,
        pos.latitude,
        pos.longitude,
      );
      dtSec = now.difference(_lastFilteredPoint!.timestamp).inMilliseconds / 1000.0;
    }

    // 4. BỘ LỌC ĐỘT BIẾN / NHẢY VỊ TRÍ PHI LÝ (Speed Spike / Teleportation Filter)
    if (_lastFilteredPoint != null && dtSec > 0.05) {
      final calculatedSpeedKmh = (distFromLast / dtSec) * 3.6;
      if (calculatedSpeedKmh > kMaxRealisticSpeedKmh) {
        debugPrint('[TripGpsTracker] Bỏ qua điểm nhảy bất thường: $calculatedSpeedKmh km/h, $distFromLast m');
        return;
      }
    }

    // Xác định vận tốc hiện tại: Ưu tiên BLE telemetry từ xe > GPS speed
    double effectiveSpeedKmh = _lastKnownBikeSpeed;
    if (effectiveSpeedKmh <= 0.0 && pos.speed >= 0.0) {
      effectiveSpeedKmh = pos.speed * 3.6;
    }

    // 5. CHỐNG NHẢY ĐỊNH VỊ KHI XE ĐỨNG YÊN / ĐÈN ĐỎ (Stationary Jitter Suppression)
    final isStationary = effectiveSpeedKmh <= kStationarySpeedKmh && (pos.speed * 3.6) <= kStationarySpeedKmh;
    if (isStationary && _lastFilteredPoint != null) {
      // Khi xe đang dừng, GPS vẫn có dao động 3-8m. Không ghi thêm điểm ziczac nếu chưa rời khỏi bán kính 6m
      if (distFromLast < kStationaryMinDistanceMeters) {
        return;
      }
    }

    // 6. LỌC ĐIỂM DỒN CỤC KHI CHẠY CHẬM (Spatial Downsampling)
    if (!isStationary && _lastFilteredPoint != null && distFromLast < kMovingMinDistanceMeters) {
      return;
    }

    // 7. BỘ LỌC KALMAN 2D LÀM MƯỢT TỌA ĐỘ
    final speedMps = effectiveSpeedKmh / 3.6;
    _kalmanFilter.filter(
      measuredLat: pos.latitude,
      measuredLng: pos.longitude,
      accuracyMeters: pos.accuracy,
      speedMps: speedMps,
      timestamp: now,
    );

    final filteredLat = _kalmanFilter.lat ?? pos.latitude;
    final filteredLng = _kalmanFilter.lng ?? pos.longitude;

    // 8. TÍNH TOÁN HƯỚNG DI CHUYỂN (HEADING)
    double? heading = pos.heading >= 0 && pos.heading <= 360 ? pos.heading : null;
    if ((heading == null || heading == 0.0) && _lastFilteredPoint != null && distFromLast >= 2.0) {
      heading = calculateBearing(
        _lastFilteredPoint!.lat,
        _lastFilteredPoint!.lng,
        filteredLat,
        filteredLng,
      );
    }

    final point = TripGpsPoint(
      lat: double.parse(filteredLat.toStringAsFixed(6)),
      lng: double.parse(filteredLng.toStringAsFixed(6)),
      speedKmh: double.parse(effectiveSpeedKmh.toStringAsFixed(1)),
      timestamp: now,
      altitude: pos.altitude > -100 ? double.parse(pos.altitude.toStringAsFixed(1)) : null,
      heading: heading != null ? double.parse(heading.toStringAsFixed(1)) : null,
    );

    _recordedPoints.add(point);
    _lastPointTime = now;
    _lastFilteredPoint = point;
    _pointController.add(point);
    unawaited(_persistPointsDebounced());
  }

  /// Tính góc phương vị di chuyển giữa 2 điểm tọa độ (Geodesic Bearing 0° - 360°)
  static double calculateBearing(double lat1, double lng1, double lat2, double lng2) {
    final phi1 = lat1 * math.pi / 180.0;
    final phi2 = lat2 * math.pi / 180.0;
    final deltaLambda = (lng2 - lng1) * math.pi / 180.0;

    final y = math.sin(deltaLambda) * math.cos(phi2);
    final x = math.cos(phi1) * math.sin(phi2) -
        math.sin(phi1) * math.cos(phi2) * math.cos(deltaLambda);

    final theta = math.atan2(y, x);
    return (theta * 180.0 / math.pi + 360.0) % 360.0;
  }

  /// Dừng ghi GPS và trả về danh sách điểm đã được làm mịn, lọc sạch
  List<TripGpsPoint> stopTracking() {
    _positionSub?.cancel();
    _positionSub = null;
    _isTracking = false;
    _kalmanFilter.reset();
    final smoothed = cleanAndSmoothRoute(_recordedPoints);
    return smoothed;
  }

  /// Lấy bản sao danh sách điểm GPS hiện tại
  List<TripGpsPoint> getCurrentRoute() {
    return List<TripGpsPoint>.from(_recordedPoints);
  }

  /// Xóa bộ nhớ đệm điểm GPS
  void clear() {
    _recordedPoints.clear();
    _lastPointTime = null;
    _lastFilteredPoint = null;
    _kalmanFilter.reset();
    unawaited(clearSavedCache());
  }

  /// Thuật toán hậu xử lý và làm mịn lộ trình:
  /// - Loại bỏ điểm đột biến GPS (speed spike > 115 km/h)
  /// - Gộp cụm điểm đứng yên tại các chốt đèn giao thông
  /// - Làm mịn đường vẽ (Weighted Moving Average) giúp đường vẽ uốn lượn tự nhiên theo mặt đường
  static List<TripGpsPoint> cleanAndSmoothRoute(List<TripGpsPoint> rawPoints) {
    if (rawPoints.length <= 2) return List.from(rawPoints);

    // Bước 1: Khử điểm nhảy đột ngột & khử cụm đứng yên dồn đống
    final filtered = <TripGpsPoint>[rawPoints.first];
    for (int i = 1; i < rawPoints.length; i++) {
      final prev = filtered.last;
      final cur = rawPoints[i];
      final dt = cur.timestamp.difference(prev.timestamp).inMilliseconds / 1000.0;
      final dist = Geolocator.distanceBetween(prev.lat, prev.lng, cur.lat, cur.lng);

      if (dt > 0.05) {
        final speed = (dist / dt) * 3.6;
        if (speed > kMaxRealisticSpeedKmh) {
          continue; // Bỏ qua điểm đột biến
        }
      }

      // Khử cụm điểm giật tại chỗ khi dừng đỗ (< 2m và tốc độ <= 1.5 km/h)
      if (dist < 2.0 && cur.speedKmh <= 1.5 && prev.speedKmh <= 1.5 && i < rawPoints.length - 1) {
        continue;
      }

      filtered.add(cur);
    }

    if (filtered.length <= 2) return filtered;

    // Bước 2: Làm mịn tọa độ theo thuật toán Weighted Moving Average (0.2 - 0.6 - 0.2)
    final smoothed = <TripGpsPoint>[filtered.first];
    for (int i = 1; i < filtered.length - 1; i++) {
      final pPrev = filtered[i - 1];
      final pCur = filtered[i];
      final pNext = filtered[i + 1];

      final smoothLat = 0.2 * pPrev.lat + 0.6 * pCur.lat + 0.2 * pNext.lat;
      final smoothLng = 0.2 * pPrev.lng + 0.6 * pCur.lng + 0.2 * pNext.lng;

      smoothed.add(TripGpsPoint(
        lat: double.parse(smoothLat.toStringAsFixed(6)),
        lng: double.parse(smoothLng.toStringAsFixed(6)),
        speedKmh: pCur.speedKmh,
        timestamp: pCur.timestamp,
        altitude: pCur.altitude,
        heading: pCur.heading,
      ));
    }
    smoothed.add(filtered.last);
    return smoothed;
  }

  /// Không sử dụng lộ trình giả lập — ứng dụng chỉ hiển thị GPS thực tế
  static List<TripGpsPoint> generateSampleRoute({
    required double distanceKm,
    required double avgSpeedKmh,
    required double maxSpeedKmh,
    required DateTime startTime,
    required int durationSec,
  }) {
    return const [];
  }
}
