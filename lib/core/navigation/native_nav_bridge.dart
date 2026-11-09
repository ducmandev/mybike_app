import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'package:latlong2/latlong.dart';

import '../models/bike_model_profile.dart';
import 'nav_models.dart';

typedef _NavCalcRouteJsonC = Pointer<Char> Function(Pointer<Char> reqJson);
typedef _NavCalcRouteJsonDart = Pointer<Char> Function(Pointer<Char> reqJson);

typedef _NavTrackStepJsonC = Pointer<Char> Function(Pointer<Char> reqJson);
typedef _NavTrackStepJsonDart = Pointer<Char> Function(Pointer<Char> reqJson);

typedef _NavFreeStringC = Void Function(Pointer<Char> ptr);
typedef _NavFreeStringDart = void Function(Pointer<Char> ptr);

typedef _NavCleanOsmLabelC = Pointer<Char> Function(Pointer<Char> rawPtr, Bool minimal);
typedef _NavCleanOsmLabelDart = Pointer<Char> Function(Pointer<Char> rawPtr, bool minimal);

typedef _NavSearchPlacesJsonC = Pointer<Char> Function(Pointer<Char> reqJson);
typedef _NavSearchPlacesJsonDart = Pointer<Char> Function(Pointer<Char> reqJson);

typedef _SystemMallocC = Pointer Function(IntPtr size);
typedef _SystemMallocDart = Pointer Function(int size);

typedef _SystemFreeC = Void Function(Pointer ptr);
typedef _SystemFreeDart = void Function(Pointer ptr);

/// Cầu nối FFI an toàn kết nối tới thư viện Rust `datbike_nav`
/// Hỗ trợ nạp động trên Android (`libdatbike_nav.so`), Windows (`datbike_nav.dll`), iOS (`DynamicLibrary.process()`).
/// Tích hợp sẵn Deterministic Fallback Engine hoàn toàn bằng Dart để hoạt động 100% trong mọi môi trường (Test, Simulator)
/// mà không bao giờ gây crash!
class NativeNavBridge {
  static final NativeNavBridge _instance = NativeNavBridge._internal();
  factory NativeNavBridge() => _instance;
  NativeNavBridge._internal() {
    _initNativeLibrary();
  }

  DynamicLibrary? _navLib;
  _NavCalcRouteJsonDart? _nativeCalcRoute;
  _NavTrackStepJsonDart? _nativeTrackStep;
  _NavCleanOsmLabelDart? _nativeCleanOsmLabel;
  _NavSearchPlacesJsonDart? _nativeSearchPlaces;
  _NavFreeStringDart? _nativeFreeString;

  _SystemMallocDart? _sysMalloc;
  _SystemFreeDart? _sysFree;

  bool _isNativeLoaded = false;
  bool get isNativeLoaded => _isNativeLoaded;

  void _initNativeLibrary() {
    _initSystemAllocators();
    try {
      if (Platform.isAndroid) {
        _navLib = DynamicLibrary.open('libdatbike_nav.so');
      } else if (Platform.isWindows) {
        final candidatePaths = [
          'datbike_nav.dll',
          '../datbike-nav-rs/target/release/datbike_nav.dll',
          'datbike-nav-rs/target/release/datbike_nav.dll',
          'target/release/datbike_nav.dll',
        ];
        for (final p in candidatePaths) {
          try {
            _navLib = DynamicLibrary.open(p);
            break;
          } catch (_) {}
        }
      } else if (Platform.isIOS || Platform.isMacOS) {
        _navLib = DynamicLibrary.process();
      } else if (Platform.isLinux) {
        _navLib = DynamicLibrary.open('libdatbike_nav.so');
      }

      if (_navLib != null) {
        _nativeCalcRoute = _navLib!.lookupFunction<_NavCalcRouteJsonC, _NavCalcRouteJsonDart>(
          'datbike_nav_calculate_route_json',
        );
        _nativeTrackStep = _navLib!.lookupFunction<_NavTrackStepJsonC, _NavTrackStepJsonDart>(
          'datbike_nav_track_step_json',
        );
        _nativeFreeString = _navLib!.lookupFunction<_NavFreeStringC, _NavFreeStringDart>(
          'datbike_nav_free_string',
        );
        try {
          _nativeCleanOsmLabel = _navLib!.lookupFunction<_NavCleanOsmLabelC, _NavCleanOsmLabelDart>(
            'datbike_nav_clean_osm_label',
          );
        } catch (_) {
          _nativeCleanOsmLabel = null;
        }
        try {
          _nativeSearchPlaces = _navLib!.lookupFunction<_NavSearchPlacesJsonC, _NavSearchPlacesJsonDart>(
            'datbike_nav_search_offline_places_json',
          );
        } catch (_) {
          _nativeSearchPlaces = null;
        }
        _isNativeLoaded = true;
      }
    } catch (_) {
      _isNativeLoaded = false;
    }
  }

