import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart' hide Path;

import '../../../core/ble/ble_controller.dart';
import '../../../core/navigation/nav_models.dart';
import '../../../core/navigation/navigation_controller.dart';
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

/// Màn hình Độc Lập Toàn Màn Hình Tìm Đường & Điều Hướng On-Device (Full-Bleed Viền Tràn)
/// Hỗ trợ mở trực tiếp từ bất kỳ màn hình nào (Dashboard, MyBikeScreen, v.v.)
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

/// Widget Bản Đồ Lái Xe Thời Gian Thực (Live GPS Cockpit Map) trên Dashboard
/// Thiết kế đồng bộ hoàn hảo theo ngôn ngữ Kinetic Stitch EV (Space Grotesk, Hairline Border)
/// - Hỗ trợ Chế độ Tối Giản (Positron - lọc sạch nhãn khu phố / tổ dân phố thừa) & Chi Tiết.
/// - La bàn tương tác xoay đa góc nhìn (Hướng Bắc, Theo hướng xe, Tổng quan).
/// - Màn hình tìm đường tràn viền full-bleed chỉ giữ nút Back thoáng đãng.
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
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
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
  bool _showSearchResultsDropdown = false;

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

      // Cập nhật vị trí GPS vào Engine Điều hướng Turn-by-Turn
      final bleState = ref.read(bleProvider);
      ref.read(navigationProvider.notifier).updateGpsPosition(
            newLoc,
            newPoint.speedKmh,
            newPoint.heading ?? 0.0,
            batterySoc: widget.batteryPercent ?? bleState.lastTelemetry?.percent,
            bikeModel: bleState.bikeModel,
          );

      if (_followBike) {
        if (_cameraMode == MapCameraMode.headingUp) {
          _mapController.rotate(-_currentHeading);
        }
        _mapController.move(newLoc, _mapController.camera.zoom);
      }
    });

    // Lấy ngay vị trí hiện tại khi vừa mở dashboard
    _locateMe(moveCamera: false);
  }

  @override
  void dispose() {
    _pointSub?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _locateMe({bool moveCamera = true}) async {
    if (_isLocating) return;
    setState(() => _isLocating = true);
    final pos = await TripGpsTracker.instance.getCurrentLocation();
    if (!mounted) return;
    setState(() => _isLocating = false);

    if (pos != null) {
      final loc = LatLng(pos.latitude, pos.longitude);
      setState(() => _myLocation = loc);
      if (moveCamera) {
        _mapController.move(loc, 16.5);
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
          final activeRoute = ref.read(navigationProvider).activeRoute;
          if (activeRoute != null && activeRoute.polyline.length >= 2) {
            _mapController.fitCamera(
              CameraFit.bounds(
                bounds: LatLngBounds.fromPoints(activeRoute.polyline),
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
    final isMin = MapTileService.isMinimal(_tileStyle);
    ref.read(navigationProvider.notifier).setMinimalMapMode(isMin);
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
                    final isMin = MapTileService.isMinimal(style);
                    ref.read(navigationProvider.notifier).setMinimalMapMode(isMin);
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

  Color _getEvStatusColor(String status) {
    switch (status) {
      case 'critical':
        return const Color(0xFFEF4444);
      case 'warning':
        return const Color(0xFFF59E0B);
      case 'safe':
      default:
        return const Color(0xFF10B981);
    }
  }

  @override
  Widget build(BuildContext context) {
    final navState = ref.watch(navigationProvider);
    final bleState = ref.watch(bleProvider);

    ref.listen<NavigationState>(navigationProvider, (previous, next) {
      if (next.activeRoute != null && previous?.activeRoute != next.activeRoute) {
        final poly = next.activeRoute!.polyline;
        if (poly.length >= 2) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            try {
              _mapController.fitCamera(
                CameraFit.bounds(
                  bounds: LatLngBounds.fromPoints(poly),
                  padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 80),
                ),
              );
            } catch (_) {}
          });
        }
      }
    });

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

    // Chuẩn bị các đoạn phân chia Polyline điều hướng đã đi / sắp đi
    List<LatLng> passedPolyline = [];
    List<LatLng> upcomingPolyline = [];
    if (navState.activeRoute != null && navState.activeRoute!.polyline.isNotEmpty) {
      final poly = navState.activeRoute!.polyline;
      final splitIdx = (navState.tracking?.closestPolylineIndex ?? 0).clamp(0, poly.length - 1);
      final snappedPt = navState.tracking?.snappedLocation;

      passedPolyline = poly.sublist(0, splitIdx + 1);
      if (snappedPt != null) {
        passedPolyline.add(snappedPt);
        upcomingPolyline = [snappedPt, ...poly.sublist(splitIdx + 1)];
      } else {
        upcomingPolyline = poly.sublist(splitIdx);
      }
    }

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
              onPositionChanged: (position, hasGesture) {
                if (hasGesture && _cameraMode == MapCameraMode.headingUp) {
                  _cameraMode = MapCameraMode.northUp;
                }
                if (position.rotation != _mapRotation) {
                  setState(() => _mapRotation = position.rotation);
                }
              },
              onLongPress: (tapPosition, point) {
                if (widget.isFullScreen) {
                  final curPos = _myLocation ??
                      (lastPoint != null
                          ? LatLng(lastPoint.lat, lastPoint.lng)
                          : _mapController.camera.center);
                  ref.read(navigationProvider.notifier).selectPointOnMap(
                        point,
                        currentPos: curPos,
                        batterySoc: widget.batteryPercent ?? bleState.lastTelemetry?.percent,
                        bikeModel: bleState.bikeModel,
                      );
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

              // Tuyến đường điều hướng On-Device Rust (PolylineLayer)
              if (navState.activeRoute != null) ...[
                // Đoạn đường đã đi qua: màu xám mờ
                if (passedPolyline.length >= 2)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: passedPolyline,
                        strokeWidth: 4.5,
                        strokeCap: StrokeCap.round,
                        strokeJoin: StrokeJoin.round,
                        color: const Color(0xFF64748B).withValues(alpha: 0.45),
                      ),
                    ],
                  ),
                // Đoạn đường sắp tới: viền phát sáng Cyan + lõi xanh neon
                if (upcomingPolyline.length >= 2)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: upcomingPolyline,
                        strokeWidth: 8.5,
                        strokeCap: StrokeCap.round,
                        strokeJoin: StrokeJoin.round,
                        color: const Color(0xFF06B6D4).withValues(alpha: 0.35),
                      ),
                      Polyline(
                        points: upcomingPolyline,
                        strokeWidth: 5.5,
                        strokeCap: StrokeCap.round,
                        strokeJoin: StrokeJoin.round,
                        color: const Color(0xFF06B6D4),
                      ),
                    ],
                  ),
              ],

              // Marker Điểm Đích (Destination)
              if (navState.destination != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: navState.destination!.latLng,
                      width: 44,
                      height: 52,
                      child: _buildDestinationMarker(navState.destination!),
                    ),
                  ],
                ),

              // Marker Vị trí xe Dat Bike với mũi tên xoay theo hướng đi thực tế
              MarkerLayer(
                markers: [
                  if (_myLocation != null || lastPoint != null)
                    Marker(
                      point: _myLocation ?? LatLng(lastPoint!.lat, lastPoint.lng),
                      width: 52,
                      height: 52,
                      child: _buildLiveBikeMarker(
                        widget.currentSpeedKmh,
                        lastPoint?.heading ?? _currentHeading,
                      ),
                    ),
                ],
              ),
            ],
          ),

          // 2. HEADER TOP Ở CHẾ ĐỘ THU NHỎ (DASHBOARD COMPACT MODE - widget.isFullScreen == false)
          // Khi ở màn hình tìm đường FullScreen thì ẨN HOÀN TOÀN để màn hình thoáng đãng, chỉ giữ nút Back!
          if (!widget.isFullScreen)
            Positioned(
              top: 8,
              left: 8,
              right: 8,
              child: Row(
                children: [
                  // Chips la bàn & tốc độ GPS (co giãn linh hoạt)
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      physics: const NeverScrollableScrollPhysics(),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
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
                                      'GPS: ${_currentGpsSpeed.toStringAsFixed(1)}',
                                      style: GoogleFonts.spaceGrotesk(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.textPrimary,
                                        fontFeatures: const [FontFeature.tabularFigures()],
                                      ),
                                    ),
                                    const SizedBox(width: 2),
                                    Text(
                                      'km/h',
                                      style: GoogleFonts.plusJakartaSans(
                                        fontSize: 9.5,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.textDim,
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
                  // Nút công cụ thu nhỏ
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

          // 3. MÀN HÌNH TÌM ĐƯỜNG FULL-SCREEN (widget.isFullScreen == true && !navState.isNavigating):
          // CHỈ GIỮ NÚT BACK Ở GÓC TRÁI + THANH TÌM KIẾM + NÚT ĐỔI LAYOUT TỐI GIẢN
          if (widget.isFullScreen && !navState.isNavigating)
            Positioned(
              top: fullScreenTopOffset,
              left: 12,
              right: 12,
              child: _buildFullScreenSearchBarRow(context, navState, bleState),
            ),

          // 4. HỘP CHỈ DẪN HUD TURN-BY-TURN KHI ĐANG DẪN ĐƯỜNG (widget.isFullScreen == true && isNavigating == true)
          // Có Nút Back để quay lại màn hình chính bất kỳ lúc nào
          if (widget.isFullScreen && navState.activeRoute != null && navState.isNavigating)
            Positioned(
              top: fullScreenTopOffset,
              left: 12,
              right: 12,
              child: _buildTurnByTurnHudBox(context, navState),
            ),

          // 5. NÚT ĐIỀU HƯỚNG TRÊN BẢN ĐỒ (Bên phải: La Bàn Xoay + Đổi Góc Nhìn + Vị trí của tôi + Bám xe)
          Positioned(
            bottom: (widget.isFullScreen || navState.activeRoute != null)
                ? 140
                : ((_gpsSpeedHistory.length >= 2) ? 46 : 12),
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

          // 5.5 CHỈ BÁO ĐANG TÍNH ĐƯỜNG BỘ THỰC TẾ
          if (navState.isCalculatingRoute)
            Positioned(
              top: widget.isFullScreen ? (fullScreenTopOffset + 58) : 50,
              left: 20,
              right: 20,
              child: Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(9999),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0B132B).withValues(alpha: 0.94),
                        borderRadius: BorderRadius.circular(9999),
                        border: Border.all(color: const Color(0xFF06B6D4), width: 1.2),
                        boxShadow: AppColors.cardShadow,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Color(0xFF06B6D4),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Đang tải tuyến đường bộ thực tế...',
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

          // 5.6 THÔNG BÁO LỖI NẾU CÓ
          if (navState.errorMessage != null)
            Positioned(
              top: widget.isFullScreen ? (fullScreenTopOffset + 58) : 50,
              left: 14,
              right: 14,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEF4444).withValues(alpha: 0.95),
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: AppColors.cardShadow,
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline_rounded, color: Colors.white, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          navState.errorMessage!,
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                          maxLines: 2,
                        ),
                      ),
                      GestureDetector(
                        onTap: () => ref.read(navigationProvider.notifier).clearRoute(),
                        child: const Icon(Icons.close_rounded, color: Colors.white, size: 18),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // 6. THẺ XEM TRƯỚC LỘ TRÌNH & PIN EV (EV ROUTE PREVIEW CARD)
          if (widget.isFullScreen && navState.activeRoute != null && !navState.isNavigating)
            Positioned(
              bottom: 12,
              left: 12,
              right: 12,
              child: _buildRoutePreviewCard(context, navState, bleState),
            ),

          // 7. BIỂU ĐỒ TỐC ĐỘ GPS (SPARKLINE CHART) (khi ở dashboard thu nhỏ)
          if (!widget.isFullScreen && navState.activeRoute == null && _gpsSpeedHistory.length >= 2)
            Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                  child: Container(
                    height: 28,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.panel.withValues(alpha: 0.94),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.panelBorderBright),
                      boxShadow: AppColors.cardShadow,
                    ),
                    child: Row(
                      children: [
                        Text(
                          'GPS SPEED',
                          style: GoogleFonts.spaceGrotesk(
                            fontSize: 8.5,
                            fontWeight: FontWeight.w800,
                            color: AppColors.textDim,
                            letterSpacing: 0.3,
                          ),
                        ),
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
                        const SizedBox(width: 6),
                        Text(
                          '${_currentGpsSpeed.toStringAsFixed(0)} km/h',
                          style: GoogleFonts.spaceGrotesk(
                            fontSize: 9.5,
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
            ),

          // 8. MINI TURN-BY-TURN PILL (Khi ở chế độ bản đồ thu nhỏ widget.isFullScreen == false && activeRoute != null)
          if (!widget.isFullScreen && navState.activeRoute != null)
            Positioned(
              bottom: 8,
              left: 8,
              right: 8,
              child: _buildMiniTurnPill(context, navState),
            ),
        ],
      ),
    );
  }

  // =========================================================================
  // SUB-WIDGETS: HUD, SEARCH & PREVIEW CARDS
  // =========================================================================

  /// Thanh Tìm kiếm toàn màn hình: CHỈ GIỮ NÚT BACK Ở GÓC TRÁI + SEARCH BAR + NÚT ĐỔI STYLE
  Widget _buildFullScreenSearchBarRow(
    BuildContext context,
    NavigationState navState,
    BleState bleState,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            // NÚT BACK DUY NHẤT ĐỂ QUAY LẠI MÀN HÌNH CHÍNH (ĐỂ MÀN HÌNH THOÁNG ĐÃNG)
            if (widget.onExpandFullScreen != null)
              Padding(
                padding: const EdgeInsets.only(right: 8.0),
                child: _miniGlassBtn(
                  icon: Icons.arrow_back_rounded,
                  tooltip: 'Thu nhỏ về mặc định',
                  onTap: widget.onExpandFullScreen!,
                ),
              ),

            // THANH NHẬP TÌM KIẾM
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.panel.withValues(alpha: 0.95),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppColors.panelBorderBright, width: 1.2),
                      boxShadow: AppColors.cardShadow,
                    ),
                    child: Row(
                      children: [
                        if (navState.isSearching)
                          const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.2,
                              color: AppColors.primary,
                            ),
                          )
                        else
                          const Icon(Icons.search_rounded, color: AppColors.primary, size: 22),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _searchController,
                            focusNode: _searchFocusNode,
                            textInputAction: TextInputAction.search,
                            onSubmitted: (val) {
                              ref.read(navigationProvider.notifier).searchPlacesImmediately(val);
                            },
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary,
                            ),
                            decoration: InputDecoration(
                              isDense: true,
                              hintText: 'Tìm điểm đến, trạm sạc Dat Charge...',
                              hintStyle: GoogleFonts.plusJakartaSans(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w500,
                                color: AppColors.textDim,
                              ),
                              border: InputBorder.none,
                            ),
                            onChanged: (val) {
                              setState(() => _showSearchResultsDropdown = val.trim().isNotEmpty);
                              ref.read(navigationProvider.notifier).searchPlaces(val);
                            },
                          ),
                        ),
                        if (_searchController.text.isNotEmpty)
                          GestureDetector(
                            onTap: () {
                              _searchController.clear();
                              ref.read(navigationProvider.notifier).clearSearch();
                              setState(() => _showSearchResultsDropdown = false);
                            },
                            child: const Padding(
                              padding: EdgeInsets.all(4.0),
                              child: Icon(Icons.close_rounded, size: 18, color: AppColors.textDim),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // NÚT ĐỔI GIAO DIỆN BẢN ĐỒ (TỐI GIẢN / CHI TIẾT)
            Padding(
              padding: const EdgeInsets.only(left: 8.0),
              child: _miniGlassBtn(
                icon: MapTileService.isMinimal(_tileStyle)
                    ? Icons.layers_clear_rounded
                    : Icons.layers_rounded,
                tooltip: 'Giao diện bản đồ (${MapTileService.getStyleName(_tileStyle)})',
                onTap: _showMapStyleMenu,
              ),
            ),
          ],
        ),

        // Quick suggestions chips (khi ô tìm kiếm trống và chưa chọn đích)
        if (navState.destination == null && !_showSearchResultsDropdown) ...[
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildQuickChip(
                  icon: Icons.ev_station_rounded,
                  label: 'Trạm Sạc Dat Charge',
                  onTap: () {
                    _searchController.text = 'Trạm Sạc Dat Charge';
                    ref.read(navigationProvider.notifier).searchPlaces('Trạm Sạc Dat Charge');
                    setState(() => _showSearchResultsDropdown = true);
                  },
                ),
                const SizedBox(width: 6),
                _buildQuickChip(
                  icon: Icons.storefront_rounded,
                  label: 'Chợ Bến Thành',
                  onTap: () {
                    _selectLandmarkByKeyword('Chợ Bến Thành', bleState);
                  },
                ),
                const SizedBox(width: 6),
                _buildQuickChip(
                  icon: Icons.apartment_rounded,
                  label: 'Landmark 81',
                  onTap: () {
                    _selectLandmarkByKeyword('Landmark 81', bleState);
                  },
                ),
              ],
            ),
          ),
        ],

        // Search Results Dropdown List
        if (_showSearchResultsDropdown) ...[
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                constraints: const BoxConstraints(maxHeight: 220),
                decoration: BoxDecoration(
                  color: AppColors.panel.withValues(alpha: 0.98),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.panelBorderBright),
                  boxShadow: AppColors.cardShadow,
                ),
                child: navState.searchResults.isNotEmpty
                    ? ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        shrinkWrap: true,
                        itemCount: navState.searchResults.length,
                        separatorBuilder: (context, index) =>
                            const Divider(height: 1, color: AppColors.panelBorderBright),
                        itemBuilder: (context, idx) {
                          final item = navState.searchResults[idx];
                          final isCharging = item.category == 'charging_station';
                          return ListTile(
                            dense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                            leading: Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: isCharging
                                    ? const Color(0xFF10B981).withValues(alpha: 0.15)
                                    : AppColors.primary.withValues(alpha: 0.12),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                isCharging ? Icons.ev_station_rounded : Icons.location_on_rounded,
                                size: 18,
                                color: isCharging ? const Color(0xFF10B981) : AppColors.primary,
                              ),
                            ),
                            title: Text(
                              item.shortName,
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textPrimary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              item.displayName,
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 10.5,
                                color: AppColors.textDim,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () {
                              _searchFocusNode.unfocus();
                              setState(() => _showSearchResultsDropdown = false);
                              final curPos = _myLocation ??
                                  (TripGpsTracker.instance.getCurrentRoute().isNotEmpty
                                      ? LatLng(
                                          TripGpsTracker.instance.getCurrentRoute().last.lat,
                                          TripGpsTracker.instance.getCurrentRoute().last.lng)
                                      : _mapController.camera.center);
                              ref.read(navigationProvider.notifier).selectDestination(
                                    item,
                                    currentPos: curPos,
                                    batterySoc: widget.batteryPercent ?? bleState.lastTelemetry?.percent,
                                    bikeModel: bleState.bikeModel,
                                  );
                              _mapController.move(item.latLng, 15.5);
                            },
                          );
                        },
                      )
                    : (navState.isSearching
                        ? Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: AppColors.primary,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Đang tìm kiếm...',
                                  style: GoogleFonts.plusJakartaSans(
                                    fontSize: 12,
                                    color: AppColors.textDim,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 14.0),
                            child: Row(
                              children: [
                                const Icon(Icons.search_off_rounded, size: 20, color: AppColors.textDim),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Không tìm thấy địa điểm phù hợp',
                                    style: GoogleFonts.plusJakartaSans(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.textDim,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          )),
              ),
            ),
          ),
        ],
      ],
    );
  }

  void _selectLandmarkByKeyword(String keyword, BleState bleState) {
    for (final lm in PlaceSearchService.builtInLandmarks) {
      if (lm.shortName.contains(keyword)) {
        final curPos = _myLocation ??
            (TripGpsTracker.instance.getCurrentRoute().isNotEmpty
                ? LatLng(
                    TripGpsTracker.instance.getCurrentRoute().last.lat,
                    TripGpsTracker.instance.getCurrentRoute().last.lng)
                : _mapController.camera.center);
        ref.read(navigationProvider.notifier).selectDestination(
              lm,
              currentPos: curPos,
              batterySoc: widget.batteryPercent ?? bleState.lastTelemetry?.percent,
              bikeModel: bleState.bikeModel,
            );
        _mapController.move(lm.latLng, 15.5);
        break;
      }
    }
  }

  Widget _buildQuickChip({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(9999),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: AppColors.panel.withValues(alpha: 0.94),
              borderRadius: BorderRadius.circular(9999),
              border: Border.all(color: AppColors.panelBorderBright),
              boxShadow: AppColors.cardShadow,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 13, color: AppColors.primary),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRoutePreviewCard(
    BuildContext context,
    NavigationState navState,
    BleState bleState,
  ) {
    final route = navState.activeRoute!;
    final forecast = route.evForecast;
    final statusColor = _getEvStatusColor(forecast.status);

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.panel.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppColors.panelBorderBright, width: 1.2),
            boxShadow: AppColors.cardShadow,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Hàng tiêu đề: Tên điểm đến + Nút Hủy
              Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF06B6D4).withValues(alpha: 0.15),
                    ),
                    child: const Icon(Icons.place_rounded, color: Color(0xFF06B6D4), size: 18),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          navState.destination?.shortName ?? 'Điểm đến',
                          style: GoogleFonts.spaceGrotesk(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '${route.formattedDistance} • ${route.formattedDuration}',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textDim,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 20, color: AppColors.textDim),
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      ref.read(navigationProvider.notifier).clearRoute();
                    },
                  ),
                ],
              ),

              const SizedBox(height: 10),

              // Dự báo Pin EV Dat Bike
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: statusColor.withValues(alpha: 0.25)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.battery_charging_full_rounded, color: statusColor, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                'Pin dự kiến tại đích: ',
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                              Text(
                                '${forecast.arrivalSocPercent.toStringAsFixed(0)}%',
                                style: GoogleFonts.spaceGrotesk(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                  color: statusColor,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '(-${forecast.estimatedSocUsedPercent.toStringAsFixed(1)}%)',
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 10,
                                  color: AppColors.textDim,
                                ),
                              ),
                            ],
                          ),
                          if (forecast.warningMessage != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              forecast.warningMessage!,
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w600,
                                color: statusColor,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 10),

              // Nút chuyển chế độ Nhanh nhất / Eco & Nút Bắt đầu đi
              Row(
                children: [
                  // Toggle Eco Mode
                  InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () {
                      final curPos = _myLocation ??
                          (TripGpsTracker.instance.getCurrentRoute().isNotEmpty
                              ? LatLng(
                                  TripGpsTracker.instance.getCurrentRoute().last.lat,
                                  TripGpsTracker.instance.getCurrentRoute().last.lng)
                              : null);
                      ref.read(navigationProvider.notifier).toggleEcoMode(
                            currentPos: curPos,
                            batterySoc:
                                widget.batteryPercent ?? bleState.lastTelemetry?.percent,
                            bikeModel: bleState.bikeModel,
                          );
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: navState.ecoMode
                            ? const Color(0xFF10B981).withValues(alpha: 0.15)
                            : AppColors.panelBorderBright.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: navState.ecoMode
                              ? const Color(0xFF10B981)
                              : AppColors.panelBorderBright,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            navState.ecoMode ? Icons.eco_rounded : Icons.speed_rounded,
                            size: 16,
                            color: navState.ecoMode
                                ? const Color(0xFF10B981)
                                : AppColors.textDim,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            navState.ecoMode ? 'Eco Tiết Kiệm' : 'Nhanh Nhất',
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: navState.ecoMode
                                  ? const Color(0xFF10B981)
                                  : AppColors.textPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(width: 8),

                  // Nút BẮT ĐẦU ĐI
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF06B6D4),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        elevation: 0,
                      ),
                      icon: const Icon(Icons.navigation_rounded, size: 16),
                      label: Text(
                        'BẮT ĐẦU ĐI',
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
                        ),
                      ),
                      onPressed: () {
                        ref.read(navigationProvider.notifier).startNavigation();
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTurnByTurnHudBox(BuildContext context, NavigationState navState) {
    final route = navState.activeRoute!;
    final tracking = navState.tracking;
    final stepIdx = tracking?.currentStepIndex ?? 0;
    final currentStep = (stepIdx < route.steps.length) ? route.steps[stepIdx] : route.steps.last;
    final maneuver = currentStep.maneuver;
    final distToManeuver = tracking?.formattedDistanceToManeuver ?? '150 m';
    final arrivalSoc = tracking?.arrivalSocPercent ?? route.evForecast.arrivalSocPercent;
    final remDist = tracking?.formattedRemainingDistance ?? route.formattedDistance;
    final remTime = tracking?.formattedRemainingTime ?? route.formattedDuration;

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF0B132B).withValues(alpha: 0.94),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFF06B6D4).withValues(alpha: 0.4), width: 1.5),
            boxShadow: const [
              BoxShadow(
                color: Color(0x3306B6D4),
                blurRadius: 16,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  // NÚT BACK QUAY LẠI MÀN HÌNH CHÍNH NGAY KHI ĐANG DẪN ĐƯỜNG
                  if (widget.onExpandFullScreen != null) ...[
                    Padding(
                      padding: const EdgeInsets.only(right: 8.0),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: widget.onExpandFullScreen,
                        child: Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Colors.white24),
                          ),
                          child: const Icon(Icons.arrow_back_rounded, color: Colors.white, size: 20),
                        ),
                      ),
                    ),
                  ],

                  // Icon mũi tên rẽ lớn nổi bật
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: const Color(0xFF06B6D4).withValues(alpha: 0.2),
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFF06B6D4), width: 2),
                    ),
                    child: Center(
                      child: Icon(maneuver.icon, color: const Color(0xFF06B6D4), size: 28),
                    ),
                  ),
                  const SizedBox(width: 10),

                  // Thông số rẽ & câu chỉ dẫn
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          distToManeuver,
                          style: GoogleFonts.spaceGrotesk(
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                            height: 1.0,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          currentStep.instruction,
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFFE2E8F0),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),

                  // Nút DỪNG
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFEF4444),
                      side: const BorderSide(color: Color(0xFFEF4444)),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      minimumSize: Size.zero,
                    ),
                    onPressed: () {
                      ref.read(navigationProvider.notifier).stopNavigation();
                    },
                    child: Text(
                      'DỪNG',
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Divider(height: 1, color: Color(0xFF1E293B)),
              const SizedBox(height: 6),
              // Thông tin đáy: Tổng còn lại, Thời gian còn lại, Pin dự kiến
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Còn: $remDist • $remTime',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF94A3B8),
                    ),
                  ),
                  Row(
                    children: [
                      const Icon(Icons.battery_charging_full_rounded,
                          size: 14, color: Color(0xFF10B981)),
                      const SizedBox(width: 3),
                      Text(
                        'Pin tới: ${arrivalSoc.toStringAsFixed(0)}%',
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: const Color(0xFF10B981),
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
    );
  }

  Widget _buildMiniTurnPill(BuildContext context, NavigationState navState) {
    final route = navState.activeRoute!;
    final tracking = navState.tracking;
    final stepIdx = tracking?.currentStepIndex ?? 0;
    final currentStep = (stepIdx < route.steps.length) ? route.steps[stepIdx] : route.steps.last;
    final dist = tracking?.formattedDistanceToManeuver ?? '150 m';

    return GestureDetector(
      onTap: widget.onExpandFullScreen,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.panel.withValues(alpha: 0.95),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF06B6D4), width: 1.2),
              boxShadow: AppColors.cardShadow,
            ),
            child: Row(
              children: [
                Icon(currentStep.maneuver.icon, size: 16, color: const Color(0xFF06B6D4)),
                const SizedBox(width: 6),
                Text(
                  dist,
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    currentStep.instruction,
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.fullscreen_rounded, size: 14, color: AppColors.textDim),
              ],
            ),
          ),
        ),
      ),
    );
  }

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

  Widget _buildDestinationMarker(NavSearchResult dest) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: const BoxDecoration(
            color: Color(0xFFEF4444),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Color(0x66EF4444),
                blurRadius: 8,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: const Center(
            child: Icon(Icons.flag_rounded, color: Colors.white, size: 18),
          ),
        ),
        Container(
          width: 3,
          height: 8,
          color: const Color(0xFFEF4444),
        ),
      ],
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
