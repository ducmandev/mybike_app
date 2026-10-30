import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/ble/ble_controller.dart' show TripRecord, TripGpsPoint;
import '../../core/services/map_tile_service.dart';
import '../../core/services/offline_map_service.dart';
import '../../core/services/trip_gps_tracker.dart';
import '../../ui/app_theme.dart';
import '../dashboard/widgets/offline_map_sheet.dart';

/// Màn hình Bản Đồ Lộ Trình & Phát Lại Vận Tốc Từng Thời Điểm
/// Thiết kế đồng bộ chuẩn Kinetic Stitch EV:
/// - Thanh tìm kiếm / chọn hành trình kiểu Textbox nhỏ gọn, cân đối.
/// - Thông tin dải tốc độ & thống kê được chuyển vào nút Info (ℹ️) xổ ra modal để bản đồ thông thoáng.
/// - Đường lộ trình chuyển sắc Gradient mượt mà tại các điểm giao nhau giữa các dải vận tốc.
/// - Báo tiến độ tải offline ngầm thời gian thực.
class TripRouteScreen extends StatefulWidget {
  final TripRecord trip;
  final int tripIndex;
  final List<TripRecord>? allTrips;

  const TripRouteScreen({
    super.key,
    required this.trip,
    required this.tripIndex,
    this.allTrips,
  });

  @override
  State<TripRouteScreen> createState() => _TripRouteScreenState();
}

class _TripRouteScreenState extends State<TripRouteScreen> with SingleTickerProviderStateMixin {
  late final MapController _mapController;

  late TripRecord _currentTrip;
  late int _currentTripIndex;
  List<TripRecord> _allTrips = [];

  List<TripGpsPoint> _routePoints = [];

  int _currentIndex = 0;
  bool _isPlaying = false;
  double _playbackSpeed = 1.0;
  Timer? _replayTimer;
  bool _followBike = true;
  bool _isLocating = false;
  LatLng? _myLocation;

  MapTileStyle _tileStyle = MapTileStyle.fastCdn;
  bool _useNavPuckMarker = true;

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    _currentTrip = widget.trip;
    _currentTripIndex = widget.tripIndex;

    if (widget.allTrips != null && widget.allTrips!.isNotEmpty) {
      _allTrips = widget.allTrips!;
    } else {
      _loadTripHistoryFromPrefs();
    }

