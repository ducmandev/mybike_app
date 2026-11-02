import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart' hide Path;

import '../../core/ble/ble_controller.dart' show TripRecord, TripGpsPoint, bleProvider, BlePhase;
import '../../core/services/map_tile_service.dart';
import '../../core/services/trip_gps_tracker.dart';
import '../../core/services/trip_storage_service.dart';
import '../../ui/app_theme.dart';
import '../dashboard/widgets/offline_map_sheet.dart';

/// Màn hình Bản Đồ Lộ Trình & Phát Lại Vận Tốc Từng Thời Điểm
/// - Mặc định vào bản đồ: Bản đồ sạch sẽ, tự động định vị vị trí hiện tại của người dùng.
/// - Khi có hành trình đang ghi: Hiển thị badge nhỏ gọn góc trên bên phải "Đang định vị chuyến đi".
/// - Quản lý dữ liệu chuẩn 2 tầng (Two-Tier Storage): Lazy load tọa độ và đồng bộ xóa 2 chiều với Riverpod.
/// - Chống sập NaN/Infinity zoom camera khi bounds diện tích = 0.
class TripRouteScreen extends ConsumerStatefulWidget {
  final TripRecord? trip;
  final int tripIndex;
  final List<TripRecord>? allTrips;

  const TripRouteScreen({
    super.key,
    this.trip,
    this.tripIndex = 0,
    this.allTrips,
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

  List<TripGpsPoint> _routePoints = [];
  bool _isViewingLive = false;

  int _currentIndex = 0;
  bool _isPlaying = false;
  double _playbackSpeed = 1.0;
  Timer? _replayTimer;
  Timer? _liveRefreshTimer;
  bool _followBike = true;
  bool _isLocating = false;
  LatLng? _myLocation;

  MapTileStyle _tileStyle = MapTileStyle.fastCdn;
  bool _useNavPuckMarker = true;

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

    // Nếu người dùng chọn xem một chuyến cụ thể từ danh sách lịch sử
    if (widget.trip != null && (widget.tripIndex > 0 || widget.trip!.distanceKm >= 0.1 || widget.trip!.route.isNotEmpty)) {
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

  /// Chọn xem 1 chuyến đi cụ thể từ danh sách
  Future<void> _selectTrip(TripRecord trip, int index) async {
    setState(() {
      _selectedTrip = trip;
      _selectedTripIndex = index;
      _isViewingLive = false;
    });

    final route = await TripStorageService.instance.loadTripRoute(trip);
    if (!mounted) return;

    setState(() {
      _routePoints = TripGpsTracker.cleanAndSmoothRoute(route);
      _currentIndex = 0;
    });

    Future.delayed(const Duration(milliseconds: 250), _fitRouteBounds);
  }

  /// Bật chế độ xem lộ trình đang đi trực tiếp
  void _startLiveTrackingView() {
    final livePoints = TripGpsTracker.instance.getCurrentRoute();
    setState(() {
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

    // Nếu chuyến bị xóa là chuyến đang xem
    if (_selectedTrip != null &&
        (_selectedTrip!.id == tripToDelete.id ||
         (_selectedTrip!.startTime.millisecondsSinceEpoch == tripToDelete.startTime.millisecondsSinceEpoch &&
          (_selectedTrip!.distanceKm - tripToDelete.distanceKm).abs() < 0.001))) {
      setState(() {
        _selectedTrip = null;
        _selectedTripIndex = 0;
        _routePoints = [];
        _currentIndex = 0;
      });
      _stopPlayback();
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
            Text(
              'Xóa Hành Trình Này?',
              style: GoogleFonts.spaceGrotesk(fontSize: 16, fontWeight: FontWeight.w700),
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

  /// Căn góc camera an toàn — Chống tuyệt đối lỗi Bounds diện tích 0 (NaN / Infinity Zoom Loop)
  void _fitRouteBounds() {
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
          padding: const EdgeInsets.only(top: 100, bottom: 260, left: 40, right: 40),
        ),
      );
    } catch (_) {
      _mapController.move(bounds.center, 15.0);
    }
  }

  /// Nội suy màu chuyển sắc liên tục (Continuous Gradient) giữa các dải tốc độ
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

  String _getSpeedLabel(double speedKmh) {
    if (speedKmh < 5.0) return 'DỪNG XE';
    if (speedKmh < 20.0) return 'DI CHUYỂN CHẬM';
    if (speedKmh < 40.0) return 'TỐC ĐỘ ỔN ĐỊNH';
    if (speedKmh < 60.0) return 'TĂNG TỐC';
    return 'VẬN TỐC CAO';
  }

  /// Mở Modal Bottom Sheet Chọn Hành Trình (Hỗ trợ tìm kiếm kiểu textbox)
  void _openTripSearchModal() {
    final searchCtrl = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (modalCtx, setModalState) {
            final tripsToDisplay = _allTrips;
            final query = searchCtrl.text.trim().toLowerCase();
            final filteredTrips = tripsToDisplay.asMap().entries.where((entry) {
              if (query.isEmpty) return true;
              final idx = tripsToDisplay.length - entry.key;
              final km = entry.value.distanceKm.toStringAsFixed(1);
              final dateStr = '${entry.value.startTime.day}/${entry.value.startTime.month}';
              return idx.toString().contains(query) ||
                  km.contains(query) ||
                  dateStr.contains(query) ||
                  'hành trình $idx'.contains(query);
            }).toList();

            return Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.85,
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

                  // Header Modal
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 16, 12),
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
                          icon: const Icon(Icons.close_rounded, color: AppColors.textDim),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                  ),

                  // Ô Tìm Kiếm Textbox
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: TextField(
                      controller: searchCtrl,
                      onChanged: (_) => setModalState(() {}),
                      style: GoogleFonts.spaceGrotesk(fontSize: 13, color: AppColors.textPrimary),
                      decoration: InputDecoration(
                        hintText: 'Tìm theo số #, ngày hoặc số km...',
                        hintStyle: GoogleFonts.plusJakartaSans(fontSize: 12.5, color: AppColors.textDim),
                        prefixIcon: const Icon(Icons.search_rounded, size: 18, color: AppColors.primary),
                        suffixIcon: searchCtrl.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear_rounded, size: 16, color: AppColors.textDim),
                                onPressed: () {
                                  searchCtrl.clear();
                                  setModalState(() {});
                                },
                              )
                            : null,
                        filled: true,
                        fillColor: AppColors.panelSecondary,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: const BorderSide(color: AppColors.panelBorder),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
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
                            padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
                            itemCount: filteredTrips.length,
                            separatorBuilder: (context, index) => const SizedBox(height: 8),
                            itemBuilder: (context, idx) {
                              final entry = filteredTrips[idx];
                              final tripItem = entry.value;
                              final tripNum = tripsToDisplay.length - entry.key;
                              final isSelected = _selectedTrip != null &&
                                  _selectedTrip!.startTime.millisecondsSinceEpoch == tripItem.startTime.millisecondsSinceEpoch;

                              final durMin = tripItem.durationSec ~/ 60;
                              final dateStr =
                                  '${tripItem.startTime.day.toString().padLeft(2, '0')}/${tripItem.startTime.month.toString().padLeft(2, '0')} · ${tripItem.startTime.hour.toString().padLeft(2, '0')}:${tripItem.startTime.minute.toString().padLeft(2, '0')}';

                              return InkWell(
                                borderRadius: BorderRadius.circular(14),
                                onTap: () {
                                  Navigator.pop(ctx);
                                  _selectTrip(tripItem, tripNum);
                                },
                                child: Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: isSelected ? const Color(0xFFEFF6FF) : AppColors.panelSecondary,
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(
                                      color: isSelected ? AppColors.primary : AppColors.panelBorderBright,
                                      width: isSelected ? 1.5 : 1.0,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 38,
                                        height: 38,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: isSelected ? AppColors.primary : AppColors.primary.withValues(alpha: 0.12),
                                        ),
                                        child: Center(
                                          child: Text(
                                            '#$tripNum',
                                            style: GoogleFonts.spaceGrotesk(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w800,
                                              color: isSelected ? Colors.white : AppColors.primary,
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
                                            ),
                                            const SizedBox(height: 3),
                                            Text(
                                              '$dateStr · ${tripItem.distanceKm.toStringAsFixed(1)} km · $durMin phút',
                                              style: GoogleFonts.plusJakartaSans(
                                                fontSize: 11,
                                                color: AppColors.textDim,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
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
                                            await _deleteTripItem(tripItem);
                                            setModalState(() {});
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
    final trip = _selectedTrip;
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
                        _selectedTrip != null ? 'Chi tiết hành trình #$_selectedTripIndex' : 'Thông tin bản đồ & Tốc độ',
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
                        ],
                      ),
                    ),

                    if (trip != null) ...[
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
                        child: Column(
                          children: [
                            _tripDetailRow('Quãng đường', '${trip.distanceKm.toStringAsFixed(1)} km'),
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
                        ),
                      ),

                      const SizedBox(height: 20),
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
        Text(label, style: GoogleFonts.plusJakartaSans(fontSize: 12.5, color: AppColors.textDim)),
        Text(value, style: GoogleFonts.spaceGrotesk(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasPoints = _routePoints.isNotEmpty;
    final currentPoint = hasPoints ? _routePoints[_currentIndex] : null;

    final bleState = ref.watch(bleProvider);
    final isTrackingActive = TripGpsTracker.instance.isTracking ||
        TripGpsTracker.instance.getCurrentRoute().isNotEmpty ||
        (bleState.phase == BlePhase.connected && bleState.trip.duration.inSeconds > 0);
    final curLiveDistance = TripGpsTracker.instance.totalDistanceKm > 0
        ? TripGpsTracker.instance.totalDistanceKm
        : bleState.trip.distanceKm;

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
                if (_selectedTrip != null && hasPoints) {
                  Future.delayed(const Duration(milliseconds: 300), _fitRouteBounds);
                } else {
                  _locateMe();
                }
              },
            ),
            children: [
              // Tile Layer
              MapTileService.buildTileLayer(style: _tileStyle),

              // Polyline Lộ trình (Gradient)
              if (hasPoints) ...[
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
                                          ? 'Đang định vị chuyến đi · ${curLiveDistance.toStringAsFixed(1)} km'
                                          : (_selectedTrip != null
                                              ? '#$_selectedTripIndex · ${_selectedTrip!.distanceKm.toStringAsFixed(1)} km'
                                              : 'Tìm kiếm hành trình...'),
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
          if (isTrackingActive)
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
                        color: _isViewingLive ? const Color(0xFF0F172A) : AppColors.panel.withValues(alpha: 0.92),
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
                  icon: Icons.download_for_offline_outlined,
                  tooltip: 'Bản đồ offline',
                  onTap: () => OfflineMapSheet.show(context),
                ),
              ],
            ),
          ),

          // 5. BẢNG ĐIỀU KHIỂN & PHÁT LẠI VẬN TỐC Ở ĐÁY MÀN HÌNH
          // CHỈ HIỆN KHI NGƯỜI DÙNG CHỌN 1 HÀNH TRÌNH HOẶC BẬT XEM LIVE
          if (_selectedTrip != null || _isViewingLive)
            Positioned(
              left: 14,
              right: 14,
              bottom: 20,
              child: ClipRRect(
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
                                              : 'Hành trình #$_selectedTripIndex',
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
                                              ? '${curLiveDistance.toStringAsFixed(1)} km · Điểm GPS: ${_routePoints.length}'
                                              : '${_selectedTrip!.distanceKm.toStringAsFixed(1)} km · ${_selectedTrip!.durationSec ~/ 60} phút · Max ${_selectedTrip!.maxSpeedKmh.toStringAsFixed(0)} km/h',
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
                                  IconButton(
                                    icon: const Icon(Icons.close_rounded, size: 20, color: AppColors.textDim),
                                    tooltip: 'Đóng chi tiết',
                                    onPressed: () {
                                      setState(() {
                                        _selectedTrip = null;
                                        _selectedTripIndex = 0;
                                        _isViewingLive = false;
                                        _routePoints = [];
                                      });
                                      _stopPlayback();
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
                                      flex: 5,
                                      child: Row(
                                        crossAxisAlignment: CrossAxisAlignment.baseline,
                                        textBaseline: TextBaseline.alphabetic,
                                        children: [
                                          Text(
                                            currentPoint.speedKmh.toStringAsFixed(0),
                                            style: GoogleFonts.spaceGrotesk(
                                              fontSize: 36,
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
                                          const SizedBox(width: 8),
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
                                const SizedBox(height: 6),
                              ],

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
                                  value: _currentIndex.toDouble(),
                                  min: 0,
                                  max: math.max(1.0, (_routePoints.length - 1).toDouble()),
                                  onChanged: (val) => _seekTo(val.round()),
                                ),
                              ),

                              // Các nút điều khiển Phát lại
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  InkWell(
                                    onTap: () {
                                      setState(() => _followBike = !_followBike);
                                      if (_followBike && currentPoint != null) {
                                        _mapController.move(LatLng(currentPoint.lat, currentPoint.lng), _mapController.camera.zoom);
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
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.navigation_rounded,
                                            size: 14,
                                            color: _followBike ? AppColors.primary : AppColors.textDim,
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            'Bám xe',
                                            style: GoogleFonts.spaceGrotesk(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w700,
                                              color: _followBike ? AppColors.primary : AppColors.textDim,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
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
                                      const SizedBox(width: 8),
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
                                      IconButton(
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
                                          _isViewingLive ? 'Đang chờ tín hiệu GPS' : 'Hành trình #$_selectedTripIndex',
                                          style: GoogleFonts.spaceGrotesk(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w700,
                                            color: AppColors.textPrimary,
                                          ),
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
                                      setState(() {
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
                            color: isMoving ? const Color(0x600284C7) : const Color(0x352563EB),
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
