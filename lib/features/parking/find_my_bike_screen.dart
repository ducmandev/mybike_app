import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart' hide Path;

import '../../core/ble/ble_controller.dart';
import '../../core/services/map_tile_service.dart';
import '../../core/services/trip_gps_tracker.dart';
import '../../ui/app_theme.dart';
import '../dashboard/widgets/optical_signal_bloom.dart';
import 'widgets/precision_radar_gauge.dart';

/// Màn hình Tìm xe & Định vị đỗ xe thông minh (Smart Parking & Precision Find My Bike)
/// Thiết kế tinh tế theo phong cách Dashboard Cockpit EV (Chuẩn tỷ lệ 70/30 và chân dung).
class FindMyBikeScreen extends ConsumerStatefulWidget {
  const FindMyBikeScreen({super.key});

  @override
  ConsumerState<FindMyBikeScreen> createState() => _FindMyBikeScreenState();
}

class _FindMyBikeScreenState extends ConsumerState<FindMyBikeScreen> {
  ParkedLocation? _parkedLocation;
  Position? _userPosition;
  StreamSubscription<Position>? _positionSub;
  Timer? _hapticTimer;

  double _estimatedDistance = 4.5;
  double _relativeHeading = 45.0;
  bool _showSignalBloom = false;
  Timer? _bloomTimer;

  late final MapController _mapController;

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    _loadInitialParkingLocation();
    _startPositionListening();
    _startHapticHeartbeat();
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _hapticTimer?.cancel();
    _bloomTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadInitialParkingLocation() async {
    final ble = ref.read(bleProvider);
    final loc = await ParkingStorageService.instance.loadParkedLocation(
      bikeId: ble.device?.remoteId.str,
    );

    if (mounted) {
      setState(() {
        _parkedLocation = loc ??
            ParkedLocation(
              latitude: TripGpsTracker.instance.currentPoint?.lat ?? 10.7769,
              longitude: TripGpsTracker.instance.currentPoint?.lng ?? 106.7009,
              timestamp: DateTime.now().subtract(const Duration(hours: 2, minutes: 18)),
              bikeId: ble.device?.remoteId.str ?? 'default_bike',
              bikeName: ble.bikeName ?? 'Dat Bike Quantum S1',
              batteryPercent: ble.lastTelemetry?.percent ?? 82,
              voltage: ble.lastTelemetry?.voltage ?? 72.4,
              address: 'Vincom Center Đồng Khởi · Hầm B2 - Cột K12',
              note: 'Cột K12 · Hầm B2',
              isLocked: ble.isLocked,
            );
      });
      _updateCalculatedMetrics();
    }
  }

