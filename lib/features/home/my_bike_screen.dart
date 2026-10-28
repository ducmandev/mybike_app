// Screen 1: Home / Remote Control — Chuyên biệt hóa cho Xe Máy Điện Dat Bike
// Thiết kế tham chiếu Geely EV nhưng tinh chỉnh 100% chuẩn tính năng xe máy điện:
// - Header tên xe (Dat Bike Quantum S1 ⇄) + badge Bluetooth Connected.
// - Cụm thông số: Quãng đường xe máy điện (270 km) font rộng.
// - 2 thanh progress nhỏ:
//     + Dung lượng Pin: 68% (185 km - xanh lá)
//     + Quãng đường khả dụng tối đa: 270 km (xanh dương)
// - Giữa màn hình: Ảnh xe máy điện Dat Bike Quantum (bike_hero.jpg).
// - Card 4 nút điều khiển nhanh xe máy điện:
//     1. Khóa cổ & Chống trộm (Lock)
//     2. Bật / Tắt nguồn xe (Power - Keyless)
//     3. Tìm xe trong bãi (Find Bike - Còi & Đèn)
//     4. Mở khóa điện cốp xe 41L (Trunk Release)
// - Card Parked Bike: Địa chỉ bãi đỗ thực tế + 2 nút tròn Đèn/Còi + Mini map định vị xe máy.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/ble/ble_controller.dart';
import '../../core/services/trip_gps_tracker.dart';
import '../scan/scan_screen.dart';
import '../settings/vehicle_settings_screen.dart';
import '../../ui/geely_icons.dart';
import 'trip_route_screen.dart';

class MyBikeScreen extends ConsumerStatefulWidget {
  const MyBikeScreen({super.key});

  @override
  ConsumerState<MyBikeScreen> createState() => _MyBikeScreenState();
}

class _MyBikeScreenState extends ConsumerState<MyBikeScreen> {
  late final AppLifecycleListener _lifecycleListener;

  // Quản lý lifecycle app