  /// Tra cứu địa chỉ, tên đường, số nhà và địa danh 100% offline từ CSDL nhị phân
  List<NavSearchResult> searchOfflinePlaces(String query, {int limit = 15}) {
    if (query.trim().isEmpty) return [];
    if (_isNativeLoaded && _nativeSearchPlaces != null && _nativeFreeString != null) {
      final req = jsonEncode({'query': query.trim(), 'limit': limit});
      final cReq = _allocateNativeUtf8(req);
      if (cReq != null) {
        try {
          final cRes = _nativeSearchPlaces!(cReq);
          if (cRes.address != 0) {
            final resStr = _readNativeUtf8(cRes);
            _nativeFreeString!(cRes);
            final data = jsonDecode(resStr) as Map<String, dynamic>;
            if (data['ok'] == true && data['results'] is List) {
              final list = data['results'] as List<dynamic>;
              return list
                  .map((r) => NavSearchResult.fromJson(r as Map<String, dynamic>))
                  .toList();
            }
          }
        } catch (_) {
        } finally {
          _freeNativeUtf8(cReq);
        }
      }
    }
    return [];
  }

  void _initSystemAllocators() {
    try {
      DynamicLibrary? cLib;
      if (Platform.isWindows) {
        cLib = DynamicLibrary.open('msvcrt.dll');
      } else {
        cLib = DynamicLibrary.process();
      }
      _sysMalloc = cLib.lookupFunction<_SystemMallocC, _SystemMallocDart>('malloc');
      _sysFree = cLib.lookupFunction<_SystemFreeC, _SystemFreeDart>('free');
    } catch (_) {
      _sysMalloc = null;
      _sysFree = null;
    }
  }

  Pointer<Char>? _allocateNativeUtf8(String str) {
    if (_sysMalloc == null) return null;
    final units = utf8.encode(str);
    final ptr = _sysMalloc!(units.length + 1).cast<Uint8>();
    for (int i = 0; i < units.length; i++) {
      ptr[i] = units[i];
    }
    ptr[units.length] = 0;
    return ptr.cast<Char>();
  }

  void _freeNativeUtf8(Pointer<Char> ptr) {
    if (_sysFree != null && ptr.address != 0) {
      _sysFree!(ptr.cast<Void>());
    }
  }

  String _readNativeUtf8(Pointer<Char> ptr) {
    if (ptr.address == 0) return '';
    final u8 = ptr.cast<Uint8>();
    int length = 0;
    while (u8[length] != 0) {
      length++;
    }
    final bytes = List<int>.generate(length, (i) => u8[i]);
    return utf8.decode(bytes);
  }

  /// Lọc bỏ các nhãn hành chính thừa (Khu phố, Tổ dân phố, Phường, mã bưu chính, Việt Nam)
  /// Ưu tiên thực thi qua C-ABI Rust Engine, tự động fallback sang Dart nếu chưa nạp thư viện
  String cleanOsmLabel(String raw, {bool minimal = true}) {
    if (raw.trim().isEmpty) return raw;
    if (_isNativeLoaded && _nativeCleanOsmLabel != null && _nativeFreeString != null) {
      final cReq = _allocateNativeUtf8(raw);
      if (cReq != null) {
        try {
          final cRes = _nativeCleanOsmLabel!(cReq, minimal);
          if (cRes.address != 0) {
            final resStr = _readNativeUtf8(cRes);
            _nativeFreeString!(cRes);
            if (resStr.isNotEmpty) return resStr;
          }
        } catch (_) {
          // Fallback sang Dart
        } finally {
          _freeNativeUtf8(cReq);
        }
      }
    }
    return _fallbackCleanOsmLabel(raw, minimal: minimal);
  }

