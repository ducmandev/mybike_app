import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart' hide Path;

import '../../../core/models/trip_gps_point.dart';
import '../../../core/services/map_tile_service.dart';
import '../../../core/services/trip_gps_tracker.dart';
import '../../../ui/app_theme.dart';
import 'offline_map_sheet.dart';

/// Widget Bản Đồ Lái Xe Thời Gian Thực (Live GPS Cockpit Map) trên Dashboard
/// Thiết kế đồng bộ hoàn hảo theo ngôn ngữ Kinetic Stitch EV (Pure White Card, Hairline Border, Space Grotesk)
/// - Mũi tên con trỏ xe tự xoay theo góc hướng đi (heading) thực tế.
/// - Đo và hiển thị Tốc độ GPS độc lập + Biểu đồ xu hướng GPS Speed (Sparkline).
/// - Lược bỏ text rườm rà, giữ giao diện thanh lịch và sắc nét.
class CockpitLiveMap extends StatefulWidget {
  final double currentSpeedKmh;
  final VoidCallback? onExpandFullScreen;
  final double? height;

  const CockpitLiveMap({
    super.key,
    required this.currentSpeedKmh,
    this.onExpandFullScreen,
    this.height,
  });

  @override
  State<CockpitLiveMap> createState() => _CockpitLiveMapState();
}

class _CockpitLiveMapState extends State<CockpitLiveMap> {
  late final MapController _mapController;
  StreamSubscription<TripGpsPoint>? _pointSub;
  List<TripGpsPoint> _liveRoute = [];
  List<double> _gpsSpeedHistory = [];

  double _currentGpsSpeed = 0.0;
  double _currentHeading = 0.0;

  MapTileStyle _tileStyle = MapTileStyle.fastCdn;
  bool _followBike = true;
  bool _isLocating = false;
  LatLng? _myLocation;

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
      setState(() {
        _liveRoute.add(newPoint);
        _myLocation = LatLng(newPoint.lat, newPoint.lng);
        _currentGpsSpeed = newPoint.speedKmh;
        _currentHeading = newPoint.heading ?? 0.0;

        _gpsSpeedHistory.add(newPoint.speedKmh);
        if (_gpsSpeedHistory.length > 30) {
          _gpsSpeedHistory.removeAt(0);
        }
      });
      if (_followBike) {
        _mapController.move(LatLng(newPoint.lat, newPoint.lng), _mapController.camera.zoom);
      }
    });

    // Lấy ngay vị trí hiện tại khi vừa mở dashboard
    _locateMe(moveCamera: false);
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

  void _cycleTileStyle() {
    setState(() {
      const styles = MapTileStyle.values;
      final nextIndex = (styles.indexOf(_tileStyle) + 1) % styles.length;
      _tileStyle = styles[nextIndex];
    });
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Bản đồ: ${MapTileService.getStyleName(_tileStyle)} (100% Free)'),
        duration: const Duration(seconds: 1),
        backgroundColor: AppColors.textPrimary,
      ),
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
    final hasRoute = _liveRoute.isNotEmpty;
    final lastPoint = hasRoute ? _liveRoute.last : null;
    final isTracking = TripGpsTracker.instance.isTracking;

    final centerCoord = _myLocation ??
        (lastPoint != null
            ? LatLng(lastPoint.lat, lastPoint.lng)
            : const LatLng(10.7719, 106.7195));

    final mapHeight = widget.height ?? 220.0;

    return Container(
      height: mapHeight,
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.panelBorderBright, width: 1),
        boxShadow: AppColors.cardShadow,
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
            ),
            children: [
              // Tile Layer
              MapTileService.buildTileLayer(style: _tileStyle),

              // Polyline Lộ trình đang di chuyển
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

              // Marker Vị trí xe Dat Bike với mũi tên xoay theo hướng đi
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

          // 2. HEADER TOP: MŨI TÊN LA BÀN HƯỚNG ĐI + TỐC ĐỘ GPS ĐỘC LẬP + NÚT CÔNG CỤ
          Positioned(
            top: 8,
            left: 8,
            right: 8,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: 540,
                child: Row(
              children: [
                // Chip Hướng đi la bàn (Mũi tên xoay tự động)
                ClipRRect(
                  borderRadius: BorderRadius.circular(9999),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4.5),
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
                              size: 13,
                              color: AppColors.primary,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${_currentHeading.toStringAsFixed(0).padLeft(3, '0')}° ${_shortCardinal(_currentHeading)}',
                            style: GoogleFonts.spaceGrotesk(
                              fontSize: 10.5,
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

                // Chip Tốc độ GPS tính riêng biệt (không phụ thuộc BMS)
                ClipRRect(
                  borderRadius: BorderRadius.circular(9999),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4.5),
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
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isTracking ? AppColors.tertiary : AppColors.secondary,
                            ),
                          ),
                          const SizedBox(width: 5),
                          Text(
                            'GPS: ${_currentGpsSpeed.toStringAsFixed(1)}',
                            style: GoogleFonts.spaceGrotesk(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                          const SizedBox(width: 2),
                          Text(
                            'km/h',
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textDim,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                const Spacer(),

                // Nút đổi Map Tile Style
                _miniGlassBtn(
                  icon: MapTileService.getStyleIcon(_tileStyle),
                  tooltip: MapTileService.getStyleName(_tileStyle),
                  onTap: _cycleTileStyle,
                ),
                const SizedBox(width: 5),

                // Nút tải bản đồ offline
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
                const SizedBox(width: 5),

                // Nút toàn màn hình
                if (widget.onExpandFullScreen != null)
                  _miniGlassBtn(
                    icon: Icons.fullscreen_rounded,
                    tooltip: 'Toàn màn hình HUD',
                    onTap: widget.onExpandFullScreen!,
                  ),
              ],
            ),
          ),
        ),
      ),

          // 3. NÚT ĐIỀU HƯỚNG TRÊN BẢN ĐỒ (Bên phải)
          Positioned(
            bottom: (_gpsSpeedHistory.length >= 2) ? 42 : 12,
            right: 8,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _miniGlassBtn(
                  icon: Icons.my_location_rounded,
                  iconColor: _isLocating ? AppColors.primary : AppColors.textDim,
                  isActive: _isLocating,
                  tooltip: 'Vị trí của tôi',
                  onTap: () => _locateMe(moveCamera: true),
                ),
                const SizedBox(height: 5),
                _miniGlassBtn(
                  icon: Icons.navigation_rounded,
                  iconColor: _followBike ? AppColors.primary : AppColors.textDim,
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
              ],
            ),
          ),

          // 4. BIỂU ĐỒ TỐC ĐỘ GPS (SPARKLINE CHART) TÍNH RIÊNG ĐỘC LẬP
          if (_gpsSpeedHistory.length >= 2)
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
        ],
      ),
    );
  }

  Widget _buildLiveBikeMarker(double speedKmh, double heading) {
    return Transform.rotate(
      angle: (heading * math.pi) / 180.0,
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
    return ClipRRect(
      borderRadius: BorderRadius.circular(9999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isActive ? const Color(0xFFEFF6FF) : AppColors.panel.withValues(alpha: 0.92),
            border: Border.all(
              color: isActive ? AppColors.primary : AppColors.panelBorderBright,
              width: 1,
            ),
            boxShadow: AppColors.cardShadow,
          ),
          child: IconButton(
            padding: EdgeInsets.zero,
            icon: Icon(
              icon,
              color: iconColor ?? (isActive ? AppColors.primary : AppColors.textDim),
              size: 15,
            ),
            tooltip: tooltip,
            onPressed: onTap,
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
