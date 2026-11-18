import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart' hide Path;

import '../../core/ble/ble_controller.dart' show TripRecord, TripGpsPoint, bleProvider, BlePhase;
import '../../core/models/merged_trip_session.dart';
import '../../core/services/gps_route_snapping_service.dart';
import '../../core/services/map_tile_service.dart';
import '../../core/services/trip_export_service.dart';
import '../../core/services/trip_gps_tracker.dart';
import '../../core/services/trip_storage_service.dart';
import '../../core/utils/app_formatters.dart';
import '../../ui/app_theme.dart';
import '../../ui/widgets.dart';
import '../dashboard/widgets/offline_map_sheet.dart';
import 'widgets/trip_clean_video_overlay.dart';
import 'widgets/trip_export_sheet.dart';
import 'widgets/trip_speed_sparkline.dart';
import 'widgets/trip_stats_insights_sheet.dart';

/// Màn hình Bản Đồ Lộ Trình & Phát Lại Vận Tốc Từng Thời Điểm
/// - Mặc định vào bản đồ: Bản đồ sạch sẽ, tự động định vị vị trí hiện tại của người dùng.
/// - Khi có hành trình đang ghi: Hiển thị badge nhỏ gọn góc trên bên phải "Đang định vị chuyến đi".
/// - Hỗ trợ ghép nhiều hành trình (theo ngày / chuỗi tùy chọn / chuỗi đã lưu) với Live-Back đa chặng & điểm nghỉ.
/// - Quản lý dữ liệu chuẩn 2 tầng (Two-Tier Storage): Lazy load tọa độ và đồng bộ xóa 2 chiều với Riverpod.
/// - Chống sập NaN/Infinity zoom camera khi bounds diện tích = 0.
class TripRouteScreen extends ConsumerStatefulWidget {
  final TripRecord? trip;
  final int tripIndex;
  final List<TripRecord>? allTrips;
  final MergedTripSession? initialMergedSession;

  const TripRouteScreen({
    super.key,
    this.trip,
    this.tripIndex = 0,
    this.allTrips,
    this.initialMergedSession,
  });

  @override
  ConsumerState<TripRouteScreen> createState() => _TripRouteScreenState();
}

class _TripRouteScreenState extends ConsumerState<TripRouteScreen> with TickerProviderStateMixin {
  late final MapController _mapController;
  late final AnimationController _pulseController;

  TripRecord? _selectedTrip;
  int _selectedTripIndex = 0;
  List<TripRecord> _allTrips = [];
  MergedTripSession? _mergedSession;

  bool get _isViewingMerged => _mergedSession != null && _mergedSession!.isMerged;

  List<TripGpsPoint> _routePoints = [];
  bool _isViewingLive = false;

  int _currentIndex = 0;
  bool _isPlaying = false;
  double _playbackSpeed = 1.0;
  Timer? _replayTimer;
  Timer? _liveRefreshTimer;
  Timer? _stopoverBannerTimer;
  Timer? _fitBoundsTimer;
  TripStopover? _activeStopoverBanner;
  int? _lastCrossedStopoverIndex;
  bool _followBike = true;
  bool _isLocating = false;
  LatLng? _myLocation;

  MapTileStyle _tileStyle = MapTileStyle.minimalLight;
  bool _useNavPuckMarker = true;
  bool _useHighlightMonoRoute = false;
  bool _isCleanVideoMode = false;

