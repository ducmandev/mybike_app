import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/trip_gps_point.dart';
import 'gps_route_snapping_service.dart';
import 'trip_recording_gate.dart';

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
  bool _hasStartedActiveRide = false;
  bool _isDriveMode = false;
  bool _isBikeConnected = false;
  bool _isBikeOn = false;
  bool _isSideStandDown = false;
  double _lastKnownBikeSpeed = 0.0;
  DateTime? _lastPointTime;
  DateTime? _lastValidFixAt;
  Position? _lastPosition;
  TripGpsPoint? _lastFilteredPoint;
  DateTime? _lastPersistTime;
  int _sessionEpoch = 0;
  bool _hasRestoredFromCache = false;
  Future<void>? _restoreFuture;

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
  bool get hasStartedActiveRide => _hasStartedActiveRide;
  bool get isActivelyRecording => _isTracking && _hasStartedActiveRide;
  bool get isDriveMode => _isDriveMode;
  bool get isBikeConnected => _isBikeConnected;
  bool get isBikeOn => _isBikeOn;
  bool get isSideStandDown => _isSideStandDown;
  List<TripGpsPoint> get recordedPoints => List.unmodifiable(_recordedPoints);
  Stream<TripGpsPoint> get onPointRecorded => _pointController.stream;
  Position? get lastPosition => _lastPosition;
  TripGpsPoint? get currentPoint => _recordedPoints.isNotEmpty ? _recordedPoints.last : null;

  /// Cập nhật chế độ lái xe (D/S/E/Cruise và không gạt chân chống)
  void setDriveMode(bool active) {
    if (_isDriveMode != active) {
      _isDriveMode = active;
      debugPrint('[TripGpsTracker] Trạng thái chế độ lái ECU: $active');
    }
  }

  /// Đánh dấu phiên hành trình hiện tại đã thực sự bắt đầu lăn bánh hay chưa.
  void setActiveRideStarted(bool started) {
    _hasStartedActiveRide = started;
  }

  /// Cập nhật trạng thái xe toàn diện từ telemetry ECU (BLE).
  ///
  /// CHỈ kích hoạt `_hasStartedActiveRide` khi ECU xác nhận xe đang ở chế độ chạy,
  /// không gạt chân chống và tốc độ do ECU trả về vượt > 4.0 km/h (không dựa vào GPS).
  void updateVehicleState({
    required bool isConnected,
    required bool isBikeOn,
    required bool isSideStandDown,
    required bool isDriveMode,
    required double speedKmh,
    bool? activeRideStarted,
  }) {
    _isBikeConnected = isConnected;
    _isBikeOn = isBikeOn;
    _isSideStandDown = isSideStandDown;
    _isDriveMode = isDriveMode;
    _lastKnownBikeSpeed = speedKmh >= 0 ? speedKmh : 0.0;

    if (activeRideStarted != null) {
      _hasStartedActiveRide = activeRideStarted;
    } else if (!_hasStartedActiveRide &&
        isConnected &&
        isBikeOn &&
        !isSideStandDown &&
        isDriveMode &&
        _lastKnownBikeSpeed > TripRecordingPolicy.kMinEcuRideSpeedKmh) {
      _hasStartedActiveRide = true;
    }
  }

  /// Tự động lưu bộ nhớ đệm GPS định kỳ vào SharedPreferences để chống mất lộ trình khi vuốt/kill app
  Future<void> _persistPointsDebounced() async {
    if (!_isTracking || _recordedPoints.isEmpty) {
      return;
    }
    final now = DateTime.now();
    if (_lastPersistTime != null && now.difference(_lastPersistTime!).inSeconds < 4) {
      return;
    }
    _lastPersistTime = now;

    final epoch = _sessionEpoch;
    final snapshotJson = jsonEncode(_recordedPoints.map((p) => p.toJson()).toList());
    final nowIso = now.toIso8601String();

    try {
      final prefs = await SharedPreferences.getInstance();
      if (epoch != _sessionEpoch) return;
      await prefs.setString(_kActiveGpsPointsKey, snapshotJson);
      if (epoch != _sessionEpoch) return;
      await prefs.setString(_kActiveGpsTimeKey, nowIso);
    } catch (e) {
      debugPrint('[TripGpsTracker] Lỗi lưu đệm GPS vào SharedPreferences: $e');
    }
  }

  /// Khôi phục các điểm GPS đang ghi dở dang nếu người dùng lỡ vuốt tắt app
  Future<void> restoreUnsavedPoints() {
    if (_restoreFuture != null) {
      return _restoreFuture!;
    }
    if (_hasRestoredFromCache || _recordedPoints.isNotEmpty) {
      return Future.value();
    }

    _hasRestoredFromCache = true;
    final epoch = _sessionEpoch;
    late final Future<void> future;
    future = _performRestoreUnsavedPoints(epoch).whenComplete(() {
      if (identical(_restoreFuture, future)) {
        _restoreFuture = null;
      }
    });
    _restoreFuture = future;
    return future;
  }

  Future<void> _performRestoreUnsavedPoints(int epoch) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (epoch != _sessionEpoch || _recordedPoints.isNotEmpty) {
        return;
      }

      final cachedJson = prefs.getString(_kActiveGpsPointsKey);
      final cachedTimeStr = prefs.getString(_kActiveGpsTimeKey);

      if (cachedJson != null && cachedJson.isNotEmpty && cachedTimeStr != null) {
        final lastTime = DateTime.tryParse(cachedTimeStr);
        // Chỉ tự động nạp lại cache GPS dở dang nếu còn mới (< 30 phút),
        // tránh kéo lại hành trình cũ khi user chỉ đi ngang qua xe đỗ.
        if (lastTime != null && DateTime.now().difference(lastTime).inMinutes < 30) {
          final decoded = jsonDecode(cachedJson) as List<dynamic>;
          final restored = decoded
              .map((item) => TripGpsPoint.fromJson(item as Map<String, dynamic>))
              .toList();
          if (restored.isNotEmpty &&
              epoch == _sessionEpoch &&
              _recordedPoints.isEmpty) {
            _recordedPoints.addAll(restored);
            _lastFilteredPoint = restored.last;
            _lastValidFixAt = restored.last.timestamp;
            debugPrint('[TripGpsTracker] Đã khôi phục ${restored.length} điểm GPS gần nhất từ bộ nhớ đệm!');
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
    _sessionEpoch++;
    _lastPersistTime = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kActiveGpsPointsKey);
      await prefs.remove(_kActiveGpsTimeKey);
    } catch (_) {}
  }

  /// Tính tổng quãng đường GPS thực tế đã tích lũy (km), đã tự động trừ các đoạn mất sóng GPS.
  double get totalDistanceKm =>
      GpsRouteAnalyzer.measureRoute(_recordedPoints).distanceKm;

  /// Số đoạn mất sóng GPS đã bị loại trừ khỏi phép đo KM GPS hiện tại.
  int get signalLossCount =>
      GpsRouteAnalyzer.measureRoute(_recordedPoints).signalLossCount;

  /// Tổng quãng đường (km) chim bay bị loại trừ do mất sóng GPS.
  double get excludedGapDistanceKm =>
      GpsRouteAnalyzer.measureRoute(_recordedPoints).excludedGapDistanceKm;

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
  Future<bool> startTracking({bool clearExisting = false}) async {
    if (_isTracking && _positionSub != null) return true;

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        debugPrint('[TripGpsTracker] Dịch vụ GPS chưa bật');
        return false;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        try {
          permission = await Geolocator.requestPermission().timeout(const Duration(seconds: 3));
        } catch (e) {
          debugPrint('[TripGpsTracker] Timeout hoặc lỗi xin quyền GPS: $e');
        }
        if (permission == LocationPermission.denied) {
          debugPrint('[TripGpsTracker] Quyền vị trí bị từ chối');
          return false;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        debugPrint('[TripGpsTracker] Quyền vị trí bị từ chối vĩnh viễn');
        return false;
      }

      if (clearExisting) {
        _sessionEpoch++;
        _recordedPoints.clear();
        _lastPointTime = null;
        _lastFilteredPoint = null;
        _lastPersistTime = null;
        _kalmanFilter.reset();
      }

      // Hủy stream cũ nếu có
      await _positionSub?.cancel();
      _positionSub = null;

      // Cấu hình tần suất lấy GPS theo từng hệ điều hành
      LocationSettings locationSettings;
      if (defaultTargetPlatform == TargetPlatform.android) {
        // Bỏ foregroundNotificationConfig của Geolocator vì app đã có ForegroundService
        // kết nối BLE chính; việc tạo thêm service thứ hai dễ bị Android 12+ chặn khi gọi từ background.
        locationSettings = AndroidSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 2,
          intervalDuration: const Duration(milliseconds: 1000),
        );
      } else if (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS) {
        locationSettings = AppleSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          activityType: ActivityType.automotiveNavigation,
          distanceFilter: 2,
          pauseLocationUpdatesAutomatically: false,
          allowBackgroundLocationUpdates: true,
          showBackgroundLocationIndicator: true,
        );
      } else {
        locationSettings = const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 2,
        );
      }

      // Khởi tạo stream GPS ngay lập tức
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

      _isTracking = true;

      // Lấy ngay vị trí ban đầu bất đồng bộ (unawaited) để không chặn luồng khởi động
      unawaited(() async {
        try {
          final initialPos = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              timeLimit: Duration(seconds: 5),
            ),
          );
          if (initialPos.accuracy <= kMaxAcceptableAccuracyMeters && initialPos.accuracy > 0) {
            _handleNewPosition(initialPos);
          }
        } catch (e) {
          debugPrint('[TripGpsTracker] Không lấy được initial position: $e');
        }
      }());

      debugPrint('[TripGpsTracker] Đã khởi động ghi GPS chuyến đi với bộ lọc Kalman');
      return true;
    } catch (e) {
      debugPrint('[TripGpsTracker] Lỗi khởi động GPS: $e');
      _isTracking = false;
      return false;
    }
  }

  /// Tiếp nhận mẫu [Position] trong unit test để kiểm chứng rule ghi nhận & mất sóng GPS.
  @visibleForTesting
  void ingestPositionForTesting(Position pos, {DateTime? now}) {
    _handleNewPosition(pos, nowOverride: now);
  }

  void _handleNewPosition(Position pos, {DateTime? nowOverride}) {
    _lastPosition = pos;
    final now = nowOverride ?? DateTime.now();
    final hasValidAccuracy =
        pos.accuracy > 0 && pos.accuracy <= kMaxAcceptableAccuracyMeters;

    // 0. CỔNG NGHIỆP VỤ ECU BẮT BUỘC:
    // - Tuyệt đối KHÔNG ghi nhận GPS khi chưa kích hoạt chuyến đi từ ECU (_hasStartedActiveRide),
    //   hoặc khi chỉ đi bộ ngang qua xe / xe tắt / lock / gạt chân chống / không ở mode chạy.
    // - Chỉ tin cậy tốc độ & chế độ chạy do ECU trả về (> 4 km/h để khởi đầu, > 0.5 km/h để tiếp tục).
    final canRecordNow = _hasStartedActiveRide &&
        _isBikeConnected &&
        _isBikeOn &&
        !_isSideStandDown &&
        _isDriveMode &&
        _lastKnownBikeSpeed > TripRecordingPolicy.kActiveContinueSpeedKmh;

    if (!canRecordNow) {
      // Khi chuyến đi đã bắt đầu và xe chỉ tạm dừng đèn đỏ mà GPS vẫn bắt sóng tốt,
      // cập nhật _lastValidFixAt để không đánh dấu nhầm là mất sóng GPS khi xe lăn bánh lại.
      if (_hasStartedActiveRide && _isBikeConnected && hasValidAccuracy) {
        _lastValidFixAt = now;
      }
      return;
    }

    // 1. BỘ LỌC ĐỘ CHÍNH XÁC (Accuracy Filter)
    // Bỏ qua các điểm có sai số lớn (> 25m hoặc âm) do phản xạ nhà cao tầng / mất sóng trong hầm.
    if (!hasValidAccuracy) {
      return;
    }

    // 2. PHÁT HIỆN MẤT SÓNG GPS (> 15 giây không có tọa độ hợp lệ và dịch chuyển > 45m)
    double distFromLast = 0.0;
    double dtSec = 0.0;
    if (_lastFilteredPoint != null) {
      distFromLast = GpsGeoMath.distanceMeters(
        _lastFilteredPoint!.lat,
        _lastFilteredPoint!.lng,
        pos.latitude,
        pos.longitude,
      );
      dtSec = now.difference(_lastFilteredPoint!.timestamp).inMilliseconds / 1000.0;
    }

    final gapFromLastFixSec =
        _lastValidFixAt != null ? now.difference(_lastValidFixAt!).inSeconds : 0;
    final isSignalLossRestart = _lastFilteredPoint != null &&
        gapFromLastFixSec > GpsRouteAnalyzer.kSignalLossGapSeconds &&
        distFromLast > GpsRouteAnalyzer.kSignalLossMinJumpMeters;

    _lastValidFixAt = now;

    // 3. GIỚI HẠN TẦN SUẤT GHI (Time Filter)
    if (!isSignalLossRestart &&
        _lastPointTime != null &&
        now.difference(_lastPointTime!).inMilliseconds < kMinIntervalMs) {
      return;
    }

    // 4. BỘ LỌC ĐỘT BIẾN / NHẢY VỊ TRÍ PHI LÝ (Speed Spike / Teleportation Filter)
    if (!isSignalLossRestart &&
        _lastFilteredPoint != null &&
        dtSec > 0.05 &&
        dtSec <= GpsRouteAnalyzer.kSignalLossGapSeconds) {
      final calculatedSpeedKmh = (distFromLast / dtSec) * 3.6;
      if (calculatedSpeedKmh > kMaxRealisticSpeedKmh) {
        debugPrint('[TripGpsTracker] Bỏ qua điểm nhảy bất thường: $calculatedSpeedKmh km/h, $distFromLast m');
        return;
      }
    }

    // Xác định vận tốc hiện tại thuần túy theo ECU xe
    final effectiveSpeedKmh = _lastKnownBikeSpeed;

    // 5. LỌC ĐIỂM DỒN CỤC KHI CHẠY CHẬM (Spatial Downsampling)
    if (!isSignalLossRestart &&
        _lastFilteredPoint != null &&
        distFromLast < kMovingMinDistanceMeters) {
      return;
    }

    // Nếu vừa phục hồi sau mất sóng GPS -> reset Kalman để không kéo ngược tọa độ vào hầm
    if (isSignalLossRestart) {
      _kalmanFilter.reset();
    }

    // 6. BỘ LỌC KALMAN 2D LÀM MƯỢT TỌA ĐỘ
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

    // 7. TÍNH TOÁN HƯỚNG DI CHUYỂN (HEADING)
    double? heading = pos.heading >= 0 && pos.heading <= 360 ? pos.heading : null;
    if ((heading == null || heading == 0.0) &&
        !isSignalLossRestart &&
        _lastFilteredPoint != null &&
        distFromLast >= 2.0) {
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
      isSignalLossRestart: isSignalLossRestart,
    );

    _recordedPoints.add(point);
    _lastPointTime = now;
    _lastFilteredPoint = point;
    _pointController.add(point);
    unawaited(_persistPointsDebounced());
  }

  /// Tính góc phương vị di chuyển giữa 2 điểm tọa độ (Geodesic Bearing 0° - 360°)
  static double calculateBearing(double lat1, double lng1, double lat2, double lng2) {
    return GpsGeoMath.bearingDegrees(lat1, lng1, lat2, lng2);
  }

  /// Dừng ghi GPS và trả về danh sách điểm đã được làm mịn, lọc sạch
  List<TripGpsPoint> stopTracking() {
    _positionSub?.cancel();
    _positionSub = null;
    _isTracking = false;
    _hasStartedActiveRide = false;
    _lastValidFixAt = null;
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
    _sessionEpoch++;
    _recordedPoints.clear();
    _lastPointTime = null;
    _lastValidFixAt = null;
    _lastFilteredPoint = null;
    _lastPersistTime = null;
    _hasStartedActiveRide = false;
    _kalmanFilter.reset();
    unawaited(clearSavedCache());
  }

  /// Thuật toán hậu xử lý và làm mịn lộ trình theo từng chặng liên tục:
  /// - Loại bỏ điểm đột biến GPS (speed spike > 110 km/h trong khoảng thời gian ngắn)
  /// - Tách riêng các chặng bị mất sóng GPS (không làm mịn vắt ngang qua hầm / vùng mất sóng)
  /// - Gộp cụm điểm đứng yên tại các chốt đèn giao thông
  /// - Làm mịn đường vẽ (Weighted Moving Average 0.2 - 0.6 - 0.2)
  static List<TripGpsPoint> cleanAndSmoothRoute(List<TripGpsPoint> rawPoints) {
    if (rawPoints.length <= 2) return List.from(rawPoints);

    // Bước 1: Khử điểm nhảy đột ngột & khử cụm đứng yên dồn đống
    final filtered = <TripGpsPoint>[rawPoints.first];
    for (int i = 1; i < rawPoints.length; i++) {
      final prev = filtered.last;
      final cur = rawPoints[i];
      final dt = cur.timestamp.difference(prev.timestamp).inMilliseconds / 1000.0;
      final dist = GpsGeoMath.distanceMeters(prev.lat, prev.lng, cur.lat, cur.lng);

      if (!cur.isSignalLossRestart &&
          dt > 0.05 &&
          dt <= GpsRouteAnalyzer.kSignalLossGapSeconds) {
        final speed = (dist / dt) * 3.6;
        if (speed > kMaxRealisticSpeedKmh) {
          continue; // Bỏ qua điểm đột biến ngắn hạn
        }
      }

      // Khử cụm điểm giật tại chỗ khi dừng đỗ (< 2m và tốc độ <= 1.5 km/h)
      if (!cur.isSignalLossRestart &&
          dist < 2.0 &&
          cur.speedKmh <= 1.5 &&
          prev.speedKmh <= 1.5 &&
          i < rawPoints.length - 1) {
        continue;
      }

      filtered.add(cur);
    }

    if (filtered.length <= 2) return filtered;

    // Bước 2: Tách theo chặng liên tục rồi làm mịn từng chặng độc lập
    final subTracks = GpsRouteAnalyzer.splitContinuousSubTracks(filtered);
    final result = <TripGpsPoint>[];

    for (var subIdx = 0; subIdx < subTracks.length; subIdx++) {
      final sub = subTracks[subIdx];
      if (sub.length <= 2) {
        for (var j = 0; j < sub.length; j++) {
          result.add(
            sub[j].copyWith(
              isSignalLossRestart: (subIdx > 0 && j == 0) || sub[j].isSignalLossRestart,
            ),
          );
        }
        continue;
      }

      result.add(
        sub.first.copyWith(
          isSignalLossRestart: (subIdx > 0) || sub.first.isSignalLossRestart,
        ),
      );
      for (int i = 1; i < sub.length - 1; i++) {
        final pPrev = sub[i - 1];
        final pCur = sub[i];
        final pNext = sub[i + 1];

        final smoothLat = 0.2 * pPrev.lat + 0.6 * pCur.lat + 0.2 * pNext.lat;
        final smoothLng = 0.2 * pPrev.lng + 0.6 * pCur.lng + 0.2 * pNext.lng;

        result.add(TripGpsPoint(
          lat: double.parse(smoothLat.toStringAsFixed(6)),
          lng: double.parse(smoothLng.toStringAsFixed(6)),
          speedKmh: pCur.speedKmh,
          timestamp: pCur.timestamp,
          altitude: pCur.altitude,
          heading: pCur.heading,
          isSignalLossRestart: false,
        ));
      }
      result.add(sub.last.copyWith(isSignalLossRestart: false));
    }

    return result;
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