    _initRouteData();
  }

  Future<void> _loadTripHistoryFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString('trip_history_v1');
      if (jsonStr != null && jsonStr.isNotEmpty) {
        final list = (jsonDecode(jsonStr) as List)
            .map((e) => TripRecord.fromJson(e as Map<String, dynamic>))
            .where((e) => e.distanceKm >= 0.1 || e.route.isNotEmpty)
            .toList();
        if (mounted && list.isNotEmpty) {
          setState(() {
            _allTrips = list;
          });
        }
      }
    } catch (_) {}
  }

  /// Xóa một chuyến đi khỏi lịch sử lưu trữ
  Future<void> _deleteTripItem(TripRecord tripToDelete) async {
    final updated = _allTrips.where((t) =>
      !(t.startTime.millisecondsSinceEpoch == tripToDelete.startTime.millisecondsSinceEpoch &&
        (t.distanceKm - tripToDelete.distanceKm).abs() < 0.001)
    ).toList();

    setState(() {
      _allTrips = updated;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      if (updated.isEmpty) {
        await prefs.remove('trip_history_v1');
      } else {
        final jsonStr = jsonEncode(updated.map((e) => e.toJson()).toList());
        await prefs.setString('trip_history_v1', jsonStr);
      }
    } catch (_) {}

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Đã xóa hành trình thành công.'),
        duration: Duration(seconds: 2),
        backgroundColor: AppColors.textPrimary,
      ),
    );

    // Nếu chuyến bị xóa là chuyến đang xem
    final isViewingDeleted = _currentTrip.startTime.millisecondsSinceEpoch == tripToDelete.startTime.millisecondsSinceEpoch &&
        (_currentTrip.distanceKm - tripToDelete.distanceKm).abs() < 0.001;

    if (isViewingDeleted) {
      if (updated.isNotEmpty) {
        setState(() {
          _currentTrip = updated.first;
          _currentTripIndex = updated.length;
          _initRouteData();
        });
        Future.delayed(const Duration(milliseconds: 200), _fitRouteBounds);
      } else {
        Navigator.pop(context);
      }
    }
  }

  /// Hộp thoại xác nhận xóa hành trình hiện tại đang xem
  Future<void> _confirmAndDeleteCurrentTrip() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Row(
          children: [
            const Icon(Icons.delete_forever_rounded, color: AppColors.red, size: 22),
            const SizedBox(width: 8),
            Text(
              'Xóa Hành Trình Này?',
              style: GoogleFonts.spaceGrotesk(fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        content: Text(
          'Bạn có chắc chắn muốn xóa vĩnh viễn hành trình #${_currentTripIndex > 0 ? _currentTripIndex : 1} (${_currentTrip.distanceKm.toStringAsFixed(1)} km) khỏi bộ nhớ thiết bị?',
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
      await _deleteTripItem(_currentTrip);
    }
  }

  void _initRouteData() {
    if (_currentTrip.route.isNotEmpty) {
      _routePoints = TripGpsTracker.cleanAndSmoothRoute(_currentTrip.route);
    } else {
      _routePoints = [];
    }
    _currentIndex = 0;
  }

  @override
  void dispose() {
    _replayTimer?.cancel();
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
    }
    setState(() => _isPlaying = true);

    _replayTimer?.cancel();
    _replayTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      setState(() {
        final step = math.max(1, (_playbackSpeed * 1.5).round());
        _currentIndex += step;
        if (_currentIndex >= _routePoints.length - 1) {
          _currentIndex = _routePoints.length - 1;
          _stopPlayback();
        }
      });

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
    setState(() => _currentIndex = clamped);

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
      } else {
        _playbackSpeed = 1.0;
      }
    });
    if (_isPlaying) {
      _startPlayback();
    }
  }

  void _fitRouteBounds() {
    if (_routePoints.isEmpty) return;
    final points = _routePoints.map((p) => LatLng(p.lat, p.lng)).toList();
    final bounds = LatLngBounds.fromPoints(points);
    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: bounds,
        padding: const EdgeInsets.only(top: 100, bottom: 260, left: 40, right: 40),
      ),
    );
  }

  /// Nội suy màu chuyển sắc liên tục (Continuous Gradient) giữa các dải tốc độ
  Color _getContinuousSpeedColor(double speedKmh) {
    if (speedKmh <= 15.0) {
      final t = (speedKmh / 15.0).clamp(0.0, 1.0);
      return Color.lerp(const Color(0xFF06B6D4), const Color(0xFF10B981), t)!; // Cyan -> Mint
    } else if (speedKmh <= 35.0) {
      final t = ((speedKmh - 15.0) / 20.0).clamp(0.0, 1.0);
      return Color.lerp(const Color(0xFF10B981), const Color(0xFF0EA5E9), t)!; // Mint -> Electric Azure
    } else if (speedKmh <= 55.0) {
      final t = ((speedKmh - 35.0) / 20.0).clamp(0.0, 1.0);
      return Color.lerp(const Color(0xFFF59E0B), const Color(0xFFF97316), t)!; // Amber -> Orange
    } else {
      final t = ((speedKmh - 55.0) / 30.0).clamp(0.0, 1.0);
      return Color.lerp(const Color(0xFFF97316), const Color(0xFFEF4444), t)!; // Orange -> Red
    }
  }

  String _getSpeedLabel(double speedKmh) {
    if (speedKmh < 5.0) return 'DỪNG XE';
    if (speedKmh < 20.0) return 'DI CHUYỂN CHẬM';
    if (speedKmh < 40.0) return 'TỐC ĐỘ ỔN ĐỊNH';
    if (speedKmh < 60.0) return 'TĂNG TỐC';
    return 'VẬN TỐC CAO';
  }

  /// Mở Modal Bottom Sheet Chọn Hành Trình (Hỗ trợ tìm kiếm kiểu textbox)
  void _openTripSearchModal() {
    final tripsToDisplay = _allTrips.isNotEmpty ? _allTrips : [_currentTrip];
    final searchCtrl = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (modalCtx, setModalState) {
            final query = searchCtrl.text.trim().toLowerCase();
            final filteredTrips = tripsToDisplay.asMap().entries.where((entry) {
              if (query.isEmpty) return true;
              final idx = tripsToDisplay.length - entry.key;
              final trip = entry.value;
              final dateStr = '${trip.startTime.day}/${trip.startTime.month}';
              final distStr = '${trip.distanceKm.toStringAsFixed(1)} km';
              return '#$idx'.contains(query) ||
                  dateStr.contains(query) ||
                  distStr.contains(query) ||
                  'hành trình $idx'.contains(query);
            }).toList();

            return Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.78,
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
                  // Thanh kéo handle
                  Container(
                    margin: const EdgeInsets.only(top: 10, bottom: 6),
                    width: 44,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),

                  // Header Modal
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 16, 10),
                    child: Row(
                      children: [
                        const Icon(Icons.route_rounded, color: AppColors.primary, size: 22),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'DANH SÁCH HÀNH TRÌNH',
                            style: GoogleFonts.spaceGrotesk(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded, color: AppColors.textDim),
                          onPressed: () => Navigator.pop(modalCtx),
                        ),
                      ],
                    ),
                  ),

                  // Ô Textbox Tìm kiếm
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: TextField(
                      controller: searchCtrl,
                      onChanged: (_) => setModalState(() {}),
                      decoration: InputDecoration(
                        hintText: 'Tìm kiếm theo #1, ngày 27/10, số km…',
                        hintStyle: GoogleFonts.plusJakartaSans(color: AppColors.textDim, fontSize: 13),
                        prefixIcon: const Icon(Icons.search_rounded, color: AppColors.primary, size: 20),
                        suffixIcon: searchCtrl.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear_rounded, size: 18),
                                onPressed: () {
                                  searchCtrl.clear();
                                  setModalState(() {});
                                },
                              )
                            : null,
                        filled: true,
                        fillColor: AppColors.panelSecondary,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: AppColors.panelBorderBright),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: AppColors.panelBorderBright),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 8),
                  const Divider(color: AppColors.panelBorder, height: 1),

                  // Danh sách hành trình đã lọc
                  Expanded(
                    child: filteredTrips.isEmpty
                        ? Center(
                            child: Text(
                              'Không tìm thấy hành trình phù hợp',
                              style: GoogleFonts.plusJakartaSans(color: AppColors.textDim, fontSize: 13),
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.all(16),
                            itemCount: filteredTrips.length,
                            separatorBuilder: (_, _) => const SizedBox(height: 8),
                            itemBuilder: (itemCtx, index) {
                              final entry = filteredTrips[index];
                              final tripItem = entry.value;
                              final tripNum = tripsToDisplay.length - entry.key;
                              final isSelected = tripItem.startTime == _currentTrip.startTime &&
                                  tripItem.distanceKm == _currentTrip.distanceKm;

                              final durMin = tripItem.durationSec ~/ 60;
                              final durText = '$durMin phút';

                              return InkWell(
                                borderRadius: BorderRadius.circular(14),
                                onTap: () {
                                  Navigator.pop(modalCtx);
                                  setState(() {
                                    _currentTrip = tripItem;
                                    _currentTripIndex = tripNum;
                                    _initRouteData();
                                  });
                                  Future.delayed(const Duration(milliseconds: 200), _fitRouteBounds);
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                  decoration: BoxDecoration(
                                    color: isSelected ? const Color(0xFFEFF6FF) : AppColors.panel,
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(
                                      color: isSelected ? AppColors.primary : AppColors.panelBorderBright,
                                      width: isSelected ? 1.5 : 1,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: isSelected
                                              ? AppColors.primary
                                              : AppColors.primary.withValues(alpha: 0.10),
                                          shape: BoxShape.circle,
                                        ),
                                        child: Icon(
                                          Icons.two_wheeler_rounded,
                                          size: 16,
                                          color: isSelected ? Colors.white : AppColors.primary,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Text(
                                                  'Hành trình #$tripNum',
                                                  style: GoogleFonts.spaceGrotesk(
                                                    fontSize: 13.5,
                                                    fontWeight: FontWeight.w700,
                                                    color: AppColors.textPrimary,
                                                  ),
                                                ),
                                                const SizedBox(width: 6),
                                                if (tripItem.route.isNotEmpty)
                                                  Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                    decoration: BoxDecoration(
                                                      color: AppColors.tertiary.withValues(alpha: 0.15),
                                                      borderRadius: BorderRadius.circular(6),
                                                    ),
                                                    child: Text(
                                                      'GPS Thực',
                                                      style: GoogleFonts.plusJakartaSans(
                                                        fontSize: 9,
                                                        fontWeight: FontWeight.w700,
                                                        color: AppColors.tertiary,
                                                      ),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              '${tripItem.distanceKm.toStringAsFixed(1)} km · $durText · ${tripItem.startTime.day.toString().padLeft(2, '0')}/${tripItem.startTime.month.toString().padLeft(2, '0')}',
                                              style: GoogleFonts.plusJakartaSans(
                                                fontSize: 11,
                                                color: AppColors.textDim,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (isSelected)
                                            const Padding(
                                              padding: EdgeInsets.only(right: 6),
                                              child: Icon(Icons.check_circle_rounded, color: AppColors.primary, size: 18),
                                            ),
                                          IconButton(
                                            tooltip: 'Xóa hành trình',
                                            icon: const Icon(Icons.delete_outline_rounded, size: 18, color: AppColors.textDim),
                                            padding: EdgeInsets.zero,
                                            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                            onPressed: () async {
                                              final confirm = await showDialog<bool>(
                                                context: context,
                                                builder: (dCtx) => AlertDialog(
                                                  backgroundColor: AppColors.panel,
                                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                                                  title: Row(
                                                    children: [
                                                      const Icon(Icons.delete_forever_rounded, color: AppColors.red, size: 22),
                                                      const SizedBox(width: 8),
                                                      Text('Xóa Hành Trình #$tripNum?', style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700)),
                                                    ],
                                                  ),
                                                  content: Text(
                                                    'Bạn có chắc muốn xóa hành trình #$tripNum (${tripItem.distanceKm.toStringAsFixed(1)} km) khỏi thiết bị?',
                                                    style: GoogleFonts.plusJakartaSans(fontSize: 13),
                                                  ),
                                                  actions: [
                                                    TextButton(
                                                      onPressed: () => Navigator.pop(dCtx, false),
                                                      child: Text('HỦY', style: GoogleFonts.spaceGrotesk(color: AppColors.textDim)),
                                                    ),
                                                    FilledButton(
                                                      style: FilledButton.styleFrom(backgroundColor: AppColors.red),
                                                      onPressed: () => Navigator.pop(dCtx, true),
                                                      child: Text('XÓA', style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700)),
                                                    ),
                                                  ],
                                                ),
                                              );
                                              if (confirm == true) {
                                                await _deleteTripItem(tripItem);
                                                setModalState(() {});
                                              }
                                            },
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// Mở Modal Thông Tin Dải Tốc Độ & Thống Kê Hành Trình (Nút Info ℹ️)
  void _showTripInfoSheet() {
    final trip = _currentTrip;
    final durMin = trip.durationSec ~/ 60;
    final durSec = trip.durationSec % 60;
    final durText = durMin > 0 ? '$durMin phút $durSec giây' : '$durSec giây';
    final co2Kg = (trip.distanceKm * 0.065).toStringAsFixed(2);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.80,
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
              Container(
                margin: const EdgeInsets.only(top: 10, bottom: 6),
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(2),
                ),
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
                        'Chi tiết hành trình',
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textPrimary,
                        ),
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
                    // 1. BẢNG MÀU DẢI TỐC ĐỘ (GRADIENT SPEED LEGEND)
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
                            const Color(0xFF06B6D4),
                            '< 15 km/h',
                            'Dừng hoặc di chuyển chậm',
                          ),
                          const Divider(color: AppColors.panelBorder, height: 16),
                          _speedLegendRow(
                            const Color(0xFF10B981),
                            '15 – 35 km/h',
                            'Tốc độ ổn định trong phố',
                          ),
                          const Divider(color: AppColors.panelBorder, height: 16),
                          _speedLegendRow(
                            const Color(0xFFF59E0B),
                            '35 – 55 km/h',
                            'Đường thoáng / đại lộ',
                          ),
                          const Divider(color: AppColors.panelBorder, height: 16),
                          _speedLegendRow(
                            const Color(0xFFEF4444),
                            '> 55 km/h',
                            'Đường trường / tốc độ cao',
                          ),
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: const Color(0xFFEFF6FF),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.auto_awesome_rounded, size: 14, color: AppColors.primary),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    'Đường đi đổi màu gradient mượt mà theo vận tốc thực tế.',
                                    style: GoogleFonts.plusJakartaSans(
                                      fontSize: 10.5,
                                      color: AppColors.primary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 18),

                    // 2. THỐNG KÊ CHI TIẾT
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
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Expanded(child: _metricTile('QUÃNG ĐƯỜNG', '${trip.distanceKm.toStringAsFixed(1)} km', Icons.straighten_rounded)),
                              Expanded(child: _metricTile('THỜI GIAN', durText, Icons.timer_outlined)),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(child: _metricTile('TỐC ĐỘ TỐI ĐA', '${trip.maxSpeedKmh.toStringAsFixed(0)} km/h', Icons.speed_rounded)),
                              Expanded(child: _metricTile('TỐC ĐỘ TRUNG BÌNH', '${trip.avgSpeedKmh.toStringAsFixed(0)} km/h', Icons.moving_rounded)),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(child: _metricTile('GIẢM THẢI CO2', '$co2Kg kg', Icons.eco_rounded)),
                              Expanded(child: _metricTile('TIÊU HAO PIN', trip.usedPercent > 0 ? '-${trip.usedPercent}%' : '--', Icons.battery_charging_full_rounded)),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(child: _metricTile('TỔNG SỐ ĐIỂM GPS', '${_routePoints.length} điểm ghi nhận', Icons.gps_fixed_rounded)),
                              Expanded(child: _metricTile('NGUỒN DỮ LIỆU', _routePoints.isNotEmpty ? 'GPS Thực Tế' : 'Chưa có GPS', Icons.sensors_rounded)),
                            ],
                          ),
                          const SizedBox(height: 20),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.red,
                                side: const BorderSide(color: Color(0xFFFCA5A5)),
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                              ),
                              icon: const Icon(Icons.delete_outline_rounded, size: 18),
                              label: Text(
                                'XÓA HÀNH TRÌNH NÀY',
                                style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700, fontSize: 13),
                              ),
                              onPressed: () {
                                Navigator.pop(ctx);
                                _confirmAndDeleteCurrentTrip();
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _speedLegendRow(Color color, String range, String desc) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 2),
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.4),
                blurRadius: 4,
                offset: const Offset(0, 1),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 85,
          child: Text(
            range,
            style: GoogleFonts.spaceGrotesk(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
        ),
        Expanded(
          child: Text(
            desc,
            style: GoogleFonts.plusJakartaSans(
              fontSize: 11,
              color: AppColors.textDim,
            ),
          ),
        ),
      ],
    );
  }

  Widget _metricTile(String label, String value, IconData icon) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: AppColors.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textDim,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                value,
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasPoints = _routePoints.isNotEmpty;
    final currentPoint = hasPoints ? _routePoints[_currentIndex] : null;

    final initialCenter = hasPoints
        ? LatLng(_routePoints.first.lat, _routePoints.first.lng)
        : const LatLng(10.7719, 106.7195);

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
                Future.delayed(const Duration(milliseconds: 300), _fitRouteBounds);
              },
            ),
            children: [
              // Tile Layer (Ưu tiên nạp từ ổ cứng offline cache)
              MapTileService.buildTileLayer(style: _tileStyle),

              // Polyline Lộ trình với dải màu vận tốc (Continuous Gradient Transitions)
              if (hasPoints) ...[
                // Lớp bóng mờ phía dưới đường đi
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _routePoints.map((p) => LatLng(p.lat, p.lng)).toList(),
                      strokeWidth: 8.0,
                      strokeCap: StrokeCap.round,
                      strokeJoin: StrokeJoin.round,
                      color: AppColors.primary.withValues(alpha: 0.20),
                    ),
                  ],
                ),
                // Lớp các đoạn polyline chuyển sắc mượt mà giữa các điểm nối
                PolylineLayer(
                  polylines: [
                    for (int i = 0; i < _routePoints.length - 1; i++)
                      Polyline(
                        points: [
                          LatLng(_routePoints[i].lat, _routePoints[i].lng),
                          LatLng(_routePoints[i + 1].lat, _routePoints[i + 1].lng),
                        ],
                        strokeWidth: 5.5,
                        strokeCap: StrokeCap.round,
                        strokeJoin: StrokeJoin.round,
                        gradientColors: [
                          _getContinuousSpeedColor(_routePoints[i].speedKmh),
                          _getContinuousSpeedColor(_routePoints[i + 1].speedKmh),
                        ],
                      ),
                  ],
                ),
              ],

              // Marker Điểm xuất phát (A), Đích đến (B), Vị trí của tôi, và Xe Dat Bike
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

          // 2. HEADER TOP: Thanh tìm kiếm kiểu Textbox & Nút Info (Cân đối rộng rãi trên mọi màn hình mobile)
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

                    // Thanh tìm kiếm & chọn hành trình kiểu Textbox (Gọn gàng, tỉ lệ chuẩn)
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
                                      _currentTripIndex > 0 ? '#$_currentTripIndex · ${_currentTrip.distanceKm.toStringAsFixed(1)} km' : 'Chuyến đi hiện tại · ${_currentTrip.distanceKm.toStringAsFixed(1)} km',
                                      style: GoogleFonts.plusJakartaSans(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.textPrimary,
                                      ),
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

                    // Nút Info (ℹ️): Xổ thông tin dải tốc độ & Thống kê hành trình (Giúp bản đồ thông thoáng)
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

          // 3. THANH CÔNG CỤ BẢN ĐỒ DỌC (Góc phải bản đồ, chuẩn Google / Apple Maps UX)
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.only(top: 56, right: 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Nút Căn toàn bộ lộ trình
                    _glassIconButton(
                      icon: Icons.crop_free_rounded,
                      tooltip: 'Căn toàn bộ lộ trình',
                      onTap: _fitRouteBounds,
                    ),
                    const SizedBox(height: 8),

                    // Nút Vị trí của tôi
                    _glassIconButton(
                      icon: Icons.my_location_rounded,
                      iconColor: _isLocating ? AppColors.primary : AppColors.textDim,
                      isActive: _isLocating,
                      tooltip: 'Vị trí của tôi',
                      onTap: _locateMe,
                    ),
                    const SizedBox(height: 8),

                    // Nút chuyển kiểu Map
                    _glassIconButton(
                      icon: MapTileService.getStyleIcon(_tileStyle),
                      tooltip: MapTileService.getStyleName(_tileStyle),
                      onTap: _cycleTileStyle,
                    ),
                    const SizedBox(height: 8),

                    // Nút Tải bản đồ offline
                    _glassIconButton(
                      icon: Icons.download_for_offline_rounded,
                      tooltip: 'Tải bản đồ offline',
                      onTap: () {
                        OfflineMapSheet.show(
                          context,
                          currentMapBounds: _mapController.camera.visibleBounds,
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),

          // 4. MINI BANNER TẢI BẢN ĐỒ NGẦM (Nếu đang tải trong nền)
          ValueListenableBuilder<DownloadProgress>(
            valueListenable: OfflineMapService.instance.progressNotifier,
            builder: (context, progress, _) {
              if (!progress.isRunning && !progress.isPaused) {
                return const SizedBox.shrink();
              }
              return Positioned(
                top: 56,
                left: 14,
                right: 58,
                child: GestureDetector(
                  onTap: () => OfflineMapSheet.show(
                    context,
                    currentMapBounds: _mapController.camera.visibleBounds,
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(9999),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: AppColors.panel.withValues(alpha: 0.94),
                          borderRadius: BorderRadius.circular(9999),
                          border: Border.all(
                            color: progress.isPaused ? AppColors.amber : AppColors.primary,
                          ),
                          boxShadow: AppColors.cardShadow,
                        ),
                        child: Row(
                          children: [
                            if (progress.isRunning)
                              const SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                              )
                            else
                              const Icon(Icons.pause_circle_rounded, size: 14, color: AppColors.amber),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                progress.isPaused
                                    ? 'Đang tạm dừng tải (${progress.percentInt}%)'
                                    : 'Đang tải bản đồ offline ngầm: ${progress.percentInt}% (${progress.sizeMbText})',
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.textPrimary,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(
                              'Chi tiết >',
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: AppColors.primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),

          // Thông báo trực quan giữa bản đồ khi chưa có dữ liệu GPS thực tế
          if (!hasPoints)
            Center(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 28),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                decoration: BoxDecoration(
                  color: AppColors.panel.withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: AppColors.panelBorderBright),
                  boxShadow: AppColors.modalShadow,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppColors.amber.withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.location_off_rounded, size: 28, color: AppColors.amber),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Chưa có dữ liệu GPS thực tế',
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Hành trình này không có dữ liệu định vị GPS. Tọa độ chỉ được ghi nhận khi xe chuyển sang chế độ lái (D hoặc S).',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 11.5,
                        color: AppColors.textDim,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // 4. BẢNG ĐIỀU KHIỂN & PHÁT LẠI VẬN TỐC Ở ĐÁY MÀN HÌNH (Replay & Telemetry HUD)
          Positioned(
            left: 14,
            right: 14,
            bottom: 20,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: Container(
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
                            // Hàng thông số Telemetry tại thời điểm đang phát lại
                            if (currentPoint != null) ...[
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            // Đồng hồ tốc độ to rõ
                            Expanded(
                              flex: 5,
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.baseline,
                                textBaseline: TextBaseline.alphabetic,
                                children: [
                                  Text(
                                    currentPoint.speedKmh.toStringAsFixed(0),
                                    style: GoogleFonts.spaceGrotesk(
                                      fontSize: 40,
                                      fontWeight: FontWeight.w900,
                                      color: currentPoint.speedKmh > 0 ? AppColors.primary : AppColors.textPrimary,
                                      fontFeatures: const [FontFeature.tabularFigures()],
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    'km/h',
                                    style: GoogleFonts.plusJakartaSans(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.textDim,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: _getContinuousSpeedColor(currentPoint.speedKmh).withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: _getContinuousSpeedColor(currentPoint.speedKmh).withValues(alpha: 0.4),
                                      ),
                                    ),
                                    child: Text(
                                      _getSpeedLabel(currentPoint.speedKmh),
                                      style: GoogleFonts.plusJakartaSans(
                                        fontSize: 9.5,
                                        fontWeight: FontWeight.w800,
                                        color: _getContinuousSpeedColor(currentPoint.speedKmh),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            // Thông tin mốc thời gian & điểm GPS
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
                                  'Điểm ${_currentIndex + 1}/${_routePoints.length}',
                                  style: GoogleFonts.plusJakartaSans(
                                    fontSize: 10.5,
                                    color: AppColors.textDim,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                      ],

                      // Thanh trượt tua thời gian hành trình (Timeline Scrubber Slider)
                      if (hasPoints)
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
                            value: _currentIndex.toDouble(),
                            min: 0,
                            max: math.max(1.0, (_routePoints.length - 1).toDouble()),
                            onChanged: (val) => _seekTo(val.round()),
                          ),
                        ),

                      // Hàng nút điều khiển Phát / Dừng / Tốc độ phát lại / Bám xe
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          // Nút chuyển chế độ bám xe (Follow Bike)
                          InkWell(
                            onTap: () {
                              setState(() => _followBike = !_followBike);
                              if (_followBike && currentPoint != null) {
                                _mapController.move(
                                  LatLng(currentPoint.lat, currentPoint.lng),
                                  _mapController.camera.zoom,
                                );
                              }
                            },
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: _followBike ? const Color(0xFFEFF6FF) : AppColors.panelSecondary,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: _followBike ? AppColors.primary : AppColors.panelBorderBright,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.navigation_rounded,
                                    size: 13,
                                    color: _followBike ? AppColors.primary : AppColors.textDim,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    'Bám xe',
                                    style: GoogleFonts.plusJakartaSans(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w700,
                                      color: _followBike ? AppColors.primary : AppColors.textDim,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),

                          // Nút tua lùi về đầu
                          IconButton(
                            icon: const Icon(Icons.replay_rounded, color: AppColors.textDim, size: 20),
                            tooltip: 'Về đầu',
                            onPressed: () => _seekTo(0),
                          ),

                          // Nút Phát / Tạm dừng Replay lớn
                          GestureDetector(
                            onTap: _togglePlayPause,
                            child: Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: AppColors.primary,
                                boxShadow: AppColors.cardShadow,
                              ),
                              child: Icon(
                                _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                color: Colors.white,
                                size: 28,
                              ),
                            ),
                          ),

                          // Nút đổi tốc độ phát lại (1x, 2x, 4x, 8x)
                          InkWell(
                            onTap: _cyclePlaybackSpeed,
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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

                          // Nút tua đến cuối
                          IconButton(
                            icon: const Icon(Icons.skip_next_rounded, color: AppColors.textDim, size: 20),
                            tooltip: 'Đến cuối',
                            onPressed: () => _seekTo(_routePoints.length - 1),
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
                              color: AppColors.primary.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(Icons.alt_route_rounded, color: AppColors.primary, size: 20),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  _currentTripIndex > 0
                                      ? 'Hành trình #$_currentTripIndex'
                                      : 'Chuyến đi hiện tại',
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
                                  '${_currentTrip.distanceKm.toStringAsFixed(1)} km · ${_currentTrip.durationSec ~/ 60} phút · Tối đa ${_currentTrip.maxSpeedKmh.toStringAsFixed(0)} km/h',
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
                          const SizedBox(width: 8),
                          InkWell(
                            onTap: _showTripInfoSheet,
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: AppColors.panelSecondary,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: AppColors.panelBorderBright),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.info_outline_rounded, size: 14, color: AppColors.primary),
                                  const SizedBox(width: 4),
                                  Text(
                                    'Chi tiết',
                                    style: GoogleFonts.plusJakartaSans(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.primary,
                                    ),
                                  ),
                                ],
                              ),
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
        ],
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

  double _getReplayHeading() {
    if (_routePoints.length < 2) return 0.0;
    final idx = _currentIndex.clamp(0, _routePoints.length - 1);
    if (idx < _routePoints.length - 1) {
      final p1 = _routePoints[idx];
      final p2 = _routePoints[idx + 1];
      final dLng = (p2.lng - p1.lng) * (math.pi / 180.0);
      final lat1 = p1.lat * (math.pi / 180.0);
      final lat2 = p2.lat * (math.pi / 180.0);
      final y = math.sin(dLng) * math.cos(lat2);
      final x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dLng);
      return math.atan2(y, x);
    } else if (idx > 0) {
      final p1 = _routePoints[idx - 1];
      final p2 = _routePoints[idx];
      final dLng = (p2.lng - p1.lng) * (math.pi / 180.0);
      final lat1 = p1.lat * (math.pi / 180.0);
      final lat2 = p2.lat * (math.pi / 180.0);
      final y = math.sin(dLng) * math.cos(lat2);
      final x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dLng);
      return math.atan2(y, x);
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
            // 1. CHẾ ĐỘ THỂ THAO HUD: Con trỏ dẫn đường xoay góc cua + Đèn pha chiếu mặt đường
            Transform.rotate(
              angle: heading,
              child: SizedBox(
                width: 88,
                height: 88,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Chùm sáng đèn pha LED quét phía trước (Headlight beam)
                    CustomPaint(
                      size: const Size(88, 88),
                      painter: _HeadlightBeamPainter(),
                    ),
                    // Vòng hào quang phát sáng radar bên dưới
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: isMoving ? const Color(0x600284C7) : const Color(0x352563EB),
                            blurRadius: isMoving ? 14 : 8,
                            spreadRadius: isMoving ? 3 : 1,
                          ),
                        ],
                      ),
                    ),
                    // Đĩa con trỏ kim loại Sapphire bóng bẩy
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFF1E293B), Color(0xFF0F172A)],
                        ),
                        border: Border.all(
                          color: const Color(0xFF38BDF8),
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
                          color: Color(0xFF38BDF8),
                          size: 20,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ] else ...[
            // 2. CHẾ ĐỘ GHIM 3D KIM LOẠI: Huy hiệu 3D Dat Bike cao cấp nổi khối
            Container(
              width: 42,
              height: 42,
              margin: const EdgeInsets.only(top: 14),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF38BDF8), Color(0xFF2563EB)],
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x502563EB),
                    blurRadius: 10,
                    spreadRadius: 2,
                    offset: Offset(0, 2),
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

          // HUD SPEED CAPSULE: Thanh hiển thị tốc độ nổi phía trên (Chuẩn xe điện hiện đại)
          Positioned(
            top: 2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xF20F172A),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isMoving ? const Color(0x6638BDF8) : const Color(0x3394A3B8),
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
                    color: isMoving ? const Color(0xFF10B981) : const Color(0xFF38BDF8),
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
            color: isActive ? const Color(0xFFEFF6FF) : AppColors.panel.withValues(alpha: 0.94),
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
        colors: const [
          Color(0x6638BDF8),
          Color(0x2638BDF8),
          Color(0x0038BDF8),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: 46));

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