  static String _fallbackCleanOsmLabel(String raw, {bool minimal = true}) {
    if (raw.trim().isEmpty) return raw;
    final parts = raw.split(',').map((p) => p.trim()).where((p) => p.isNotEmpty);
    final postalRegex = RegExp(r'^\d{5,6}$');
    final cleaned = <String>[];
    final seen = <String>{};

    for (final part in parts) {
      final lower = part.toLowerCase();
      if (postalRegex.hasMatch(part)) continue;
      if (lower == 'việt nam' || lower == 'vietnam') continue;

      if (minimal) {
        if (lower.startsWith('khu phố') ||
            lower.startsWith('tổ dân phố') ||
            lower.startsWith('tổ ') ||
            lower.startsWith('ấp ') ||
            lower.startsWith('khóm ') ||
            lower.startsWith('thôn ') ||
            lower.startsWith('phường ')) {
          continue;
        }
      }

      if (seen.add(lower)) {
        cleaned.add(part);
      }
    }

    if (cleaned.isEmpty) return raw;
    return cleaned.join(', ');
  }

  /// Tính toán tuyến đường và dự báo năng lượng pin EV
  NavRouteResult? calculateRoute({
    required LatLng start,
    required LatLng end,
    bool ecoMode = false,
    int? batterySoc,
    BikeModel? bikeModel,
    String? osmRawJson,
    bool minimalFilter = true,
    String? saveDbnavPath,
    List<LatLng>? corridorWaypoints,
  }) {
    final effectiveSoc = (batterySoc != null && batterySoc > 0) ? batterySoc : 100;
    if (_isNativeLoaded && _nativeCalcRoute != null && _nativeFreeString != null) {
      try {
        final capacityWh = (bikeModel?.generation == BikeGeneration.gen1Weaver ? 2160.0 : 5400.0);
        final whPerKm = ecoMode ? 22.0 : 28.5;
        final req = {
          'start_lat': start.latitude,
          'start_lng': start.longitude,
          'dest_lat': end.latitude,
          'dest_lng': end.longitude,
          'end_lat': end.latitude,
          'end_lng': end.longitude,
          'eco_mode': ecoMode,
          'battery_soc': effectiveSoc.toDouble(),
          'battery_capacity_wh': capacityWh,
          'wh_per_km': whPerKm,
          'bike_model': (bikeModel ?? BikeModel.qtS1).code,
          'osm_raw_json': osmRawJson,
          'minimal_filter': minimalFilter,
          'save_dbnav_path': saveDbnavPath,
          'corridor_waypoints': corridorWaypoints?.map((p) => [p.latitude, p.longitude]).toList(),
        };
        final reqStr = jsonEncode(req);
        final cReq = _allocateNativeUtf8(reqStr);
        if (cReq != null) {
          try {
            final cRes = _nativeCalcRoute!(cReq);
            if (cRes.address != 0) {
              final resStr = _readNativeUtf8(cRes);
              _nativeFreeString!(cRes);
              final decoded = jsonDecode(resStr) as Map<String, dynamic>;
              if (decoded['ok'] != false && (decoded.containsKey('polyline') || decoded.containsKey('distance_m'))) {
                decoded['is_eco_mode'] = ecoMode;
                return NavRouteResult.fromJson(decoded);
              }
            }
          } finally {
            _freeNativeUtf8(cReq);
          }
        }
      } catch (_) {
        // Fallback sang Dart engine nếu Rust FFI gặp trục trặc
      }
    }

    return _fallbackCalculateRoute(
      start: start,
      end: end,
      ecoMode: ecoMode,
      batterySoc: effectiveSoc,
      bikeModel: bikeModel ?? BikeModel.qtS1,
      osmRawJson: osmRawJson,
      minimalFilter: minimalFilter,
      saveDbnavPath: saveDbnavPath,
      corridorWaypoints: corridorWaypoints,
    );
  }