  void _startPositionListening() {
    try {
      _positionSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 1,
        ),
      ).listen((pos) {
        if (!mounted) return;
        setState(() {
          _userPosition = pos;
        });
        _updateCalculatedMetrics();
      });
    } catch (_) {}
  }

  void _updateCalculatedMetrics() {
    final ble = ref.read(bleProvider);
    final parked = _parkedLocation;

    if (ble.phase == BlePhase.connected && ble.rssi != null && ble.rssi! < 0) {
      // 1. Nếu đang kết nối BLE: Quy đổi từ RSSI sang khoảng cách mét
      // TxPower ~ -59 dBm, hệ số suy hao n ~ 2.4
      final rawDist = math.pow(10, (-59 - ble.rssi!) / (10 * 2.4)).toDouble();
      _estimatedDistance = rawDist.clamp(0.5, 25.0);
    } else if (_userPosition != null && parked != null) {
      // 2. Nếu ở xa: Tính khoảng cách GPS thực tế
      final gpsDist = Geolocator.distanceBetween(
        _userPosition!.latitude,
        _userPosition!.longitude,
        parked.latitude,
        parked.longitude,
      );
      _estimatedDistance = gpsDist.clamp(0.5, 9999.0);
    }

    // 3. Tính góc phương vị la bàn dẫn đường (Relative Heading)
    if (_userPosition != null && parked != null) {
      final bearing = Geolocator.bearingBetween(
        _userPosition!.latitude,
        _userPosition!.longitude,
        parked.latitude,
        parked.longitude,
      );
      final userHeading = _userPosition!.heading;
      final rel = (bearing - userHeading + 360) % 360;
      _relativeHeading = rel;
    }
  }

  /// Nhịp rung xúc giác Haptic phản hồi theo cự ly phong cách Apple AirTag
  void _startHapticHeartbeat() {
    _hapticTimer?.cancel();
    _hapticTimer = Timer.periodic(const Duration(milliseconds: 700), (_) {
      if (!mounted) return;
      if (_estimatedDistance <= 1.5) {
        HapticFeedback.heavyImpact();
      } else if (_estimatedDistance <= 6.0) {
        HapticFeedback.mediumImpact();
      } else if (_estimatedDistance <= 15.0) {
        HapticFeedback.selectionClick();
      }
    });
  }

  void _triggerSignalFlash() {
    _bloomTimer?.cancel();
    setState(() => _showSignalBloom = true);

    // Kêu còi / nháy đèn trên xe qua BLE
    ref.read(bleProvider.notifier).findBike();

    _bloomTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _showSignalBloom = false);
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '💡 Đã gửi lệnh nháy xi-nhan và phát còi tìm xe!',
          style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600),
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(milliseconds: 1600),
      ),
    );
  }

  void _triggerChirp() {
    ref.read(bleProvider.notifier).findBike();
    HapticFeedback.lightImpact();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '🔊 Đã phát còi "BÍP BÍP" định vị âm thanh xe!',
          style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600),
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(milliseconds: 1600),
      ),
    );
  }

  Future<void> _triggerUnlock() async {
    final notifier = ref.read(bleProvider.notifier);
    final msg = await notifier.unlockBike();
    HapticFeedback.heavyImpact();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            msg,
            style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600),
          ),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          backgroundColor: AppColors.primary,
        ),
      );
    }
  }

  void _openNoteSheet() {
    final controller = TextEditingController(text: _parkedLocation?.note ?? '');

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
        ),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          boxShadow: AppColors.modalShadow,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Ghi Chú Vị Trí Đỗ Xe',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Nhập số cột hoặc khu vực đỗ xe trong hầm để tiện tìm lại.',
              style: GoogleFonts.plusJakartaSans(
                fontSize: 13,
                color: AppColors.textDim,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
              decoration: InputDecoration(
                hintText: 'Ví dụ: Cột K12 - Hầm B2 Vincom',
                hintStyle: GoogleFonts.plusJakartaSans(
                  fontSize: 14,
                  color: AppColors.textMuted,
                ),
                filled: true,
                fillColor: AppColors.surfaceContainer,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: AppColors.surfaceContainerHigh),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: AppColors.surfaceContainerHigh),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
                ),
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: () async {
                  final text = controller.text.trim();
                  if (text.isNotEmpty) {
                    await ParkingStorageService.instance.updateNote(
                      bikeId: ref.read(bleProvider).device?.remoteId.str,
                      note: text,
                    );
                    setState(() {
                      _parkedLocation = _parkedLocation?.copyWith(note: text);
                    });
                  }
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                child: Text(
                  'LƯU GHI CHÚ',
                  style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ble = ref.watch(bleProvider);
    final isConnected = ble.phase == BlePhase.connected;

    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          color: AppColors.textPrimary,
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          children: [
            Text(
              'TÌM XE & VỊ TRÍ ĐỖ',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
                letterSpacing: 0.5,
              ),
            ),
            Text(
              ble.bikeName ?? _parkedLocation?.bikeName ?? 'DAT BIKE QUANTUM S1',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.textDim,
              ),
            ),
          ],
        ),
        centerTitle: true,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: isConnected ? const Color(0xFFEFFDF5) : AppColors.surfaceContainer,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isConnected ? const Color(0xFFBBF7D0) : AppColors.surfaceContainerHigh,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isConnected ? AppColors.tertiary : AppColors.textMuted,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      isConnected ? 'BLE ON' : 'DÒ SÓNG',
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: isConnected ? AppColors.tertiary : AppColors.textDim,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= 720;

          if (isWide) {
            // BỐ CỤC NGANG 70% / 30% CHUẨN COCKPIT HUD
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 70% BÊN TRÁI: PRECISION RADAR GAUGE + OPTICAL BLOOM
                  Expanded(
                    flex: 7,
                    child: _buildRadarCard(ble, isConnected, isLandscape: true),
                  ),
                  const SizedBox(width: 16),

                  // 30% BÊN PHẢI: BẢN ĐỒ GPS + 3 NÚT ĐIỀU KHIỂN
                  Expanded(
                    flex: 3,
                    child: Column(
                      children: [
                        Expanded(child: _buildMiniMapCard(isLandscape: true)),
                        const SizedBox(height: 12),
                        _buildControlButtonsCard(isLandscape: true),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }

          // BỐ CỤC DỌC (PORTRAIT)
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                _buildRadarCard(ble, isConnected),
                const SizedBox(height: 16),
                _buildMiniMapCard(height: 240),
                const SizedBox(height: 16),
                _buildControlButtonsCard(),
                const SizedBox(height: 20),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Card 70% chứa Đồng hồ Precision Radar + Hiệu ứng vệt sáng xi-nhan cam đỏ
  Widget _buildRadarCard(BleState ble, bool isConnected, {bool isLandscape = false}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.surfaceContainerHigh),
        boxShadow: AppColors.cardShadow,
      ),
      child: OpticalSignalBloom(
        isLeft: _showSignalBloom,
        isRight: _showSignalBloom,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: isLandscape ? 16 : 20,
            vertical: isLandscape ? 12 : 16,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Top Bar thông tin xe & thời gian đỗ
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.tertiary,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            _parkedLocation?.bikeName ?? 'DAT BIKE QUANTUM S1',
                            style: GoogleFonts.spaceGrotesk(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.6,
                              color: AppColors.textPrimary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'PIN: ${_parkedLocation?.batteryPercent ?? ble.lastTelemetry?.percent ?? 82}% (${_parkedLocation?.voltage?.toStringAsFixed(1) ?? "72.4"}V)',
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textDim,
                    ),
                  ),
                ],
              ),
              if (!isLandscape) const SizedBox(height: 12),

              // Cụm Đồng hồ Precision Radar Gauge
              isLandscape
                  ? Expanded(
                      child: Center(
                        child: PrecisionRadarGauge(
                          distanceMeters: _estimatedDistance,
                          headingDegrees: _relativeHeading,
                          rssi: ble.rssi,
                          isBleConnected: isConnected,
                        ),
                      ),
                    )
                  : PrecisionRadarGauge(
                      distanceMeters: _estimatedDistance,
                      headingDegrees: _relativeHeading,
                      rssi: ble.rssi,
                      isBleConnected: isConnected,
                    ),
              if (!isLandscape) const SizedBox(height: 12),

              // Bottom thông tin địa chỉ & ghi chú cột đỗ
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.surfaceContainer),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.local_parking_rounded,
                      size: 16,
                      color: AppColors.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _parkedLocation?.note?.isNotEmpty == true
                            ? _parkedLocation!.note!
                            : (_parkedLocation?.address ?? 'Vincom Đồng Khởi · Hầm B2 - Cột K12'),
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    InkWell(
                      onTap: _openNoteSheet,
                      child: Text(
                        'Sửa',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Khối Bản đồ GPS dẫn đường từ xa
  Widget _buildMiniMapCard({double? height, bool isLandscape = false}) {
    final bikeLat = _parkedLocation?.latitude ?? 10.7769;
    final bikeLng = _parkedLocation?.longitude ?? 106.7009;
    final bikePoint = LatLng(bikeLat, bikeLng);
    final userPoint = _userPosition != null
        ? LatLng(_userPosition!.latitude, _userPosition!.longitude)
        : LatLng(bikeLat - 0.0004, bikeLng - 0.0004);

    return Container(
      height: height,
      padding: EdgeInsets.all(isLandscape ? 10 : 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.surfaceContainerHigh),
        boxShadow: AppColors.cardShadow,
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  'BẢN ĐỒ VỊ TRÍ ĐỖ',
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: isLandscape ? 10 : 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: AppColors.textDim,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                '${_estimatedDistance.toStringAsFixed(0)}m đi bộ',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: isLandscape ? 10 : 11,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
          SizedBox(height: isLandscape ? 6 : 10),

          // Khung bản đồ FlutterMap
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: bikePoint,
                  initialZoom: 17.5,
                  interactionOptions: const InteractionOptions(
                    flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag,
                  ),
                ),
                children: [
                  MapTileService.buildTileLayer(),
                  // Tuyến đường đi bộ nét đứt
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: [userPoint, bikePoint],
                        strokeWidth: 3.0,
                        color: AppColors.primary,
                      ),
                    ],
                  ),
                  // Marker xe và người dùng
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: bikePoint,
                        width: 32,
                        height: 32,
                        child: Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFFEA580C),
                            border: Border.all(color: Colors.white, width: 2),
                            boxShadow: const [
                              BoxShadow(color: Color(0x33EA580C), blurRadius: 6),
                            ],
                          ),
                          child: const Icon(
                            Icons.two_wheeler_rounded,
                            size: 16,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      Marker(
                        point: userPoint,
                        width: 24,
                        height: 24,
                        child: Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.primary,
                            border: Border.all(color: Colors.white, width: 2),
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
      ),
    );
  }

  /// Khối 3 nút điều khiển dạng icon trên cùng 1 hàng (Kêu Còi - Xi-nhan - Mở Khóa)
  Widget _buildControlButtonsCard({bool isLandscape = false}) {
    return Container(
      padding: EdgeInsets.all(isLandscape ? 10 : 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.surfaceContainerHigh),
        boxShadow: AppColors.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'CÔNG CỤ HỖ TRỢ TÌM XE',
            style: GoogleFonts.spaceGrotesk(
              fontSize: isLandscape ? 9.5 : 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: AppColors.textDim,
            ),
          ),
          SizedBox(height: isLandscape ? 6 : 10),
          Row(
            children: [
              // Nút 1: Kêu còi
              Expanded(
                child: _buildActionButton(
                  icon: Icons.volume_up_rounded,
                  label: 'Kêu Còi',
                  color: AppColors.primary,
                  onTap: _triggerChirp,
                  isLandscape: isLandscape,
                ),
              ),
              const SizedBox(width: 8),

              // Nút 2: Nháy xi-nhan
              Expanded(
                child: _buildActionButton(
                  icon: Icons.lightbulb_outline_rounded,
                  label: 'Xi-nhan',
                  color: const Color(0xFFEA580C),
                  onTap: _triggerSignalFlash,
                  isLandscape: isLandscape,
                ),
              ),
              const SizedBox(width: 8),

              // Nút 3: Mở khóa xe
              Expanded(
                child: _buildActionButton(
                  icon: Icons.lock_open_rounded,
                  label: 'Mở Khóa',
                  color: AppColors.primary,
                  isFilled: true,
                  onTap: _triggerUnlock,
                  isLandscape: isLandscape,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
    bool isFilled = false,
    bool isLandscape = false,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        height: isLandscape ? 48 : 58,
        decoration: BoxDecoration(
          color: isFilled ? color : AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isFilled ? color : AppColors.surfaceContainerHigh,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: isLandscape ? 18 : 20,
              color: isFilled ? Colors.white : color,
            ),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  label,
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: isLandscape ? 10 : 11,
                    fontWeight: FontWeight.w700,
                    color: isFilled ? Colors.white : AppColors.textPrimary,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
