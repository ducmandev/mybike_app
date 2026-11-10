import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart' hide Path;

import '../../../core/ble/ble_controller.dart';
import '../../../core/services/map_tile_service.dart';
import '../../../core/services/trip_gps_tracker.dart';
import '../../../ui/app_theme.dart';
import 'offline_map_sheet.dart';

/// Chế độ góc nhìn xoay camera bản đồ
enum MapCameraMode {
  northUp,   // Cố định Hướng Bắc (0 độ)
  headingUp, // Xoay theo Hướng Xe đang di chuyển
  overview,  // Góc nhìn Tổng Quan Lộ Trình
}

/// Màn hình Độc Lập Toàn Màn Hình Bản Đồ Hành Trình (Full-Bleed Viền Tràn)
/// Hỗ trợ mở trực tiếp từ Dashboard hoặc các màn hình khác
class FullScreenNavigationPage extends StatelessWidget {
  final double currentSpeedKmh;
  final int? batteryPercent;
  final double? voltage;

  const FullScreenNavigationPage({
    super.key,
    this.currentSpeedKmh = 0.0,
    this.batteryPercent,
    this.voltage,
  });

  static Route<void> route({
    double currentSpeedKmh = 0.0,
    int? batteryPercent,
    double? voltage,
  }) {
    return MaterialPageRoute(
      builder: (_) => FullScreenNavigationPage(
        currentSpeedKmh: currentSpeedKmh,
        batteryPercent: batteryPercent,
        voltage: voltage,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: CockpitLiveMap(
        height: double.infinity,
        isFullScreen: true,
        currentSpeedKmh: currentSpeedKmh,
        batteryPercent: batteryPercent,
        voltage: voltage,
        onExpandFullScreen: () => Navigator.of(context).maybePop(),
      ),
    );
  }
}

/// Widget Bản Đồ Lái Xe Thời Gian Thực & Đồng Hồ Tốc Độ Kép (Live Cockpit Map & Dual Speedometer HUD)
/// Thiết kế đồng bộ hoàn hảo theo ngôn ngữ Kinetic Stitch EV (Space Grotesk, Hairline Border)
/// - Hiển thị bản đồ xe đang di chuyển thực tế (Breadcrumbs với dải màu tốc độ liên tục)
/// - Bảng báo tốc độ kép: Tốc độ xe (ECU/BLE) song song với tốc độ tính từ GPS
/// - La bàn tương tác xoay đa góc nhìn (Hướng Bắc, Theo hướng xe, Tổng quan)
class CockpitLiveMap extends ConsumerStatefulWidget {
  final double currentSpeedKmh;
  final VoidCallback? onExpandFullScreen;
  final double? height;
  final bool isFullScreen;
  final int? batteryPercent;
  final double? voltage;
  final VoidCallback? onTurnOn;
  final VoidCallback? onTurnOff;
  final VoidCallback? onToggleLock;
  final bool? isLocked;
  final bool powerBusy;

  const CockpitLiveMap({
    super.key,
    required this.currentSpeedKmh,
    this.onExpandFullScreen,
    this.height,
    this.isFullScreen = false,
    this.batteryPercent,
    this.voltage,
    this.onTurnOn,
    this.onTurnOff,
    this.onToggleLock,
    this.isLocked,
    this.powerBusy = false,
  });

  @override
  ConsumerState<CockpitLiveMap> createState() => _CockpitLiveMapState();
}

class _CockpitLiveMapState extends ConsumerState<CockpitLiveMap> {
  late final MapController _mapController;
  StreamSubscription<TripGpsPoint>? _pointSub;
  List<TripGpsPoint> _liveRoute = [];
  List<double> _gpsSpeedHistory = [];

  double _currentGpsSpeed = 0.0;
  double _currentHeading = 0.0;
  double _mapRotation = 0.0;

  // Mặc định sử dụng bản đồ Tối Giản (100% OpenStreetMap Free qua bộ lọc GPU làm dịu chi tiết thừa)
  MapTileStyle _tileStyle = MapTileStyle.minimalLight;
  MapCameraMode _cameraMode = MapCameraMode.northUp;
  bool _followBike = true;
  bool _isLocating = false;
  LatLng? _myLocation;
  bool _hasInitialCentered = false;