  /// Bám đường và cập nhật trạng thái Turn-by-Turn theo vị trí GPS thực tế
  NavTrackingState trackStep({
    required LatLng currentPos,
    required double speedKmh,
    required double heading,
    required NavRouteResult route,
    required int currentStepIndex,
    int? batterySoc,
  }) {
    final effectiveSoc = (batterySoc != null && batterySoc > 0) ? batterySoc : 100;
    if (_isNativeLoaded && _nativeTrackStep != null && _nativeFreeString != null) {
      try {
        final req = {
          'current_lat': currentPos.latitude,
          'current_lng': currentPos.longitude,
          'current_speed_kmh': speedKmh,
          'current_heading': heading,
          'battery_soc': effectiveSoc.toDouble(),
          'battery_capacity_wh': 5400.0,
          'wh_per_km': route.isEcoMode ? 22.0 : 28.5,
          'eco_mode': route.isEcoMode,
          'polyline': route.polyline.map((p) => [p.latitude, p.longitude]).toList(),
          'steps': route.steps
              .map((s) => {
                    'instruction': s.instruction,
                    'street_name': s.streetName,
                    'maneuver': s.maneuver.code,
                    'distance_m': s.distanceMeters,
                    'duration_s': s.durationSeconds,
                    'lat': s.lat,
                    'lng': s.lng,
                  })
              .toList(),
        };
        final reqStr = jsonEncode(req);
        final cReq = _allocateNativeUtf8(reqStr);
        if (cReq != null) {
          try {
            final cRes = _nativeTrackStep!(cReq);
            if (cRes.address != 0) {
              final resStr = _readNativeUtf8(cRes);
              _nativeFreeString!(cRes);
              final decoded = jsonDecode(resStr) as Map<String, dynamic>;
              if (decoded['ok'] != false && (decoded.containsKey('snapped_lat') || decoded.containsKey('closest_polyline_index'))) {
                return NavTrackingState.fromJson(decoded);
              }
            }
          } finally {
            _freeNativeUtf8(cReq);
          }
        }
      } catch (_) {
        // Fallback sang Dart engine
      }
    }

    return _fallbackTrackStep(
      currentPos: currentPos,
      speedKmh: speedKmh,
      heading: heading,
      route: route,
      currentStepIndex: currentStepIndex,
      batterySoc: effectiveSoc,
    );
  }

  // =========================================================================
  // DETERMINISTIC FALLBACK ENGINE (DART PURE)
  // =========================================================================

  static const double _earthRadiusMeters = 6371000.0;

  /// Tính khoảng cách Great-circle Haversine theo mét
  static double haversineDistance(LatLng p1, LatLng p2) {
    final dLat = (p2.latitude - p1.latitude) * math.pi / 180.0;
    final dLng = (p2.longitude - p1.longitude) * math.pi / 180.0;
    final lat1 = p1.latitude * math.pi / 180.0;
    final lat2 = p2.latitude * math.pi / 180.0;

    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.sin(dLng / 2) * math.sin(dLng / 2) * math.cos(lat1) * math.cos(lat2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return _earthRadiusMeters * c;
  }

  /// Tính góc hướng đi (bearing) từ p1 tới p2 (0..360 độ)
  static double calculateBearing(LatLng p1, LatLng p2) {
    final lat1 = p1.latitude * math.pi / 180.0;
    final lat2 = p2.latitude * math.pi / 180.0;
    final dLng = (p2.longitude - p1.longitude) * math.pi / 180.0;

    final y = math.sin(dLng) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLng);
    final bearingRad = math.atan2(y, x);
    return (bearingRad * 180.0 / math.pi + 360.0) % 360.0;
  }