  @override
  void initState() {
    super.initState();
    _mapController = MapController();

    // Hiệu ứng nhấp nháy cho đèn báo "Đang định vị chuyến đi"
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    // Nạp danh sách hành trình
    if (widget.allTrips != null && widget.allTrips!.isNotEmpty) {
      _allTrips = widget.allTrips!;
    } else {
      _loadTripHistory();
    }

    // Nếu được mở trực tiếp với phiên hành trình ghép sẵn
    if (widget.initialMergedSession != null) {
      final session = widget.initialMergedSession!;
      _mergedSession = session;
      _selectedTrip = session.segments.isNotEmpty ? session.segments.first.trip : null;
      _selectedTripIndex = 0;
      _isViewingLive = false;
      _routePoints = session.allPoints;
      _currentIndex = 0;
      _scheduleFitRouteBounds();
    } else if (widget.trip != null && (widget.tripIndex > 0 || widget.trip!.distanceKm >= 0.1 || widget.trip!.route.isNotEmpty)) {
      // Nếu người dùng chọn xem một chuyến cụ thể từ danh sách lịch sử
      _selectTrip(widget.trip!, widget.tripIndex);
    } else {
      // Mặc định: Bản đồ trống, định vị tại vị trí hiện tại
      _selectedTrip = null;
      _selectedTripIndex = 0;
      _routePoints = [];
      _locateMe();
    }

    // Chu kỳ cập nhật nếu đang theo dõi trực tiếp (Live Tracking)
    _liveRefreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted) return;
      if (_isViewingLive) {
        final livePoints = TripGpsTracker.instance.getCurrentRoute();
        if (livePoints.isNotEmpty) {
          setState(() {
            _routePoints = TripGpsTracker.cleanAndSmoothRoute(livePoints);
            _currentIndex = _routePoints.length - 1;
          });
          if (_followBike && _routePoints.isNotEmpty) {
            final last = _routePoints.last;
            _mapController.move(LatLng(last.lat, last.lng), _mapController.camera.zoom);
          }
        }
      }
    });
  }

  Future<void> _loadTripHistory() async {
    try {
      final list = await TripStorageService.instance.loadAllTrips();
      if (mounted && list.isNotEmpty) {
        setState(() {
          _allTrips = list;
        });
      }
    } catch (_) {}
  }

  void _clearStopoverBanner() {
    _stopoverBannerTimer?.cancel();
    _stopoverBannerTimer = null;
    _activeStopoverBanner = null;
    _lastCrossedStopoverIndex = null;
  }

  void _showStopoverBanner(TripStopover stopover, {bool autoHide = true}) {
    _stopoverBannerTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _activeStopoverBanner = stopover;
      _lastCrossedStopoverIndex = stopover.index;
    });
    if (autoHide) {
      _stopoverBannerTimer = Timer(const Duration(milliseconds: 1800), () {
        if (!mounted) return;
        setState(() {
          if (_activeStopoverBanner?.index == stopover.index) {
            _activeStopoverBanner = null;
          }
        });
      });
    }
  }

  /// Chọn xem 1 chuyến đi cụ thể từ danh sách
  Future<void> _selectTrip(TripRecord trip, int index) async {
    _stopPlayback();
    _clearStopoverBanner();
    setState(() {
      _mergedSession = null;
      _selectedTrip = trip;
      _selectedTripIndex = index;
      _isViewingLive = false;
    });

    final route = await TripStorageService.instance.loadTripRoute(trip);
    if (!mounted) return;

    final cleaned = TripGpsTracker.cleanAndSmoothRoute(route);
    setState(() {
      _routePoints = cleaned;
      _currentIndex = 0;
    });

    _scheduleFitRouteBounds();

    if (cleaned.length >= 2 && !trip.isGpsRoadSnapped) {
      unawaited(_snapSelectedTripIfOnline(trip, cleaned));
    }
  }

  /// Tự động nắn đường bộ cho chuyến đi đang xem nếu chưa từng nắn (lưu cache để dùng lại).
  Future<void> _snapSelectedTripIfOnline(
    TripRecord trip,
    List<TripGpsPoint> currentRoute,
  ) async {
    try {
      final snapped = await GpsRouteSnappingService.instance.snapRouteToRoads(currentRoute);
      if (!mounted || !snapped.metrics.isRoadSnapped) return;

      final roundedGpsKm = double.parse(snapped.metrics.distanceKm.toStringAsFixed(2));
      await ref.read(bleProvider.notifier).updateTripGpsMatchResult(
        tripId: trip.id,
        gpsDistanceKm: roundedGpsKm,
        isRoadSnapped: true,
        signalLossCount: snapped.metrics.signalLossCount,
        snappedRoute: snapped.points,
      );

      if (!mounted) return;
      final isStillSelected = _selectedTrip?.id == trip.id && !_isViewingLive && !_isViewingMerged;
      setState(() {
        _allTrips = _allTrips.map((t) {
          if (t.id != trip.id) return t;
          return t.copyWith(
            gpsDistanceKm: roundedGpsKm,
            isGpsRoadSnapped: true,
            gpsSignalLossCount: snapped.metrics.signalLossCount,
          );
        }).toList();
        if (isStillSelected) {
          _selectedTrip = _selectedTrip!.copyWith(
            gpsDistanceKm: roundedGpsKm,
            isGpsRoadSnapped: true,
            gpsSignalLossCount: snapped.metrics.signalLossCount,
          );
          _routePoints = snapped.points;
          if (_currentIndex >= _routePoints.length) {
            _currentIndex = math.max(0, _routePoints.length - 1);
          }
        }
      });
    } catch (_) {}
  }

  /// Ghép nhiều hành trình thành một phiên Live-Back liên tục theo thứ tự thời gian
  Future<void> _selectMergedTrips(
    List<TripRecord> trips, {
    TripMergeMode mode = TripMergeMode.customChain,
    String? customTitle,
  }) async {
    if (trips.isEmpty) return;
    _stopPlayback();
    _clearStopoverBanner();

    final session = await TripStorageService.instance.buildMergedSession(
      trips,
      mode: mode,
      customTitle: customTitle,
      cleaner: TripGpsTracker.cleanAndSmoothRoute,
    );
    if (!mounted) return;

    setState(() {
      _isViewingLive = false;
      _mergedSession = session;
      _selectedTrip = session.segments.isNotEmpty ? session.segments.first.trip : null;
      _selectedTripIndex = 0;
      _routePoints = session.allPoints;
      _currentIndex = 0;
    });

    _scheduleFitRouteBounds();
  }

  /// Bật chế độ xem lộ trình đang đi trực tiếp
  void _startLiveTrackingView() {
    _stopPlayback();
    _clearStopoverBanner();
    final livePoints = TripGpsTracker.instance.getCurrentRoute();
    setState(() {
      _mergedSession = null;
      _isViewingLive = true;
      _selectedTrip = null;
      _selectedTripIndex = 0;
      _routePoints = TripGpsTracker.cleanAndSmoothRoute(livePoints);
      _currentIndex = _routePoints.isNotEmpty ? _routePoints.length - 1 : 0;
    });

    if (_routePoints.isNotEmpty) {
      final p = _routePoints.last;
      _mapController.move(LatLng(p.lat, p.lng), 16.5);
    } else {
      _locateMe();
    }
  }

  /// Xóa một chuyến đi: Đồng bộ cả Storage tầng 2 và Riverpod Provider
  Future<void> _deleteTripItem(TripRecord tripToDelete) async {
    await ref.read(bleProvider.notifier).deleteTrip(tripToDelete);

    final updated = await TripStorageService.instance.loadAllTrips();
    if (mounted) {
      setState(() {
        _allTrips = updated;
      });
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Đã xóa hành trình thành công.'),
        duration: Duration(seconds: 2),
        backgroundColor: AppColors.textPrimary,
      ),
    );

    if (_mergedSession != null && _mergedSession!.segments.any((s) => s.trip.id == tripToDelete.id)) {
      final remaining = _mergedSession!.segments
          .map((s) => s.trip)
          .where((t) => t.id != tripToDelete.id)
          .toList();
      if (remaining.isNotEmpty) {
        await _selectMergedTrips(remaining, mode: _mergedSession!.mode);
      } else {
        _stopPlayback();
        _clearStopoverBanner();
        setState(() {
          _mergedSession = null;
          _selectedTrip = null;
          _selectedTripIndex = 0;
          _routePoints = [];
          _currentIndex = 0;
        });
      }
      return;
    }

    // Nếu chuyến bị xóa là chuyến đang xem
    if (_selectedTrip != null &&
        (_selectedTrip!.id == tripToDelete.id ||
         (_selectedTrip!.startTime.millisecondsSinceEpoch == tripToDelete.startTime.millisecondsSinceEpoch &&
          (_selectedTrip!.distanceKm - tripToDelete.distanceKm).abs() < 0.001))) {
      _stopPlayback();
      _clearStopoverBanner();
      setState(() {
        _mergedSession = null;
        _selectedTrip = null;
        _selectedTripIndex = 0;
        _routePoints = [];
        _currentIndex = 0;
      });
    }
  }

  /// Hộp thoại xác nhận xóa hành trình hiện tại đang xem
  Future<void> _confirmAndDeleteCurrentTrip() async {
    if (_selectedTrip == null) return;
    final tripToDelete = _selectedTrip!;
    final tripNum = _selectedTripIndex > 0 ? _selectedTripIndex : 1;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Row(
          children: [
            const Icon(Icons.delete_forever_rounded, color: AppColors.red, size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Xóa Hành Trình Này?',
                style: GoogleFonts.spaceGrotesk(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        content: Text(
          'Bạn có chắc chắn muốn xóa vĩnh viễn hành trình #$tripNum (${tripToDelete.distanceKm.toStringAsFixed(1)} km) khỏi bộ nhớ thiết bị?',
          style: GoogleFonts.plusJakartaSans(fontSize: 13, height: 1.45, color: AppColors.textPrimary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('HỦY', style: GoogleFonts.spaceGrotesk(color: AppColors.textDim)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('XÓA', style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await _deleteTripItem(tripToDelete);
    }
  }

  @override
  void dispose() {
    _replayTimer?.cancel();
    _liveRefreshTimer?.cancel();
    _stopoverBannerTimer?.cancel();
    _fitBoundsTimer?.cancel();
    _pulseController.dispose();
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _locateMe() async {
    if (_isLocating) return;
    setState(() => _isLocating = true);
    final pos = await TripGpsTracker.instance.getCurrentLocation();
    if (!mounted) return;
    setState(() => _isLocating = false);

    if (pos != null) {
      final loc = LatLng(pos.latitude, pos.longitude);
      setState(() => _myLocation = loc);
      _mapController.move(loc, 16.0);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Không thể lấy vị trí hiện tại. Vui lòng bật GPS trên máy.'),
          backgroundColor: AppColors.red,
        ),
      );
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

  void _togglePlayPause() {
    if (_isPlaying) {
      _stopPlayback();
    } else {
      _startPlayback();
    }
  }

  void _startPlayback() {
    if (_routePoints.isEmpty) return;
    if (_currentIndex >= _routePoints.length - 1) {
      _currentIndex = 0;
      _lastCrossedStopoverIndex = null;
    }
    setState(() => _isPlaying = true);

    _replayTimer?.cancel();
    _replayTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      final prevIndex = _currentIndex;
      final step = math.max(1, (_playbackSpeed * 1.5).round());
      final nextIndex = math.min(_routePoints.length - 1, prevIndex + step);

      TripStopover? crossedStopover;
      if (_isViewingMerged) {
        for (final stopover in _mergedSession!.stopovers) {
          if (stopover.afterGlobalPointIndex > prevIndex &&
              stopover.afterGlobalPointIndex <= nextIndex &&
              _lastCrossedStopoverIndex != stopover.index) {
            crossedStopover = stopover;
            break;
          }
        }
      }

      setState(() {
        _currentIndex = nextIndex;
        if (_currentIndex >= _routePoints.length - 1) {
          _currentIndex = _routePoints.length - 1;
          _stopPlayback();
        }
      });

      if (crossedStopover != null) {
        _showStopoverBanner(crossedStopover, autoHide: true);
      }

      if (_followBike && _routePoints.isNotEmpty && _currentIndex < _routePoints.length) {
        final cur = _routePoints[_currentIndex];
        _mapController.move(LatLng(cur.lat, cur.lng), _mapController.camera.zoom);
      }
    });
  }

  void _stopPlayback() {
    _replayTimer?.cancel();
    _replayTimer = null;
    if (mounted) {
      setState(() => _isPlaying = false);
    }
  }

  void _seekTo(int index) {
    if (_routePoints.isEmpty) return;
    final clamped = index.clamp(0, _routePoints.length - 1);
    setState(() {
      _currentIndex = clamped;
      if (_activeStopoverBanner != null &&
          (_activeStopoverBanner!.afterGlobalPointIndex - clamped).abs() > 3) {
        _activeStopoverBanner = null;
      }
    });

    final cur = _routePoints[clamped];
    if (_followBike) {
      _mapController.move(LatLng(cur.lat, cur.lng), _mapController.camera.zoom);
    }
  }

  void _cyclePlaybackSpeed() {
    setState(() {
      if (_playbackSpeed == 1.0) {
        _playbackSpeed = 2.0;
      } else if (_playbackSpeed == 2.0) {
        _playbackSpeed = 4.0;
      } else if (_playbackSpeed == 4.0) {
        _playbackSpeed = 8.0;
      } else if (_playbackSpeed == 8.0) {
        _playbackSpeed = 16.0;
      } else {
        _playbackSpeed = 1.0;
      }
    });
    if (_isPlaying) {
      _startPlayback();
    }
  }

  String _formatHm(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  String _formatHms(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  double _cumulativeDistanceKmAt(int index, double liveDistanceKm) {
    if (_isViewingMerged && _mergedSession != null) {
      return _mergedSession!.cumulativeDistanceAtPointIndex(index);
    }
    if (_isViewingLive) {
      return liveDistanceKm;
    }
    if (_selectedTrip != null) {
      if (_routePoints.length <= 1) return _selectedTrip!.distanceKm;
      final ratio = index.clamp(0, _routePoints.length - 1) / (_routePoints.length - 1);
      return _selectedTrip!.distanceKm * ratio;
    }
    return 0.0;
  }

  double? _cumulativeGpsDistanceKmAt(int index, double liveGpsDistanceKm) {
    if (_isViewingMerged && _mergedSession != null) {
      if (!_mergedSession!.hasGpsDistance) return null;
      return _mergedSession!.cumulativeGpsDistanceAtPointIndex(index);
    }
    if (_isViewingLive) {
      return liveGpsDistanceKm > 0 ? liveGpsDistanceKm : null;
    }
    if (_selectedTrip != null) {
      final totalGps = _selectedTrip!.effectiveGpsDistanceKm(_routePoints);
      if (totalGps == null) return null;
      if (_routePoints.length <= 1) return totalGps;
      final ratio = index.clamp(0, _routePoints.length - 1) / (_routePoints.length - 1);
      return totalGps * ratio;
    }
    return null;
  }

  MergedTripSession? _buildExportableSession() {
    if (_mergedSession != null) {
      return _mergedSession!;
    }
    if (_selectedTrip != null) {
      return TripExportService.instance.sessionFromSingleTrip(
        _selectedTrip!,
        _routePoints,
        tripNumber: _selectedTripIndex > 0 ? _selectedTripIndex : 1,
      );
    }
    if (_isViewingLive && _routePoints.length >= 2) {
      final first = _routePoints.first;
      final last = _routePoints.last;
      final durSec = math.max(1, last.timestamp.difference(first.timestamp).inSeconds);
      final liveMetrics = GpsRouteAnalyzer.measureRoute(_routePoints);
      final liveGpsKm = liveMetrics.distanceKm;
      final liveOdoKm = ref.read(bleProvider).trip.distanceKm;
      final effDist = liveOdoKm > 0 ? liveOdoKm : liveGpsKm;
      double maxSpd = 0.0;
      for (final p in _routePoints) {
        if (p.speedKmh > maxSpd) maxSpd = p.speedKmh;
      }
      final liveTrip = TripRecord(
        id: 'live_${first.timestamp.millisecondsSinceEpoch}',
        startTime: first.timestamp,
        endTime: last.timestamp,
        distanceKm: effDist,
        gpsDistanceKm: liveGpsKm,
        gpsSignalLossCount: liveMetrics.signalLossCount,
        durationSec: durSec,
        avgSpeedKmh: durSec > 0 ? effDist / (durSec / 3600.0) : 0.0,
        maxSpeedKmh: maxSpd,
        usedPercent: 0,
        route: _routePoints,
      );
      return TripExportService.instance.sessionFromSingleTrip(liveTrip, _routePoints);
    }
    return null;
  }

  Future<void> _showExportShareSheet() async {
    final session = _buildExportableSession();
    if (session == null || session.allPoints.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Chưa có dữ liệu tọa độ GPS để xuất tệp.'),
          backgroundColor: AppColors.textPrimary,
        ),
      );
      return;
    }

    await TripExportSheet.show(
      context,
      session: session,
      singleTrip: _selectedTrip,
    );
  }

  void _scheduleFitRouteBounds([Duration delay = const Duration(milliseconds: 250)]) {
    _fitBoundsTimer?.cancel();
    _fitBoundsTimer = Timer(delay, () {
      if (!mounted) return;
      _fitRouteBounds();
    });
  }

  /// Căn góc camera an toàn — Chống tuyệt đối lỗi Bounds diện tích 0 (NaN / Infinity Zoom Loop)
  void _fitRouteBounds() {
    if (!mounted) return;
    if (_routePoints.length < 2) {
      if (_routePoints.isNotEmpty) {
        _mapController.move(LatLng(_routePoints.first.lat, _routePoints.first.lng), 16.0);
      }
      return;
    }
    final points = _routePoints.map((p) => LatLng(p.lat, p.lng)).toList();
    final bounds = LatLngBounds.fromPoints(points);

    // Kiểm tra span để chống bounds siêu nhỏ hoặc diện tích 0
    final latSpan = (bounds.north - bounds.south).abs();
    final lngSpan = (bounds.east - bounds.west).abs();
    if (latSpan < 0.0001 && lngSpan < 0.0001) {
      _mapController.move(bounds.center, 16.0);
      return;
    }

    try {
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: bounds,
          padding: EdgeInsets.only(
            top: 100,
            bottom: _isViewingMerged ? 310 : 260,
            left: 40,
            right: 40,
          ),
        ),
      );
    } catch (_) {
      _mapController.move(bounds.center, 15.0);
    }
  }

  String _getSpeedLabel(double speedKmh) {
    if (speedKmh < 5.0) return 'DỪNG XE';
    if (speedKmh < 20.0) return 'DI CHUYỂN CHẬM';
    if (speedKmh < 40.0) return 'TỐC ĐỘ ỔN ĐỊNH';
    if (speedKmh < 60.0) return 'TĂNG TỐC';
    return 'VẬN TỐC CAO';
  }

  /// Mở Modal Bottom Sheet Chọn Hành Trình (3 tab: Tất cả, Theo ngày, Đã lưu)
  void _openTripSearchModal() {
    final searchCtrl = TextEditingController();
    bool isMultiSelect = false;
    final Set<String> selectedIds = {};
    final Set<String> expandedDayKeys = {};
    bool includeLiveInToday = true;
    List<SavedMergedTripChain> savedChains = [];
    bool chainsLoading = true;
    bool didInitLoad = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (modalCtx, setModalState) {
            if (!didInitLoad) {
              didInitLoad = true;
              TripStorageService.instance.loadSavedMergedChains().then((chains) {
                if (modalCtx.mounted) {
                  setModalState(() {
                    savedChains = chains;
                    chainsLoading = false;
                  });
                }
              }).catchError((_) {
                if (modalCtx.mounted) {
                  setModalState(() => chainsLoading = false);
                }
              });
            }

            final tripsToDisplay = _allTrips;
            final query = searchCtrl.text.trim().toLowerCase();
            final filteredTrips = tripsToDisplay.asMap().entries.where((entry) {
              if (query.isEmpty) return true;
              final idx = tripsToDisplay.length - entry.key;
              final t = entry.value;
              final km = t.distanceKm.toStringAsFixed(1);
              final dateStr = '${t.startTime.day}/${t.startTime.month}';
              final paddedDateStr =
                  '${t.startTime.day.toString().padLeft(2, '0')}/${t.startTime.month.toString().padLeft(2, '0')}';
              return idx.toString().contains(query) ||
                  km.contains(query) ||
                  dateStr.contains(query) ||
                  paddedDateStr.contains(query) ||
                  'hành trình $idx'.contains(query);
            }).toList();

            final selectedTrips = tripsToDisplay
                .where((t) => selectedIds.contains(t.id))
                .toList();
            final selectedTotalKm = selectedTrips.fold<double>(0.0, (sum, t) => sum + t.distanceKm);

            return DefaultTabController(
              length: 3,
              child: Container(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.88,
                ),
                decoration: const BoxDecoration(
                  color: AppColors.panel,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                  border: Border(top: BorderSide(color: AppColors.panelBorderBright)),
                  boxShadow: AppColors.modalShadow,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SheetDragHandle(
                      width: 44,
                      margin: EdgeInsets.only(top: 10, bottom: 6),
                    ),

                    // Header Modal
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 6, 12, 8),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: AppColors.primary.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(Icons.route_rounded, color: AppColors.primary, size: 20),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'DANH SÁCH HÀNH TRÌNH',
                                  style: GoogleFonts.spaceGrotesk(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.5,
                                    color: AppColors.textPrimary,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  '${tripsToDisplay.length} hành trình đã lưu',
                                  style: GoogleFonts.plusJakartaSans(
                                    fontSize: 11,
                                    color: AppColors.textDim,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.bar_chart_rounded, color: AppColors.primary),
                            tooltip: 'Thống kê 7/30 ngày',
                            onPressed: () => TripStatsInsightsSheet.show(context, _allTrips),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close_rounded, color: AppColors.textDim),
                            onPressed: () => Navigator.pop(ctx),
                          ),
                        ],
                      ),
                    ),

                    // 3 Tabs: Tất cả / Theo ngày / Đã lưu
                    TabBar(
                      labelColor: AppColors.primary,
                      unselectedLabelColor: AppColors.textDim,
                      indicatorColor: AppColors.primary,
                      indicatorWeight: 2.5,
                      dividerColor: AppColors.panelBorder,
                      labelStyle: GoogleFonts.spaceGrotesk(fontSize: 12.5, fontWeight: FontWeight.w700),
                      unselectedLabelStyle: GoogleFonts.spaceGrotesk(fontSize: 12.5, fontWeight: FontWeight.w600),
                      tabs: [
                        const Tab(text: 'Tất cả'),
                        const Tab(text: 'Theo ngày'),
                        Tab(text: savedChains.isNotEmpty ? 'Đã lưu (${savedChains.length})' : 'Đã lưu'),
                      ],
                    ),

                    Expanded(
                      child: TabBarView(
                        children: [
                          // TAB 1: TẤT CẢ (Search + Multi-select + Sticky Bottom Bar)
                          _buildAllTripsTab(
                            modalCtx: ctx,
                            searchCtrl: searchCtrl,
                            tripsToDisplay: tripsToDisplay,
                            filteredTrips: filteredTrips,
                            isMultiSelect: isMultiSelect,
                            selectedIds: selectedIds,
                            selectedTrips: selectedTrips,
                            selectedTotalKm: selectedTotalKm,
                            onToggleMultiSelect: () {
                              setModalState(() {
                                isMultiSelect = !isMultiSelect;
                                if (!isMultiSelect) selectedIds.clear();
                              });
                            },
                            onSearchChanged: () => setModalState(() {}),
                            onToggleTripSelection: (tripId) {
                              setModalState(() {
                                if (selectedIds.contains(tripId)) {
                                  selectedIds.remove(tripId);
                                } else {
                                  selectedIds.add(tripId);
                                }
                              });
                            },
                            onSelectAllFiltered: () {
                              setModalState(() {
                                for (final entry in filteredTrips) {
                                  selectedIds.add(entry.value.id);
                                }
                              });
                            },
                            onClearSelection: () {
                              setModalState(() => selectedIds.clear());
                            },
                            onDeleteTrip: (tripItem) async {
                              await _deleteTripItem(tripItem);
                              selectedIds.remove(tripItem.id);
                              if (modalCtx.mounted) setModalState(() {});
                            },
                            onChainSaved: (updatedChains) {
                              if (modalCtx.mounted) {
                                setModalState(() => savedChains = updatedChains);
                              }
                            },
                          ),

                          // TAB 2: THEO NGÀY
                          _buildByDayTripsTab(
                            modalCtx: ctx,
                            expandedDayKeys: expandedDayKeys,
                            includeLiveInToday: includeLiveInToday,
                            onToggleExpand: (dateKey) {
                              setModalState(() {
                                if (expandedDayKeys.contains(dateKey)) {
                                  expandedDayKeys.remove(dateKey);
                                } else {
                                  expandedDayKeys.add(dateKey);
                                }
                              });
                            },
                            onToggleIncludeLive: (val) {
                              setModalState(() => includeLiveInToday = val);
                            },
                          ),

                          // TAB 3: ĐÃ LƯU
                          _buildSavedChainsTab(
                            modalCtx: ctx,
                            savedChains: savedChains,
                            isLoading: chainsLoading,
                            onDeleteChain: (chainId) async {
                              final updated = await TripStorageService.instance.deleteMergedChain(chainId);
                              if (modalCtx.mounted) {
                                setModalState(() => savedChains = updated);
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ).whenComplete(() {
      searchCtrl.dispose();
    });
  }

  Widget _buildAllTripsTab({
    required BuildContext modalCtx,
    required TextEditingController searchCtrl,
    required List<TripRecord> tripsToDisplay,
    required List<MapEntry<int, TripRecord>> filteredTrips,
    required bool isMultiSelect,
    required Set<String> selectedIds,
    required List<TripRecord> selectedTrips,
    required double selectedTotalKm,
    required VoidCallback onToggleMultiSelect,
    required VoidCallback onSearchChanged,
    required ValueChanged<String> onToggleTripSelection,
    required VoidCallback onSelectAllFiltered,
    required VoidCallback onClearSelection,
    required Future<void> Function(TripRecord) onDeleteTrip,
    required ValueChanged<List<SavedMergedTripChain>> onChainSaved,
  }) {
    return Column(
      children: [
        // Search + Chọn nhiều toggle
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: searchCtrl,
                  onChanged: (_) => onSearchChanged(),
                  style: GoogleFonts.spaceGrotesk(fontSize: 13, color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'Tìm số #, ngày, số km...',
                    hintStyle: GoogleFonts.plusJakartaSans(fontSize: 12, color: AppColors.textDim),
                    prefixIcon: const Icon(Icons.search_rounded, size: 18, color: AppColors.primary),
                    suffixIcon: searchCtrl.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear_rounded, size: 16, color: AppColors.textDim),
                            onPressed: () {
                              searchCtrl.clear();
                              onSearchChanged();
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: AppColors.panelSecondary,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppColors.panelBorder),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              InkWell(
                onTap: onToggleMultiSelect,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  decoration: BoxDecoration(
                    color: isMultiSelect ? AppColors.primary : AppColors.panelSecondary,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isMultiSelect ? AppColors.primary : AppColors.panelBorderBright,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isMultiSelect ? Icons.close_rounded : Icons.checklist_rounded,
                        size: 16,
                        color: isMultiSelect ? Colors.white : AppColors.primary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        isMultiSelect ? 'Hủy' : 'Chọn nhiều',
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: isMultiSelect ? Colors.white : AppColors.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),

        // Quick actions when Chọn nhiều active
        if (isMultiSelect)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
            child: Row(
              children: [
                TextButton.icon(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: filteredTrips.isEmpty ? null : onSelectAllFiltered,
                  icon: const Icon(Icons.select_all_rounded, size: 15),
                  label: Text('Chọn tất cả', style: GoogleFonts.spaceGrotesk(fontSize: 11.5, fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.textDim,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: selectedIds.isEmpty ? null : onClearSelection,
                  icon: const Icon(Icons.deselect_rounded, size: 15),
                  label: Text('Bỏ chọn', style: GoogleFonts.spaceGrotesk(fontSize: 11.5, fontWeight: FontWeight.w700)),
                ),
                const Spacer(),
                Text(
                  '${selectedIds.length} đã chọn',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
                  ),
                ),
              ],
            ),
          ),

        const Divider(color: AppColors.panelBorder, height: 1),

        // Trip List
        Expanded(
          child: filteredTrips.isEmpty
              ? Center(
                  child: Text(
                    'Không tìm thấy hành trình phù hợp',
                    style: GoogleFonts.plusJakartaSans(color: AppColors.textDim, fontSize: 13),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                  itemCount: filteredTrips.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, idx) {
                    final entry = filteredTrips[idx];
                    final tripItem = entry.value;
                    final tripNum = tripsToDisplay.length - entry.key;
                    final isMultiChecked = selectedIds.contains(tripItem.id);
                    final isCurrentSingle = !_isViewingMerged &&
                        _selectedTrip != null &&
                        _selectedTrip!.startTime.millisecondsSinceEpoch == tripItem.startTime.millisecondsSinceEpoch;
                    final highlight = isMultiSelect ? isMultiChecked : isCurrentSingle;

                    final durMin = tripItem.durationSec ~/ 60;
                    final dateStr =
                        '${tripItem.startTime.day.toString().padLeft(2, '0')}/${tripItem.startTime.month.toString().padLeft(2, '0')} · ${_formatHm(tripItem.startTime)}';

                    return InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () {
                        if (isMultiSelect) {
                          onToggleTripSelection(tripItem.id);
                        } else {
                          Navigator.pop(modalCtx);
                          _selectTrip(tripItem, tripNum);
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: highlight ? AppColors.primary.withValues(alpha: 0.08) : AppColors.panelSecondary,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: highlight ? AppColors.primary : AppColors.panelBorderBright,
                            width: highlight ? 1.5 : 1.0,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: highlight ? AppColors.primary : AppColors.primary.withValues(alpha: 0.12),
                              ),
                              child: Center(
                                child: isMultiSelect && isMultiChecked
                                    ? const Icon(Icons.check_rounded, color: Colors.white, size: 18)
                                    : Text(
                                        '#$tripNum',
                                        style: GoogleFonts.spaceGrotesk(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w800,
                                          color: highlight ? Colors.white : AppColors.primary,
                                        ),
                                      ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Hành trình #$tripNum',
                                    style: GoogleFonts.spaceGrotesk(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.textPrimary,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    tripItem.effectiveGpsDistanceKm() != null
                                        ? '$dateStr · ${tripItem.distanceKm.toStringAsFixed(1)} km (GPS ${tripItem.effectiveGpsDistanceKm()!.toStringAsFixed(1)}) · $durMin p'
                                        : '$dateStr · ${tripItem.distanceKm.toStringAsFixed(1)} km · $durMin phút',
                                    style: GoogleFonts.plusJakartaSans(
                                      fontSize: 11,
                                      color: AppColors.textDim,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            if (isMultiSelect)
                              Icon(
                                isMultiChecked ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                                color: isMultiChecked ? AppColors.primary : AppColors.textMuted,
                                size: 22,
                              )
                            else
                              IconButton(
                                icon: const Icon(Icons.delete_outline_rounded, color: AppColors.red, size: 20),
                                tooltip: 'Xóa hành trình',
                                onPressed: () async {
                                  final confirm = await showDialog<bool>(
                                    context: context,
                                    builder: (c) => AlertDialog(
                                      backgroundColor: AppColors.panel,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                                      title: Text('Xóa Hành Trình #$tripNum?', style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700)),
                                      content: Text(
                                        'Bạn có chắc muốn xóa hành trình #$tripNum (${tripItem.distanceKm.toStringAsFixed(1)} km) khỏi thiết bị?',
                                        style: GoogleFonts.plusJakartaSans(fontSize: 13),
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.pop(c, false),
                                          child: Text('HỦY', style: GoogleFonts.spaceGrotesk(color: AppColors.textDim)),
                                        ),
                                        FilledButton(
                                          style: FilledButton.styleFrom(backgroundColor: AppColors.red),
                                          onPressed: () => Navigator.pop(c, true),
                                          child: Text('XÓA', style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700)),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (confirm == true) {
                                    await onDeleteTrip(tripItem);
                                  }
                                },
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),

        // Sticky Bottom Bar in Multi-Select Mode
        if (isMultiSelect)
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              decoration: const BoxDecoration(
                color: AppColors.panel,
                border: Border(top: BorderSide(color: AppColors.panelBorderBright)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Đã chọn ${selectedTrips.length} chặng · ${selectedTotalKm.toStringAsFixed(1)} km',
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Flexible(
                        flex: 4,
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.primary,
                            side: BorderSide(
                              color: selectedTrips.isNotEmpty ? AppColors.primary : AppColors.panelBorderBright,
                            ),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 10),
                          ),
                          onPressed: selectedTrips.isEmpty
                              ? null
                              : () async {
                                  final title = await _promptSaveChainTitleDialog(selectedTrips.length);
                                  if (title == null || title.trim().isEmpty) return;
                                  final sorted = [...selectedTrips]
                                    ..sort((a, b) => a.startTime.compareTo(b.startTime));
                                  final chain = SavedMergedTripChain(
                                    id: 'chain_${DateTime.now().millisecondsSinceEpoch}',
                                    title: title.trim(),
                                    createdAt: DateTime.now(),
                                    tripIds: sorted.map((t) => t.id).toList(),
                                    mode: TripMergeMode.customChain,
                                  );
                                  final updated = await TripStorageService.instance.saveMergedChain(chain);
                                  onChainSaved(updated);
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text('Đã lưu chuỗi "${chain.title}"'),
                                        duration: const Duration(seconds: 2),
                                        backgroundColor: AppColors.textPrimary,
                                      ),
                                    );
                                  }
                                },
                          icon: const Icon(Icons.bookmark_add_outlined, size: 17),
                          label: Text(
                            'Lưu chuỗi',
                            style: GoogleFonts.spaceGrotesk(fontSize: 12, fontWeight: FontWeight.w700),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 6,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 12),
                          ),
                          onPressed: selectedTrips.isEmpty
                              ? null
                              : () {
                                  Navigator.pop(modalCtx);
                                  _selectMergedTrips(selectedTrips, mode: TripMergeMode.customChain);
                                },
                          icon: const Icon(Icons.play_circle_filled_rounded, size: 18),
                          label: Text(
                            'GHÉP & LIVE-BACK',
                            style: GoogleFonts.spaceGrotesk(fontSize: 12, fontWeight: FontWeight.w800),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Future<String?> _promptSaveChainTitleDialog(int segmentCount) async {
    final ctrl = TextEditingController(text: 'Chuỗi $segmentCount chặng');
    final result = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: AppColors.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(
          'Lưu chuỗi hành trình',
          style: GoogleFonts.spaceGrotesk(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: GoogleFonts.plusJakartaSans(fontSize: 13.5, color: AppColors.textPrimary),
          decoration: InputDecoration(
            labelText: 'Tên chuỗi hành trình',
            labelStyle: GoogleFonts.plusJakartaSans(fontSize: 12, color: AppColors.textDim),
            filled: true,
            fillColor: AppColors.panelSecondary,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: Text('HỦY', style: GoogleFonts.spaceGrotesk(color: AppColors.textDim)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
            onPressed: () => Navigator.pop(c, ctrl.text),
            child: Text('LƯU', style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    ctrl.dispose();
    return result;
  }

  Widget _buildByDayTripsTab({
    required BuildContext modalCtx,
    required Set<String> expandedDayKeys,
    required bool includeLiveInToday,
    required ValueChanged<String> onToggleExpand,
    required ValueChanged<bool> onToggleIncludeLive,
  }) {
    final dayGroups = TripDayGroup.groupTripsByDay(_allTrips);
    final now = DateTime.now();

    TripRecord? liveTripRecord;
    if (TripGpsTracker.instance.isActivelyRecording) {
      final livePts = TripGpsTracker.instance.getCurrentRoute();
      if (livePts.length >= 2) {
        final liveGpsDist = TripGpsTracker.instance.totalDistanceKm;
        final liveOdoDist = ref.read(bleProvider).trip.distanceKm;
        final effDist = liveOdoDist > 0 ? liveOdoDist : liveGpsDist;
        final durSec = math.max(1, livePts.last.timestamp.difference(livePts.first.timestamp).inSeconds);
        double maxSpd = 0.0;
        for (final p in livePts) {
          if (p.speedKmh > maxSpd) maxSpd = p.speedKmh;
        }
        final avgSpd = durSec > 0 ? effDist / (durSec / 3600.0) : 0.0;
        liveTripRecord = TripRecord(
          id: 'live_today_${livePts.first.timestamp.millisecondsSinceEpoch}',
          startTime: livePts.first.timestamp,
          endTime: livePts.last.timestamp,
          distanceKm: effDist,
          gpsDistanceKm: liveGpsDist,
          gpsSignalLossCount: TripGpsTracker.instance.signalLossCount,
          durationSec: durSec,
          avgSpeedKmh: avgSpd,
          maxSpeedKmh: maxSpd,
          usedPercent: 0,
          route: livePts,
        );
      }
    }

    if (dayGroups.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Chưa có hành trình nào được lưu theo ngày',
            style: GoogleFonts.plusJakartaSans(color: AppColors.textDim, fontSize: 13),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      itemCount: dayGroups.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final group = dayGroups[index];
        final isExpanded = expandedDayKeys.contains(group.dateKey);
        final isToday = group.day.year == now.year &&
            group.day.month == now.month &&
            group.day.day == now.day;

        final tripsForDay = (isToday && liveTripRecord != null && includeLiveInToday)
            ? [...group.chronologicalTrips, liveTripRecord]
            : group.chronologicalTrips;
        final totalKm = tripsForDay.fold<double>(0.0, (s, t) => s + t.distanceKm);
        final totalGpsKm = tripsForDay.fold<double>(0.0, (s, t) => s + (t.effectiveGpsDistanceKm() ?? 0.0));
        final hasDayGpsKm = tripsForDay.any((t) => t.effectiveGpsDistanceKm() != null);
        final movingMin = tripsForDay.fold<int>(0, (s, t) => s + t.durationSec) ~/ 60;
        final label = group.formatDateLabel(now: now);

        return Container(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            color: AppColors.panelSecondary,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.panelBorderBright),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.calendar_today_rounded, size: 17, color: AppColors.primary),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: GoogleFonts.spaceGrotesk(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: AppColors.textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          hasDayGpsKm
                              ? '${tripsForDay.length} chặng · ODO ${totalKm.toStringAsFixed(1)} · GPS ${totalGpsKm.toStringAsFixed(1)} km · $movingMin p'
                              : '${tripsForDay.length} chặng · ${totalKm.toStringAsFixed(1)} km · $movingMin phút',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 11.5,
                            color: AppColors.textDim,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  if (group.totalUsedPercent > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppColors.tertiary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '-${group.totalUsedPercent}%',
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: AppColors.tertiary,
                        ),
                      ),
                    ),
                ],
              ),

              if (isToday && liveTripRecord != null) ...[
                const SizedBox(height: 8),
                InkWell(
                  onTap: () => onToggleIncludeLive(!includeLiveInToday),
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: includeLiveInToday
                          ? AppColors.tertiary.withValues(alpha: 0.12)
                          : AppColors.panel,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: includeLiveInToday ? AppColors.tertiary : AppColors.panelBorderBright,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          includeLiveInToday ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                          size: 16,
                          color: includeLiveInToday ? AppColors.tertiary : AppColors.textDim,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            'Gộp thêm chặng đang đi (${liveTripRecord.distanceKm.toStringAsFixed(1)} km)',
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 10),
              Row(
                children: [
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.textDim,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: () => onToggleExpand(group.dateKey),
                    icon: Icon(
                      isExpanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                      size: 18,
                    ),
                    label: Text(
                      isExpanded ? 'Thu gọn' : 'Xem các chặng',
                      style: GoogleFonts.spaceGrotesk(fontSize: 11.5, fontWeight: FontWeight.w700),
                    ),
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      minimumSize: Size.zero,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () {
                      Navigator.pop(modalCtx);
                      _selectMergedTrips(
                        tripsForDay,
                        mode: TripMergeMode.byDay,
                        customTitle: label,
                      );
                    },
                    icon: const Icon(Icons.play_arrow_rounded, size: 17),
                    label: Text(
                      'Xem & Live-Back',
                      style: GoogleFonts.spaceGrotesk(fontSize: 12, fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),

              if (isExpanded) ...[
                const Divider(color: AppColors.panelBorder, height: 16),
                for (int i = 0; i < tripsForDay.length; i++) ...[
                  _buildDayTripPreviewRow(
                    modalCtx: modalCtx,
                    order: i + 1,
                    trip: tripsForDay[i],
                    isLiveSegment: tripsForDay[i].id.startsWith('live_today_'),
                  ),
                  if (i < tripsForDay.length - 1) const SizedBox(height: 6),
                ],
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildDayTripPreviewRow({
    required BuildContext modalCtx,
    required int order,
    required TripRecord trip,
    required bool isLiveSegment,
  }) {
    final durMin = trip.durationSec ~/ 60;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () {
        Navigator.pop(modalCtx);
        if (isLiveSegment) {
          _startLiveTrackingView();
        } else {
          final idx = _allTrips.indexWhere((t) => t.id == trip.id);
          final tripNum = idx >= 0 ? (_allTrips.length - idx) : order;
          _selectTrip(trip, tripNum);
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.panel,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.panelBorder),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: isLiveSegment
                    ? AppColors.tertiary.withValues(alpha: 0.14)
                    : AppColors.primary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                isLiveSegment ? 'LIVE' : 'C$order',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  color: isLiveSegment ? AppColors.tertiary : AppColors.primary,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                trip.effectiveGpsDistanceKm() != null
                    ? '${_formatHm(trip.startTime)} → ${_formatHm(trip.endTime)} · ${trip.distanceKm.toStringAsFixed(1)} km (GPS ${trip.effectiveGpsDistanceKm()!.toStringAsFixed(1)}) · $durMin p'
                    : '${_formatHm(trip.startTime)} → ${_formatHm(trip.endTime)} · ${trip.distanceKm.toStringAsFixed(1)} km · $durMin p',
                style: GoogleFonts.plusJakartaSans(fontSize: 11.5, color: AppColors.textPrimary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(Icons.chevron_right_rounded, size: 16, color: AppColors.textDim),
          ],
        ),
      ),
    );
  }

  Widget _buildSavedChainsTab({
    required BuildContext modalCtx,
    required List<SavedMergedTripChain> savedChains,
    required bool isLoading,
    required Future<void> Function(String chainId) onDeleteChain,
  }) {
    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (savedChains.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.bookmarks_outlined, size: 36, color: AppColors.textMuted),
              const SizedBox(height: 10),
              Text(
                'Chưa có chuỗi hành trình đã lưu',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                'Vào tab "Tất cả" → bấm "Chọn nhiều" → "Lưu chuỗi" để lưu các chặng hay đi.',
                style: GoogleFonts.plusJakartaSans(fontSize: 12, color: AppColors.textDim),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    final tripById = <String, TripRecord>{for (final t in _allTrips) t.id: t};

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      itemCount: savedChains.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final chain = savedChains[index];
        final resolvedTrips = chain.tripIds
            .map((id) => tripById[id])
            .whereType<TripRecord>()
            .toList();
        final totalKm = resolvedTrips.fold<double>(0.0, (sum, t) => sum + t.distanceKm);
        final dateStr =
            '${chain.createdAt.day.toString().padLeft(2, '0')}/${chain.createdAt.month.toString().padLeft(2, '0')}/${chain.createdAt.year}';

        return Container(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            color: AppColors.panelSecondary,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.panelBorderBright),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.bookmark_rounded, size: 18, color: AppColors.primary),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          chain.title,
                          style: GoogleFonts.spaceGrotesk(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: AppColors.textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${resolvedTrips.length}/${chain.tripIds.length} chặng · ${totalKm.toStringAsFixed(1)} km · Lưu $dateStr',
                          style: GoogleFonts.plusJakartaSans(fontSize: 11.5, color: AppColors.textDim),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline_rounded, color: AppColors.red, size: 20),
                    tooltip: 'Xóa chuỗi đã lưu',
                    onPressed: () => onDeleteChain(chain.id),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      minimumSize: Size.zero,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: resolvedTrips.isEmpty
                        ? null
                        : () {
                            Navigator.pop(modalCtx);
                            _selectMergedTrips(
                              resolvedTrips,
                              mode: chain.mode,
                              customTitle: chain.title,
                            );
                          },
                    icon: const Icon(Icons.replay_rounded, size: 17),
                    label: Text(
                      'Phát lại',
                      style: GoogleFonts.spaceGrotesk(fontSize: 12, fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  /// Mở Modal Thông Tin Dải Tốc Độ & Thống Kê Hành Trình (Nút Info ℹ️)
  void _showTripInfoSheet() {
    final trip = _selectedTrip;
    final merged = _isViewingMerged ? _mergedSession : null;
    final durMin = trip != null ? trip.durationSec ~/ 60 : 0;
    final durSec = trip != null ? trip.durationSec % 60 : 0;
    final durText = durMin > 0 ? '$durMin phút $durSec giây' : '$durSec giây';
    final co2Kg = trip != null ? (trip.distanceKm * 0.065).toStringAsFixed(2) : '0.00';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.82,
          ),
          decoration: const BoxDecoration(
            color: AppColors.panel,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            border: Border(top: BorderSide(color: AppColors.panelBorderBright)),
            boxShadow: AppColors.modalShadow,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SheetDragHandle(
                width: 44,
                margin: EdgeInsets.only(top: 10, bottom: 6),
              ),

              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 16, 10),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.info_rounded, color: AppColors.primary, size: 20),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        merged != null
                            ? merged.title
                            : (_selectedTrip != null
                                ? 'Chi tiết hành trình #$_selectedTripIndex'
                                : 'Thông tin bản đồ & Tốc độ'),
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, color: AppColors.textDim),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),

              const Divider(color: AppColors.panelBorder, height: 1),

              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                  children: [
                    Text(
                      'DẢI TỐC ĐỘ',
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                        color: AppColors.textDim,
                      ),
                    ),
                    const SizedBox(height: 8),

                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.panelSecondary,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: AppColors.panelBorderBright),
                      ),
                      child: Column(
                        children: [
                          _speedLegendRow(
                            MapTileService.getHighContrastSpeedColor(10),
                            '< 15 km/h',
                            'Dừng hoặc di chuyển chậm',
                          ),
                          const Divider(color: AppColors.panelBorder, height: 16),
                          _speedLegendRow(
                            MapTileService.getHighContrastSpeedColor(25),
                            '15 – 35 km/h',
                            'Tốc độ ổn định trong phố',
                          ),
                          const Divider(color: AppColors.panelBorder, height: 16),
                          _speedLegendRow(
                            MapTileService.getHighContrastSpeedColor(45),
                            '35 – 55 km/h',
                            'Đường thoáng / đại lộ',
                          ),
                          const Divider(color: AppColors.panelBorder, height: 16),
                          _speedLegendRow(
                            MapTileService.getHighContrastSpeedColor(70),
                            '> 55 km/h',
                            'Đường trường / tốc độ cao',
                          ),
                        ],
                      ),
                    ),

                    if (merged != null) ...[
                      const SizedBox(height: 20),
                      Text(
                        'THỐNG KÊ HÀNH TRÌNH GHÉP (${merged.segmentCount} CHẶNG)',
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: AppColors.textDim,
                        ),
                      ),
                      const SizedBox(height: 8),

                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppColors.panelSecondary,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: AppColors.panelBorderBright),
                        ),
                        child: Column(
                          children: [
                            _tripDetailRow('Tổng KM xe (ODO)', '${merged.totalDistanceKm.toStringAsFixed(1)} km'),
                            const Divider(color: AppColors.panelBorder, height: 14),
                            _tripDetailRow(
                              'Tổng KM theo GPS',
                              merged.hasGpsDistance
                                  ? '${merged.totalGpsDistanceKm.toStringAsFixed(1)} km${merged.isGpsRoadSnapped ? ' (nắn đường)' : ' (trừ mất sóng)'}'
                                  : '--',
                            ),
                            if (merged.totalGpsSignalLossCount > 0) ...[
                              const Divider(color: AppColors.panelBorder, height: 14),
                              _tripDetailRow('Đoạn mất sóng đã trừ', '${merged.totalGpsSignalLossCount} đoạn'),
                            ],
                            const Divider(color: AppColors.panelBorder, height: 14),
                            _tripDetailRow('Thời gian di chuyển', AppFormatters.formatDurationVerboseSec(merged.totalMovingDurationSec)),
                            const Divider(color: AppColors.panelBorder, height: 14),
                            _tripDetailRow('Thời gian dừng nghỉ', AppFormatters.formatDurationVerboseSec(merged.totalStopDurationSec)),
                            const Divider(color: AppColors.panelBorder, height: 14),
                            _tripDetailRow('Vận tốc TB di chuyển', '${merged.avgMovingSpeedKmh.toStringAsFixed(0)} km/h'),
                            const Divider(color: AppColors.panelBorder, height: 14),
                            _tripDetailRow('Vận tốc cao nhất', '${merged.maxSpeedKmh.toStringAsFixed(0)} km/h'),
                            const Divider(color: AppColors.panelBorder, height: 14),
                            _tripDetailRow('Tiêu thụ pin', merged.totalUsedPercent > 0 ? '-${merged.totalUsedPercent}%' : '--'),
                            const Divider(color: AppColors.panelBorder, height: 14),
                            _tripDetailRow('Giảm phát thải CO2', '${merged.totalCo2SavedKg.toStringAsFixed(2)} kg'),
                          ],
                        ),
                      ),

                      const SizedBox(height: 20),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        icon: const Icon(Icons.ios_share_rounded, size: 18),
                        label: Text(
                          'XUẤT GPX / CSV / KML GHÉP VIDEO',
                          style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700),
                        ),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _showExportShareSheet();
                        },
                      ),

                      const SizedBox(height: 16),
                      Text(
                        'CHI TIẾT TỪNG CHẶNG & ĐIỂM NGHỈ',
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: AppColors.textDim,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ..._buildMergedBreakdownWidgets(ctx, merged),
                    ] else if (trip != null) ...[
                      const SizedBox(height: 20),
                      Text(
                        'THỐNG KÊ HÀNH TRÌNH',
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: AppColors.textDim,
                        ),
                      ),
                      const SizedBox(height: 8),

                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppColors.panelSecondary,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: AppColors.panelBorderBright),
                        ),
                        child: Builder(
                          builder: (_) {
                            final singleGpsKm = trip.effectiveGpsDistanceKm(_routePoints);
                            final routeMetrics = GpsRouteAnalyzer.measureRoute(
                              _routePoints,
                              isRoadSnapped: trip.isGpsRoadSnapped,
                            );
                            final lossCount = math.max(trip.gpsSignalLossCount, routeMetrics.signalLossCount);
                            final gapKm = routeMetrics.excludedGapDistanceKm;

                            return Column(
                              children: [
                                _tripDetailRow('Quãng đường xe (ODO)', '${trip.distanceKm.toStringAsFixed(1)} km'),
                                const Divider(color: AppColors.panelBorder, height: 14),
                                _tripDetailRow(
                                  'Quãng đường theo GPS',
                                  singleGpsKm != null
                                      ? '${singleGpsKm.toStringAsFixed(1)} km${trip.isGpsRoadSnapped ? ' (đã nắn đường)' : ' (trừ mất sóng)'}'
                                      : '--',
                                ),
                                if (lossCount > 0 || gapKm > 0.01) ...[
                                  const Divider(color: AppColors.panelBorder, height: 14),
                                  _tripDetailRow(
                                    'Loại trừ mất sóng GPS',
                                    gapKm > 0.01
                                        ? '$lossCount đoạn (${gapKm.toStringAsFixed(2)} km)'
                                        : '$lossCount đoạn',
                                  ),
                                ],
                                const Divider(color: AppColors.panelBorder, height: 14),
                                _tripDetailRow('Thời gian di chuyển', durText),
                                const Divider(color: AppColors.panelBorder, height: 14),
                                _tripDetailRow('Vận tốc trung bình', '${trip.avgSpeedKmh.toStringAsFixed(0)} km/h'),
                                const Divider(color: AppColors.panelBorder, height: 14),
                                _tripDetailRow('Vận tốc cao nhất', '${trip.maxSpeedKmh.toStringAsFixed(0)} km/h'),
                                const Divider(color: AppColors.panelBorder, height: 14),
                                _tripDetailRow('Tiêu thụ pin', trip.usedPercent > 0 ? '-${trip.usedPercent}%' : '--'),
                                const Divider(color: AppColors.panelBorder, height: 14),
                                _tripDetailRow('Giảm phát thải CO2', '$co2Kg kg'),
                              ],
                            );
                          },
                        ),
                      ),

                      const SizedBox(height: 20),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        icon: const Icon(Icons.ios_share_rounded, size: 18),
                        label: Text(
                          'XUẤT GPX / CSV / KML GHÉP VIDEO',
                          style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700),
                        ),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _showExportShareSheet();
                        },
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.red,
                          side: const BorderSide(color: AppColors.red),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        icon: const Icon(Icons.delete_outline_rounded, size: 18),
                        label: Text('XÓA HÀNH TRÌNH NÀY', style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700)),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _confirmAndDeleteCurrentTrip();
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _buildMergedBreakdownWidgets(BuildContext sheetCtx, MergedTripSession session) {
    final widgets = <Widget>[];
    final usedStopovers = <int>{};

    for (int i = 0; i < session.segments.length; i++) {
      final seg = session.segments[i];
      widgets.add(
        InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: !seg.hasPoints
              ? null
              : () {
                  Navigator.pop(sheetCtx);
                  _seekTo(seg.startPointIndex);
                },
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.panelSecondary,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.panelBorderBright),
            ),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.primary.withValues(alpha: 0.12),
                  ),
                  child: Center(
                    child: Text(
                      'C${seg.displayOrder}',
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: AppColors.primary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Chặng ${seg.displayOrder} · ${_formatHm(seg.trip.startTime)} → ${_formatHm(seg.trip.endTime)}',
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        seg.gpsDistanceKm != null
                            ? '${seg.trip.distanceKm.toStringAsFixed(1)} km ODO · ${seg.gpsDistanceKm!.toStringAsFixed(1)} km GPS · ${AppFormatters.formatDurationVerboseSec(seg.trip.durationSec)} · Max ${seg.trip.maxSpeedKmh.toStringAsFixed(0)} km/h${seg.trip.usedPercent > 0 ? ' · -${seg.trip.usedPercent}%' : ''}'
                            : '${seg.trip.distanceKm.toStringAsFixed(1)} km · ${AppFormatters.formatDurationVerboseSec(seg.trip.durationSec)} · Max ${seg.trip.maxSpeedKmh.toStringAsFixed(0)} km/h${seg.trip.usedPercent > 0 ? ' · -${seg.trip.usedPercent}%' : ''}',
                        style: GoogleFonts.plusJakartaSans(fontSize: 11, color: AppColors.textDim),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (seg.hasPoints)
                  const Icon(Icons.my_location_rounded, size: 16, color: AppColors.primary),
              ],
            ),
          ),
        ),
      );

      // Find matching stopover after this segment
      TripStopover? matchedStopover;
      for (final st in session.stopovers) {
        if (usedStopovers.contains(st.index)) continue;
        if (st.arrivedAt.isAtSameMomentAs(seg.trip.endTime) ||
            (seg.hasPoints && st.afterGlobalPointIndex == seg.endPointIndex)) {
          matchedStopover = st;
          usedStopovers.add(st.index);
          break;
        }
      }

      if (matchedStopover != null) {
        final stopover = matchedStopover;
        widgets.add(const SizedBox(height: 6));
        widgets.add(
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              Navigator.pop(sheetCtx);
              _onTapStopover(stopover);
            },
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 10),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.amber.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.amber.withValues(alpha: 0.4)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.amber,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      stopover.label,
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Điểm nghỉ ${stopover.label} · ${_formatHm(stopover.arrivedAt)} → ${_formatHm(stopover.departedAt)} (${stopover.formattedDuration})',
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }

      if (i < session.segments.length - 1) {
        widgets.add(const SizedBox(height: 8));
      }
    }

    return widgets;
  }

  Widget _speedLegendRow(Color color, String speedText, String desc) {
    return Row(
      children: [
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 85,
          child: Text(
            speedText,
            style: GoogleFonts.spaceGrotesk(
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary,
            ),
          ),
        ),
        Expanded(
          child: Text(
            desc,
            style: GoogleFonts.plusJakartaSans(
              fontSize: 11.5,
              color: AppColors.textDim,
            ),
          ),
        ),
      ],
    );
  }

  Widget _tripDetailRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text(
            label,
            style: GoogleFonts.plusJakartaSans(fontSize: 12.5, color: AppColors.textDim),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            value,
            style: GoogleFonts.spaceGrotesk(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
            textAlign: TextAlign.end,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  /// Trả về các cặp chỉ số `(start, end)` của từng đoạn GPS liên tục (cắt tại điểm mất sóng).
  List<({int start, int end})> _contiguousRunRanges(List<TripGpsPoint> points) {
    if (points.isEmpty) return const [];
    final ranges = <({int start, int end})>[];
    var runStart = 0;
    for (var i = 1; i < points.length; i++) {
      if (GpsRouteAnalyzer.isSignalGap(points[i - 1], points[i])) {
        ranges.add((start: runStart, end: i - 1));
        runStart = i;
      }
    }
    ranges.add((start: runStart, end: points.length - 1));
    return ranges;
  }

  void _appendGapAndBackgroundRuns(
    List<TripGpsPoint> pts,
    Color borderBase,
    List<Polyline> out,
  ) {
    final runs = _contiguousRunRanges(pts);
    for (var r = 0; r < runs.length; r++) {
      final run = runs[r];
      if (r > 0) {
        final prevEnd = pts[runs[r - 1].end];
        final curStart = pts[run.start];
        out.add(
          Polyline(
            points: [
              LatLng(prevEnd.lat, prevEnd.lng),
              LatLng(curStart.lat, curStart.lng),
            ],
            strokeWidth: 2.2,
            strokeCap: StrokeCap.round,
            color: AppColors.textMuted.withValues(alpha: 0.65),
            borderStrokeWidth: 1.0,
            borderColor: borderBase.withValues(alpha: 0.20),
            pattern: StrokePattern.dashed(segments: const [5, 5]),
          ),
        );
      }
      if (run.end > run.start) {
        out.add(
          Polyline(
            points: pts.sublist(run.start, run.end + 1).map((p) => LatLng(p.lat, p.lng)).toList(),
            strokeWidth: 8.0,
            strokeCap: StrokeCap.round,
            strokeJoin: StrokeJoin.round,
            color: AppColors.primary.withValues(alpha: 0.20),
            borderStrokeWidth: 2.5,
            borderColor: borderBase.withValues(alpha: 0.25),
          ),
        );
      }
    }
  }

  List<Polyline> _buildBackgroundPolylines() {
    final borderBase = MapTileService.routeBorderColorFor(_tileStyle);
    if (_mergedSession != null) {
      final polylines = <Polyline>[];
      TripSegment? prevWithPoints;
      for (final seg in _mergedSession!.segments) {
        if (!seg.hasPoints) continue;
        if (prevWithPoints != null && seg.gapDistanceBeforeMeters > 40.0) {
          polylines.add(
            Polyline(
              points: [
                LatLng(prevWithPoints.points.last.lat, prevWithPoints.points.last.lng),
                LatLng(seg.points.first.lat, seg.points.first.lng),
              ],
              strokeWidth: 2.5,
              strokeCap: StrokeCap.round,
              color: AppColors.textMuted.withValues(alpha: 0.75),
              borderStrokeWidth: 1.5,
              borderColor: borderBase.withValues(alpha: 0.30),
              pattern: StrokePattern.dashed(segments: const [6, 6]),
            ),
          );
        }
        if (seg.points.length >= 2) {
          _appendGapAndBackgroundRuns(seg.points, borderBase, polylines);
        }
        prevWithPoints = seg;
      }
      return polylines;
    }

    if (_routePoints.length < 2) return const [];
    final singlePolylines = <Polyline>[];
    _appendGapAndBackgroundRuns(_routePoints, borderBase, singlePolylines);
    return singlePolylines;
  }

  List<Polyline> _buildSegmentSpeedPolylines(
    List<TripGpsPoint> segPoints,
    int segStartGlobalIndex,
    int stride,
  ) {
    final n = segPoints.length;
    if (n < 2) return const [];

    final borderBase = MapTileService.routeBorderColorFor(_tileStyle);
    final polylines = <Polyline>[];
    final runs = _contiguousRunRanges(segPoints);

    for (final run in runs) {
      if (run.end <= run.start) continue;

      final sampled = <int>[run.start];
      for (int i = run.start + stride; i < run.end; i += stride) {
        sampled.add(i);
      }
      sampled.add(run.end);

      final localCur = _currentIndex - segStartGlobalIndex;
      if (localCur >= run.start && localCur <= run.end && !sampled.contains(localCur)) {
        sampled.add(localCur);
        sampled.sort();
      }

      for (int k = 0; k < sampled.length - 1; k++) {
        final a = sampled[k];
        final b = sampled[k + 1];
        final isPlayed = (segStartGlobalIndex + b) <= _currentIndex;

        var c1 = _useHighlightMonoRoute
            ? AppColors.primary
            : MapTileService.getHighContrastSpeedColor(segPoints[a].speedKmh);
        var c2 = _useHighlightMonoRoute
            ? AppColors.primary
            : MapTileService.getHighContrastSpeedColor(segPoints[b].speedKmh);
        if (!isPlayed) {
          c1 = c1.withValues(alpha: 0.35);
          c2 = c2.withValues(alpha: 0.35);
        }

        polylines.add(
          Polyline(
            points: [
              LatLng(segPoints[a].lat, segPoints[a].lng),
              LatLng(segPoints[b].lat, segPoints[b].lng),
            ],
            strokeWidth: isPlayed ? 5.5 : 4.5,
            strokeCap: StrokeCap.round,
            strokeJoin: StrokeJoin.round,
            borderStrokeWidth: isPlayed ? 2.5 : 1.5,
            borderColor: isPlayed ? borderBase : borderBase.withValues(alpha: 0.30),
            gradientColors: [c1, c2],
          ),
        );
      }
    }
    return polylines;
  }

  List<Polyline> _buildAllSpeedGradientPolylines() {
    if (_routePoints.length < 2) return const [];
    final stride = _routePoints.length > 800 ? (_routePoints.length / 800).ceil() : 1;

    if (_mergedSession != null) {
      final polylines = <Polyline>[];
      for (final seg in _mergedSession!.segments) {
        if (seg.hasPoints && seg.points.length >= 2) {
          polylines.addAll(_buildSegmentSpeedPolylines(seg.points, seg.startPointIndex, stride));
        }
      }
      return polylines;
    }

    return _buildSegmentSpeedPolylines(_routePoints, 0, stride);
  }

  void _onTapStopover(TripStopover stopover) {
    if (_routePoints.isNotEmpty) {
      _seekTo(stopover.afterGlobalPointIndex);
    }
    _showStopoverBanner(stopover, autoHide: false);
  }

  @override
  Widget build(BuildContext context) {
    final hasPoints = _routePoints.isNotEmpty;
    final safeIndex = hasPoints ? _currentIndex.clamp(0, _routePoints.length - 1) : 0;
    final currentPoint = hasPoints ? _routePoints[safeIndex] : null;
    final activeSegment = _isViewingMerged ? _mergedSession!.segmentAtPointIndex(safeIndex) : null;

    final bleSummary = ref.watch(
      bleProvider.select(
        (s) => (
          isConnected: s.phase == BlePhase.connected,
          tripDurationSec: s.trip.duration.inSeconds,
          tripDistanceKm: s.trip.distanceKm,
          tripGpsDistanceKm: s.trip.gpsDistanceKm,
        ),
      ),
    );
    final isTrackingActive = TripGpsTracker.instance.isActivelyRecording ||
        (bleSummary.isConnected && bleSummary.tripDurationSec > 0);
    final curLiveGpsDistance = TripGpsTracker.instance.totalDistanceKm > 0
        ? TripGpsTracker.instance.totalDistanceKm
        : bleSummary.tripGpsDistanceKm;
    final curLiveDistance = bleSummary.tripDistanceKm > 0
        ? bleSummary.tripDistanceKm
        : curLiveGpsDistance;
    final selectedTripGpsKm = _selectedTrip?.effectiveGpsDistanceKm(_routePoints);

    final initialCenter = hasPoints
        ? LatLng(_routePoints.first.lat, _routePoints.first.lng)
        : (_myLocation ?? const LatLng(10.7719, 106.7195));

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        children: [
          // 1. BẢN ĐỒ FLUTTER_MAP
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: initialCenter,
              initialZoom: 15.0,
              onMapReady: () {
                if ((_selectedTrip != null || _mergedSession != null) && hasPoints) {
                  _scheduleFitRouteBounds(const Duration(milliseconds: 300));
                } else {
                  _locateMe();
                }
              },
            ),
            children: [
              // Tile Layer
              MapTileService.buildTileLayer(style: _tileStyle),

              // Polyline Lộ trình (Per-segment background + gap dashed connector + progressive speed gradient)
              if (hasPoints) ...[
                PolylineLayer(
                  polylines: _buildBackgroundPolylines(),
                ),
                PolylineLayer(
                  polylines: _buildAllSpeedGradientPolylines(),
                ),
              ],

              // Marker Layer
              MarkerLayer(
                markers: [
                  if (_myLocation != null)
                    Marker(
                      point: _myLocation!,
                      width: 44,
                      height: 44,
                      child: _buildMyLocationMarker(),
                    ),
                  if (hasPoints) ...[
                    Marker(
                      point: LatLng(_routePoints.first.lat, _routePoints.first.lng),
                      width: 32,
                      height: 32,
                      child: _buildStartEndPin(label: 'A', isStart: true),
                    ),
                    Marker(
                      point: LatLng(_routePoints.last.lat, _routePoints.last.lng),
                      width: 32,
                      height: 32,
                      child: _buildStartEndPin(label: 'B', isStart: false),
                    ),
                    if (_mergedSession != null)
                      for (final stopover in _mergedSession!.stopovers)
                        Marker(
                          point: LatLng(stopover.location.lat, stopover.location.lng),
                          width: 44,
                          height: 44,
                          child: GestureDetector(
                            onTap: () => _onTapStopover(stopover),
                            child: _buildStopoverMarker(stopover),
                          ),
                        ),
                    if (currentPoint != null)
                      Marker(
                        point: LatLng(currentPoint.lat, currentPoint.lng),
                        width: 90,
                        height: 90,
                        alignment: Alignment.center,
                        child: _buildBikeReplayMarker(currentPoint),
                      ),
                  ],
                ],
              ),
            ],
          ),

          // 2. HEADER TOP: Thanh tìm kiếm kiểu Textbox & Nút Info
          if (!_isCleanVideoMode)
            SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      _glassIconButton(
                        icon: Icons.arrow_back_ios_new_rounded,
                        tooltip: 'Quay lại',
                        onTap: () => Navigator.pop(context),
                      ),
                      const SizedBox(width: 8),

                      // Thanh tìm kiếm & chọn hành trình
                      Expanded(
                        child: InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: _openTripSearchModal,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: BackdropFilter(
                              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                              child: Container(
                                height: 38,
                                padding: const EdgeInsets.symmetric(horizontal: 10),
                                decoration: BoxDecoration(
                                  color: AppColors.panel.withValues(alpha: 0.94),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(color: AppColors.panelBorderBright),
                                  boxShadow: AppColors.cardShadow,
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.search_rounded, size: 16, color: AppColors.primary),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        _isViewingLive
                                            ? 'Đang ghi · ODO ${curLiveDistance.toStringAsFixed(1)} · GPS ${curLiveGpsDistance.toStringAsFixed(1)} km'
                                            : (_isViewingMerged
                                                ? (_mergedSession!.hasGpsDistance
                                                    ? '${_mergedSession!.title} · ${_mergedSession!.totalDistanceKm.toStringAsFixed(1)} km (GPS ${_mergedSession!.totalGpsDistanceKm.toStringAsFixed(1)})'
                                                    : '${_mergedSession!.title} · ${_mergedSession!.totalDistanceKm.toStringAsFixed(1)} km')
                                                : (_selectedTrip != null
                                                    ? (selectedTripGpsKm != null
                                                        ? '#$_selectedTripIndex · ${_selectedTrip!.distanceKm.toStringAsFixed(1)} km (GPS ${selectedTripGpsKm.toStringAsFixed(1)})'
                                                        : '#$_selectedTripIndex · ${_selectedTrip!.distanceKm.toStringAsFixed(1)} km')
                                                    : 'Tìm kiếm hành trình...')),
                                        style: GoogleFonts.plusJakartaSans(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700,
                                          color: AppColors.textPrimary,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const Icon(Icons.unfold_more_rounded, size: 16, color: AppColors.textDim),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),

                      // Nút Info (ℹ️)
                      _glassIconButton(
                        icon: Icons.info_outline_rounded,
                        iconColor: AppColors.primary,
                        tooltip: 'Thông tin tốc độ & Lộ trình',
                        onTap: _showTripInfoSheet,
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // 3. NOTIFICATION BADGE NHỎ GÓC TRÊN BÊN PHẢI (Ngay dưới thanh tìm kiếm khi đang định vị chuyến đi)
          if (!_isCleanVideoMode && isTrackingActive)
            Positioned(
              top: MediaQuery.of(context).padding.top + 54,
              right: 12,
              child: InkWell(
                onTap: _startLiveTrackingView,
                borderRadius: BorderRadius.circular(20),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: _isViewingLive ? AppColors.textPrimary : AppColors.panel.withValues(alpha: 0.92),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: _isViewingLive ? AppColors.tertiary : AppColors.panelBorderBright,
                          width: _isViewingLive ? 1.5 : 1.0,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.tertiary.withValues(alpha: _isViewingLive ? 0.35 : 0.15),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AnimatedBuilder(
                            animation: _pulseController,
                            builder: (context, child) => Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: AppColors.tertiary.withValues(alpha: 0.4 + 0.6 * _pulseController.value),
                                boxShadow: [
                                  BoxShadow(
                                    color: AppColors.tertiary.withValues(alpha: 0.6 * _pulseController.value),
                                    blurRadius: 6,
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Đang định vị chuyến đi',
                            style: GoogleFonts.spaceGrotesk(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: _isViewingLive ? Colors.white : AppColors.textPrimary,
                            ),
                          ),
                          if (curLiveDistance > 0) ...[
                            const SizedBox(width: 4),
                            Text(
                              '· ${curLiveDistance.toStringAsFixed(1)} km',
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800,
                                color: AppColors.tertiary,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

          // 4. THANH CÔNG CỤ DỌC (Góc phải bản đồ)
          if (!_isCleanVideoMode)
            Positioned(
              top: MediaQuery.of(context).padding.top + (isTrackingActive ? 98 : 58),
              right: 12,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hasPoints) ...[
                    _glassIconButton(
                      icon: Icons.crop_free_rounded,
                      tooltip: 'Căn toàn bộ lộ trình',
                      onTap: _fitRouteBounds,
                    ),
                    const SizedBox(height: 8),
                  ],
                  _glassIconButton(
                    icon: Icons.my_location_rounded,
                    iconColor: _isLocating ? AppColors.primary : AppColors.textDim,
                    tooltip: 'Vị trí của tôi',
                    onTap: _locateMe,
                  ),
                  const SizedBox(height: 8),
                  _glassIconButton(
                    icon: Icons.layers_outlined,
                    tooltip: 'Đổi kiểu bản đồ',
                    onTap: _cycleTileStyle,
                  ),
                  const SizedBox(height: 8),
                  _glassIconButton(
                    icon: Icons.palette_outlined,
                    tooltip: 'Đổi màu lộ trình: Tốc độ / Nổi bật',
                    isActive: _useHighlightMonoRoute,
                    onTap: () {
                      setState(() => _useHighlightMonoRoute = !_useHighlightMonoRoute);
                      ScaffoldMessenger.of(context).hideCurrentSnackBar();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            _useHighlightMonoRoute
                                ? 'Màu lộ trình: Nổi bật đồng nhất'
                                : 'Màu lộ trình: Dải tốc độ tương phản cao',
                          ),
                          duration: const Duration(seconds: 1),
                          backgroundColor: AppColors.textPrimary,
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  _glassIconButton(
                    icon: Icons.videocam_outlined,
                    tooltip: 'Chế độ quay Video Overlay',
                    isActive: _isCleanVideoMode,
                    onTap: () => setState(() => _isCleanVideoMode = true),
                  ),
                  const SizedBox(height: 8),
                  _glassIconButton(
                    icon: Icons.bar_chart_rounded,
                    tooltip: 'Thống kê 7/30 ngày',
                    onTap: () => TripStatsInsightsSheet.show(context, _allTrips),
                  ),
                  const SizedBox(height: 8),
                  _glassIconButton(
                    icon: Icons.download_for_offline_outlined,
                    tooltip: 'Bản đồ offline',
                    onTap: () => OfflineMapSheet.show(context),
                  ),
                ],
              ),
            ),

          // 4B. COMPACT VIDEO OVERLAY PILL (Khi bật _isCleanVideoMode)
          if (_isCleanVideoMode)
            Positioned(
              left: 14,
              bottom: MediaQuery.of(context).padding.bottom + 20,
              child: TripCleanVideoOverlay(
                speedKmh: currentPoint?.speedKmh ?? 0.0,
                distanceKm: _cumulativeDistanceKmAt(safeIndex, curLiveDistance),
                gpsDistanceKm: _cumulativeGpsDistanceKmAt(safeIndex, curLiveGpsDistance),
                durationText: _formatHms(currentPoint?.timestamp ?? DateTime.now()),
                isLive: _isViewingLive,
                onExit: () => setState(() => _isCleanVideoMode = false),
              ),
            ),

          // 5. BẢNG ĐIỀU KHIỂN & PHÁT LẠI VẬN TỐC Ở ĐÁY MÀN HÌNH
          // CHỈ HIỆN KHI NGƯỜI DÙNG CHỌN 1 HÀNH TRÌNH, PHIÊN GHÉP HOẶC BẬT XEM LIVE
          if (!_isCleanVideoMode && (_selectedTrip != null || _isViewingLive || _isViewingMerged))
            Positioned(
              left: 14,
              right: 14,
              bottom: 20,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_activeStopoverBanner != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: AppColors.textPrimary.withValues(alpha: 0.96),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: AppColors.amber.withValues(alpha: 0.7)),
                          boxShadow: AppColors.cardShadow,
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppColors.amber,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                _activeStopoverBanner!.label,
                                style: GoogleFonts.spaceGrotesk(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Điểm nghỉ ${_activeStopoverBanner!.label} · ${_formatHm(_activeStopoverBanner!.arrivedAt)} → ${_formatHm(_activeStopoverBanner!.departedAt)} (${_activeStopoverBanner!.formattedDuration})',
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            InkWell(
                              onTap: () => setState(() => _activeStopoverBanner = null),
                              child: const Padding(
                                padding: EdgeInsets.all(2),
                                child: Icon(Icons.close_rounded, size: 16, color: Colors.white70),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                  ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: AppColors.panel.withValues(alpha: 0.96),
                          borderRadius: BorderRadius.circular(22),
                          border: Border.all(color: AppColors.panelBorderBright),
                          boxShadow: AppColors.modalShadow,
                        ),
                        child: hasPoints
                            ? Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  // Hàng tiêu đề + Nút đóng
                                  Row(
                                    crossAxisAlignment: CrossAxisAlignment.center,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(7),
                                        decoration: BoxDecoration(
                                          color: AppColors.primary.withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        child: Icon(
                                          _isViewingLive ? Icons.gps_fixed_rounded : Icons.alt_route_rounded,
                                          color: AppColors.primary,
                                          size: 18,
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              _isViewingLive
                                                  ? 'Đang định vị trực tiếp'
                                                  : (_isViewingMerged
                                                      ? _mergedSession!.title
                                                      : 'Hành trình #$_selectedTripIndex'),
                                              style: GoogleFonts.spaceGrotesk(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w700,
                                                color: AppColors.textPrimary,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            Text(
                                              _isViewingLive
                                                  ? 'ODO ${curLiveDistance.toStringAsFixed(1)} km · GPS ${curLiveGpsDistance.toStringAsFixed(1)} km · ${_routePoints.length} điểm'
                                                  : (_isViewingMerged
                                                      ? (_mergedSession!.hasGpsDistance
                                                          ? 'ODO ${_mergedSession!.totalDistanceKm.toStringAsFixed(1)} · GPS ${_mergedSession!.totalGpsDistanceKm.toStringAsFixed(1)} km · Chặng ${activeSegment?.displayOrder ?? 1}/${_mergedSession!.segmentCount}'
                                                          : '${_mergedSession!.totalDistanceKm.toStringAsFixed(1)} km · Chặng ${activeSegment?.displayOrder ?? 1}/${_mergedSession!.segmentCount}')
                                                      : (selectedTripGpsKm != null
                                                          ? 'ODO ${_selectedTrip!.distanceKm.toStringAsFixed(1)} km · GPS ${selectedTripGpsKm.toStringAsFixed(1)} km · Max ${_selectedTrip!.maxSpeedKmh.toStringAsFixed(0)} km/h'
                                                          : '${_selectedTrip!.distanceKm.toStringAsFixed(1)} km · ${_selectedTrip!.durationSec ~/ 60} phút · Max ${_selectedTrip!.maxSpeedKmh.toStringAsFixed(0)} km/h')),
                                              style: GoogleFonts.plusJakartaSans(
                                                fontSize: 11,
                                                color: AppColors.textDim,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (_selectedTrip != null ||
                                          _isViewingMerged ||
                                          (_isViewingLive && _routePoints.length >= 2))
                                        IconButton(
                                          icon: const Icon(
                                            Icons.ios_share_rounded,
                                            size: 19,
                                            color: AppColors.primary,
                                          ),
                                          tooltip: 'Xuất GPX / CSV / KML ghép Video',
                                          onPressed: _showExportShareSheet,
                                        ),
                                      IconButton(
                                        icon: const Icon(Icons.close_rounded, size: 20, color: AppColors.textDim),
                                        tooltip: 'Đóng chi tiết',
                                        onPressed: () {
                                          _stopPlayback();
                                          _clearStopoverBanner();
                                          setState(() {
                                            _mergedSession = null;
                                            _selectedTrip = null;
                                            _selectedTripIndex = 0;
                                            _isViewingLive = false;
                                            _routePoints = [];
                                            _currentIndex = 0;
                                          });
                                        },
                                      ),
                                    ],
                                  ),

                                  const SizedBox(height: 10),

                                  // Đồng hồ tốc độ & Telemetry
                                  if (currentPoint != null) ...[
                                    Row(
                                      crossAxisAlignment: CrossAxisAlignment.end,
                                      children: [
                                        Expanded(
                                          child: Row(
                                            crossAxisAlignment: CrossAxisAlignment.baseline,
                                            textBaseline: TextBaseline.alphabetic,
                                            children: [
                                              Text(
                                                currentPoint.speedKmh.toStringAsFixed(0),
                                                style: GoogleFonts.spaceGrotesk(
                                                  fontSize: 34,
                                                  fontWeight: FontWeight.w900,
                                                  color: currentPoint.speedKmh > 0 ? AppColors.primary : AppColors.textPrimary,
                                                  fontFeatures: const [FontFeature.tabularFigures()],
                                                ),
                                              ),
                                              const SizedBox(width: 4),
                                              Text(
                                                'km/h',
                                                style: GoogleFonts.plusJakartaSans(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w700,
                                                  color: AppColors.textDim,
                                                ),
                                              ),
                                              const SizedBox(width: 6),
                                              Flexible(
                                                child: Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                                                  decoration: BoxDecoration(
                                                    color: MapTileService.getHighContrastSpeedColor(currentPoint.speedKmh).withValues(alpha: 0.15),
                                                    borderRadius: BorderRadius.circular(8),
                                                    border: Border.all(
                                                      color: MapTileService.getHighContrastSpeedColor(currentPoint.speedKmh).withValues(alpha: 0.4),
                                                    ),
                                                  ),
                                                  child: Text(
                                                    _getSpeedLabel(currentPoint.speedKmh),
                                                    style: GoogleFonts.plusJakartaSans(
                                                      fontSize: 9.5,
                                                      fontWeight: FontWeight.w800,
                                                      color: MapTileService.getHighContrastSpeedColor(currentPoint.speedKmh),
                                                    ),
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Column(
                                          crossAxisAlignment: CrossAxisAlignment.end,
                                          children: [
                                            Text(
                                              '${currentPoint.timestamp.hour.toString().padLeft(2, '0')}:${currentPoint.timestamp.minute.toString().padLeft(2, '0')}:${currentPoint.timestamp.second.toString().padLeft(2, '0')}',
                                              style: GoogleFonts.spaceGrotesk(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w700,
                                                color: AppColors.textPrimary,
                                                fontFeatures: const [FontFeature.tabularFigures()],
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              _isViewingMerged
                                                  ? '${_mergedSession!.cumulativeDistanceAtPointIndex(safeIndex).toStringAsFixed(1)} / ${_mergedSession!.totalDistanceKm.toStringAsFixed(1)} km'
                                                  : 'Điểm ${safeIndex + 1}/${_routePoints.length}',
                                              style: GoogleFonts.plusJakartaSans(
                                                fontSize: 10.5,
                                                fontWeight: _isViewingMerged ? FontWeight.w700 : FontWeight.w400,
                                                color: _isViewingMerged ? AppColors.primary : AppColors.textDim,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                  ],

                                  // Quick-jump chips theo từng chặng khi xem phiên ghép
                                  if (_isViewingMerged) ...[
                                    SizedBox(
                                      height: 30,
                                      child: ListView.separated(
                                        scrollDirection: Axis.horizontal,
                                        itemCount: _mergedSession!.segments.length,
                                        separatorBuilder: (_, _) => const SizedBox(width: 6),
                                        itemBuilder: (context, idx) {
                                          final seg = _mergedSession!.segments[idx];
                                          final isCurrentSeg = activeSegment?.segmentIndex == seg.segmentIndex;
                                          return InkWell(
                                            borderRadius: BorderRadius.circular(10),
                                            onTap: !seg.hasPoints
                                                ? null
                                                : () => _seekTo(seg.startPointIndex),
                                            child: Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                              decoration: BoxDecoration(
                                                color: isCurrentSeg
                                                    ? AppColors.primary
                                                    : AppColors.panelSecondary,
                                                borderRadius: BorderRadius.circular(10),
                                                border: Border.all(
                                                  color: isCurrentSeg
                                                      ? AppColors.primary
                                                      : AppColors.panelBorderBright,
                                                ),
                                              ),
                                              child: Center(
                                                child: Text(
                                                  'Chặng ${seg.displayOrder}',
                                                  style: GoogleFonts.spaceGrotesk(
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.w700,
                                                    color: isCurrentSeg
                                                        ? Colors.white
                                                        : (seg.hasPoints ? AppColors.textPrimary : AppColors.textMuted),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                  ],

                                  // Mini Speed Sparkline Scrubber phía trên Slider
                                  if (_routePoints.length >= 2)
                                    Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 10),
                                      child: TripSpeedSparkline(
                                        speeds: _routePoints.map((p) => p.speedKmh).toList(growable: false),
                                        progress: (safeIndex / (_routePoints.length - 1)).clamp(0.0, 1.0),
                                        useMonoHighlight: _useHighlightMonoRoute,
                                        onSeekProgress: (t) {
                                          _seekTo((t * (_routePoints.length - 1)).round());
                                        },
                                      ),
                                    ),

                                  // Slider tua lại hành trình
                                  SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      trackHeight: 4,
                                      activeTrackColor: AppColors.primary,
                                      inactiveTrackColor: AppColors.surfaceContainer,
                                      thumbColor: AppColors.primary,
                                      overlayColor: AppColors.primary.withValues(alpha: 0.15),
                                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                                    ),
                                    child: Slider(
                                      value: safeIndex.toDouble(),
                                      min: 0,
                                      max: math.max(1.0, (_routePoints.length - 1).toDouble()),
                                      onChanged: (val) => _seekTo(val.round()),
                                    ),
                                  ),

                                  // Các nút điều khiển Phát lại
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Flexible(
                                        child: InkWell(
                                          onTap: () {
                                            setState(() => _followBike = !_followBike);
                                            if (_followBike && currentPoint != null) {
                                              _mapController.move(LatLng(currentPoint.lat, currentPoint.lng), _mapController.camera.zoom);
                                            }
                                          },
                                          borderRadius: BorderRadius.circular(10),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                                            decoration: BoxDecoration(
                                              color: _followBike ? AppColors.primary.withValues(alpha: 0.08) : AppColors.panelSecondary,
                                              borderRadius: BorderRadius.circular(10),
                                              border: Border.all(
                                                color: _followBike ? AppColors.primary : AppColors.panelBorderBright,
                                              ),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(
                                                  Icons.navigation_rounded,
                                                  size: 14,
                                                  color: _followBike ? AppColors.primary : AppColors.textDim,
                                                ),
                                                const SizedBox(width: 4),
                                                Flexible(
                                                  child: Text(
                                                    'Bám xe',
                                                    style: GoogleFonts.spaceGrotesk(
                                                      fontSize: 11,
                                                      fontWeight: FontWeight.w700,
                                                      color: _followBike ? AppColors.primary : AppColors.textDim,
                                                    ),
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            style: IconButton.styleFrom(
                                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                            ),
                                            constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                                            padding: EdgeInsets.zero,
                                            icon: const Icon(Icons.skip_previous_rounded, color: AppColors.textDim, size: 20),
                                            tooltip: 'Về đầu',
                                            onPressed: () => _seekTo(0),
                                          ),
                                          InkWell(
                                            onTap: _togglePlayPause,
                                            borderRadius: BorderRadius.circular(24),
                                            child: Container(
                                              width: 42,
                                              height: 42,
                                              decoration: BoxDecoration(
                                                shape: BoxShape.circle,
                                                color: AppColors.primary,
                                                boxShadow: [
                                                  BoxShadow(
                                                    color: AppColors.primary.withValues(alpha: 0.35),
                                                    blurRadius: 8,
                                                    offset: const Offset(0, 3),
                                                  ),
                                                ],
                                              ),
                                              child: Icon(
                                                _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                                color: Colors.white,
                                                size: 26,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          InkWell(
                                            onTap: _cyclePlaybackSpeed,
                                            borderRadius: BorderRadius.circular(10),
                                            child: Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                                              decoration: BoxDecoration(
                                                color: AppColors.panelSecondary,
                                                borderRadius: BorderRadius.circular(10),
                                                border: Border.all(color: AppColors.panelBorderBright),
                                              ),
                                              child: Text(
                                                '${_playbackSpeed.toStringAsFixed(0)}x',
                                                style: GoogleFonts.spaceGrotesk(
                                                  fontSize: 11.5,
                                                  fontWeight: FontWeight.w800,
                                                  color: AppColors.primary,
                                                ),
                                              ),
                                            ),
                                          ),
                                          IconButton(
                                            style: IconButton.styleFrom(
                                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                            ),
                                            constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                                            padding: EdgeInsets.zero,
                                            icon: const Icon(Icons.skip_next_rounded, color: AppColors.textDim, size: 20),
                                            tooltip: 'Đến cuối',
                                            onPressed: () => _seekTo(_routePoints.length - 1),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ],
                              )
                            : Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    crossAxisAlignment: CrossAxisAlignment.center,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: AppColors.amber.withValues(alpha: 0.15),
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        child: const Icon(Icons.location_off_rounded, color: AppColors.amber, size: 20),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              _isViewingLive
                                                  ? 'Đang chờ tín hiệu GPS'
                                                  : (_isViewingMerged
                                                      ? _mergedSession!.title
                                                      : 'Hành trình #$_selectedTripIndex'),
                                              style: GoogleFonts.spaceGrotesk(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w700,
                                                color: AppColors.textPrimary,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              'Chưa có dữ liệu tọa độ GPS thực tế.',
                                              style: GoogleFonts.plusJakartaSans(
                                                fontSize: 11,
                                                color: AppColors.textDim,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.close_rounded, size: 20, color: AppColors.textDim),
                                        onPressed: () {
                                          _stopPlayback();
                                          _clearStopoverBanner();
                                          setState(() {
                                            _mergedSession = null;
                                            _selectedTrip = null;
                                            _isViewingLive = false;
                                            _routePoints = [];
                                          });
                                        },
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStopoverMarker(TripStopover stopover) {
    final isActive = _activeStopoverBanner?.index == stopover.index;
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        decoration: BoxDecoration(
          color: isActive ? AppColors.textPrimary : AppColors.amber,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: [
            BoxShadow(
              color: AppColors.amber.withValues(alpha: 0.45),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Text(
          stopover.label,
          style: GoogleFonts.spaceGrotesk(
            fontSize: 10,
            fontWeight: FontWeight.w900,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _buildStartEndPin({required String label, required bool isStart}) {
    final color = isStart ? AppColors.tertiary : AppColors.red;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.4),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Center(
        child: Text(
          label,
          style: GoogleFonts.plusJakartaSans(
            fontSize: 8.5,
            fontWeight: FontWeight.w900,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _buildMyLocationMarker() {
    return Stack(
      alignment: Alignment.center,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.primary.withValues(alpha: 0.20),
            border: Border.all(color: AppColors.primary.withValues(alpha: 0.5), width: 1.5),
          ),
        ),
        Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.primary,
            border: Border.all(color: Colors.white, width: 2.5),
            boxShadow: const [
              BoxShadow(color: Color(0x40000000), blurRadius: 4, offset: Offset(0, 1)),
            ],
          ),
        ),
      ],
    );
  }

  double _bearingBetween(TripGpsPoint p1, TripGpsPoint p2) {
    final dLng = (p2.lng - p1.lng) * (math.pi / 180.0);
    final lat1 = p1.lat * (math.pi / 180.0);
    final lat2 = p2.lat * (math.pi / 180.0);
    final y = math.sin(dLng) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dLng);
    return math.atan2(y, x);
  }

  double _getReplayHeading() {
    if (_routePoints.length < 2) return 0.0;
    final idx = _currentIndex.clamp(0, _routePoints.length - 1);
    int minIdx = 0;
    int maxIdx = _routePoints.length - 1;
    if (_mergedSession != null) {
      final seg = _mergedSession!.segmentAtPointIndex(idx);
      if (seg != null && seg.hasPoints) {
        minIdx = seg.startPointIndex;
        maxIdx = seg.endPointIndex;
      }
    }
    if (idx < maxIdx) {
      return _bearingBetween(_routePoints[idx], _routePoints[idx + 1]);
    } else if (idx > minIdx) {
      return _bearingBetween(_routePoints[idx - 1], _routePoints[idx]);
    }
    return 0.0;
  }

  Widget _buildBikeReplayMarker(TripGpsPoint point) {
    final heading = _getReplayHeading();
    final isMoving = point.speedKmh > 1.0;

    return GestureDetector(
      onTap: () {
        setState(() => _useNavPuckMarker = !_useNavPuckMarker);
      },
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          if (_useNavPuckMarker) ...[
            Transform.rotate(
              angle: heading,
              child: SizedBox(
                width: 88,
                height: 88,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CustomPaint(
                      size: const Size(88, 88),
                      painter: _HeadlightBeamPainter(),
                    ),
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: isMoving
                                ? AppColors.accent.withValues(alpha: 0.38)
                                : AppColors.primary.withValues(alpha: 0.21),
                            blurRadius: isMoving ? 14 : 8,
                            spreadRadius: isMoving ? 3 : 1,
                          ),
                        ],
                      ),
                    ),
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [AppColors.onSurface, AppColors.textPrimary],
                        ),
                        border: Border.all(
                          color: AppColors.secondaryContainer,
                          width: 2.2,
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x40000000),
                            blurRadius: 6,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                      child: const Center(
                        child: Icon(
                          Icons.navigation_rounded,
                          color: AppColors.secondaryContainer,
                          size: 20,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ] else ...[
            Container(
              width: 42,
              height: 42,
              margin: const EdgeInsets.only(top: 14),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [AppColors.secondaryContainer, AppColors.primary],
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.31),
                    blurRadius: 10,
                    spreadRadius: 2,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              padding: const EdgeInsets.all(2.5),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Image.asset(
                  'assets/images/bike_logo_3d.png',
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const Icon(
                    Icons.two_wheeler_rounded,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
              ),
            ),
          ],

          Positioned(
            top: 2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.textPrimary.withValues(alpha: 0.95),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isMoving
                      ? AppColors.secondaryContainer.withValues(alpha: 0.40)
                      : AppColors.textMuted.withValues(alpha: 0.20),
                  width: 1,
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x4D000000),
                    blurRadius: 6,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.bolt_rounded,
                    size: 11,
                    color: isMoving ? AppColors.tertiary : AppColors.secondaryContainer,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    '${point.speedKmh.toStringAsFixed(0)} km/h',
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _glassIconButton({
    required IconData icon,
    required VoidCallback onTap,
    String? tooltip,
    Color? iconColor,
    bool isActive = false,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: isActive ? AppColors.primary.withValues(alpha: 0.08) : AppColors.panel.withValues(alpha: 0.94),
            borderRadius: BorderRadius.circular(12),
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
              size: 18,
            ),
            tooltip: tooltip,
            onPressed: onTap,
          ),
        ),
      ),
    );
  }
}

class _HeadlightBeamPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    final path = Path()
      ..moveTo(center.dx, center.dy)
      ..lineTo(center.dx - 24, center.dy - 42)
      ..arcToPoint(
        Offset(center.dx + 24, center.dy - 42),
        radius: const Radius.circular(36),
      )
      ..close();

    final paint = Paint()
      ..shader = RadialGradient(
        center: const Alignment(0, 0.1),
        radius: 0.85,
        colors: [
          AppColors.secondaryContainer.withValues(alpha: 0.40),
          AppColors.secondaryContainer.withValues(alpha: 0.15),
          AppColors.secondaryContainer.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: 46));

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