  void _moveCameraSafely(LatLng target, double zoom) {
    if (!mounted) return;
    try {
      _mapController.move(target, zoom);
      _hasInitialCentered = true;
    } catch (_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        try {
          _mapController.move(target, zoom);
          _hasInitialCentered = true;
        } catch (_) {}
      });
    }
  }

  static String _shortCardinal(double deg) {
    const dirs = ['B', 'ĐB', 'Đ', 'ĐN', 'N', 'TN', 'T', 'TB'];
    final idx = ((deg + 22.5) % 360 / 45).floor();
    return dirs[idx % 8];
  }

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    _liveRoute = TripGpsTracker.instance.getCurrentRoute();

    final cp = TripGpsTracker.instance.currentPoint;
    final lp = TripGpsTracker.instance.lastPosition;
    if (cp != null) {
      _myLocation = LatLng(cp.lat, cp.lng);
    } else if (lp != null) {
      _myLocation = LatLng(lp.latitude, lp.longitude);
    } else if (_liveRoute.isNotEmpty) {
      _myLocation = LatLng(_liveRoute.last.lat, _liveRoute.last.lng);
    }

    _gpsSpeedHistory = _liveRoute.map((p) => p.speedKmh).toList();
    if (_gpsSpeedHistory.length > 30) {
      _gpsSpeedHistory = _gpsSpeedHistory.sublist(_gpsSpeedHistory.length - 30);
    }
    if (_liveRoute.isNotEmpty) {
      _currentGpsSpeed = _liveRoute.last.speedKmh;
      _currentHeading = _liveRoute.last.heading ?? 0.0;
    }

    // Lắng nghe điểm GPS mới khi xe di chuyển trong thời gian thực
    _pointSub = TripGpsTracker.instance.onPointRecorded.listen((newPoint) {
      if (!mounted) return;
      final newLoc = LatLng(newPoint.lat, newPoint.lng);
      setState(() {
        _liveRoute.add(newPoint);
        _myLocation = newLoc;
        _currentGpsSpeed = newPoint.speedKmh;
        _currentHeading = newPoint.heading ?? 0.0;

        _gpsSpeedHistory.add(newPoint.speedKmh);
        if (_gpsSpeedHistory.length > 30) {
          _gpsSpeedHistory.removeAt(0);
        }
      });

      if (_followBike) {
        if (_cameraMode == MapCameraMode.headingUp) {
          _mapController.rotate(-_currentHeading);
        }
        _mapController.move(newLoc, _mapController.camera.zoom);
      }
    });

    // Lấy ngay vị trí hiện tại khi vừa mở dashboard
    _locateMe(moveCamera: true);
  }

  @override
  void dispose() {
    _pointSub?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _locateMe({bool moveCamera = true}) async {
    if (_isLocating) return;
    setState(() => _isLocating = true);
    try {
      final pos = await TripGpsTracker.instance.getCurrentLocation();
      if (!mounted) return;

      if (pos != null) {
        final loc = LatLng(pos.latitude, pos.longitude);
        setState(() => _myLocation = loc);
        if (moveCamera) {
          _moveCameraSafely(loc, widget.isFullScreen ? 16.5 : 16.0);
        }
      } else {
        final parked = await ParkingStorageService.instance.loadParkedLocation();
        if (!mounted) return;
        if (parked != null) {
          final loc = LatLng(parked.latitude, parked.longitude);
          if (mounted) setState(() => _myLocation ??= loc);
          if (moveCamera) {
            _moveCameraSafely(loc, widget.isFullScreen ? 16.5 : 16.0);
          }
        }
      }
    } catch (_) {
    } finally {
      if (mounted) {
        setState(() => _isLocating = false);
      }
    }
  }

  void _showNotice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: GoogleFonts.plusJakartaSans(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        duration: const Duration(seconds: 1),
        backgroundColor: const Color(0xFF0F172A),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  void _toggleCameraMode() {
    setState(() {
      switch (_cameraMode) {
        case MapCameraMode.northUp:
          _cameraMode = MapCameraMode.headingUp;
          _mapController.rotate(-_currentHeading);
          _showNotice('Góc nhìn: Xoay theo hướng xe (${_currentHeading.toStringAsFixed(0)}°)');
          break;
        case MapCameraMode.headingUp:
          _cameraMode = MapCameraMode.overview;
          _mapController.rotate(0);
          if (_liveRoute.length >= 2) {
            _mapController.fitCamera(
              CameraFit.bounds(
                bounds: LatLngBounds.fromPoints(
                  _liveRoute.map((p) => LatLng(p.lat, p.lng)).toList(),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 90),
              ),
            );
          } else if (_myLocation != null) {
            _mapController.move(_myLocation!, 15.0);
          }
          _showNotice('Góc nhìn: Tổng quan lộ trình');
          break;
        case MapCameraMode.overview:
          _cameraMode = MapCameraMode.northUp;
          _mapController.rotate(0);
          if (_myLocation != null) {
            _mapController.move(_myLocation!, 16.5);
          }
          _showNotice('Góc nhìn: Cố định Hướng Bắc');
          break;
      }
    });
  }

  void _cycleTileStyle() {
    setState(() {
      const styles = MapTileStyle.values;
      final nextIndex = (styles.indexOf(_tileStyle) + 1) % styles.length;
      _tileStyle = styles[nextIndex];
    });
    _showNotice('Bản đồ: ${MapTileService.getStyleName(_tileStyle)}');
  }

  void _showMapStyleMenu() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return Container(
          decoration: const BoxDecoration(
            color: Color(0xFF0F172A),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            border: Border(top: BorderSide(color: Color(0xFF334155), width: 1)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFF475569),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Icon(Icons.layers_rounded, color: Color(0xFF06B6D4), size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Chọn Giao Diện Bản Đồ',
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Lọc bớt nhãn khu phố/phường hoặc xem đầy đủ địa danh',
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 12,
                  color: const Color(0xFF94A3B8),
                ),
              ),
              const SizedBox(height: 16),
              for (final style in MapTileStyle.values)
                InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    setState(() => _tileStyle = style);
                    _showNotice('Đã đổi: ${MapTileService.getStyleName(style)}');
                  },
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: _tileStyle == style
                          ? const Color(0xFF06B6D4).withValues(alpha: 0.15)
                          : const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: _tileStyle == style
                            ? const Color(0xFF06B6D4)
                            : const Color(0xFF334155),
                        width: _tileStyle == style ? 1.5 : 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _tileStyle == style
                                ? const Color(0xFF06B6D4).withValues(alpha: 0.25)
                                : const Color(0xFF334155),
                          ),
                          child: Icon(
                            MapTileService.getStyleIcon(style),
                            size: 18,
                            color: _tileStyle == style ? const Color(0xFF06B6D4) : Colors.white70,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      MapTileService.getStyleName(style),
                                      style: GoogleFonts.spaceGrotesk(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.white,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (MapTileService.isMinimal(style)) ...[
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF10B981).withValues(alpha: 0.2),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        'TỐI GIẢN',
                                        style: GoogleFonts.plusJakartaSans(
                                          fontSize: 8.5,
                                          fontWeight: FontWeight.w800,
                                          color: const Color(0xFF10B981),
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                MapTileService.getStyleDescription(style),
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 11,
                                  color: const Color(0xFF94A3B8),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        if (_tileStyle == style)
                          const Icon(Icons.check_circle_rounded, color: Color(0xFF06B6D4), size: 20),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Color _getContinuousSpeedColor(double speedKmh) {
    if (speedKmh <= 15.0) {
      final t = (speedKmh / 15.0).clamp(0.0, 1.0);
      return Color.lerp(const Color(0xFF06B6D4), const Color(0xFF10B981), t)!;
    } else if (speedKmh <= 35.0) {
      final t = ((speedKmh - 15.0) / 20.0).clamp(0.0, 1.0);
      return Color.lerp(const Color(0xFF10B981), const Color(0xFF0EA5E9), t)!;
    } else if (speedKmh <= 55.0) {
      final t = ((speedKmh - 35.0) / 20.0).clamp(0.0, 1.0);
      return Color.lerp(const Color(0xFFF59E0B), const Color(0xFFF97316), t)!;
    } else {
      final t = ((speedKmh - 55.0) / 30.0).clamp(0.0, 1.0);
      return Color.lerp(const Color(0xFFF97316), const Color(0xFFEF4444), t)!;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bleState = ref.watch(bleProvider);
    final bikeSpeed = bleState.lastTelemetry?.speed ?? widget.currentSpeedKmh;
    final gpsSpeed = _currentGpsSpeed;

    final hasRoute = _liveRoute.isNotEmpty;
    final lastPoint = hasRoute ? _liveRoute.last : null;
    final isTracking = TripGpsTracker.instance.isTracking;

    final centerCoord = _myLocation ??
        (lastPoint != null
            ? LatLng(lastPoint.lat, lastPoint.lng)
            : const LatLng(10.7719, 106.7195));

    final mapHeight = widget.isFullScreen ? widget.height : (widget.height ?? 220.0);
    final topPadding = MediaQuery.of(context).padding.top;
    final fullScreenTopOffset = math.max(topPadding, 8.0) + 6.0;

    return Container(
      height: mapHeight,
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: widget.isFullScreen ? BorderRadius.zero : BorderRadius.circular(20),
        border: widget.isFullScreen ? null : Border.all(color: AppColors.panelBorderBright, width: 1),
        boxShadow: widget.isFullScreen ? null : AppColors.cardShadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          // 1. BẢN ĐỒ FLUTTER_MAP THỜI GIAN THỰC
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: centerCoord,
              initialZoom: 16.0,
              initialRotation: _mapRotation,
              onMapReady: () {
                final target = _myLocation ??
                    (lastPoint != null ? LatLng(lastPoint.lat, lastPoint.lng) : null);
                if (target != null) {
                  _moveCameraSafely(target, widget.isFullScreen ? 16.5 : 16.0);
                }
              },
              onTap: (tapPosition, point) {
                if (!_hasInitialCentered) {
                  final target = _myLocation ??
                      (lastPoint != null ? LatLng(lastPoint.lat, lastPoint.lng) : null);
                  if (target != null) {
                    _moveCameraSafely(target, widget.isFullScreen ? 16.5 : 16.0);
                  } else {
                    _locateMe(moveCamera: true);
                  }
                }
                if (!widget.isFullScreen && widget.onExpandFullScreen != null) {
                  widget.onExpandFullScreen!();
                }
              },
              onPositionChanged: (position, hasGesture) {
                if (hasGesture && !_hasInitialCentered) {
                  if (_myLocation != null) {
                    _moveCameraSafely(_myLocation!, widget.isFullScreen ? 16.5 : 16.0);
                  } else {
                    _locateMe(moveCamera: true);
                    _hasInitialCentered = true;
                  }
                }
                if (hasGesture && _cameraMode == MapCameraMode.headingUp) {
                  _cameraMode = MapCameraMode.northUp;
                }
                if (position.rotation != _mapRotation) {
                  setState(() => _mapRotation = position.rotation);
                }
              },
            ),
            children: [
              // Tile Layer (Hỗ trợ Tối Giản Positron lọc bớt khu phố/phường & Chi Tiết)
              MapTileService.buildTileLayer(style: _tileStyle),

              // Polyline Lộ trình xe đang di chuyển thực tế (Breadcrumbs)
              if (hasRoute) ...[
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _liveRoute.map((p) => LatLng(p.lat, p.lng)).toList(),
                      strokeWidth: 8.0,
                      strokeCap: StrokeCap.round,
                      strokeJoin: StrokeJoin.round,
                      color: AppColors.primary.withValues(alpha: 0.22),
                    ),
                  ],
                ),
                PolylineLayer(
                  polylines: [
                    for (int i = 0; i < _liveRoute.length - 1; i++)
                      Polyline(
                        points: [
                          LatLng(_liveRoute[i].lat, _liveRoute[i].lng),
                          LatLng(_liveRoute[i + 1].lat, _liveRoute[i + 1].lng),
                        ],
                        strokeWidth: 5.0,
                        strokeCap: StrokeCap.round,
                        strokeJoin: StrokeJoin.round,
                        gradientColors: [
                          _getContinuousSpeedColor(_liveRoute[i].speedKmh),
                          _getContinuousSpeedColor(_liveRoute[i + 1].speedKmh),
                        ],
                      ),
                  ],
                ),
              ],

              // Marker Vị trí xe Dat Bike với mũi tên xoay theo hướng đi thực tế
              MarkerLayer(
                markers: [
                  if (_myLocation != null || lastPoint != null)
                    Marker(
                      point: _myLocation ?? LatLng(lastPoint!.lat, lastPoint.lng),
                      width: 52,
                      height: 52,
                      child: _buildLiveBikeMarker(
                        bikeSpeed,
                        lastPoint?.heading ?? _currentHeading,
                      ),
                    ),
                ],
              ),
            ],
          ),

          // 2. HEADER TOP Ở CHẾ ĐỘ THU NHỎ (DASHBOARD COMPACT MODE - !widget.isFullScreen)
          if (!widget.isFullScreen)
            Positioned(
              top: 8,
              left: 8,
              right: 8,
              child: Row(
                children: [
                  // Chips: La bàn hướng đi, Tốc độ Xe, Tốc độ GPS
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      physics: const BouncingScrollPhysics(),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 1. Chip La bàn hướng đi
                          ClipRRect(
                            borderRadius: BorderRadius.circular(9999),
                            child: BackdropFilter(
                              filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                                decoration: BoxDecoration(
                                  color: AppColors.panel.withValues(alpha: 0.94),
                                  borderRadius: BorderRadius.circular(9999),
                                  border: Border.all(color: AppColors.panelBorderBright),
                                  boxShadow: AppColors.cardShadow,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Transform.rotate(
                                      angle: (_currentHeading * math.pi) / 180.0,
                                      child: const Icon(
                                        Icons.navigation_rounded,
                                        size: 14,
                                        color: AppColors.primary,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      '${_currentHeading.toStringAsFixed(0).padLeft(3, '0')}° ${_shortCardinal(_currentHeading)}',
                                      style: GoogleFonts.spaceGrotesk(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.textPrimary,
                                        fontFeatures: const [FontFeature.tabularFigures()],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          // 2. Chip Tốc độ Xe (ECU/BLE)
                          ClipRRect(
                            borderRadius: BorderRadius.circular(9999),
                            child: BackdropFilter(
                              filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                                decoration: BoxDecoration(
                                  color: AppColors.panel.withValues(alpha: 0.94),
                                  borderRadius: BorderRadius.circular(9999),
                                  border: Border.all(color: AppColors.panelBorderBright),
                                  boxShadow: AppColors.cardShadow,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.speed_rounded,
                                      size: 13,
                                      color: AppColors.primary,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      'XE: ${bikeSpeed.toStringAsFixed(0)} km/h',
                                      style: GoogleFonts.spaceGrotesk(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.textPrimary,
                                        fontFeatures: const [FontFeature.tabularFigures()],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          // 3. Chip Tốc độ GPS
                          ClipRRect(
                            borderRadius: BorderRadius.circular(9999),
                            child: BackdropFilter(
                              filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                                decoration: BoxDecoration(
                                  color: AppColors.panel.withValues(alpha: 0.94),
                                  borderRadius: BorderRadius.circular(9999),
                                  border: Border.all(
                                    color: isTracking
                                        ? AppColors.tertiary.withValues(alpha: 0.35)
                                        : AppColors.panelBorderBright,
                                  ),
                                  boxShadow: AppColors.cardShadow,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 7,
                                      height: 7,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: isTracking ? AppColors.tertiary : AppColors.secondary,
                                      ),
                                    ),
                                    const SizedBox(width: 5),
                                    Text(
                                      'GPS: ${gpsSpeed.toStringAsFixed(1)} km/h',
                                      style: GoogleFonts.spaceGrotesk(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.textPrimary,
                                        fontFeatures: const [FontFeature.tabularFigures()],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Nút công cụ thu nhỏ: Đổi kiểu, Offline, Phóng to
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _miniGlassBtn(
                        icon: MapTileService.getStyleIcon(_tileStyle),
                        tooltip: MapTileService.getStyleName(_tileStyle),
                        onTap: _cycleTileStyle,
                      ),
                      const SizedBox(width: 6),
                      _miniGlassBtn(
                        icon: Icons.download_for_offline_rounded,
                        tooltip: 'Tải bản đồ offline',
                        onTap: () {
                          OfflineMapSheet.show(
                            context,
                            currentMapBounds: _mapController.camera.visibleBounds,
                          );
                        },
                      ),
                      if (widget.onExpandFullScreen != null) ...[
                        const SizedBox(width: 6),
                        _miniGlassBtn(
                          icon: Icons.fullscreen_rounded,
                          tooltip: 'Phóng to bản đồ',
                          onTap: widget.onExpandFullScreen!,
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),

          // 3. THANH HEADER TRÊN CÙNG KHI Ở CHẾ ĐỘ TOÀN MÀN HÌNH (widget.isFullScreen == true)
          if (widget.isFullScreen)
            Positioned(
              top: fullScreenTopOffset,
              left: 12,
              right: 12,
              child: Row(
                children: [
                  // Nút Back
                  if (widget.onExpandFullScreen != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 8.0),
                      child: _miniGlassBtn(
                        icon: Icons.arrow_back_rounded,
                        tooltip: 'Quay lại',
                        onTap: widget.onExpandFullScreen!,
                      ),
                    ),

                  // Ở giữa: Thẻ kính mờ hiển thị tiêu đề 'BẢN ĐỒ HÀNH TRÌNH XE' + Hướng la bàn
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: AppColors.panel.withValues(alpha: 0.95),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: AppColors.panelBorderBright, width: 1.2),
                            boxShadow: AppColors.cardShadow,
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 28,
                                height: 28,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: AppColors.primary.withValues(alpha: 0.15),
                                ),
                                child: const Icon(
                                  Icons.map_rounded,
                                  size: 16,
                                  color: AppColors.primary,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'BẢN ĐỒ HÀNH TRÌNH XE',
                                      style: GoogleFonts.spaceGrotesk(
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w800,
                                        color: AppColors.textPrimary,
                                        letterSpacing: 0.3,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 1),
                                    Text(
                                      'Hướng di chuyển: ${_currentHeading.toStringAsFixed(0).padLeft(3, '0')}° ${_shortCardinal(_currentHeading)}',
                                      style: GoogleFonts.plusJakartaSans(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.textDim,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),

                  // Bên phải: Nút chọn giao diện bản đồ
                  Padding(
                    padding: const EdgeInsets.only(left: 8.0),
                    child: _miniGlassBtn(
                      icon: MapTileService.isMinimal(_tileStyle)
                          ? Icons.layers_clear_rounded
                          : Icons.layers_rounded,
                      iconColor: MapTileService.isMinimal(_tileStyle)
                          ? const Color(0xFF10B981)
                          : AppColors.textPrimary,
                      tooltip: 'Giao diện bản đồ (${MapTileService.getStyleName(_tileStyle)})',
                      onTap: _showMapStyleMenu,
                    ),
                  ),
                ],
              ),
            ),

          // 4. NÚT ĐIỀU HƯỚNG TRÊN BẢN ĐỒ (Bên phải: La Bàn Xoay + Vị trí của tôi + Bám xe + Offline + Menu Layer)
          Positioned(
            bottom: widget.isFullScreen ? 148 : 48,
            right: 10,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Chỉ hiển thị La Bàn Tương Tác và Đổi Kiểu Bản Đồ trên cột phải khi ở chế độ FullScreen
                if (widget.isFullScreen) ...[
                  _buildCompassButton(),
                  const SizedBox(height: 8),
                ],

                // Nút định vị bản thân
                _miniGlassBtn(
                  icon: Icons.my_location_rounded,
                  iconColor: _isLocating ? AppColors.primary : AppColors.textPrimary,
                  isActive: _isLocating,
                  tooltip: 'Vị trí của tôi',
                  onTap: () => _locateMe(moveCamera: true),
                ),
                const SizedBox(height: 8),

                // Nút bám theo xe
                _miniGlassBtn(
                  icon: Icons.navigation_rounded,
                  iconColor: _followBike ? AppColors.primary : AppColors.textPrimary,
                  isActive: _followBike,
                  tooltip: _followBike ? 'Đang bám xe' : 'Tự do xoay bản đồ',
                  onTap: () {
                    setState(() => _followBike = !_followBike);
                    if (_followBike && (_myLocation != null || lastPoint != null)) {
                      _mapController.move(
                        _myLocation ?? LatLng(lastPoint!.lat, lastPoint.lng),
                        _mapController.camera.zoom,
                      );
                    }
                  },
                ),

                if (widget.isFullScreen) ...[
                  const SizedBox(height: 8),
                  // Nút tải bản đồ offline trực tiếp trên màn hình bản đồ lớn
                  _miniGlassBtn(
                    icon: Icons.download_for_offline_rounded,
                    tooltip: 'Tải bản đồ offline',
                    onTap: () {
                      OfflineMapSheet.show(
                        context,
                        currentMapBounds: _mapController.camera.visibleBounds,
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  // Nút mở nhanh menu Giao diện Bản đồ Tối Giản / Chi Tiết
                  _miniGlassBtn(
                    icon: MapTileService.isMinimal(_tileStyle)
                        ? Icons.layers_clear_rounded
                        : Icons.layers_rounded,
                    iconColor: MapTileService.isMinimal(_tileStyle)
                        ? const Color(0xFF10B981)
                        : AppColors.textPrimary,
                    tooltip: 'Giao diện bản đồ (${MapTileService.getStyleName(_tileStyle)})',
                    onTap: _showMapStyleMenu,
                  ),
                ],
              ],
            ),
          ),

          // 5. BẢNG BÁO TỐC ĐỘ DƯỚI ĐÁY BẢN ĐỒ THU NHỎ (DASHBOARD COMPACT BOTTOM BAR - !widget.isFullScreen)
          if (!widget.isFullScreen)
            Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                  child: Container(
                    height: 34,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.panel.withValues(alpha: 0.94),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.panelBorderBright),
                      boxShadow: AppColors.cardShadow,
                    ),
                    child: Row(
                      children: [
                        // Bên trái: TỐC ĐỘ XE
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.speed_rounded, size: 14, color: AppColors.primary),
                            const SizedBox(width: 4),
                            Text(
                              'TỐC ĐỘ XE: ',
                              style: GoogleFonts.spaceGrotesk(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w800,
                                color: AppColors.textDim,
                                letterSpacing: 0.3,
                              ),
                            ),
                            Text(
                              '${bikeSpeed.toStringAsFixed(0)} km/h',
                              style: GoogleFonts.spaceGrotesk(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                color: AppColors.primary,
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                            ),
                          ],
                        ),
                        // Ở giữa: Biểu đồ sparkline nếu history >= 2
                        if (_gpsSpeedHistory.length >= 2) ...[
                          const SizedBox(width: 8),
                          Expanded(
                            child: CustomPaint(
                              size: const Size(double.infinity, 22),
                              painter: _GpsSpeedSparklinePainter(
                                history: _gpsSpeedHistory,
                                color: AppColors.secondary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                        ] else ...[
                          const Spacer(),
                        ],
                        // Bên phải: TỐC ĐỘ GPS
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: isTracking ? AppColors.tertiary : AppColors.secondary,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'TỐC ĐỘ GPS: ',
                              style: GoogleFonts.spaceGrotesk(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w800,
                                color: AppColors.textDim,
                                letterSpacing: 0.3,
                              ),
                            ),
                            Text(
                              '${gpsSpeed.toStringAsFixed(1)} km/h',
                              style: GoogleFonts.spaceGrotesk(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                color: AppColors.secondary,
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // 6. BẢNG BÁO TỐC ĐỘ KÉP TOÀN MÀN HÌNH (DUAL SPEEDOMETER TELEMETRY HUD CARD - widget.isFullScreen == true)
          if (widget.isFullScreen)
            Positioned(
              bottom: 14,
              left: 12,
              right: 12,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: AppColors.panel.withValues(alpha: 0.95),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: AppColors.panelBorderBright, width: 1.2),
                      boxShadow: AppColors.cardShadow,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Hàng hiển thị song song 2 đồng hồ tốc độ (50% - 50%)
                        Row(
                          children: [
                            // Cột trái — TỐC ĐỘ XE (ECU)
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(
                                        Icons.speed_rounded,
                                        size: 15,
                                        color: AppColors.primary,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        'TỐC ĐỘ XE',
                                        style: GoogleFonts.spaceGrotesk(
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w800,
                                          color: AppColors.textDim,
                                          letterSpacing: 0.5,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Row(
                                    crossAxisAlignment: CrossAxisAlignment.baseline,
                                    textBaseline: TextBaseline.alphabetic,
                                    children: [
                                      Text(
                                        bikeSpeed.toStringAsFixed(1),
                                        style: GoogleFonts.spaceGrotesk(
                                          fontSize: 26,
                                          fontWeight: FontWeight.w800,
                                          color: AppColors.textPrimary,
                                          fontFeatures: const [FontFeature.tabularFigures()],
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        'km/h',
                                        style: GoogleFonts.spaceGrotesk(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700,
                                          color: AppColors.primary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),

                            // Vạch ngăn cách dọc
                            Container(
                              width: 1,
                              height: 44,
                              color: AppColors.panelBorderBright,
                            ),

                            // Cột phải — TỐC ĐỘ GPS
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.only(left: 12.0),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Row(
                                      children: [
                                        Container(
                                          width: 7,
                                          height: 7,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: isTracking
                                                ? AppColors.tertiary
                                                : const Color(0xFF0EA5E9),
                                          ),
                                        ),
                                        const SizedBox(width: 5),
                                        Text(
                                          'TỐC ĐỘ GPS',
                                          style: GoogleFonts.spaceGrotesk(
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w800,
                                            color: AppColors.textDim,
                                            letterSpacing: 0.5,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 2),
                                    Row(
                                      crossAxisAlignment: CrossAxisAlignment.baseline,
                                      textBaseline: TextBaseline.alphabetic,
                                      children: [
                                        Text(
                                          gpsSpeed.toStringAsFixed(1),
                                          style: GoogleFonts.spaceGrotesk(
                                            fontSize: 26,
                                            fontWeight: FontWeight.w800,
                                            color: const Color(0xFF0EA5E9),
                                            fontFeatures: const [FontFeature.tabularFigures()],
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          'km/h',
                                          style: GoogleFonts.spaceGrotesk(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                            color: const Color(0xFF0EA5E9),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),

                        // Hàng thông tin phụ bên dưới
                        const Divider(height: 12, color: AppColors.panelBorderBright),
                        Row(
                          children: [
                            // Độ lệch: ${(bikeSpeed - gpsSpeed).abs().toStringAsFixed(1)} km/h
                            Text(
                              'Độ lệch: ${(bikeSpeed - gpsSpeed).abs().toStringAsFixed(1)} km/h',
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textDim,
                              ),
                            ),
                            const SizedBox(width: 8),
                            // Sparkline ở giữa nếu history >= 2
                            if (_gpsSpeedHistory.length >= 2) ...[
                              Expanded(
                                child: SizedBox(
                                  height: 18,
                                  child: CustomPaint(
                                    size: const Size(double.infinity, 18),
                                    painter: _GpsSpeedSparklinePainter(
                                      history: _gpsSpeedHistory,
                                      color: const Color(0xFF0EA5E9),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                            ] else ...[
                              const Spacer(),
                            ],
                            // Trạng thái GPS
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  isTracking ? Icons.gps_fixed_rounded : Icons.gps_not_fixed_rounded,
                                  size: 12,
                                  color: isTracking ? AppColors.tertiary : AppColors.textDim,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  'GPS: ${isTracking ? "Đang theo dõi" : "Sẵn sàng"}',
                                  style: GoogleFonts.plusJakartaSans(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: isTracking ? AppColors.tertiary : AppColors.textDim,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // =========================================================================
  // SUB-WIDGETS: COMPASS & LIVE BIKE MARKER
  // =========================================================================

  /// Nút La Bàn Tương Tác Xoay Đa Góc Nhìn (Interactive Map Compass)
  Widget _buildCompassButton() {
    final label = _cameraMode == MapCameraMode.northUp
        ? 'BẮC'
        : (_cameraMode == MapCameraMode.headingUp ? 'XE' : 'TỔNG');
    final color = _cameraMode == MapCameraMode.northUp
        ? AppColors.textPrimary
        : (_cameraMode == MapCameraMode.headingUp ? const Color(0xFF06B6D4) : AppColors.primary);

    return Tooltip(
      message: 'Góc nhìn: ${_cameraMode == MapCameraMode.northUp ? "Cố định Hướng Bắc (chạm để đổi)" : (_cameraMode == MapCameraMode.headingUp ? "Theo hướng xe chạy (chạm để đổi)" : "Tổng quan lộ trình (chạm để đổi)")}',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _toggleCameraMode,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
              child: Container(
                width: 38,
                height: 46,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: AppColors.panel.withValues(alpha: 0.94),
                  border: Border.all(
                    color: _cameraMode != MapCameraMode.northUp
                        ? color.withValues(alpha: 0.6)
                        : AppColors.panelBorderBright,
                    width: _cameraMode != MapCameraMode.northUp ? 1.5 : 1,
                  ),
                  boxShadow: AppColors.cardShadow,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Transform.rotate(
                      angle: -(_mapRotation * math.pi) / 180.0,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          const Icon(Icons.navigation_rounded, color: Color(0xFFEF4444), size: 18),
                          Transform.rotate(
                            angle: math.pi,
                            child: const Icon(Icons.navigation_rounded, color: Color(0xFF94A3B8), size: 12),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      label,
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 8.5,
                        fontWeight: FontWeight.w800,
                        color: color,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLiveBikeMarker(double speedKmh, double heading) {
    // Mũi tên xe Dat Bike xoay đồng bộ góc nhìn màn hình: (heading + _mapRotation)
    final relativeAngle = ((heading + _mapRotation) * math.pi) / 180.0;

    return Transform.rotate(
      angle: relativeAngle,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.primary.withValues(alpha: 0.20),
              border: Border.all(
                color: AppColors.primary.withValues(alpha: 0.45),
                width: 1.5,
              ),
            ),
          ),
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.primary,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x4D2563EB),
                  blurRadius: 8,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: const Center(
              child: Icon(
                Icons.navigation_rounded,
                color: Colors.white,
                size: 15,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _miniGlassBtn({
    required IconData icon,
    required VoidCallback onTap,
    String? tooltip,
    Color? iconColor,
    bool isActive = false,
  }) {
    return Tooltip(
      message: tooltip ?? '',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
              child: Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color:
                      isActive ? const Color(0xFFEFF6FF) : AppColors.panel.withValues(alpha: 0.94),
                  border: Border.all(
                    color: isActive ? AppColors.primary : AppColors.panelBorderBright,
                    width: 1,
                  ),
                  boxShadow: AppColors.cardShadow,
                ),
                child: Icon(
                  icon,
                  color: iconColor ?? (isActive ? AppColors.primary : AppColors.textPrimary),
                  size: 20,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GpsSpeedSparklinePainter extends CustomPainter {
  final List<double> history;
  final Color color;

  _GpsSpeedSparklinePainter({required this.history, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (history.length < 2) return;

    final maxVal = history.reduce(math.max).clamp(20.0, 120.0);
    const minVal = 0.0;
    final range = maxVal - minVal;

    final path = Path();
    final fillPath = Path();

    final stepX = size.width / (history.length - 1);

    for (int i = 0; i < history.length; i++) {
      final x = i * stepX;
      final normalized = ((history[i] - minVal) / range).clamp(0.0, 1.0);
      final y = size.height - (normalized * (size.height - 4)) - 2;

      if (i == 0) {
        path.moveTo(x, y);
        fillPath.moveTo(x, size.height);
        fillPath.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fillPath.lineTo(x, y);
      }

      if (i == history.length - 1) {
        fillPath.lineTo(x, size.height);
        fillPath.close();

        final dotPaint = Paint()
          ..color = color
          ..style = PaintingStyle.fill;
        canvas.drawCircle(Offset(x, y), 2.2, dotPaint);
      }
    }

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          color.withValues(alpha: 0.22),
          color.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.drawPath(fillPath, fillPaint);

    final linePaint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(_GpsSpeedSparklinePainter old) =>
      old.history.length != history.length ||
      (history.isNotEmpty && old.history.isNotEmpty && old.history.last != history.last);
}