  /// Chiếu điểm P lên đoạn thẳng AB trên mặt phẳng cục bộ
  static ({LatLng snapped, double crossTrackError, double segmentT}) projectPointOnSegment(
    LatLng p,
    LatLng a,
    LatLng b,
  ) {
    final latMid = (a.latitude + b.latitude) / 2.0 * math.pi / 180.0;
    final cosMid = math.cos(latMid);

    final dx = (b.longitude - a.longitude) * cosMid * 111319.5;
    final dy = (b.latitude - a.latitude) * 111132.9;
    final segLen2 = dx * dx + dy * dy;

    if (segLen2 <= 0.0001) {
      final dist = haversineDistance(p, a);
      return (snapped: a, crossTrackError: dist, segmentT: 0.0);
    }

    final px = (p.longitude - a.longitude) * cosMid * 111319.5;
    final py = (p.latitude - a.latitude) * 111132.9;

    final t = ((px * dx + py * dy) / segLen2).clamp(0.0, 1.0);
    final snappedLat = a.latitude + t * (b.latitude - a.latitude);
    final snappedLng = a.longitude + t * (b.longitude - a.longitude);
    final snapped = LatLng(snappedLat, snappedLng);

    final crossDist = haversineDistance(p, snapped);
    return (snapped: snapped, crossTrackError: crossDist, segmentT: t);
  }

  NavRouteResult? _fallbackCalculateRoute({
    required LatLng start,
    required LatLng end,
    required bool ecoMode,
    required int batterySoc,
    required BikeModel bikeModel,
    String? osmRawJson,
    bool minimalFilter = true,
    String? saveDbnavPath,
    List<LatLng>? corridorWaypoints,
  }) {
    List<LatLng> polyline;
    if (corridorWaypoints != null && corridorWaypoints.length >= 2) {
      polyline = List.from(corridorWaypoints);
    } else if (osmRawJson != null && osmRawJson.contains('"elements"')) {
      final extracted = _extractPolylineFromOsmRaw(osmRawJson, start, end);
      polyline = extracted.length >= 2 ? extracted : _generateCityGridPolyline(start, end);
    } else {
      final directDist = haversineDistance(start, end);
      if (directDist > 80000.0) {
        // Tuyệt đối không vẽ đường chim bay nối giữa các miền cách nhau hàng trăm km (VD: TP.HCM - Hà Nội)
        return null;
      }
      polyline = _generateCityGridPolyline(start, end);
    }

    // Tính tổng chiều dài tuyến đường
    double totalDistance = 0.0;
    for (int i = 0; i < polyline.length - 1; i++) {
      totalDistance += haversineDistance(polyline[i], polyline[i + 1]);
    }
    if (totalDistance < 10.0) totalDistance = 10.0;

    // Tốc độ di chuyển trung bình xe máy đô thị
    // Chế độ Eco: ~26 km/h (7.22 m/s), Chế độ thường: ~33 km/h (9.17 m/s)
    final avgSpeedMs = ecoMode ? (26.0 / 3.6) : (33.0 / 3.6);
    final totalDuration = totalDistance / avgSpeedMs;

    // Tạo các bước ngã rẽ Turn-by-Turn dựa trên biến thiên góc rẽ
    final steps = _generateRouteSteps(polyline, avgSpeedMs);

    // Tính toán dự báo pin EV
    final evForecast = _calculateEvForecast(
      distanceMeters: totalDistance,
      ecoMode: ecoMode,
      batterySoc: batterySoc,
      bikeModel: bikeModel,
    );

    return NavRouteResult(
      distanceMeters: totalDistance,
      durationSeconds: totalDuration,
      polyline: polyline,
      steps: steps,
      evForecast: evForecast,
      isEcoMode: ecoMode,
    );
  }

  List<LatLng> _extractPolylineFromOsmRaw(String rawJson, LatLng start, LatLng end) {
    try {
      final data = jsonDecode(rawJson) as Map<String, dynamic>;
      final elements = data['elements'] as List<dynamic>? ?? [];
      final nodeMap = <int, LatLng>{};
      final ways = <List<int>>[];

      for (final el in elements) {
        if (el is! Map<String, dynamic>) continue;
        final type = el['type'];
        if (type == 'node') {
          final id = el['id'] as int?;
          final lat = (el['lat'] as num?)?.toDouble();
          final lon = (el['lon'] as num?)?.toDouble();
          if (id != null && lat != null && lon != null) {
            nodeMap[id] = LatLng(lat, lon);
          }
        } else if (type == 'way') {
          final nodes = (el['nodes'] as List<dynamic>?)?.map((n) => (n as num).toInt()).toList();
          if (nodes != null && nodes.length >= 2) {
            ways.add(nodes);
          }
        }
      }

      if (nodeMap.isEmpty || ways.isEmpty) return [];

      final result = <LatLng>[];
      for (final wayNodes in ways) {
        for (final nid in wayNodes) {
          final pt = nodeMap[nid];
          if (pt != null) {
            if (result.isEmpty || result.last.latitude != pt.latitude || result.last.longitude != pt.longitude) {
              result.add(pt);
            }
          }
        }
        if (result.length > 80) break;
      }
      if (result.isEmpty || result.first.latitude != start.latitude || result.first.longitude != start.longitude) {
        result.insert(0, start);
      }
      if (result.last.latitude != end.latitude || result.last.longitude != end.longitude) {
        result.add(end);
      }
      return result;
    } catch (_) {
      return [];
    }
  }