  @override
  void initState() {
    super.initState();
    _lifecycleListener = AppLifecycleListener(
      onResume: _onAppResume,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _checkAndRestore();
    });
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    super.dispose();
  }

  void _onAppResume() {
    _checkAndRestore();
  }

  Future<void> _checkAndRestore() async {
    final ble = ref.read(bleProvider);
    if (ble.phase == BlePhase.connected ||
        ble.phase == BlePhase.connecting ||
        ble.phase == BlePhase.reconnecting ||
        ble.phase == BlePhase.disconnected) {
      return;
    }
    final last = await ref.read(bleProvider.notifier).lastBikeId();
    if (last != null && mounted) {
      await ref.read(bleProvider.notifier).tryRestoreLastBike();
    }
  }

  Future<void> _handleConnectTap() async {
    final ble = ref.read(bleProvider);
    final notifier = ref.read(bleProvider.notifier);

    if (ble.phase == BlePhase.connecting || ble.phase == BlePhase.reconnecting) {
      _heroSnack('Đang trong quá trình kết nối với xe, vui lòng đợi giây lát...');
      return;
    }

    final lastId = await notifier.lastBikeId();
    final lastName = await notifier.lastBikeName();

    if (lastId != null && lastId.isNotEmpty) {
      _heroSnack('Đang tìm và kết nối lại với ${lastName ?? "xe"}...', duration: const Duration(seconds: 3));
      final ok = await notifier.tryRestoreLastBike();
      if (!ok && mounted) {
        _heroSnack('Không tìm thấy xe ở gần. Đang mở quét tìm xe...');
        await Future.delayed(const Duration(milliseconds: 600));
        if (mounted) {
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ScanScreen()));
        }
      }
    } else {
      if (mounted) {
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ScanScreen()));
      }
    }
  }

  void _heroSnack(String msg, {String? actionLabel, VoidCallback? onAction, Duration? duration}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg, style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w500)),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: duration ?? const Duration(milliseconds: 1800),
        action: actionLabel != null && onAction != null
            ? SnackBarAction(
                label: actionLabel,
                textColor: const Color(0xFFF59E0B),
                onPressed: onAction,
              )
            : null,
      ));
  }

  Future<void> _quickLockToggle() async {
    final ble = ref.read(bleProvider);
    final notifier = ref.read(bleProvider.notifier);
    if (ble.isLocked) {
      final msg = await notifier.unlockBike();
      _heroSnack(msg);
      return;
    }

    final spd = ble.lastTelemetry?.speed ?? 0.0;
    if (spd > 0.5) {
      _heroSnack('⚠️ Cảnh báo an toàn: Xe đang di chuyển (${spd.toStringAsFixed(0)} km/h), không thể khóa!');
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Khóa Cổ & Chống Trộm',
          style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700, color: const Color(0xFF0F172A)),
        ),
        content: Text(
          'Hệ thống sẽ khóa chốt cổ điện tử và kích hoạt cảm biến cảnh báo chống dắt xe.',
          style: GoogleFonts.plusJakartaSans(fontSize: 14, color: const Color(0xFF475569)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('HỦY', style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600, color: const Color(0xFF64748B))),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFEF4444),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('KHÓA NGAY', style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    _heroSnack(await notifier.lockBike());
  }

  Future<void> _quickPowerToggle() async {
    final ble = ref.read(bleProvider);
    final notifier = ref.read(bleProvider.notifier);
    final on = ble.lastTelemetry?.isBikeOn == true;
    final spd = ble.lastTelemetry?.speed ?? 0.0;

    if (on && spd > 0.5) {
      _heroSnack('⚠️ Cảnh báo an toàn: Không thể tắt xe khi đang chạy (${spd.toStringAsFixed(1)} km/h)!');
      return;
    }

    try {
      if (on) {
        await notifier.turnOffBike();
        _heroSnack('Đã gửi lệnh TẮT nguồn xe máy điện');
      } else {
        await notifier.turnOnBike();
        _heroSnack('Đã gửi lệnh BẬT nguồn xe máy điện (Ready to drive)');
      }
    } catch (e) {
      _heroSnack('$e');
    }
  }

  Future<void> _quickFindBike() async {
    final ble = ref.read(bleProvider);
    final notifier = ref.read(bleProvider.notifier);
    if (ble.isFindingBike) {
      final msg = await notifier.stopFindBike();
      if (mounted) _heroSnack(msg);
    } else {
      final msg = await notifier.findBike();
      if (mounted) {
        if (ref.read(bleProvider).isFindingBike) {
          _heroSnack(
            'Đang phát còi tìm xe trong bãi…',
            actionLabel: 'TẮT CÒI',
            duration: const Duration(seconds: 8),
            onAction: () async {
              final stopMsg = await ref.read(bleProvider.notifier).stopFindBike();
              if (mounted) _heroSnack(stopMsg);
            },
          );
        } else {
          _heroSnack(msg);
        }
      }
    }
  }

  Future<void> _quickSyncTime() async {
    final msg = await ref.read(bleProvider.notifier).syncTimeWithBike();
    if (mounted) _heroSnack(msg);
  }

  void _openRemoteControlsSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Consumer(
        builder: (context, sheetRef, _) => StatefulBuilder(
          builder: (context, setSheetState) {
            final ble = sheetRef.watch(bleProvider);

          return Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            ),
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Thanh kéo định vị (Drag Handle)
                  Center(
                    child: Container(
                      width: 38,
                      height: 4,
                      decoration: BoxDecoration(
                        color: const Color(0xFFCBD5E1),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Tiêu đề & Icon thanh mảnh
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: const Color(0xFFEFF6FF),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFFBFDBFE)),
                        ),
                        child: const Icon(Icons.tune_rounded, color: Color(0xFF2563EB), size: 20),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Điều khiển xe',
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                                color: const Color(0xFF0F172A),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Cài đặt an toàn & tiện ích nhanh',
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 12,
                                color: const Color(0xFF64748B),
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded, size: 20, color: Color(0xFF94A3B8)),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),

                  // ══════════════════════════════════════════════════════════
                  // 1. AN TOÀN & KHÓA XE
                  // ══════════════════════════════════════════════════════════
                  Text(
                    'AN TOÀN & KHÓA XE',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFF94A3B8),
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: const Color(0xFFF1F5F9)),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x040F172A),
                          blurRadius: 10,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        _sheetToggleRow(
                          icon: Icons.lock_clock_rounded,
                          iconColor: const Color(0xFF2563EB),
                          iconBg: const Color(0xFFEFF6FF),
                          title: 'Tự khóa khi rời xe',
                          subtitle: 'Khóa an toàn khi ra khỏi vùng Bluetooth',
                          value: ble.autoLockWalkAway,
                          onChanged: (v) {
                            ref.read(bleProvider.notifier).setAutoLockWalkAway(v);
                            setSheetState(() {});
                            _heroSnack(v ? 'Đã bật tự khóa khi rời xe' : 'Đã tắt tự khóa');
                          },
                        ),
                        if (ble.autoLockWalkAway) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      'Mức sóng tự khóa khi rời xa:',
                                      style: GoogleFonts.plusJakartaSans(
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w600,
                                        color: const Color(0xFF64748B),
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFEFF6FF),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        '${(ble.autoLockRssiThreshold ?? [-75.0, -83.0, -90.0][ble.autoLockDistance.clamp(0, 2)]).round()} dBm · ~${_lockDistLabel(ble.autoLockRssiThreshold ?? [-75.0, -83.0, -90.0][ble.autoLockDistance.clamp(0, 2)])}',
                                        style: GoogleFonts.plusJakartaSans(
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w700,
                                          color: const Color(0xFF2563EB),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    _sheetSegmentPill(
                                      label: 'Gần',
                                      sub: '~3m (-75dBm)',
                                      selected: (ble.autoLockRssiThreshold ?? -83.0) >= -78.0,
                                      onTap: () {
                                        ref.read(bleProvider.notifier).setAutoLockRssiThreshold(-75.0);
                                        setSheetState(() {});
                                        _heroSnack('Ngưỡng khóa: Gần (~3m · -75 dBm)');
                                      },
                                    ),
                                    const SizedBox(width: 8),
                                    _sheetSegmentPill(
                                      label: 'Vừa',
                                      sub: '~5m (-83dBm)',
                                      selected: (ble.autoLockRssiThreshold ?? -83.0) < -78.0 &&
                                          (ble.autoLockRssiThreshold ?? -83.0) > -88.0,
                                      onTap: () {
                                        ref.read(bleProvider.notifier).setAutoLockRssiThreshold(-83.0);
                                        setSheetState(() {});
                                        _heroSnack('Ngưỡng khóa: Vừa (~5m · -83 dBm)');
                                      },
                                    ),
                                    const SizedBox(width: 8),
                                    _sheetSegmentPill(
                                      label: 'Xa',
                                      sub: '~8m (-90dBm)',
                                      selected: (ble.autoLockRssiThreshold ?? -83.0) <= -88.0,
                                      onTap: () {
                                        ref.read(bleProvider.notifier).setAutoLockRssiThreshold(-90.0);
                                        setSheetState(() {});
                                        _heroSnack('Ngưỡng khóa: Xa (~8m · -90 dBm)');
                                      },
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                // Slider tùy chỉnh dải sóng khi rời xa
                                SliderTheme(
                                  data: SliderTheme.of(context).copyWith(
                                    trackHeight: 4,
                                    activeTrackColor: const Color(0xFF2563EB),
                                    inactiveTrackColor: const Color(0xFFE2E8F0),
                                    thumbColor: const Color(0xFF2563EB),
                                    overlayColor: const Color(0xFF2563EB).withValues(alpha: 0.15),
                                  ),
                                  child: Slider(
                                    value: (ble.autoLockRssiThreshold ?? -83.0).clamp(-95.0, -68.0),
                                    min: -95.0,
                                    max: -68.0,
                                    divisions: 27,
                                    onChanged: (val) {
                                      ref.read(bleProvider.notifier).setAutoLockRssiThreshold(val);
                                      setSheetState(() {});
                                    },
                                  ),
                                ),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      '-95 dBm (Xa ~10m)',
                                      style: GoogleFonts.plusJakartaSans(fontSize: 10, color: const Color(0xFF94A3B8)),
                                    ),
                                    Text(
                                      '-68 dBm (Gần ~2m)',
                                      style: GoogleFonts.plusJakartaSans(fontSize: 10, color: const Color(0xFF94A3B8)),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                        const Divider(color: Color(0xFFF8FAFC), height: 1, thickness: 1, indent: 56, endIndent: 16),
                        _sheetToggleRow(
                          icon: Icons.key_rounded,
                          iconColor: const Color(0xFF10B981),
                          iconBg: const Color(0xFFF0FDF4),
                          title: 'Mở khóa & Bật xe khi lại gần',
                          subtitle: 'Tự động mở khóa bánh và bật sáng taplo khi đến gần xe',
                          value: ble.walkUpUnlock,
                          onChanged: (v) {
                            ref.read(bleProvider.notifier).setWalkUpUnlock(v);
                            setSheetState(() {});
                            _heroSnack(v ? 'Đã bật mở khóa & bật sáng taplo khi lại gần' : 'Đã tắt tự mở xe');
                          },
                        ),
                        if (ble.walkUpUnlock) ...[
                          // Tính năng phụ: BẬT XE SẴN KHI Ở RẤT GẦN
                          Container(
                            margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            decoration: BoxDecoration(
                              color: ble.walkUpAutoPowerOn
                                  ? const Color(0xFFFFFBEB)
                                  : const Color(0xFFF8FAFC),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: ble.walkUpAutoPowerOn
                                    ? const Color(0xFFFDE68A)
                                    : const Color(0xFFE2E8F0),
                              ),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 32,
                                  height: 32,
                                  decoration: BoxDecoration(
                                    color: ble.walkUpAutoPowerOn ? const Color(0xFFF59E0B) : const Color(0xFFCBD5E1),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(Icons.bolt_rounded, color: Colors.white, size: 18),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Text(
                                            'Bật xe sẵn khi ở rất gần',
                                            style: GoogleFonts.plusJakartaSans(
                                              fontSize: 12.5,
                                              fontWeight: FontWeight.w700,
                                              color: const Color(0xFF0F172A),
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFFFEF3C7),
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              'TIỆN ÍCH',
                                              style: GoogleFonts.plusJakartaSans(
                                                fontSize: 8.5,
                                                fontWeight: FontWeight.w800,
                                                color: const Color(0xFFB45309),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        'Tự mở khóa & bật nguồn xe sẵn sàng ngay khi tới cạnh xe',
                                        style: GoogleFonts.plusJakartaSans(
                                          fontSize: 11,
                                          color: const Color(0xFF64748B),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Switch.adaptive(
                                  value: ble.walkUpAutoPowerOn,
                                  activeTrackColor: const Color(0xFFF59E0B),
                                  onChanged: (v) {
                                    ref.read(bleProvider.notifier).setWalkUpAutoPowerOn(v);
                                    setSheetState(() {});
                                    _heroSnack(v ? 'Đã bật tự khởi động xe sẵn khi lại gần' : 'Đã tắt tự bật xe');
                                  },
                                ),
                              ],
                            ),
                          ),

                          // Tùy chỉnh mức sóng khi đến gần
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      'Mức sóng kích hoạt khi đến gần:',
                                      style: GoogleFonts.plusJakartaSans(
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w600,
                                        color: const Color(0xFF64748B),
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFF0FDF4),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        '${(ble.walkUpRssiThreshold ?? -55.0).round()} dBm · ~${_nearDistLabel(ble.walkUpRssiThreshold ?? -55.0)}',
                                        style: GoogleFonts.plusJakartaSans(
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w700,
                                          color: const Color(0xFF10B981),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    _sheetSegmentPill(
                                      label: 'Cực gần',
                                      sub: '~0.8m (-50dBm)',
                                      selected: (ble.walkUpRssiThreshold ?? -55.0) >= -52.0,
                                      onTap: () {
                                        ref.read(bleProvider.notifier).setWalkUpRssiThreshold(-50.0);
                                        setSheetState(() {});
                                        _heroSnack('Ngưỡng đến gần: Cực gần (~0.8m · -50 dBm)');
                                      },
                                    ),
                                    const SizedBox(width: 8),
                                    _sheetSegmentPill(
                                      label: 'Rất gần',
                                      sub: '~1.5m (-55dBm)',
                                      selected: (ble.walkUpRssiThreshold ?? -55.0) < -52.0 &&
                                          (ble.walkUpRssiThreshold ?? -55.0) > -58.0,
                                      onTap: () {
                                        ref.read(bleProvider.notifier).setWalkUpRssiThreshold(-55.0);
                                        setSheetState(() {});
                                        _heroSnack('Ngưỡng đến gần: Rất gần (~1.5m · -55 dBm)');
                                      },
                                    ),
                                    const SizedBox(width: 8),
                                    _sheetSegmentPill(
                                      label: 'Vừa',
                                      sub: '~2.5m (-62dBm)',
                                      selected: (ble.walkUpRssiThreshold ?? -55.0) <= -58.0,
                                      onTap: () {
                                        ref.read(bleProvider.notifier).setWalkUpRssiThreshold(-62.0);
                                        setSheetState(() {});
                                        _heroSnack('Ngưỡng đến gần: Vừa (~2.5m · -62 dBm)');
                                      },
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                // Slider tùy chỉnh mức sóng khi lại gần
                                SliderTheme(
                                  data: SliderTheme.of(context).copyWith(
                                    trackHeight: 4,
                                    activeTrackColor: const Color(0xFF10B981),
                                    inactiveTrackColor: const Color(0xFFE2E8F0),
                                    thumbColor: const Color(0xFF10B981),
                                    overlayColor: const Color(0xFF10B981).withValues(alpha: 0.15),
                                  ),
                                  child: Slider(
                                    value: (ble.walkUpRssiThreshold ?? -55.0).clamp(-70.0, -45.0),
                                    min: -70.0,
                                    max: -45.0,
                                    divisions: 25,
                                    onChanged: (val) {
                                      ref.read(bleProvider.notifier).setWalkUpRssiThreshold(val);
                                      setSheetState(() {});
                                    },
                                  ),
                                ),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      '-70 dBm (Xa hơn ~3m)',
                                      style: GoogleFonts.plusJakartaSans(fontSize: 10, color: const Color(0xFF94A3B8)),
                                    ),
                                    Text(
                                      '-45 dBm (Sát xe ~0.5m)',
                                      style: GoogleFonts.plusJakartaSans(fontSize: 10, color: const Color(0xFF94A3B8)),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                        const Divider(color: Color(0xFFF8FAFC), height: 1, thickness: 1, indent: 56, endIndent: 16),
                        _sheetToggleRow(
                          icon: Icons.security_rounded,
                          iconColor: const Color(0xFFEF4444),
                          iconBg: const Color(0xFFFEF2F2),
                          title: 'Chống trộm từ xa',
                          subtitle: 'Khóa cứng nếu cách xa hơn 5m',
                          value: ble.antiTheft5m,
                          onChanged: (v) {
                            ref.read(bleProvider.notifier).setAntiTheft5m(v);
                            setSheetState(() {});
                            _heroSnack(v ? 'Đã kích hoạt chống trộm 5m' : 'Đã tắt chống trộm 5m');
                          },
                        ),
                        const Divider(color: Color(0xFFF8FAFC), height: 1, thickness: 1, indent: 56, endIndent: 16),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          child: Row(
                            children: [
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: ble.isFindingBike ? const Color(0xFFFEF2F2) : const Color(0xFFEFF6FF),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(
                                  ble.isFindingBike ? Icons.volume_off_rounded : Icons.campaign_rounded,
                                  color: ble.isFindingBike ? const Color(0xFFEF4444) : const Color(0xFF2563EB),
                                  size: 18,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Còi tìm xe',
                                      style: GoogleFonts.plusJakartaSans(
                                        fontSize: 13.5,
                                        fontWeight: FontWeight.w600,
                                        color: const Color(0xFF0F172A),
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      ble.isFindingBike ? 'Đang hú còi định vị…' : 'Phát còi tìm xe trong bãi đỗ',
                                      style: GoogleFonts.plusJakartaSans(
                                        fontSize: 11.5,
                                        color: ble.isFindingBike ? const Color(0xFFEF4444) : const Color(0xFF64748B),
                                        fontWeight: ble.isFindingBike ? FontWeight.w600 : FontWeight.w400,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              OutlinedButton(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: ble.isFindingBike ? const Color(0xFFEF4444) : const Color(0xFF2563EB),
                                  side: BorderSide(
                                    color: ble.isFindingBike ? const Color(0xFFEF4444) : const Color(0xFFBFDBFE),
                                  ),
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                  minimumSize: Size.zero,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                                onPressed: () async {
                                  await _quickFindBike();
                                  setSheetState(() {});
                                },
                                child: Text(
                                  ble.isFindingBike ? 'TẮT CÒI' : 'TÌM XE',
                                  style: GoogleFonts.plusJakartaSans(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // ══════════════════════════════════════════════════════════
                  // 2. VẬN HÀNH & TỐC ĐỘ
                  // ══════════════════════════════════════════════════════════
                  Text(
                    'VẬN HÀNH & TỐC ĐỘ',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFF94A3B8),
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: const Color(0xFFF1F5F9)),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x040F172A),
                          blurRadius: 10,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Giới hạn tốc độ ECE 60
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Giới hạn tốc độ 60 km/h',
                                    style: GoogleFonts.plusJakartaSans(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w600,
                                      color: const Color(0xFF0F172A),
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'An toàn & tiết kiệm thêm 15% pin',
                                    style: GoogleFonts.plusJakartaSans(fontSize: 11.5, color: const Color(0xFF64748B)),
                                  ),
                                ],
                              ),
                            ),
                            Switch.adaptive(
                              value: ble.speedLimitMode == 1,
                              activeTrackColor: const Color(0xFF2563EB),
                              onChanged: (v) async {
                                final res = await ref.read(bleProvider.notifier).setSafeSpeedLimit60(v);
                                _heroSnack(res);
                                setSheetState(() {});
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        const Divider(color: Color(0xFFF8FAFC), height: 1, thickness: 1),
                        const SizedBox(height: 10),

                        // Chế độ Grab
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Chế độ Grab (Ga êm)',
                                    style: GoogleFonts.plusJakartaSans(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w600,
                                      color: const Color(0xFF0F172A),
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Ga mượt mà, không giật khi chở tải',
                                    style: GoogleFonts.plusJakartaSans(fontSize: 11.5, color: const Color(0xFF64748B)),
                                  ),
                                ],
                              ),
                            ),
                            Switch.adaptive(
                              value: ble.grabMode == 1,
                              activeTrackColor: const Color(0xFF10B981),
                              onChanged: (v) async {
                                ref.read(bleProvider.notifier).setGrabMode(v ? 1 : 0);
                                final res = await ref.read(bleProvider.notifier).setFwGrabMode(v);
                                _heroSnack(res);
                                setSheetState(() {});
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Nút mở Settings toàn diện
                  InkWell(
                    onTap: () {
                      Navigator.pop(ctx);
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const VehicleSettingsScreen()),
                      );
                    },
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      height: 48,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.settings_outlined, size: 18, color: Color(0xFF2563EB)),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              'TẤT CẢ CÀI ĐẶT XE',
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.5,
                                color: const Color(0xFF2563EB),
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Icon(Icons.arrow_forward_rounded, size: 15, color: Color(0xFF2563EB)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ),
  );
}

  Widget _sheetToggleRow({
    required IconData icon,
    required Color iconColor,
    required Color iconBg,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: iconColor, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF0F172A),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 11.5,
                    color: const Color(0xFF64748B),
                  ),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: value,
            activeTrackColor: const Color(0xFF2563EB),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _sheetSegmentPill({
    required String label,
    required String sub,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFEFF6FF) : const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? const Color(0xFF2563EB) : const Color(0xFFE2E8F0),
              width: selected ? 1.5 : 1.0,
            ),
          ),
          child: Column(
            children: [
              Text(
                label,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  color: selected ? const Color(0xFF2563EB) : const Color(0xFF0F172A),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                sub,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w500,
                  color: selected ? const Color(0xFF2563EB) : const Color(0xFF94A3B8),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _lockDistLabel(double rssi) {
    if (rssi >= -76.0) return '3m';
    if (rssi >= -84.0) return '5m';
    if (rssi >= -90.0) return '8m';
    return '10m';
  }

  String _nearDistLabel(double rssi) {
    if (rssi >= -48.0) return '0.5m';
    if (rssi >= -52.0) return '0.8m';
    if (rssi >= -58.0) return '1.5m';
    if (rssi >= -65.0) return '2.5m';
    return '3.5m';
  }

  void _openBikeSwitcherSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Consumer(
        builder: (context, sheetRef, _) {
          final ble = sheetRef.watch(bleProvider);
          final serial = (ble.frameSerial != null && ble.frameSerial!.trim().isNotEmpty)
              ? ble.frameSerial!.trim()
              : (ble.lastTelemetry != null && ble.lastTelemetry!.frame.trim().isNotEmpty
                  ? ble.lastTelemetry!.frame.trim()
                  : 'Chưa rõ số khung');
          final connected = ble.phase == BlePhase.connected;
          final percent = ble.lastTelemetry?.percent;
          final kmLeft = (ble.lastTelemetry != null && ble.lastTelemetry!.kmLeft > 0)
              ? ble.lastTelemetry!.kmLeft.round()
              : null;
          final hasBike = ble.bikeName != null || ble.device != null;
          final infoStr = (connected && percent != null)
              ? '$serial · $percent% Pin${kmLeft != null ? " ($kmLeft km)" : ""}'
              : (connected ? '$serial · Đã kết nối' : '$serial · Ngoại tuyến');

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xFFCBD5E1),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Xe Của Bạn',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFF0F172A),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Chuyển đổi xe đang điều khiển hoặc thêm xe mới',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 12,
                            color: const Color(0xFF64748B),
                          ),
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, color: Color(0xFF64748B)),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                if (hasBike)
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEFF6FF),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFBFDBFE), width: 1.5),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: const [
                              BoxShadow(color: Color(0x100F172A), blurRadius: 6, offset: Offset(0, 2)),
                            ],
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Image.asset(
                            'assets/images/bike_logo_3d.png',
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const Icon(Icons.two_wheeler_rounded, color: Color(0xFF2563EB), size: 24),
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
                                    ble.bikeName ?? 'Xe Dat Bike',
                                    style: GoogleFonts.plusJakartaSans(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                      color: const Color(0xFF0F172A),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF2563EB),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      'ĐANG CHỌN',
                                      style: GoogleFonts.plusJakartaSans(fontSize: 9, fontWeight: FontWeight.w700, color: Colors.white),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                infoStr,
                                style: GoogleFonts.plusJakartaSans(fontSize: 11.5, color: const Color(0xFF475569)),
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.check_circle_rounded, color: Color(0xFF2563EB), size: 22),
                      ],
                    ),
                  )
                else
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Column(
                      children: [
                        const Icon(Icons.two_wheeler_outlined, size: 40, color: Color(0xFF94A3B8)),
                        const SizedBox(height: 10),
                        Text(
                          'Chưa có xe nào được liên kết',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFF0F172A),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Bấm "TÌM & GHÉP ĐÔI XE" bên dưới để quét kết nối xe Dat Bike của bạn',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 12,
                            color: const Color(0xFF64748B),
                          ),
                        ),
                      ],
                    ),
                  ),

                const SizedBox(height: 20),

                // Nút Tìm & Ghép Đôi Xe BLE (Thanh mảnh & tinh tế)
                InkWell(
                  onTap: () {
                    Navigator.pop(ctx);
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const ScanScreen()),
                    );
                  },
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    height: 48,
                    decoration: BoxDecoration(
                      color: const Color(0xFFEFF6FF),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFBFDBFE), width: 1.2),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.bluetooth_searching_rounded, size: 18, color: Color(0xFF2563EB)),
                        const SizedBox(width: 8),
                        Text(
                          'TÌM & GHÉP ĐÔI XE (BLUETOOTH BLE)',
                          style: GoogleFonts.plusJakartaSans(fontSize: 12.5, fontWeight: FontWeight.w700, color: const Color(0xFF2563EB), letterSpacing: 0.5),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ble = ref.watch(bleProvider);
    final connected = ble.phase == BlePhase.connected;
    final telemetry = ble.lastTelemetry;
    final hasTelemetry = connected && telemetry != null;
    final percent = telemetry?.percent ?? 0;
    final kmLeftVal = (telemetry != null && telemetry.kmLeft > 0)
        ? telemetry.kmLeft.round()
        : (hasTelemetry ? ((percent / 100.0) * 270).round() : null);
    final percentDisplay = hasTelemetry ? '$percent' : '--';
    final kmLeftDisplay = hasTelemetry ? '$kmLeftVal' : '--';
    final speed = telemetry?.speed ?? 0.0;
    final isBikeOn = telemetry?.isBikeOn == true;
    final isLocked = ble.isLocked;
    final isConnecting = ble.phase == BlePhase.connecting || ble.phase == BlePhase.reconnecting;
    final hasBike = ble.bikeName != null || ble.device != null;

    // Trạng thái vận hành thực tế của xe máy điện
    final statusText = !connected
        ? (isConnecting
            ? 'Đang kết nối lại với xe...'
            : (hasBike
                ? 'Chưa kết nối xe — Chạm để kết nối'
                : 'Chưa có xe — Chạm để quét & kết nối'))
        : (isLocked
            ? 'Đang khóa an toàn (Locked)'
            : (speed > 0.5
                ? 'Đang chạy (${speed.toStringAsFixed(0)} km/h)'
                : (isBikeOn ? 'Sẵn sàng chạy (Ready)' : 'Đang đỗ (Parking)')));

    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ══════════════════════════════════════════════════════════════
              // 1. HEADER: Tên xe máy điện + Nút 1-chạm HUD/Logs/Lab + Badge BLE
              // ══════════════════════════════════════════════════════════════
              Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () => _openBikeSwitcherSheet(context),
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                        child: Row(
                          children: [
                            Container(
                              width: 26,
                              height: 26,
                              margin: const EdgeInsets.only(right: 8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(7),
                                boxShadow: const [
                                  BoxShadow(color: Color(0x180F172A), blurRadius: 4, offset: Offset(0, 1)),
                                ],
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: Image.asset(
                                'assets/images/bike_logo_3d.png',
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => const Icon(Icons.two_wheeler_rounded, size: 18, color: Color(0xFF2563EB)),
                              ),
                            ),
                            Flexible(
                              child: Text(
                                ble.bikeName ?? (ble.device != null ? 'Xe Dat Bike' : 'Chưa ghép đôi xe'),
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.3,
                                  color: const Color(0xFF0F172A),
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Icon(Icons.swap_horiz_rounded, size: 18, color: Color(0xFF2563EB)),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // Nút mở nhanh Cockpit HUD
                  IconButton(
                    tooltip: 'Đồng hồ tốc độ Cockpit HUD',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.speed_rounded, size: 21, color: Color(0xFF0F172A)),
                    onPressed: () => Navigator.of(context).pushNamed('/dashboard'),
                  ),
                  // Nút mở nhanh Nhật ký BLE
                  IconButton(
                    tooltip: 'Nhật ký Bluetooth',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.receipt_long_rounded, size: 20, color: Color(0xFF6366F1)),
                    onPressed: () => Navigator.of(context).pushNamed('/logs'),
                  ),
                  // Nút mở nhanh Firmware Lab
                  IconButton(
                    tooltip: 'Phòng Lab Firmware',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.science_rounded, size: 20, color: Color(0xFF8B5CF6)),
                    onPressed: () => Navigator.of(context).pushNamed('/lab'),
                  ),
                  const SizedBox(width: 2),
                  // Badge Bluetooth Connected hình viên thuốc trắng
                  InkWell(
                    onTap: connected ? null : _handleConnectTap,
                    borderRadius: BorderRadius.circular(22),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: connected ? const Color(0xFFBFDBFE) : const Color(0xFFE2E8F0)),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x080F172A),
                            blurRadius: 8,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            connected ? Icons.bluetooth_connected_rounded : Icons.bluetooth_disabled_rounded,
                            size: 15,
                            color: connected ? const Color(0xFF2563EB) : const Color(0xFF94A3B8),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            connected ? 'Online' : (isConnecting ? 'Đang nối...' : 'Offline'),
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: connected ? const Color(0xFF0F172A) : const Color(0xFF94A3B8),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 18),

              // ══════════════════════════════════════════════════════════════
              // 2. CỤM THÔNG SỐ: Quãng đường còn lại của xe máy điện (Font rộng)
              //    - Quãng đường: số thật từ ECU xe hoặc '--' khi chưa kết nối
              //    - Huy hiệu Mode lái D/S/R và cảnh báo chân chống
              // ══════════════════════════════════════════════════════════════
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    kmLeftDisplay,
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 54,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -1.0,
                      color: const Color(0xFF0F172A),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'km',
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF64748B),
                    ),
                  ),
                  const Spacer(),
                  if (hasTelemetry) ...[
                    // Huy hiệu Chân chống nếu đang hạ
                    if (telemetry.isSideStandDown) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFEF2F2),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFFFECACA)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.report_problem_rounded, size: 13, color: Color(0xFFEF4444)),
                            const SizedBox(width: 4),
                            Text(
                              'HẠ CHỐNG',
                              style: GoogleFonts.spaceGrotesk(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800,
                                color: const Color(0xFFEF4444),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    // Huy hiệu Mode lái D / S / R
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEFF6FF),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFFBFDBFE)),
                      ),
                      child: Text(
                        'MODE ${telemetry.drivingModeShort}',
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: const Color(0xFF2563EB),
                        ),
                      ),
                    ),
                  ],
                ],
              ),

              const SizedBox(height: 8),

              // Dải thông số năng lượng xe máy điện: ⚡ Dung lượng pin · 🔋 Quãng đường đầy
              Row(
                children: [
                  // Điện năng hiện có: % Pin + Km
                  Row(
                    children: [
                      const Icon(Icons.bolt_rounded, size: 17, color: Color(0xFF10B981)),
                      const SizedBox(width: 4),
                      Text(
                        hasTelemetry ? '$percentDisplay% Pin ($kmLeftDisplay km)' : '--% Pin (Chưa kết nối xe)',
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFF0F172A),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 20),
                  // Quãng đường tiêu chuẩn tối đa khi đầy pin: 270 km
                  Row(
                    children: [
                      Container(
                        width: 9,
                        height: 9,
                        decoration: const BoxDecoration(
                          color: Color(0xFF2563EB),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '270 km Max',
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFF0F172A),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 10),
                  const Icon(Icons.swap_horiz_rounded, size: 16, color: Color(0xFF94A3B8)),
                ],
              ),

              const SizedBox(height: 8),

              // 2 thanh progress nhỏ cho xe máy điện:
              // - Thanh 1: Tiến trình dung lượng Pin khả dụng (xanh lá)
              // - Thanh 2: Quãng đường còn lại / Dự phòng (xanh dương)
              Row(
                children: [
                  // Thanh Pin khả dụng (xanh lá)
                  Expanded(
                    flex: hasTelemetry && percent > 0 ? percent : 1,
                    child: Container(
                      height: 4,
                      decoration: BoxDecoration(
                        color: hasTelemetry ? const Color(0xFF10B981) : const Color(0xFFE2E8F0),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  // Thanh Quãng đường dự phòng (xanh dương)
                  Expanded(
                    flex: hasTelemetry ? (100 - percent).clamp(5, 100).toInt() : 1,
                    child: Container(
                      height: 4,
                      decoration: BoxDecoration(
                        color: hasTelemetry ? const Color(0xFF2563EB) : const Color(0xFFE2E8F0),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 8),

              // Trạng thái vận hành xe máy điện (Parking / Ready / Driving)
              if (!connected)
                InkWell(
                  onTap: _handleConnectTap,
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    margin: const EdgeInsets.only(top: 2),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEFF6FF),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFBFDBFE), width: 1.2),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isConnecting ? Icons.sync_rounded : Icons.bluetooth_searching_rounded,
                          size: 16,
                          color: const Color(0xFF2563EB),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          statusText,
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFF2563EB),
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(Icons.arrow_forward_ios_rounded, size: 11, color: Color(0xFF2563EB)),
                      ],
                    ),
                  ),
                )
              else
                Text(
                  statusText,
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: const Color(0xFF64748B),
                  ),
                ),

              const SizedBox(height: 10),

              // ══════════════════════════════════════════════════════════════
              // 3. GIỮA MÀN HÌNH: ẢNH XE MÁY ĐIỆN DAT BIKE QUANTUM
              // ══════════════════════════════════════════════════════════════
              Container(
                width: double.infinity,
                height: 230,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  color: Colors.white,
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x080F172A),
                      blurRadius: 20,
                      offset: Offset(0, 6),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Image.asset(
                      'assets/images/bike_hero_3d.jpg',
                      fit: BoxFit.contain,
                      width: double.infinity,
                      height: double.infinity,
                      errorBuilder: (context, error, stackTrace) => const Center(
                        child: Icon(Icons.two_wheeler_rounded, size: 90, color: Color(0xFF2563EB)),
                      ),
                    ),
                    // Badge trạng thái xe đang Bật / Khóa
                    if (isBikeOn)
                      Positioned(
                        top: 14,
                        left: 14,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: const Color(0xFFDCFCE7),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: const Color(0xFF86EFAC)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 6,
                                height: 6,
                                decoration: const BoxDecoration(
                                  color: Color(0xFF16A34A),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'XE SẴN SÀNG',
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: const Color(0xFF16A34A),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    // Badge Đang hú còi tìm xe (kèm nút 1 chạm để Tắt ngay)
                    if (ble.isFindingBike)
                      Positioned(
                        top: 14,
                        right: 14,
                        child: InkWell(
                          onTap: _quickFindBike,
                          borderRadius: BorderRadius.circular(20),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFEF2F2),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: const Color(0xFFEF4444)),
                              boxShadow: const [
                                BoxShadow(color: Color(0x20EF4444), blurRadius: 8, offset: Offset(0, 2)),
                              ],
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.volume_off_rounded, size: 14, color: Color(0xFFEF4444)),
                                const SizedBox(width: 4),
                                Text(
                                  'ĐANG HÚ CÒI · BẤM TẮT',
                                  style: GoogleFonts.plusJakartaSans(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    color: const Color(0xFFEF4444),
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

              const SizedBox(height: 16),

              // ══════════════════════════════════════════════════════════════
              // 4. CARD 4 NÚT ĐIỀU KHIỂN NHANH CHUYÊN BIỆT CHO XE MÁY ĐIỆN:
              //    1. Khóa (Lock/Unlock)
              //    2. Bật Xe (Power On/Off - Keyless)
              //    3. Tìm Xe (Find Bike - Còi & Đèn)
              //    4. Mở Cốp (Trunk - Cốp 41L)
              //    (Loại bỏ quạt điều hòa vì xe máy không có cabin AC!)
              // ══════════════════════════════════════════════════════════════
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFFF1F5F9)),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x060F172A),
                      blurRadius: 16,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          // 1. Khóa Cổ & Chống Trộm
                          _quickActionButton(
                            icon: isLocked
                                ? GeelyIcons.lock(
                                    color: const Color(0xFFEF4444),
                                    size: 24,
                                  )
                                : GeelyIcons.lockOpen(
                                    color: const Color(0xFF2563EB),
                                    size: 24,
                                  ),
                            label: isLocked ? 'Mở Khóa' : 'Khóa Cổ',
                            onTap: _quickLockToggle,
                            active: isLocked,
                            activeColor: const Color(0xFFFEF2F2),
                            activeBorderColor: const Color(0xFFFECACA),
                          ),

                          // 2. Bật / Tắt Nguồn Xe Máy Điện (Keyless Power)
                          _quickActionButton(
                            icon: Icon(
                              Icons.power_settings_new_rounded,
                              color: isBikeOn ? const Color(0xFF10B981) : const Color(0xFF64748B),
                              size: 24,
                            ),
                            label: isBikeOn ? 'Tắt Máy' : 'Bật Xe',
                            onTap: _quickPowerToggle,
                            active: isBikeOn,
                            activeColor: const Color(0xFFF0FDF4),
                            activeBorderColor: const Color(0xFFBBF7D0),
                          ),

                          // 3. Tìm Xe Trong Bãi (Còi & Đèn Định Vị - Bật / Tắt 2 chiều)
                          _quickActionButton(
                            icon: ble.isFindingBike
                                ? const Icon(
                                    Icons.volume_off_rounded,
                                    color: Color(0xFFEF4444),
                                    size: 24,
                                  )
                                : GeelyIcons.findBike(
                                    color: const Color(0xFF2563EB),
                                    size: 24,
                                  ),
                            label: ble.isFindingBike ? 'Tắt Còi' : 'Tìm Xe',
                            onTap: _quickFindBike,
                            active: ble.isFindingBike,
                            activeColor: const Color(0xFFFEF2F2),
                            activeBorderColor: const Color(0xFFFECACA),
                          ),

                          // 4. Đồng bộ thời gian thực Taplo (RTC)
                          _quickActionButton(
                            icon: GeelyIcons.clock(
                              color: const Color(0xFF0F172A),
                              size: 24,
                            ),
                            label: 'Đồng bộ giờ',
                            onTap: _quickSyncTime,
                          ),
                        ],
                      ),
                    ),

                    const Divider(color: Color(0xFFF1F5F9), height: 1, thickness: 1),

                    // Remote controls >
                    InkWell(
                      onTap: _openRemoteControlsSheet,
                      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(20)),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Cài đặt nhanh & Chống trộm',
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: const Color(0xFF0F172A),
                              ),
                            ),
                            const Icon(Icons.chevron_right_rounded, size: 20, color: Color(0xFF94A3B8)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // ══════════════════════════════════════════════════════════════
              // 5. CARD CHUYẾN ĐI (Trip Computer & Thống kê hành trình)
              // ══════════════════════════════════════════════════════════════
              _buildTripCard(ble.trip),

              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // WIDGETS CHUYẾN ĐI (TRIP COMPUTER) CHO XE MÁY ĐIỆN DAT BIKE
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildTripCard(TripData trip) {
    final mins = trip.duration.inMinutes;
    final secs = trip.duration.inSeconds % 60;
    final durationText = mins > 0
        ? '$mins phút ${secs > 0 ? "$secs s" : ""} · Đang ghi'
        : (secs > 0 ? '$secs giây · Đang ghi' : 'Sẵn sàng ghi nhận');

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFF1F5F9)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x060F172A),
            blurRadius: 16,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: Icon Chuyến đi + Tiêu đề + Nút xem Lịch sử
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF6FF),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFDBEAFE)),
                ),
                child: const Icon(
                  Icons.alt_route_rounded,
                  color: Color(0xFF2563EB),
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Chuyến Đi Hiện Tại',
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFF0F172A),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      durationText,
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: const Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
              ),
              InkWell(
                onTap: () => _openTripHistorySheet(context),
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Lịch sử',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFF2563EB),
                        ),
                      ),
                      const SizedBox(width: 2),
                      const Icon(
                        Icons.chevron_right_rounded,
                        size: 16,
                        color: Color(0xFF2563EB),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // Lưới 4 thông số chuyến đi của xe máy điện
          Row(
            children: [
              Expanded(
                child: _tripMetricItem(
                  icon: Icons.straighten_rounded,
                  iconColor: const Color(0xFF2563EB),
                  label: 'Quãng đường',
                  value: trip.distanceKm.toStringAsFixed(1),
                  unit: 'km',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _tripMetricItem(
                  icon: Icons.speed_rounded,
                  iconColor: const Color(0xFF0D9488),
                  label: 'Vận tốc TB',
                  value: trip.avgSpeedKmh.toStringAsFixed(1),
                  unit: 'km/h',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _tripMetricItem(
                  icon: Icons.electric_bolt_rounded,
                  iconColor: const Color(0xFFD97706),
                  label: 'Tốc độ tối đa',
                  value: trip.maxSpeedKmh.toStringAsFixed(0),
                  unit: 'km/h',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _tripMetricItem(
                  icon: Icons.battery_charging_full_rounded,
                  iconColor: const Color(0xFF059669),
                  label: 'Pin tiêu hao',
                  value: '-${trip.usedPercent}',
                  unit: '%',
                ),
              ),
            ],
          ),

          const SizedBox(height: 14),

          // Eco impact banner + Nút Bản đồ + Nút đặt lại Trip
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFF0FDF4),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFDCFCE7)),
            ),
            child: Row(
              children: [
                const Icon(Icons.eco_rounded, size: 16, color: Color(0xFF16A34A)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Giảm ${(trip.distanceKm * 0.16).toStringAsFixed(1)} kg CO₂ so với xe xăng',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF166534),
                    ),
                  ),
                ),
                InkWell(
                  onTap: () {
                    final curTrip = TripRecord(
                      startTime: trip.duration.inSeconds > 0
                          ? DateTime.now().subtract(trip.duration)
                          : DateTime.now(),
                      endTime: DateTime.now(),
                      distanceKm: trip.distanceKm,
                      durationSec: trip.duration.inSeconds,
                      avgSpeedKmh: trip.avgSpeedKmh,
                      maxSpeedKmh: trip.maxSpeedKmh,
                      usedPercent: trip.usedPercent,
                      route: TripGpsTracker.instance.getCurrentRoute(),
                    );
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => TripRouteScreen(
                          trip: curTrip,
                          tripIndex: 0,
                          allTrips: ref.read(bleProvider).tripHistory,
                        ),
                      ),
                    );
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    child: Row(
                      children: [
                        const Icon(Icons.map_rounded, size: 14, color: Color(0xFF2563EB)),
                        const SizedBox(width: 4),
                        Text(
                          'Bản đồ',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFF2563EB),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                InkWell(
                  onTap: _confirmResetTrip,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    child: Row(
                      children: [
                        const Icon(Icons.refresh_rounded, size: 14, color: Color(0xFF166534)),
                        const SizedBox(width: 4),
                        Text(
                          'Đặt lại',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFF166534),
                          ),
                        ),
                      ],
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

  Widget _tripMetricItem({
    required IconData icon,
    required Color iconColor,
    required String label,
    required String value,
    required String unit,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFF1F5F9)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: iconColor),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: const Color(0xFF64748B),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: const Color(0xFF0F172A),
                  letterSpacing: -0.5,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 4),
              Text(
                unit,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFF94A3B8),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmResetTrip() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Đặt Lại Chuyến Đi (Trip)',
          style: GoogleFonts.plusJakartaSans(
            fontWeight: FontWeight.w700,
            color: const Color(0xFF0F172A),
          ),
        ),
        content: Text(
          'Hệ thống sẽ đặt lại quãng đường, thời gian lái và vận tốc trung bình của chuyến đi hiện tại về 0.',
          style: GoogleFonts.plusJakartaSans(
            fontSize: 14,
            color: const Color(0xFF475569),
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              'HỦY',
              style: GoogleFonts.plusJakartaSans(
                fontWeight: FontWeight.w600,
                color: const Color(0xFF64748B),
              ),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('ĐẶT LẠI', style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      ref.read(bleProvider.notifier).resetTrip();
      _heroSnack('Đã đặt lại đồng hồ chuyến đi (Trip) về 0');
    }
  }

  void _openTripHistorySheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Consumer(
        builder: (context, sheetRef, _) {
          final ble = sheetRef.watch(bleProvider);
          final history = ble.tripHistory;

          final now = DateTime.now();
          final oneWeekAgo = now.subtract(const Duration(days: 7));
          final weekTrips = history.where((t) => t.startTime.isAfter(oneWeekAgo)).toList();

          final weekDist = weekTrips.fold<double>(0.0, (sum, t) => sum + t.distanceKm);
          final weekCount = weekTrips.length;
          final savedMoney = (weekDist * 575).round();
          final savedCo2 = (weekDist * 0.065);

          return DraggableScrollableSheet(
            initialChildSize: 0.75,
            minChildSize: 0.5,
            maxChildSize: 0.95,
            expand: false,
            builder: (context, scrollController) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: ListView(
                  controller: scrollController,
                  children: [
                    const SizedBox(height: 12),
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: const Color(0xFFCBD5E1),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Lịch Sử Chuyến Đi',
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                  color: const Color(0xFF0F172A),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Tổng hợp hành trình & hiệu suất xe máy điện',
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 12,
                                  color: const Color(0xFF64748B),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (history.isNotEmpty)
                          IconButton(
                            tooltip: 'Xóa lịch sử chuyến đi',
                            icon: const Icon(Icons.delete_outline_rounded, color: Color(0xFF94A3B8), size: 20),
                            onPressed: () async {
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (c) => AlertDialog(
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                                  title: Text('Xóa Lịch Sử Chuyến Đi', style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700)),
                                  content: Text(
                                    'Bạn có chắc chắn muốn xóa toàn bộ lịch sử chuyến đi đã lưu trên thiết bị này?',
                                    style: GoogleFonts.plusJakartaSans(fontSize: 14),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(c, false),
                                      child: Text('HỦY', style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600, color: const Color(0xFF64748B))),
                                    ),
                                    FilledButton(
                                      style: FilledButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
                                      onPressed: () => Navigator.pop(c, true),
                                      child: Text('XÓA HẾT', style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700)),
                                    ),
                                  ],
                                ),
                              );
                              if (confirm == true) {
                                await sheetRef.read(bleProvider.notifier).clearTripHistory();
                              }
                            },
                          ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded, color: Color(0xFF64748B)),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Card Tổng hợp tuần này (Dữ liệu thật 100%)
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: const Color(0xFFF1F5F9), width: 1),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x060F172A),
                            blurRadius: 14,
                            offset: Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'TUẦN NÀY',
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: const Color(0xFF64748B),
                                  letterSpacing: 1.0,
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFECFDF5),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: const Color(0xFFA7F3D0)),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.eco_rounded, size: 12, color: Color(0xFF059669)),
                                    const SizedBox(width: 4),
                                    Text(
                                      '-${savedCo2.toStringAsFixed(1)} kg CO₂',
                                      style: GoogleFonts.plusJakartaSans(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: const Color(0xFF059669),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: _summaryStat(label: 'Tổng quãng đường', value: weekDist.toStringAsFixed(1), unit: 'km'),
                              ),
                              Container(width: 1, height: 32, color: const Color(0xFFF1F5F9)),
                              Expanded(
                                child: _summaryStat(label: 'Số chuyến đi', value: '$weekCount', unit: 'chuyến'),
                              ),
                              Container(width: 1, height: 32, color: const Color(0xFFF1F5F9)),
                              Expanded(
                                child: _summaryStat(
                                  label: 'Tiết kiệm xăng',
                                  value: savedMoney >= 1000
                                      ? '${savedMoney ~/ 1000}.${(savedMoney % 1000).toString().padLeft(3, '0')}'
                                      : '$savedMoney',
                                  unit: 'đ',
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),
                    Text(
                      'CÁC HÀNH TRÌNH GẦN ĐÂY',
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFF64748B),
                        letterSpacing: 1.0,
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Danh sách chuyến đi thực tế hoặc Empty State trung thực
                    if (history.isEmpty) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                        ),
                        child: Column(
                          children: [
                            const Icon(Icons.route_outlined, size: 44, color: Color(0xFF94A3B8)),
                            const SizedBox(height: 12),
                            Text(
                              'Chưa có chuyến đi nào được lưu',
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: const Color(0xFF475569),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Hành trình sẽ tự động lưu khi xe di chuyển trên 50m\nhoặc khi bấm Đặt lại Trip / Tắt xe.',
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 12,
                                color: const Color(0xFF94A3B8),
                                height: 1.4,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ] else ...[
                      ...history.asMap().entries.map((entry) {
                        final index = entry.key;
                        final trip = entry.value;
                        final isRecent = index == 0;
                        final durMin = trip.durationSec ~/ 60;
                        final durSec = trip.durationSec % 60;
                        final durText = durMin > 0 ? '$durMin phút $durSec giây' : '$durSec giây';
                        final timeStr = '${trip.startTime.day.toString().padLeft(2, '0')}/${trip.startTime.month.toString().padLeft(2, '0')} · ${trip.startTime.hour.toString().padLeft(2, '0')}:${trip.startTime.minute.toString().padLeft(2, '0')} ($durText)';
                        final co2 = (trip.distanceKm * 0.065).toStringAsFixed(1);

                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => TripRouteScreen(
                                    trip: trip,
                                    tripIndex: history.length - index,
                                    allTrips: history,
                                  ),
                                ),
                              );
                            },
                            child: _tripHistoryItem(
                              title: 'Hành trình #${history.length - index}',
                              time: timeStr,
                              distance: '${trip.distanceKm.toStringAsFixed(1)} km',
                              avgSpeed: '${trip.avgSpeedKmh.toStringAsFixed(0)} km/h',
                              batteryUsed: trip.usedPercent > 0 ? '-${trip.usedPercent}%' : '--',
                              co2Saved: '$co2 kg',
                              isRecent: isRecent,
                              hasGps: trip.route.isNotEmpty,
                            ),
                          ),
                        );
                      }),
                    ],
                    const SizedBox(height: 24),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _summaryStat({required String label, required String value, required String unit}) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              value,
              style: GoogleFonts.spaceGrotesk(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: const Color(0xFF0F172A),
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 2),
            Text(
              unit,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: const Color(0xFF64748B),
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: GoogleFonts.plusJakartaSans(
            fontSize: 10,
            color: const Color(0xFF64748B),
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _tripHistoryItem({
    required String title,
    required String time,
    required String distance,
    required String avgSpeed,
    required String batteryUsed,
    required String co2Saved,
    bool isRecent = false,
    bool hasGps = false,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isRecent ? const Color(0xFFBFDBFE) : const Color(0xFFF1F5F9),
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x040F172A),
            blurRadius: 10,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: isRecent ? const Color(0xFFEFF6FF) : const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.two_wheeler_rounded,
                  size: 18,
                  color: isRecent ? const Color(0xFF2563EB) : const Color(0xFF64748B),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          title,
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFF0F172A),
                          ),
                        ),
                        const SizedBox(width: 6),
                        if (hasGps)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: const Color(0xFFECFDF5),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: const Color(0xFFA7F3D0)),
                            ),
                            child: Text(
                              'GPS',
                              style: GoogleFonts.spaceGrotesk(
                                fontSize: 9,
                                fontWeight: FontWeight.w800,
                                color: const Color(0xFF059669),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      time,
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 11.5,
                        color: const Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                distance,
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: const Color(0xFF0F172A),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _tripBadge(icon: Icons.speed_rounded, label: avgSpeed),
              const SizedBox(width: 8),
              _tripBadge(
                icon: Icons.battery_std_rounded,
                label: batteryUsed,
                color: const Color(0xFF059669),
              ),
              const SizedBox(width: 8),
              _tripBadge(
                icon: Icons.eco_rounded,
                label: '-$co2Saved CO₂',
                color: const Color(0xFF16A34A),
              ),
              const Spacer(),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Bản đồ & Replay',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFF2563EB),
                    ),
                  ),
                  const SizedBox(width: 2),
                  const Icon(
                    Icons.chevron_right_rounded,
                    size: 16,
                    color: Color(0xFF2563EB),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _tripBadge({
    required IconData icon,
    required String label,
    Color color = const Color(0xFF64748B),
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: GoogleFonts.plusJakartaSans(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: const Color(0xFF334155),
            ),
          ),
        ],
      ),
    );
  }

  Widget _quickActionButton({
    required Widget icon,
    required String label,
    required VoidCallback onTap,
    bool active = false,
    Color? activeColor,
    Color? activeBorderColor,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? (activeColor ?? const Color(0xFFEFF6FF)) : const Color(0xFFF8FAFC),
              border: Border.all(
                color: active ? (activeBorderColor ?? const Color(0xFFBFDBFE)) : const Color(0xFFF1F5F9),
                width: 1,
              ),
              boxShadow: active
                  ? [
                      BoxShadow(
                        color: (activeBorderColor ?? const Color(0xFF2563EB)).withValues(alpha: 0.15),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ]
                  : null,
            ),
            child: Center(child: icon),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: GoogleFonts.plusJakartaSans(
              fontSize: 11.5,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              color: active ? const Color(0xFF0F172A) : const Color(0xFF64748B),
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}
