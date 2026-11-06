import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart' hide Path;
import '../scan/scan_screen.dart';

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
  static const String _kHapticEnabledKey = 'find_bike_haptic_enabled_v1';
  bool _isHapticEnabled = true;

  SavedBike? _selectedSavedBike;
  BikeModel? _selectedModelOverride;
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
    _loadHapticSetting();
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

  Future<void> _loadHapticSetting() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool(_kHapticEnabledKey);
      if (enabled != null && mounted) {
        setState(() {
          _isHapticEnabled = enabled;
        });
        if (!_isHapticEnabled) {
          _hapticTimer?.cancel();
        }
      }
    } catch (_) {}
  }

  Future<void> _toggleHaptic() async {
    final next = !_isHapticEnabled;
    setState(() {
      _isHapticEnabled = next;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kHapticEnabledKey, next);
    } catch (_) {}

    if (next) {
      HapticFeedback.lightImpact();
      _startHapticHeartbeat();
    } else {
      _hapticTimer?.cancel();
    }

    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              next ? '📳 Đã BẬT rung phản hồi radar' : '📴 Đã TẮT rung phản hồi radar',
              style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600, fontSize: 13),
            ),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            duration: const Duration(milliseconds: 1400),
          ),
        );
    }
  }

  Future<void> _loadInitialParkingLocation() async {
    final ble = ref.read(bleProvider);
    final loc = await ParkingStorageService.instance.loadParkedLocation(
      bikeId: ble.device?.remoteId.str,
    );

    if (mounted) {
      setState(() {
        if (loc != null) {
          _parkedLocation = loc;
        } else {
          final curLat = TripGpsTracker.instance.currentPoint?.lat ?? TripGpsTracker.instance.lastPosition?.latitude;
          final curLng = TripGpsTracker.instance.currentPoint?.lng ?? TripGpsTracker.instance.lastPosition?.longitude;
          if (curLat != null && curLng != null) {
            _parkedLocation = ParkedLocation(
              latitude: curLat,
              longitude: curLng,
              timestamp: DateTime.now(),
              bikeId: ble.device?.remoteId.str ?? 'default_bike',
              bikeName: ble.bikeName ?? _getEffectiveBikeName(ble),
              batteryPercent: ble.lastTelemetry?.percent,
              voltage: ble.lastTelemetry?.voltage,
              address: null,
              note: null,
              isLocked: ble.isLocked,
            );
          } else {
            _parkedLocation = null;
          }
        }
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
    if (!_isHapticEnabled) return;

    _hapticTimer = Timer.periodic(const Duration(milliseconds: 700), (_) {
      if (!mounted || !_isHapticEnabled) return;
      final ble = ref.read(bleProvider);
      final isBleConnected = ble.phase == BlePhase.connected;
      final hasGpsLock = _userPosition != null && _parkedLocation != null;

      // Tránh rung giả: chỉ rung khi đang kết nối BLE hoặc có tọa độ GPS thực tế
      if (!isBleConnected && !hasGpsLock) return;

      if (_estimatedDistance <= 1.5) {
        HapticFeedback.heavyImpact();
      } else if (_estimatedDistance <= 6.0) {
        HapticFeedback.mediumImpact();
      } else if (_estimatedDistance <= 15.0) {
        HapticFeedback.selectionClick();
      }
    });
  }

  void _triggerChirp() {
    _bloomTimer?.cancel();
    setState(() => _showSignalBloom = true);
    ref.read(bleProvider.notifier).findBike();
    if (_isHapticEnabled) {
      HapticFeedback.lightImpact();
    }
    _bloomTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _showSignalBloom = false);
    });
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
    if (_isHapticEnabled) {
      HapticFeedback.heavyImpact();
    }
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

  String _getEffectiveBikeName(BleState ble) {
    if (_selectedSavedBike != null) {
      final modelStr = _selectedModelOverride?.displayName ?? _selectedSavedBike!.model;
      if (modelStr != null && modelStr.isNotEmpty && !_selectedSavedBike!.name.toLowerCase().contains(modelStr.toLowerCase())) {
        return '${_selectedSavedBike!.name} ($modelStr)';
      }
      return _selectedSavedBike!.name;
    }

    final activeSaved = ble.savedBikes.where((b) => ble.device != null && b.id.toLowerCase() == ble.device!.remoteId.str.toLowerCase()).firstOrNull;
    if (activeSaved != null) {
      return activeSaved.name;
    }

    if (ble.bikeName != null && ble.bikeName!.trim().isNotEmpty) {
      return ble.bikeName!;
    }

    if (_selectedModelOverride != null) {
      return _selectedModelOverride!.displayName;
    }

    if (_parkedLocation?.bikeName != null &&
        _parkedLocation!.bikeName.isNotEmpty &&
        _parkedLocation!.bikeName != 'Dat Bike Quantum S1' &&
        _parkedLocation!.bikeName != 'DAT BIKE QUANTUM S1') {
      return _parkedLocation!.bikeName;
    }

    if (ble.savedBikes.isNotEmpty) {
      return ble.savedBikes.first.name;
    }

    return 'Chưa kết nối xe — Chạm để kết nối / chọn dòng xe';
  }

  bool _isNoBike(BleState ble) {
    return ble.device == null &&
        ble.bikeName == null &&
        ble.savedBikes.isEmpty &&
        _selectedSavedBike == null &&
        _selectedModelOverride == null &&
        (_parkedLocation?.bikeName == null ||
            _parkedLocation!.bikeName == 'Dat Bike Quantum S1' ||
            _parkedLocation!.bikeName == 'DAT BIKE QUANTUM S1');
  }

  String _getBatteryDisplay(BleState ble) {
    final percent = _parkedLocation?.batteryPercent ?? ble.lastTelemetry?.percent;
    final voltage = _parkedLocation?.voltage ?? ble.lastTelemetry?.voltage;
    if (percent != null) {
      final voltStr = voltage != null ? ' (${voltage.toStringAsFixed(1)}V)' : '';
      return 'PIN: $percent%$voltStr';
    }
    return 'PIN: --%';
  }

  Widget _buildNoBikeBanner(BuildContext context, BleState ble) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7ED),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFED7AA)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFFFEDD5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.two_wheeler_rounded,
              color: Color(0xFFEA580C),
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Chưa kết nối với xe nào',
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFF9A3412),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Kết nối Bluetooth hoặc chọn dòng xe để tìm vị trí đỗ chính xác.',
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 11,
                    color: const Color(0xFFC2410C),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              TextButton(
                style: TextButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ScanScreen()),
                  );
                },
                child: Text(
                  'Kết nối ngay',
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              InkWell(
                onTap: () => _openBikeSelectionBottomSheet(context, ble),
                child: Text(
                  'Chọn dòng xe',
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primary,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _openBikeSelectionBottomSheet(BuildContext context, BleState ble) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (bottomSheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final savedBikes = ble.savedBikes;
            return Container(
              height: MediaQuery.of(context).size.height * 0.75,
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: Column(
                children: [
                  Container(
                    margin: const EdgeInsets.only(top: 12, bottom: 8),
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                    child: Row(
                      children: [
                        const Icon(Icons.two_wheeler_rounded, color: AppColors.primary),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'CHỌN XE & DÒNG XE TÌM KIẾM',
                            style: GoogleFonts.spaceGrotesk(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded, size: 20),
                          onPressed: () => Navigator.pop(bottomSheetContext),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                      children: [
                        if (savedBikes.isNotEmpty) ...[
                          Text(
                            'XE ĐÃ LƯU (${savedBikes.length})',
                            style: GoogleFonts.spaceGrotesk(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textDim,
                              letterSpacing: 1.0,
                            ),
                          ),
                          const SizedBox(height: 10),
                          ...savedBikes.map((bike) {
                            final isCurrent = _selectedSavedBike?.id == bike.id ||
                                (_selectedSavedBike == null && ble.device?.remoteId.str == bike.id);
                            return Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              decoration: BoxDecoration(
                                color: isCurrent ? const Color(0xFFEFFDF5) : AppColors.surfaceContainer,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: isCurrent ? AppColors.tertiary : AppColors.surfaceContainerHigh,
                                  width: isCurrent ? 1.5 : 1.0,
                                ),
                              ),
                              child: ListTile(
                                leading: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: isCurrent ? AppColors.tertiary : Colors.white,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    Icons.electric_moped_rounded,
                                    size: 20,
                                    color: isCurrent ? Colors.white : AppColors.primary,
                                  ),
                                ),
                                title: Text(
                                  bike.name,
                                  style: GoogleFonts.spaceGrotesk(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                                subtitle: Text(
                                  'Model: ${bike.model ?? "Chưa rõ"} · ID: ${bike.id.length > 8 ? bike.id.substring(0, 8) : bike.id}...',
                                  style: GoogleFonts.spaceGrotesk(
                                    fontSize: 11,
                                    color: AppColors.textDim,
                                  ),
                                ),
                                trailing: isCurrent
                                    ? const Icon(Icons.check_circle_rounded, color: AppColors.tertiary)
                                    : const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: AppColors.textMuted),
                                onTap: () async {
                                  setState(() {
                                    _selectedSavedBike = bike;
                                    _selectedModelOverride = null;
                                  });
                                  Navigator.pop(bottomSheetContext);
                                  await ref.read(bleProvider.notifier).switchBike(bike);
                                  final loc = await ParkingStorageService.instance.loadParkedLocation(bikeId: bike.id);
                                  if (mounted) {
                                    setState(() {
                                      _parkedLocation = loc;
                                    });
                                    _updateCalculatedMetrics();
                                  }
                                },
                              ),
                            );
                          }),
                          const SizedBox(height: 16),
                        ],
                        Text(
                          'CHỌN DÒNG XE DAT BIKE',
                          style: GoogleFonts.spaceGrotesk(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textDim,
                            letterSpacing: 1.0,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Chọn loại xe của bạn nếu chưa kết nối Bluetooth',
                          style: GoogleFonts.spaceGrotesk(
                            fontSize: 11,
                            color: AppColors.textMuted,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: BikeModel.values.map((model) {
                            final isModelSelected = _selectedModelOverride == model ||
                                (_selectedModelOverride == null && ble.bikeModel == model && _selectedSavedBike == null);
                            return ChoiceChip(
                              label: Text(model.displayName),
                              labelStyle: GoogleFonts.spaceGrotesk(
                                fontSize: 12,
                                fontWeight: isModelSelected ? FontWeight.w700 : FontWeight.w500,
                                color: isModelSelected ? Colors.white : AppColors.textPrimary,
                              ),
                              selected: isModelSelected,
                              selectedColor: AppColors.primary,
                              backgroundColor: AppColors.surfaceContainer,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20),
                                side: BorderSide(
                                  color: isModelSelected ? AppColors.primary : AppColors.surfaceContainerHigh,
                                ),
                              ),
                              onSelected: (selected) {
                                if (selected) {
                                  setState(() {
                                    _selectedModelOverride = model;
                                    _selectedSavedBike = null;
                                  });
                                  Navigator.pop(bottomSheetContext);
                                }
                              },
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: 24),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          onPressed: () {
                            Navigator.pop(bottomSheetContext);
                            Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => const ScanScreen()),
                            );
                          },
                          icon: const Icon(Icons.bluetooth_searching_rounded),
                          label: Text(
                            'Quét & Kết Nối Xe Mới',
                            style: GoogleFonts.spaceGrotesk(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                      ],
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
        title: InkWell(
          onTap: () => _openBikeSelectionBottomSheet(context, ble),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
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
                      const SizedBox(width: 4),
                      const Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 18,
                        color: AppColors.primary,
                      ),
                    ],
                  ),
                ),
                Text(
                  _getEffectiveBikeName(ble),
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: _isNoBike(ble) ? const Color(0xFFEA580C) : AppColors.textDim,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: _isHapticEnabled ? 'Tắt rung radar' : 'Bật rung radar',
            icon: Icon(
              _isHapticEnabled ? Icons.vibration_rounded : Icons.mobile_off_rounded,
              size: 20,
              color: _isHapticEnabled ? AppColors.primary : AppColors.textDim,
            ),
            onPressed: _toggleHaptic,
          ),
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
                if (_isNoBike(ble)) _buildNoBikeBanner(context, ble),
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
                    child: InkWell(
                      onTap: () => _openBikeSelectionBottomSheet(context, ble),
                      borderRadius: BorderRadius.circular(8),
                      child: Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isConnected
                                  ? AppColors.tertiary
                                  : (_isNoBike(ble) ? const Color(0xFFEA580C) : AppColors.primary),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              _getEffectiveBikeName(ble),
                              style: GoogleFonts.spaceGrotesk(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.6,
                                color: _isNoBike(ble) ? const Color(0xFFEA580C) : AppColors.textPrimary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 4),
                          const Icon(
                            Icons.swap_horiz_rounded,
                            size: 14,
                            color: AppColors.primary,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _getBatteryDisplay(ble),
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textDim,
                    ),
                  ),
                  const SizedBox(width: 8),
                  _buildHapticToggleChip(),
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
                            : (_parkedLocation?.address?.isNotEmpty == true
                                ? _parkedLocation!.address!
                                : 'Chưa có thông tin điểm đỗ xe'),
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: (_parkedLocation?.note?.isNotEmpty == true || _parkedLocation?.address?.isNotEmpty == true)
                              ? AppColors.textPrimary
                              : AppColors.textDim,
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
                _parkedLocation != null
                    ? '${_estimatedDistance.toStringAsFixed(0)}m đi bộ'
                    : 'Chưa lưu điểm đỗ',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: isLandscape ? 10 : 11,
                  fontWeight: FontWeight.w700,
                  color: _parkedLocation != null ? AppColors.primary : AppColors.textDim,
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

  /// Khối 2 nút điều khiển dạng icon trên cùng 1 hàng (Kêu Còi (Tìm Xe) - Mở Khóa Xe) cân đối 50% - 50%
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
              // Nút 1: Kêu còi (Tìm Xe) - 50% width, màu cam nổi bật
              Expanded(
                child: _buildActionButton(
                  icon: Icons.volume_up_rounded,
                  label: 'Kêu Còi (Tìm Xe)',
                  color: const Color(0xFFEA580C),
                  isFilled: true,
                  onTap: _triggerChirp,
                  isLandscape: isLandscape,
                ),
              ),
              const SizedBox(width: 10),

              // Nút 2: Mở khóa xe - 50% width, primary
              Expanded(
                child: _buildActionButton(
                  icon: Icons.lock_open_rounded,
                  label: 'Mở Khóa Xe',
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

  Widget _buildHapticToggleChip() {
    return InkWell(
      onTap: _toggleHaptic,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: _isHapticEnabled
              ? AppColors.primary.withValues(alpha: 0.12)
              : AppColors.surfaceContainerHigh.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _isHapticEnabled
                ? AppColors.primary.withValues(alpha: 0.3)
                : AppColors.surfaceContainerHigh,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _isHapticEnabled ? Icons.vibration_rounded : Icons.mobile_off_rounded,
              size: 13,
              color: _isHapticEnabled ? AppColors.primary : AppColors.textDim,
            ),
            const SizedBox(width: 4),
            Text(
              _isHapticEnabled ? 'RUNG: BẬT' : 'RUNG: TẮT',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
                color: _isHapticEnabled ? AppColors.primary : AppColors.textDim,
              ),
            ),
          ],
        ),
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