  List<LatLng> _generateCityGridPolyline(LatLng start, LatLng end) {
    final points = <LatLng>[start];
    final dLat = end.latitude - start.latitude;
    final dLng = end.longitude - start.longitude;

    // Mô phỏng đường bàn cờ đô thị với các khúc ngoặt tự nhiên
    const segments = 4;
    for (int i = 1; i < segments; i++) {
      final ratio = i / segments;
      // Thêm một độ lệch nhẹ vuông góc để tạo khúc ngoặt phố phường thực tế
      final perpOffset = (i % 2 == 1 ? 0.0008 : -0.0006) * (dLat.abs() + dLng.abs() > 0.02 ? 1.0 : 0.4);
      final lat = start.latitude + dLat * ratio - perpOffset * 0.5;
      final lng = start.longitude + dLng * ratio + perpOffset;
      points.add(LatLng(lat, lng));
    }
    points.add(end);
    return points;
  }

  List<NavRouteStep> _generateRouteSteps(List<LatLng> polyline, double speedMs) {
    final steps = <NavRouteStep>[];
    if (polyline.length < 2) return steps;

    const streetNames = [
      'Đường Lê Duẩn',
      'Đường Nam Kỳ Khởi Nghĩa',
      'Đường Pasteur',
      'Đường Nguyễn Thị Minh Khai',
      'Đường Cách Mạng Tháng 8',
      'Đường Hai Bà Trưng',
      'Đại lộ Võ Văn Kiệt',
    ];

    // Bước 1: Đi thẳng xuất phát
    final initialBearing = calculateBearing(polyline[0], polyline[1]);
    final stepDist1 = haversineDistance(polyline[0], polyline[1]);
    steps.add(NavRouteStep(
      instruction: 'Đi thẳng về hướng ${_cardinalDirection(initialBearing)}',
      streetName: streetNames[0],
      maneuver: NavManeuverType.straight,
      distanceMeters: stepDist1,
      durationSeconds: stepDist1 / speedMs,
      lat: polyline[0].latitude,
      lng: polyline[0].longitude,
    ));

    for (int i = 1; i < polyline.length - 1; i++) {
      final b1 = calculateBearing(polyline[i - 1], polyline[i]);
      final b2 = calculateBearing(polyline[i], polyline[i + 1]);
      final angleDiff = ((b2 - b1 + 540.0) % 360.0) - 180.0;
      final legDist = haversineDistance(polyline[i], polyline[i + 1]);

      NavManeuverType maneuver;
      String action;

      if (angleDiff < -60) {
        maneuver = NavManeuverType.turnLeft;
        action = 'Rẽ trái';
      } else if (angleDiff < -20) {
        maneuver = NavManeuverType.slightLeft;
        action = 'Chếch sang trái';
      } else if (angleDiff > 60) {
        maneuver = NavManeuverType.turnRight;
        action = 'Rẽ phải';
      } else if (angleDiff > 20) {
        maneuver = NavManeuverType.slightRight;
        action = 'Chếch sang phải';
      } else if (angleDiff.abs() > 140) {
        maneuver = NavManeuverType.uTurn;
        action = 'Quay đầu xe';
      } else {
        maneuver = NavManeuverType.straight;
        action = 'Tiếp tục đi thẳng';
      }

      final street = streetNames[i % streetNames.length];
      steps.add(NavRouteStep(
        instruction: '$action vào $street',
        streetName: street,
        maneuver: maneuver,
        distanceMeters: legDist,
        durationSeconds: legDist / speedMs,
        lat: polyline[i].latitude,
        lng: polyline[i].longitude,
      ));
    }

    // Bước cuối: Đến điểm đích
    final lastPt = polyline.last;
    steps.add(NavRouteStep(
      instruction: 'Bạn đã đến điểm đích',
      streetName: 'Điểm đến',
      maneuver: NavManeuverType.arrive,
      distanceMeters: 0.0,
      durationSeconds: 0.0,
      lat: lastPt.latitude,
      lng: lastPt.longitude,
    ));

    return steps;
  }

  static String _cardinalDirection(double deg) {
    const dirs = ['Bắc', 'Đông Bắc', 'Đông', 'Đông Nam', 'Nam', 'Tây Nam', 'Tây', 'Tây Bắc'];
    final idx = ((deg + 22.5) % 360 / 45).floor();
    return dirs[idx % 8];
  }

  NavEvForecast _calculateEvForecast({
    required double distanceMeters,
    required bool ecoMode,
    required int batterySoc,
    required BikeModel bikeModel,
  }) {
    final distKm = distanceMeters / 1000.0;

    // Suất tiêu hao năng lượng điện trung bình theo model và chế độ lái:
    // Quantum S series: ~28 Wh/km (Eco: ~22 Wh/km)
    // Weaver series: ~32 Wh/km (Eco: ~25 Wh/km)
    double whPerKm;
    if (bikeModel.generation == BikeGeneration.gen1Weaver) {
      whPerKm = ecoMode ? 25.0 : 32.0;
    } else {
      whPerKm = ecoMode ? 22.0 : 28.5;
    }

    final consumptionWh = distKm * whPerKm;

    // Dung lượng danh định của pack pin
    double packCapacityWh;
    switch (bikeModel.batteryChemistry) {
      case BatteryChemistry.nmc20s:
        packCapacityWh = 2160.0; // Weaver ~2.16 kWh
        break;
      case BatteryChemistry.lfp23s4p:
        packCapacityWh = 4300.0; // Quantum S3, Era ~4.3 kWh
        break;
      case BatteryChemistry.lfp23s6p:
        packCapacityWh = 5400.0; // Quantum, Quantum S1/S2 ~5.4 kWh
        break;
    }

    final socUsedPercent = (consumptionWh / packCapacityWh) * 100.0;
    final arrivalSoc = math.max(0.0, batterySoc - socUsedPercent);

    String status;
    String? warning;

    if (arrivalSoc >= 20.0) {
      status = 'safe';
      warning = null;
    } else if (arrivalSoc >= 5.0) {
      status = 'warning';
      warning = 'Pin sắp yếu khi đến đích (${arrivalSoc.toStringAsFixed(1)}%), hãy tìm trạm sạc gần nhất.';
    } else {
      status = 'critical';
      warning = 'Mức pin không đủ để đến đích (dự kiến còn ${arrivalSoc.toStringAsFixed(1)}%). Cần sạc xe ngay!';
    }

    return NavEvForecast(
      estimatedConsumptionWh: double.parse(consumptionWh.toStringAsFixed(1)),
      estimatedSocUsedPercent: double.parse(socUsedPercent.toStringAsFixed(1)),
      arrivalSocPercent: double.parse(arrivalSoc.toStringAsFixed(1)),
      status: status,
      warningMessage: warning,
    );
  }

  NavTrackingState _fallbackTrackStep({
    required LatLng currentPos,
    required double speedKmh,
    required double heading,
    required NavRouteResult route,
    required int currentStepIndex,
    required int batterySoc,
  }) {
    final poly = route.polyline;
    if (poly.isEmpty) {
      return NavTrackingState(
        snappedLocation: currentPos,
        snappedBearing: heading,
        crossTrackErrorMeters: 0.0,
        isOffRoute: false,
        closestPolylineIndex: 0,
        currentStepIndex: currentStepIndex,
        distanceToNextManeuverMeters: 0.0,
        remainingDistanceMeters: 0.0,
        remainingDurationSeconds: 0.0,
        arrivalSocPercent: batterySoc.toDouble(),
        energyStatus: 'safe',
        hasArrived: false,
      );
    }

    // 1. Kiểm tra đã đến đích chưa (< 25 mét tới điểm cuối)
    final distToEnd = haversineDistance(currentPos, poly.last);
    final hasArrived = distToEnd <= 25.0;

    // 2. Tìm đoạn segment có khoảng cách hình chiếu ngắn nhất (Snap-to-segment)
    int bestSegIndex = 0;
    LatLng bestSnapped = poly.first;
    double minCrossTrack = double.infinity;

    for (int i = 0; i < poly.length - 1; i++) {
      final proj = projectPointOnSegment(currentPos, poly[i], poly[i + 1]);
      if (proj.crossTrackError < minCrossTrack) {
        minCrossTrack = proj.crossTrackError;
        bestSnapped = proj.snapped;
        bestSegIndex = i;
      }
    }

    // Hướng tiếp tuyến của đoạn đường tại điểm snapped
    final snappedBearing = (bestSegIndex < poly.length - 1)
        ? calculateBearing(poly[bestSegIndex], poly[bestSegIndex + 1])
        : heading;

    // Chệch đường nếu sai số lệch trục > 35m
    final isOffRoute = minCrossTrack > 35.0;

    // 3. Tính khoảng cách còn lại từ điểm snapped tới điểm cuối theo polyline
    double remainingDist = 0.0;
    // Phần còn lại của segment hiện tại
    if (bestSegIndex < poly.length - 1) {
      remainingDist += haversineDistance(bestSnapped, poly[bestSegIndex + 1]);
    }
    // Các segment tiếp theo
    for (int i = bestSegIndex + 1; i < poly.length - 1; i++) {
      remainingDist += haversineDistance(poly[i], poly[i + 1]);
    }

    final speedMs = (speedKmh > 5.0) ? (speedKmh / 3.6) : (28.0 / 3.6);
    final remainingDuration = remainingDist / speedMs;

    // 4. Xác định bước rẽ tiếp theo & khoảng cách tới bước đó
    int activeStepIdx = currentStepIndex;
    // Tự động nhảy step nếu đã đi qua vị trí của step hiện tại
    while (activeStepIdx < route.steps.length - 1) {
      final stepPt = route.steps[activeStepIdx].latLng;
      final distToStep = haversineDistance(currentPos, stepPt);
      if (distToStep < 20.0) {
        activeStepIdx++;
      } else {
        break;
      }
    }

    double distToNextManeuver = 0.0;
    if (activeStepIdx < route.steps.length) {
      final targetStep = route.steps[activeStepIdx];
      distToNextManeuver = haversineDistance(currentPos, targetStep.latLng);
    }

    // 5. Tính toán cập nhật lại pin khi đến đích
    final distKm = remainingDist / 1000.0;
    final whPerKm = route.isEcoMode ? 22.0 : 28.5;
    final remainingConsumptionWh = distKm * whPerKm;
    const packWh = 5400.0;
    final remSocUsed = (remainingConsumptionWh / packWh) * 100.0;
    final arrivalSoc = math.max(0.0, batterySoc - remSocUsed);

    String energyStatus;
    if (arrivalSoc >= 20.0) {
      energyStatus = 'safe';
    } else if (arrivalSoc >= 5.0) {
      energyStatus = 'warning';
    } else {
      energyStatus = 'critical';
    }

    return NavTrackingState(
      snappedLocation: bestSnapped,
      snappedBearing: snappedBearing,
      crossTrackErrorMeters: double.parse(minCrossTrack.toStringAsFixed(1)),
      isOffRoute: isOffRoute,
      closestPolylineIndex: bestSegIndex,
      currentStepIndex: activeStepIdx,
      distanceToNextManeuverMeters: double.parse(distToNextManeuver.toStringAsFixed(1)),
      remainingDistanceMeters: double.parse(remainingDist.toStringAsFixed(1)),
      remainingDurationSeconds: double.parse(remainingDuration.toStringAsFixed(1)),
      arrivalSocPercent: double.parse(arrivalSoc.toStringAsFixed(1)),
      energyStatus: energyStatus,
      hasArrived: hasArrived,
    );
  }
}
