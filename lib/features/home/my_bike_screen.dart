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

import '../../core/ble/ble_controller.dart';
import '../../core/utils/rssi_distance_helper.dart';
import '../../ui/app_theme.dart';
import '../../ui/geely_icons.dart';
import '../../ui/widgets.dart';
import '../parking/find_my_bike_screen.dart';
import '../scan/scan_screen.dart';
import '../settings/vehicle_management_screen.dart';
import '../settings/vehicle_settings_screen.dart';
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
    ref.read(bleProvider.notifier).onAppResumed();
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
    final cleanMsg = msg.replaceFirst(RegExp(r'^(Exception|TimeoutException):\s*'), '');
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(
          cleanMsg,
          style: AppTypography.bodySm(color: Colors.white).copyWith(fontWeight: FontWeight.w500),
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: duration ?? const Duration(milliseconds: 1800),
        action: actionLabel != null && onAction != null
            ? SnackBarAction(
                label: actionLabel,
                textColor: AppColors.amber,
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
          style: AppTypography.bodyLg(color: AppColors.textPrimary).copyWith(fontWeight: FontWeight.w700),
        ),
        content: Text(
          'Hệ thống sẽ khóa chốt cổ điện tử và kích hoạt cảm biến cảnh báo chống dắt xe.',
          style: AppTypography.bodyMd(color: AppColors.textDim).copyWith(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              'HỦY',
              style: AppTypography.labelLg(color: AppColors.textDim),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.red,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'KHÓA NGAY',
              style: AppTypography.labelLg(color: AppColors.onPrimary, fontWeight: FontWeight.w700),
            ),
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
                color: AppColors.panel,
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Thanh kéo định vị (Drag Handle)
                    const SheetDragHandle(),
                    const SizedBox(height: 16),

                    // Tiêu đề & Icon thanh mảnh
                    Row(
                      children: [
                        const TemplateBadgeIcon(
                          icon: Icons.tune_rounded,
                          color: AppColors.primary,
                          size: 40,
                          iconSize: 20,
                          borderRadius: 14,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Điều khiển xe',
                                style: AppTypography.bodyLg(color: AppColors.textPrimary).copyWith(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Cài đặt an toàn & tiện ích nhanh',
                                style: AppTypography.labelMd(
                                  color: AppColors.textDim,
                                  fontWeight: FontWeight.w400,
                                ).copyWith(letterSpacing: 0),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded, size: 20, color: AppColors.textMuted),
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
                      style: AppTypography.labelSm(
                        color: AppColors.textMuted,
                        fontWeight: FontWeight.w700,
                      ).copyWith(letterSpacing: 0.8),
                    ),
                    const SizedBox(height: 10),
                    Panel(
                      padding: EdgeInsets.zero,
                      borderRadius: 18,
                      child: Column(
                        children: [
                          _sheetToggleRow(
                            icon: Icons.lock_clock_rounded,
                            iconColor: AppColors.primary,
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
                            Builder(builder: (_) {
                              final isIos = RssiDistanceHelper.isIosPlatform();
                              final lockPresets = RssiDistanceHelper.defaultAutoLockThresholds(isIos: isIos);
                              final curAutoLock = ble.autoLockRssiThreshold ??
                                  lockPresets[ble.autoLockDistance.clamp(0, 2)];
                              final lockMin = -95.0;
                              final lockMax = isIos ? -65.0 : -68.0;
                              final midUpper = (lockPresets[0] + lockPresets[1]) / 2.0;
                              final midLower = (lockPresets[1] + lockPresets[2]) / 2.0;
                              final liveRssi = ble.filteredRssi ?? ble.rssi;
                              return Padding(
                                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Expanded(
                                          child: Text(
                                            liveRssi != null
                                                ? 'Mức sóng tự khóa (Hiện tại: $liveRssi dBm):'
                                                : 'Mức sóng tự khóa khi rời xa:',
                                            style: AppTypography.labelMd(
                                              color: AppColors.textDim,
                                              fontWeight: FontWeight.w600,
                                            ).copyWith(fontSize: 11.5, letterSpacing: 0),
                                          ),
                                        ),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: AppColors.primary.withValues(alpha: 0.08),
                                            borderRadius: BorderRadius.circular(6),
                                          ),
                                          child: Text(
                                            '${curAutoLock.round()} dBm · ~${RssiDistanceHelper.lockDistanceLabel(curAutoLock)}',
                                            style: AppTypography.labelSm(
                                              color: AppColors.primary,
                                              fontWeight: FontWeight.w700,
                                            ).copyWith(fontSize: 10.5, letterSpacing: 0),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      children: [
                                        _sheetSegmentPill(
                                          label: 'Gần',
                                          sub: '~3m (${lockPresets[0].round()}dBm)',
                                          selected: curAutoLock >= midUpper,
                                          onTap: () {
                                            ref.read(bleProvider.notifier).setAutoLockRssiThreshold(lockPresets[0]);
                                            setSheetState(() {});
                                            _heroSnack('Ngưỡng khóa: Gần (~3m · ${lockPresets[0].round()} dBm)');
                                          },
                                        ),
                                        const SizedBox(width: 8),
                                        _sheetSegmentPill(
                                          label: 'Vừa',
                                          sub: '~5m (${lockPresets[1].round()}dBm)',
                                          selected: curAutoLock < midUpper && curAutoLock > midLower,
                                          onTap: () {
                                            ref.read(bleProvider.notifier).setAutoLockRssiThreshold(lockPresets[1]);
                                            setSheetState(() {});
                                            _heroSnack('Ngưỡng khóa: Vừa (~5m · ${lockPresets[1].round()} dBm)');
                                          },
                                        ),
                                        const SizedBox(width: 8),
                                        _sheetSegmentPill(
                                          label: 'Xa',
                                          sub: '~8m (${lockPresets[2].round()}dBm)',
                                          selected: curAutoLock <= midLower,
                                          onTap: () {
                                            ref.read(bleProvider.notifier).setAutoLockRssiThreshold(lockPresets[2]);
                                            setSheetState(() {});
                                            _heroSnack('Ngưỡng khóa: Xa (~8m · ${lockPresets[2].round()} dBm)');
                                          },
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    // Slider tùy chỉnh dải sóng khi rời xa
                                    SliderTheme(
                                      data: SliderTheme.of(context).copyWith(
                                        trackHeight: 4,
                                        activeTrackColor: AppColors.primary,
                                        inactiveTrackColor: AppColors.panelBorderBright,
                                        thumbColor: AppColors.primary,
                                        overlayColor: AppColors.primary.withValues(alpha: 0.15),
                                      ),
                                      child: Slider(
                                        value: curAutoLock.clamp(lockMin, lockMax),
                                        min: lockMin,
                                        max: lockMax,
                                        divisions: (lockMax - lockMin).round(),
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
                                          '${lockMin.round()} dBm (Xa ~10m)',
                                          style: AppTypography.labelSm(color: AppColors.textMuted)
                                              .copyWith(fontSize: 10, letterSpacing: 0),
                                        ),
                                        Text(
                                          '${lockMax.round()} dBm (Gần ~2m)',
                                          style: AppTypography.labelSm(color: AppColors.textMuted)
                                              .copyWith(fontSize: 10, letterSpacing: 0),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              );
                            }),
                          ],
                          const PanelDivider(indent: 56, endIndent: 16),
                          _sheetToggleRow(
                            icon: Icons.key_rounded,
                            iconColor: AppColors.tertiary,
                            title: 'Mở khóa xe khi lại gần',
                            subtitle: 'Chỉ tự động mở khóa bánh xe khi điện thoại vào vùng gần',
                            value: ble.walkUpUnlock,
                            onChanged: (v) {
                              ref.read(bleProvider.notifier).setWalkUpUnlock(v);
                              setSheetState(() {});
                              _heroSnack(v ? 'Đã bật tự mở khóa xe khi lại gần' : 'Đã tắt tự mở khóa khi lại gần');
                            },
                          ),
                          if (ble.walkUpUnlock) ...[
                            // Mục con 1: Tự bật nguồn xe khi lại gần
                            _sheetSubFeatureCard(
                              icon: Icons.bolt_rounded,
                              accentColor: AppColors.amber,
                              title: 'Tự bật nguồn xe khi lại gần',
                              badgeLabel: 'TIỆN ÍCH',
                              subtitle: 'Tự bật sáng taplo & khởi động điện xe ngay sau khi mở khóa (không tắt xe nếu đã mở)',
                              value: ble.walkUpAutoPowerOn,
                              onChanged: (v) {
                                ref.read(bleProvider.notifier).setWalkUpAutoPowerOn(v);
                                setSheetState(() {});
                                _heroSnack(v ? 'Đã bật tự khởi động nguồn xe khi lại gần' : 'Đã tắt tự bật nguồn xe');
                              },
                            ),
                            // Mục con 2 (đỏ): Giữ xe không tự động tắt khi ở gần
                            _sheetSubFeatureCard(
                              icon: Icons.power_settings_new_rounded,
                              accentColor: AppColors.red,
                              title: 'Giữ xe không tự động tắt',
                              badgeLabel: 'LUÔN BẬT',
                              subtitle:
                                  'Không tự tắt sau 90s; khi ở gần dù tắt tay hay tự tắt do chân chống xe vẫn tự động mở lại',
                              value: ble.walkUpKeepAwake,
                              onChanged: (v) {
                                ref.read(bleProvider.notifier).setWalkUpKeepAwake(v);
                                setSheetState(() {});
                                _heroSnack(
                                  v ? 'Đã bật giữ xe không tự tắt khi ở gần' : 'Đã tắt giữ xe không tự tắt',
                                );
                              },
                            ),

                            // Tùy chỉnh mức sóng khi đến gần
                            Builder(builder: (_) {
                              final isIos = RssiDistanceHelper.isIosPlatform();
                              final nearPresets = isIos
                                  ? const [-56.0, -62.0, -68.0]
                                  : const [-50.0, -55.0, -62.0];
                              final curWalkUp = ble.walkUpRssiThreshold ??
                                  RssiDistanceHelper.defaultWalkUpThreshold(isIos: isIos);
                              final nearMin = isIos ? -75.0 : -70.0;
                              final nearMax = -45.0;
                              final midUpper = (nearPresets[0] + nearPresets[1]) / 2.0;
                              final midLower = (nearPresets[1] + nearPresets[2]) / 2.0;
                              final liveRssi = ble.filteredRssi ?? ble.rssi;
                              return Padding(
                                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Expanded(
                                          child: Text(
                                            liveRssi != null
                                                ? 'Mức sóng mở xe (Hiện tại: $liveRssi dBm):'
                                                : 'Mức sóng kích hoạt khi đến gần:',
                                            style: AppTypography.labelMd(
                                              color: AppColors.textDim,
                                              fontWeight: FontWeight.w600,
                                            ).copyWith(fontSize: 11.5, letterSpacing: 0),
                                          ),
                                        ),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: AppColors.tertiary.withValues(alpha: 0.10),
                                            borderRadius: BorderRadius.circular(6),
                                          ),
                                          child: Text(
                                            '${curWalkUp.round()} dBm · ~${RssiDistanceHelper.nearDistanceLabel(curWalkUp)}',
                                            style: AppTypography.labelSm(
                                              color: AppColors.tertiary,
                                              fontWeight: FontWeight.w700,
                                            ).copyWith(fontSize: 10.5, letterSpacing: 0),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      children: [
                                        _sheetSegmentPill(
                                          label: 'Cực gần',
                                          sub: '~0.8m (${nearPresets[0].round()}dBm)',
                                          selected: curWalkUp >= midUpper,
                                          onTap: () {
                                            ref.read(bleProvider.notifier).setWalkUpRssiThreshold(nearPresets[0]);
                                            setSheetState(() {});
                                            _heroSnack('Ngưỡng đến gần: Cực gần (~0.8m · ${nearPresets[0].round()} dBm)');
                                          },
                                        ),
                                        const SizedBox(width: 8),
                                        _sheetSegmentPill(
                                          label: 'Rất gần',
                                          sub: '~1.5m (${nearPresets[1].round()}dBm)',
                                          selected: curWalkUp < midUpper && curWalkUp > midLower,
                                          onTap: () {
                                            ref.read(bleProvider.notifier).setWalkUpRssiThreshold(nearPresets[1]);
                                            setSheetState(() {});
                                            _heroSnack('Ngưỡng đến gần: Rất gần (~1.5m · ${nearPresets[1].round()} dBm)');
                                          },
                                        ),
                                        const SizedBox(width: 8),
                                        _sheetSegmentPill(
                                          label: 'Vừa',
                                          sub: '~2.5m (${nearPresets[2].round()}dBm)',
                                          selected: curWalkUp <= midLower,
                                          onTap: () {
                                            ref.read(bleProvider.notifier).setWalkUpRssiThreshold(nearPresets[2]);
                                            setSheetState(() {});
                                            _heroSnack('Ngưỡng đến gần: Vừa (~2.5m · ${nearPresets[2].round()} dBm)');
                                          },
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    // Slider tùy chỉnh mức sóng khi lại gần
                                    SliderTheme(
                                      data: SliderTheme.of(context).copyWith(
                                        trackHeight: 4,
                                        activeTrackColor: AppColors.tertiary,
                                        inactiveTrackColor: AppColors.panelBorderBright,
                                        thumbColor: AppColors.tertiary,
                                        overlayColor: AppColors.tertiary.withValues(alpha: 0.15),
                                      ),
                                      child: Slider(
                                        value: curWalkUp.clamp(nearMin, nearMax),
                                        min: nearMin,
                                        max: nearMax,
                                        divisions: (nearMax - nearMin).round(),
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
                                          '${nearMin.round()} dBm (Xa hơn ~3m)',
                                          style: AppTypography.labelSm(color: AppColors.textMuted)
                                              .copyWith(fontSize: 10, letterSpacing: 0),
                                        ),
                                        Text(
                                          '-45 dBm (Sát xe ~0.5m)',
                                          style: AppTypography.labelSm(color: AppColors.textMuted)
                                              .copyWith(fontSize: 10, letterSpacing: 0),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              );
                            }),
                          ],
                          const PanelDivider(indent: 56, endIndent: 16),
                          _sheetToggleRow(
                            icon: Icons.security_rounded,
                            iconColor: AppColors.red,
                            title: 'Chống trộm từ xa',
                            subtitle: 'Khóa cứng nếu cách xa hơn 5m',
                            value: ble.antiTheft5m,
                            onChanged: (v) {
                              ref.read(bleProvider.notifier).setAntiTheft5m(v);
                              setSheetState(() {});
                              _heroSnack(v ? 'Đã kích hoạt chống trộm 5m' : 'Đã tắt chống trộm 5m');
                            },
                          ),
                          const PanelDivider(indent: 56, endIndent: 16),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            child: Row(
                              children: [
                                TemplateBadgeIcon(
                                  icon: ble.isFindingBike ? Icons.volume_off_rounded : Icons.campaign_rounded,
                                  color: ble.isFindingBike ? AppColors.red : AppColors.primary,
                                  size: 36,
                                  iconSize: 18,
                                  borderRadius: 10,
                                  bordered: false,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Còi tìm xe',
                                        style: AppTypography.labelLg(color: AppColors.textPrimary)
                                            .copyWith(fontSize: 13.5, letterSpacing: 0),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        ble.isFindingBike ? 'Đang hú còi định vị…' : 'Phát còi tìm xe trong bãi đỗ',
                                        style: AppTypography.bodySm(
                                          color: ble.isFindingBike ? AppColors.red : AppColors.textDim,
                                        ).copyWith(
                                          fontSize: 11.5,
                                          fontWeight: ble.isFindingBike ? FontWeight.w600 : FontWeight.w400,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: ble.isFindingBike ? AppColors.red : AppColors.primary,
                                    side: BorderSide(
                                      color: ble.isFindingBike
                                          ? AppColors.red
                                          : AppColors.primary.withValues(alpha: 0.30),
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
                                    style: AppTypography.labelSm(
                                      color: ble.isFindingBike ? AppColors.red : AppColors.primary,
                                      fontWeight: FontWeight.w700,
                                    ).copyWith(letterSpacing: 0),
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
                    // 2. TỰ ĐỘNG KẾT NỐI & QUÉT XE
                    // ══════════════════════════════════════════════════════════
                    Text(
                      'TỰ ĐỘNG KẾT NỐI & QUÉT XE',
                      style: AppTypography.labelSm(
                        color: AppColors.textMuted,
                        fontWeight: FontWeight.w700,
                      ).copyWith(letterSpacing: 0.8),
                    ),
                    const SizedBox(height: 10),
                    Panel(
                      padding: EdgeInsets.zero,
                      borderRadius: 18,
                      child: Column(
                        children: [
                          _sheetToggleRow(
                            icon: Icons.bluetooth_searching_rounded,
                            iconColor: AppColors.primary,
                            title: 'Tự động quét & kết nối lại',
                            subtitle: 'Tự tìm và kết nối xe khi mở app hoặc mất tín hiệu',
                            value: ble.autoReconnect,
                            onChanged: (v) {
                              ref.read(bleProvider.notifier).setAutoReconnect(v);
                              setSheetState(() {});
                              _heroSnack(v ? 'Đã bật tự động kết nối lại' : 'Đã tắt tự động quét & kết nối');
                            },
                          ),
                          if (ble.autoReconnect) ...[
                            const PanelDivider(indent: 56, endIndent: 16),
                            _sheetToggleRow(
                              icon: Icons.all_inclusive_rounded,
                              iconColor: AppColors.tertiary,
                              title: 'Quét liên tục (Không giới hạn)',
                              subtitle: 'Luôn sẵn sàng kết nối ngay khi xe xuất hiện trong tầm sóng',
                              value: ble.continuousScan,
                              onChanged: (v) {
                                ref.read(bleProvider.notifier).setContinuousScan(v);
                                setSheetState(() {});
                                _heroSnack(v ? 'Đã bật chế độ quét liên tục' : 'Đã chuyển về giới hạn số lần quét');
                              },
                            ),
                            if (!ble.continuousScan) ...[
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Expanded(
                                          child: Text(
                                            'Số lần quét thử lại tối đa:',
                                            style: AppTypography.labelMd(
                                              color: AppColors.textDim,
                                              fontWeight: FontWeight.w600,
                                            ).copyWith(fontSize: 11.5, letterSpacing: 0),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: AppColors.primary.withValues(alpha: 0.08),
                                            borderRadius: BorderRadius.circular(6),
                                          ),
                                          child: Text(
                                            '${ble.reconnectMaxAttempts} lần',
                                            style: AppTypography.labelSm(
                                              color: AppColors.primary,
                                              fontWeight: FontWeight.w700,
                                            ).copyWith(fontSize: 10.5, letterSpacing: 0),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      children: [
                                        _sheetSegmentPill(
                                          label: '3 lần',
                                          sub: 'Nhanh',
                                          selected: ble.reconnectMaxAttempts == 3,
                                          onTap: () {
                                            ref.read(bleProvider.notifier).setReconnectMaxAttempts(3);
                                            setSheetState(() {});
                                            _heroSnack('Số lần quét tối đa: 3 lần');
                                          },
                                        ),
                                        const SizedBox(width: 8),
                                        _sheetSegmentPill(
                                          label: '5 lần',
                                          sub: 'Chuẩn',
                                          selected: ble.reconnectMaxAttempts == 5,
                                          onTap: () {
                                            ref.read(bleProvider.notifier).setReconnectMaxAttempts(5);
                                            setSheetState(() {});
                                            _heroSnack('Số lần quét tối đa: 5 lần');
                                          },
                                        ),
                                        const SizedBox(width: 8),
                                        _sheetSegmentPill(
                                          label: '10 lần',
                                          sub: 'Kiên trì',
                                          selected: ble.reconnectMaxAttempts == 10,
                                          onTap: () {
                                            ref.read(bleProvider.notifier).setReconnectMaxAttempts(10);
                                            setSheetState(() {});
                                            _heroSnack('Số lần quét tối đa: 10 lần');
                                          },
                                        ),
                                        const SizedBox(width: 8),
                                        _sheetSegmentPill(
                                          label: '15 lần',
                                          sub: 'Nhiều',
                                          selected: ble.reconnectMaxAttempts == 15,
                                          onTap: () {
                                            ref.read(bleProvider.notifier).setReconnectMaxAttempts(15);
                                            setSheetState(() {});
                                            _heroSnack('Số lần quét tối đa: 15 lần');
                                          },
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Expanded(
                                        child: Text(
                                          'Chu kỳ quét / Sau bao lâu thử lại:',
                                          style: AppTypography.labelMd(
                                            color: AppColors.textDim,
                                            fontWeight: FontWeight.w600,
                                          ).copyWith(fontSize: 11.5, letterSpacing: 0),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: AppColors.tertiary.withValues(alpha: 0.10),
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          '${ble.reconnectIntervalSeconds} giây',
                                          style: AppTypography.labelSm(
                                            color: AppColors.tertiary,
                                            fontWeight: FontWeight.w700,
                                          ).copyWith(fontSize: 10.5, letterSpacing: 0),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      _sheetSegmentPill(
                                        label: '3s',
                                        sub: 'Rất nhanh',
                                        selected: ble.reconnectIntervalSeconds == 3,
                                        onTap: () {
                                          ref.read(bleProvider.notifier).setReconnectIntervalSeconds(3);
                                          setSheetState(() {});
                                          _heroSnack('Chu kỳ quét: 3 giây');
                                        },
                                      ),
                                      const SizedBox(width: 8),
                                      _sheetSegmentPill(
                                        label: '5s',
                                        sub: 'Tiêu chuẩn',
                                        selected: ble.reconnectIntervalSeconds == 5,
                                        onTap: () {
                                          ref.read(bleProvider.notifier).setReconnectIntervalSeconds(5);
                                          setSheetState(() {});
                                          _heroSnack('Chu kỳ quét: 5 giây');
                                        },
                                      ),
                                      const SizedBox(width: 8),
                                      _sheetSegmentPill(
                                        label: '10s',
                                        sub: 'Cân bằng',
                                        selected: ble.reconnectIntervalSeconds == 10,
                                        onTap: () {
                                          ref.read(bleProvider.notifier).setReconnectIntervalSeconds(10);
                                          setSheetState(() {});
                                          _heroSnack('Chu kỳ quét: 10 giây');
                                        },
                                      ),
                                      const SizedBox(width: 8),
                                      _sheetSegmentPill(
                                        label: '20s',
                                        sub: 'Tiết kiệm',
                                        selected: ble.reconnectIntervalSeconds == 20,
                                        onTap: () {
                                          ref.read(bleProvider.notifier).setReconnectIntervalSeconds(20);
                                          setSheetState(() {});
                                          _heroSnack('Chu kỳ quét: 20 giây');
                                        },
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
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
                          color: AppColors.panelSecondary,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: AppColors.panelBorderBright),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.settings_outlined, size: 18, color: AppColors.primary),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                'TẤT CẢ CÀI ĐẶT XE',
                                style: AppTypography.labelMd(
                                  color: AppColors.primary,
                                  fontWeight: FontWeight.w700,
                                ).copyWith(letterSpacing: 0.5),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 6),
                            const Icon(Icons.arrow_forward_rounded, size: 15, color: AppColors.primary),
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
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          TemplateBadgeIcon(
            icon: icon,
            color: iconColor,
            size: 34,
            iconSize: 18,
            borderRadius: 10,
            bordered: false,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppTypography.labelLg(color: AppColors.textPrimary)
                      .copyWith(fontSize: 13.5, letterSpacing: 0),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: AppTypography.bodySm(color: AppColors.textDim).copyWith(fontSize: 11.5),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: value,
            activeTrackColor: AppColors.primary,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  /// Thẻ tùy chọn phụ (cấp 2) bên trong cài đặt Walk-Up (dùng chung cho mục cam & mục đỏ).
  Widget _sheetSubFeatureCard({
    required IconData icon,
    required Color accentColor,
    required String title,
    required String badgeLabel,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: value ? accentColor.withValues(alpha: 0.08) : AppColors.panelSecondary,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: value ? accentColor.withValues(alpha: 0.35) : AppColors.panelBorderBright,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: value ? accentColor : AppColors.surfaceContainerHighest,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: Colors.white, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style: AppTypography.labelMd(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w700,
                        ).copyWith(fontSize: 12.5, letterSpacing: 0),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                      decoration: BoxDecoration(
                        color: accentColor.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        badgeLabel,
                        style: AppTypography.labelSm(
                          color: accentColor,
                          fontWeight: FontWeight.w800,
                        ).copyWith(fontSize: 8.5, letterSpacing: 0),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: AppTypography.labelSm(color: AppColors.textDim)
                      .copyWith(letterSpacing: 0),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: value,
            activeTrackColor: accentColor,
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
            color: selected
                ? AppColors.primary.withValues(alpha: 0.08)
                : AppColors.panelSecondary,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? AppColors.primary : AppColors.panelBorderBright,
              width: selected ? 1.5 : 1.0,
            ),
          ),
          child: Column(
            children: [
              Text(
                label,
                style: AppTypography.labelMd(
                  color: selected ? AppColors.primary : AppColors.textPrimary,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                ).copyWith(fontSize: 12.5, letterSpacing: 0),
              ),
              const SizedBox(height: 2),
              Text(
                sub,
                style: AppTypography.labelSm(
                  color: selected ? AppColors.primary : AppColors.textMuted,
                  fontWeight: FontWeight.w500,
                ).copyWith(fontSize: 9.5, letterSpacing: 0),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openBikeSwitcherSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.panel,
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
                const SheetDragHandle(width: 40),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Xe Của Bạn',
                            style: AppTypography.bodyLg(color: AppColors.textPrimary).copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Chuyển đổi xe đang điều khiển hoặc thêm xe mới',
                            style: AppTypography.labelMd(
                              color: AppColors.textDim,
                              fontWeight: FontWeight.w400,
                            ).copyWith(letterSpacing: 0),
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
                const SizedBox(height: 16),

                if (ble.savedBikes.isNotEmpty) ...[
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(context).size.height * 0.42,
                    ),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: ble.savedBikes.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, idx) {
                        final bike = ble.savedBikes[idx];
                        final isConnected = connected && (ble.device?.remoteId.str.toLowerCase() == bike.id.toLowerCase());
                        final isActive = (ble.activeBikeId?.toLowerCase() == bike.id.toLowerCase()) || isConnected;
                        final percent = isConnected ? ble.lastTelemetry?.percent : bike.lastBatteryPercent;
                        final odo = isConnected ? ble.lastTelemetry?.odo : bike.lastOdo;

                        return InkWell(
                          onTap: () {
                            if (!isActive || !isConnected) {
                              sheetRef.read(bleProvider.notifier).switchBike(bike, autoConnect: true);
                              Navigator.pop(ctx);
                              _heroSnack('Đang chuyển điều khiển sang ${bike.name}...');
                            }
                          },
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: isActive
                                  ? AppColors.primary.withValues(alpha: 0.08)
                                  : AppColors.panelSecondary,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: isConnected
                                    ? AppColors.primary
                                    : (isActive
                                        ? AppColors.primary.withValues(alpha: 0.30)
                                        : AppColors.panelBorderBright),
                                width: isConnected ? 1.8 : 1.2,
                              ),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 42,
                                  height: 42,
                                  decoration: BoxDecoration(
                                    color: AppColors.panel,
                                    borderRadius: BorderRadius.circular(12),
                                    boxShadow: AppColors.cardShadow,
                                  ),
                                  clipBehavior: Clip.antiAlias,
                                  child: Image.asset(
                                    'assets/images/bike_logo_3d.png',
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) => const Icon(
                                      Icons.two_wheeler_rounded,
                                      color: AppColors.primary,
                                      size: 22,
                                    ),
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
                                              bike.name,
                                              style: AppTypography.bodyMd(color: AppColors.textPrimary).copyWith(
                                                fontSize: 14.5,
                                                fontWeight: FontWeight.w700,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          if (bike.isDefault) ...[
                                            const SizedBox(width: 6),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                              decoration: BoxDecoration(
                                                color: AppColors.amber.withValues(alpha: 0.16),
                                                borderRadius: BorderRadius.circular(6),
                                              ),
                                              child: Text(
                                                'MẶC ĐỊNH',
                                                style: AppTypography.labelSm(
                                                  color: AppColors.amber,
                                                  fontWeight: FontWeight.w800,
                                                ).copyWith(fontSize: 8, letterSpacing: 0),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '${bike.model ?? "Dat Bike"}${bike.licensePlate != null ? " · ${bike.licensePlate}" : ""}${percent != null ? " · $percent% pin" : ""}${odo != null && odo > 0 ? " · ${odo.toStringAsFixed(0)} km" : ""}',
                                        style: AppTypography.labelMd(
                                          color: AppColors.textDim,
                                          fontWeight: FontWeight.w400,
                                        ).copyWith(fontSize: 11.5, letterSpacing: 0),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                if (isConnected)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: AppColors.primary,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(Icons.check_rounded, color: AppColors.onPrimary, size: 12),
                                        const SizedBox(width: 4),
                                        Text(
                                          'ĐANG ĐIỀU KHIỂN',
                                          style: AppTypography.labelSm(
                                            color: AppColors.onPrimary,
                                            fontWeight: FontWeight.w700,
                                          ).copyWith(fontSize: 9, letterSpacing: 0),
                                        ),
                                      ],
                                    ),
                                  )
                                else if (isActive)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: AppColors.primary.withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      'ĐÃ CHỌN',
                                      style: AppTypography.labelSm(
                                        color: AppColors.primaryContainer,
                                        fontWeight: FontWeight.w700,
                                      ).copyWith(fontSize: 9, letterSpacing: 0),
                                    ),
                                  )
                                else
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: AppColors.panelBorder,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      'CHỌN XE',
                                      style: AppTypography.labelSm(
                                        color: AppColors.textDim,
                                        fontWeight: FontWeight.w700,
                                      ).copyWith(fontSize: 9, letterSpacing: 0),
                                    ),
                                  ),
                                const SizedBox(width: 4),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline_rounded, color: AppColors.red, size: 20),
                                  tooltip: 'Xóa xe này',
                                  constraints: const BoxConstraints(),
                                  padding: const EdgeInsets.all(6),
                                  onPressed: () async {
                                    final confirm = await showDialog<bool>(
                                      context: context,
                                      builder: (dCtx) => AlertDialog(
                                        backgroundColor: AppColors.panel,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                        title: Text(
                                          'Xóa xe khỏi danh sách?',
                                          style: AppTypography.bodyLg(color: AppColors.red).copyWith(
                                            fontSize: 17,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        content: Text(
                                          'Bạn có chắc chắn muốn xóa "${bike.name}" khỏi danh sách nhà xe?',
                                          style: AppTypography.bodyMd(color: AppColors.textDim).copyWith(fontSize: 14),
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () => Navigator.pop(dCtx, false),
                                            child: Text('HỦY', style: AppTypography.labelLg(color: AppColors.textDim)),
                                          ),
                                          ElevatedButton(
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: AppColors.red,
                                              foregroundColor: AppColors.onPrimary,
                                              shape: const StadiumBorder(),
                                            ),
                                            onPressed: () => Navigator.pop(dCtx, true),
                                            child: Text(
                                              'XÓA XE',
                                              style: AppTypography.headlineSm(color: AppColors.onPrimary).copyWith(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (confirm == true) {
                                      await sheetRef.read(bleProvider.notifier).deleteBike(bike.id);
                                      _heroSnack('Đã xóa "${bike.name}" khỏi nhà xe');
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
                ] else if (hasBike)
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppColors.primary.withValues(alpha: 0.28), width: 1.5),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: AppColors.panel,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Image.asset(
                            'assets/images/bike_logo_3d.png',
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const Icon(
                              Icons.two_wheeler_rounded,
                              color: AppColors.primary,
                              size: 24,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                ble.bikeName ?? 'Xe Dat Bike',
                                style: AppTypography.bodyMd(color: AppColors.textPrimary).copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                infoStr,
                                style: AppTypography.bodySm(color: AppColors.textDim).copyWith(fontSize: 11.5),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline_rounded, color: AppColors.red, size: 22),
                          tooltip: 'Xóa / Quên xe này',
                          onPressed: () async {
                            final confirm = await showDialog<bool>(
                              context: context,
                              builder: (dCtx) => AlertDialog(
                                backgroundColor: AppColors.panel,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                title: Text(
                                  'Quên xe này?',
                                  style: AppTypography.bodyLg(color: AppColors.red).copyWith(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                content: Text(
                                  'Bạn có chắc muốn quên thông tin xe hiện tại khỏi ứng dụng?',
                                  style: AppTypography.bodyMd(color: AppColors.textDim).copyWith(fontSize: 14),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(dCtx, false),
                                    child: Text('HỦY', style: AppTypography.labelLg(color: AppColors.textDim)),
                                  ),
                                  ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: AppColors.red,
                                      foregroundColor: AppColors.onPrimary,
                                      shape: const StadiumBorder(),
                                    ),
                                    onPressed: () => Navigator.pop(dCtx, true),
                                    child: Text(
                                      'QUÊN XE',
                                      style: AppTypography.headlineSm(color: AppColors.onPrimary).copyWith(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                            if (confirm == true) {
                              await sheetRef.read(bleProvider.notifier).forgetBike();
                              if (ctx.mounted) Navigator.pop(ctx);
                              _heroSnack('Đã xóa / quên thông tin xe');
                            }
                          },
                        ),
                      ],
                    ),
                  )
                else
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: AppColors.panelSecondary,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppColors.panelBorderBright),
                    ),
                    child: Column(
                      children: [
                        const Icon(Icons.two_wheeler_outlined, size: 40, color: AppColors.textMuted),
                        const SizedBox(height: 10),
                        Text(
                          'Chưa có xe nào trong nhà xe',
                          style: AppTypography.bodyMd(color: AppColors.textPrimary).copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Bấm "GHÉP ĐÔI XE MỚI" bên dưới để quét kết nối xe Dat Bike của bạn',
                          textAlign: TextAlign.center,
                          style: AppTypography.labelMd(
                            color: AppColors.textDim,
                            fontWeight: FontWeight.w400,
                          ).copyWith(letterSpacing: 0),
                        ),
                      ],
                    ),
                  ),

                const SizedBox(height: 20),

                // 2 nút tiện ích: Quản lý nhà xe & Ghép đôi xe mới
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          side: const BorderSide(color: AppColors.surfaceContainerHighest),
                        ),
                        icon: const Icon(Icons.garage_rounded, size: 18, color: AppColors.textPrimary),
                        label: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            'QUẢN LÝ NHÀ XE',
                            style: AppTypography.labelMd(
                              color: AppColors.textPrimary,
                              fontWeight: FontWeight.w700,
                            ).copyWith(letterSpacing: 0),
                          ),
                        ),
                        onPressed: () {
                          Navigator.pop(ctx);
                          Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const VehicleManagementScreen()),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        icon: const Icon(Icons.add_rounded, size: 18, color: AppColors.onPrimary),
                        label: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            'GHÉP ĐÔI XE MỚI',
                            style: AppTypography.labelMd(
                              color: AppColors.onPrimary,
                              fontWeight: FontWeight.w700,
                            ).copyWith(letterSpacing: 0),
                          ),
                        ),
                        onPressed: () {
                          Navigator.pop(ctx);
                          Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const ScanScreen()),
                          );
                        },
                      ),
                    ),
                  ],
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
    final phase = ref.watch(bleProvider.select((s) => s.phase));
    final telemetry = ref.watch(bleProvider.select((s) => s.lastTelemetry));
    final isLocked = ref.watch(bleProvider.select((s) => s.isLocked));
    final bikeName = ref.watch(bleProvider.select((s) => s.bikeName));
    final hasDevice = ref.watch(bleProvider.select((s) => s.device != null));
    final savedBikesCount = ref.watch(bleProvider.select((s) => s.savedBikes.length));
    final isFindingBike = ref.watch(bleProvider.select((s) => s.isFindingBike));

    final connected = phase == BlePhase.connected;
    final hasTelemetry = connected && telemetry != null;
    final percent = telemetry?.percent ?? 0;
    final kmLeftVal = (telemetry != null && telemetry.kmLeft > 0)
        ? telemetry.kmLeft.round()
        : (hasTelemetry ? ((percent / 100.0) * 270).round() : null);
    final percentDisplay = hasTelemetry ? '$percent' : '--';
    final kmLeftDisplay = hasTelemetry ? '$kmLeftVal' : '--';
    final speed = telemetry?.speed ?? 0.0;
    final isBikeOn = telemetry?.isBikeOn == true;
    final isConnecting = phase == BlePhase.connecting || phase == BlePhase.reconnecting;
    final hasBike = bikeName != null || hasDevice;

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
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ══════════════════════════════════════════════════════════════
              // 1. HEADER: Tên xe máy điện + Nút 1-chạm Cockpit HUD + Badge BLE
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
                                boxShadow: AppColors.cardShadow,
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: Image.asset(
                                'assets/images/bike_logo_3d.png',
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => const Icon(
                                  Icons.two_wheeler_rounded,
                                  size: 18,
                                  color: AppColors.primary,
                                ),
                              ),
                            ),
                            Flexible(
                              child: Text(
                                bikeName ?? (hasDevice ? 'Xe Dat Bike' : 'Chưa ghép đôi xe'),
                                style: AppTypography.bodyLg(color: AppColors.textPrimary).copyWith(
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.3,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (savedBikesCount > 1) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppColors.primary.withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
                                ),
                                child: Text(
                                  '$savedBikesCount xe',
                                  style: AppTypography.labelSm(
                                    color: AppColors.primary,
                                    fontWeight: FontWeight.w700,
                                  ).copyWith(fontSize: 10, letterSpacing: 0),
                                ),
                              ),
                            ],
                            const SizedBox(width: 4),
                            const Icon(Icons.swap_horiz_rounded, size: 18, color: AppColors.primary),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // Nút mở nhanh Cockpit HUD
                  IconButton(
                    tooltip: 'Đồng hồ tốc độ Cockpit HUD',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.speed_rounded, size: 21, color: AppColors.textPrimary),
                    onPressed: () => Navigator.of(context).pushNamed('/dashboard'),
                  ),
                  const SizedBox(width: 4),
                  // Badge Bluetooth Connected hình viên thuốc trắng
                  InkWell(
                    onTap: connected ? null : _handleConnectTap,
                    borderRadius: BorderRadius.circular(22),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: AppColors.panel,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: connected
                              ? AppColors.primary.withValues(alpha: 0.25)
                              : AppColors.panelBorderBright,
                        ),
                        boxShadow: AppColors.cardShadow,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            connected ? Icons.bluetooth_connected_rounded : Icons.bluetooth_disabled_rounded,
                            size: 15,
                            color: connected ? AppColors.primary : AppColors.textMuted,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            connected ? 'Online' : (isConnecting ? 'Đang nối...' : 'Offline'),
                            style: AppTypography.labelMd(
                              color: connected ? AppColors.textPrimary : AppColors.textMuted,
                              fontWeight: FontWeight.w600,
                            ).copyWith(fontSize: 11.5, letterSpacing: 0),
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
                    style: AppTypography.displayLg(color: AppColors.textPrimary).copyWith(
                      fontSize: 54,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -1.0,
                      height: 1.0,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'km',
                    style: AppTypography.headlineSm(color: AppColors.textDim).copyWith(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  if (hasTelemetry) ...[
                    // Huy hiệu Chân chống nếu đang hạ
                    if (telemetry.isSideStandDown) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: AppColors.red.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.red.withValues(alpha: 0.30)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.report_problem_rounded, size: 13, color: AppColors.red),
                            const SizedBox(width: 4),
                            Text(
                              'HẠ CHỐNG',
                              style: AppTypography.headlineSm(color: AppColors.red).copyWith(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800,
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
                        color: AppColors.primary.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
                      ),
                      child: Text(
                        'MODE ${telemetry.drivingModeShort}',
                        style: AppTypography.headlineSm(color: AppColors.primary).copyWith(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
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
                  Flexible(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.bolt_rounded, size: 17, color: AppColors.tertiary),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            hasTelemetry ? '$percentDisplay% Pin ($kmLeftDisplay km)' : '--% Pin (Chưa kết nối xe)',
                            style: AppTypography.headlineSm(color: AppColors.textPrimary).copyWith(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 14),
                  // Quãng đường tiêu chuẩn tối đa khi đầy pin: 270 km
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 9,
                        height: 9,
                        decoration: const BoxDecoration(
                          color: AppColors.primary,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '270 km Max',
                        style: AppTypography.headlineSm(color: AppColors.textPrimary).copyWith(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.swap_horiz_rounded, size: 16, color: AppColors.textMuted),
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
                        color: hasTelemetry ? AppColors.tertiary : AppColors.panelBorderBright,
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
                        color: hasTelemetry ? AppColors.primary : AppColors.panelBorderBright,
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
                      color: AppColors.primary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: AppColors.primary.withValues(alpha: 0.25),
                        width: 1.2,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isConnecting ? Icons.sync_rounded : Icons.bluetooth_searching_rounded,
                          size: 16,
                          color: AppColors.primary,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            statusText,
                            style: AppTypography.labelMd(
                              color: AppColors.primary,
                              fontWeight: FontWeight.w700,
                            ).copyWith(fontSize: 12.5, letterSpacing: 0),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(Icons.arrow_forward_ios_rounded, size: 11, color: AppColors.primary),
                      ],
                    ),
                  ),
                )
              else
                Text(
                  statusText,
                  style: AppTypography.bodySm(color: AppColors.textDim).copyWith(
                    fontWeight: FontWeight.w500,
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
                  color: AppColors.panel,
                  boxShadow: AppColors.cardShadow,
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
                        child: Icon(Icons.two_wheeler_rounded, size: 90, color: AppColors.primary),
                      ),
                    ),
                    // Badge trạng thái xe đang Bật / Khóa
                    if (isBikeOn)
                      const Positioned(
                        top: 14,
                        left: 14,
                        child: StatusPill(
                          label: 'XE SẴN SÀNG',
                          color: AppColors.tertiary,
                          pulse: true,
                        ),
                      ),
                    // Badge Đang hú còi tìm xe (kèm nút 1 chạm để Tắt ngay)
                    if (isFindingBike)
                      Positioned(
                        top: 14,
                        right: 14,
                        child: InkWell(
                          onTap: _quickFindBike,
                          borderRadius: BorderRadius.circular(20),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: AppColors.red.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: AppColors.red),
                              boxShadow: [
                                BoxShadow(
                                  color: AppColors.red.withValues(alpha: 0.12),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.volume_off_rounded, size: 14, color: AppColors.red),
                                const SizedBox(width: 4),
                                Text(
                                  'ĐANG HÚ CÒI · BẤM TẮT',
                                  style: AppTypography.labelSm(
                                    color: AppColors.red,
                                    fontWeight: FontWeight.w800,
                                  ).copyWith(fontSize: 10, letterSpacing: 0),
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
              //    4. Đồng bộ giờ Taplo
              // ══════════════════════════════════════════════════════════════
              Panel(
                padding: EdgeInsets.zero,
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
                                    color: AppColors.red,
                                    size: 24,
                                  )
                                : GeelyIcons.lockOpen(
                                    color: AppColors.primary,
                                    size: 24,
                                  ),
                            label: isLocked ? 'Mở Khóa' : 'Khóa Cổ',
                            onTap: _quickLockToggle,
                            active: isLocked,
                            activeColor: AppColors.red.withValues(alpha: 0.08),
                            activeBorderColor: AppColors.red.withValues(alpha: 0.30),
                          ),

                          // 2. Bật / Tắt Nguồn Xe Máy Điện (Keyless Power)
                          _quickActionButton(
                            icon: Icon(
                              Icons.power_settings_new_rounded,
                              color: isBikeOn ? AppColors.tertiary : AppColors.textDim,
                              size: 24,
                            ),
                            label: isBikeOn ? 'Tắt Máy' : 'Bật Xe',
                            onTap: _quickPowerToggle,
                            active: isBikeOn,
                            activeColor: AppColors.tertiary.withValues(alpha: 0.10),
                            activeBorderColor: AppColors.tertiary.withValues(alpha: 0.35),
                          ),

                          // 3. Tìm Xe Trong Bãi (Còi & Đèn Định Vị - Mở Precision Radar)
                          _quickActionButton(
                            icon: isFindingBike
                                ? const Icon(
                                    Icons.volume_off_rounded,
                                    color: AppColors.red,
                                    size: 24,
                                  )
                                : GeelyIcons.findBike(
                                    color: AppColors.primary,
                                    size: 24,
                                  ),
                            label: isFindingBike ? 'Tắt Còi' : 'Tìm Xe',
                            onTap: () {
                              if (isFindingBike) {
                                _quickFindBike();
                              } else {
                                Navigator.of(context).push(
                                  MaterialPageRoute(builder: (_) => const FindMyBikeScreen()),
                                );
                              }
                            },
                            active: isFindingBike,
                            activeColor: AppColors.red.withValues(alpha: 0.08),
                            activeBorderColor: AppColors.red.withValues(alpha: 0.30),
                          ),

                          // 4. Đồng bộ thời gian thực Taplo (RTC)
                          _quickActionButton(
                            icon: GeelyIcons.clock(
                              color: AppColors.textPrimary,
                              size: 24,
                            ),
                            label: 'Đồng bộ giờ',
                            onTap: _quickSyncTime,
                          ),
                        ],
                      ),
                    ),

                    const PanelDivider(indent: 0, endIndent: 0),

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
                              style: AppTypography.bodySm(color: AppColors.textPrimary).copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const Icon(Icons.chevron_right_rounded, size: 20, color: AppColors.textMuted),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // ══════════════════════════════════════════════════════════════
              // 4.5. CARD VỊ TRÍ ĐỖ XE & TÌM XE (SMART PARKING)
              // ══════════════════════════════════════════════════════════════
              _buildSmartParkingCard(),

              const SizedBox(height: 16),

              // ══════════════════════════════════════════════════════════════
              // 5. CARD CHUYẾN ĐI (Trip Computer & Thống kê hành trình)
              // ══════════════════════════════════════════════════════════════
              Consumer(
                builder: (context, tripRef, _) {
                  final trip = tripRef.watch(bleProvider.select((s) => s.trip));
                  return _buildTripCard(trip);
                },
              ),

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

  Widget _buildSmartParkingCard() {
    final deviceId = ref.watch(bleProvider.select((s) => s.device?.remoteId.str));
    return FutureBuilder<ParkedLocation?>(
      future: ParkingStorageService.instance.loadParkedLocation(
        bikeId: deviceId,
      ),
      builder: (context, snapshot) {
        final loc = snapshot.data;
        final now = DateTime.now();
        final parkedTime = loc?.timestamp;
        final durationText = parkedTime != null
            ? (() {
                final diff = now.difference(parkedTime);
                final hours = diff.inHours;
                final mins = diff.inMinutes % 60;
                return hours > 0 ? 'Đã đỗ ${hours}h ${mins}p' : 'Đã đỗ ${mins}p';
              })()
            : 'Chưa có dữ liệu đỗ xe';
        final addressText = loc?.note?.isNotEmpty == true
            ? loc!.note!
            : (loc?.address?.isNotEmpty == true
                ? loc!.address!
                : 'Chưa có thông tin vị trí đỗ xe');

        return Panel(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const TemplateBadgeIcon(
                    icon: Icons.local_parking_rounded,
                    color: AppColors.primary,
                    size: 38,
                    iconSize: 20,
                    borderRadius: 12,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Vị Trí Đỗ Xe & Tìm Xe',
                          style: AppTypography.bodyMd(color: AppColors.textPrimary).copyWith(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '$durationText · Tự động ghim',
                          style: AppTypography.labelMd(
                            color: AppColors.textDim,
                            fontWeight: FontWeight.w500,
                          ).copyWith(letterSpacing: 0),
                        ),
                      ],
                    ),
                  ),
                  InkWell(
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const FindMyBikeScreen()),
                      );
                    },
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: AppColors.panelSecondary,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: AppColors.panelBorderBright),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Radar',
                            style: AppTypography.labelMd(
                              color: AppColors.primary,
                              fontWeight: FontWeight.w600,
                            ).copyWith(letterSpacing: 0),
                          ),
                          const SizedBox(width: 2),
                          const Icon(
                            Icons.radar_rounded,
                            size: 16,
                            color: AppColors.primary,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.panelSecondary,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.panelBorder),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.place_rounded,
                      size: 16,
                      color: AppColors.amber,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        addressText,
                        style: AppTypography.labelMd(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w600,
                        ).copyWith(letterSpacing: 0),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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

  Widget _buildTripCard(TripData trip) {
    final mins = trip.duration.inMinutes;
    final secs = trip.duration.inSeconds % 60;
    final durationText = mins > 0
        ? '$mins phút ${secs > 0 ? "$secs s" : ""} · Đang ghi'
        : (secs > 0 ? '$secs giây · Đang ghi' : 'Sẵn sàng ghi nhận');

    return Panel(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: Icon Chuyến đi + Tiêu đề + Nút xem Lịch sử
          Row(
            children: [
              const TemplateBadgeIcon(
                icon: Icons.alt_route_rounded,
                color: AppColors.primary,
                size: 38,
                iconSize: 20,
                borderRadius: 12,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Chuyến Đi Hiện Tại',
                      style: AppTypography.bodyMd(color: AppColors.textPrimary).copyWith(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      durationText,
                      style: AppTypography.labelMd(
                        color: AppColors.textDim,
                        fontWeight: FontWeight.w500,
                      ).copyWith(letterSpacing: 0),
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
                    color: AppColors.panelSecondary,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppColors.panelBorderBright),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Lịch sử',
                        style: AppTypography.labelMd(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w600,
                        ).copyWith(letterSpacing: 0),
                      ),
                      const SizedBox(width: 2),
                      const Icon(
                        Icons.chevron_right_rounded,
                        size: 16,
                        color: AppColors.primary,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // Lưới thông số chuyến đi của xe máy điện (KM xe ODO & KM GPS song song)
          Row(
            children: [
              Expanded(
                child: _tripMetricItem(
                  icon: Icons.straighten_rounded,
                  iconColor: AppColors.primary,
                  label: 'KM xe (ODO)',
                  value: trip.distanceKm.toStringAsFixed(1),
                  unit: 'km',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _tripMetricItem(
                  icon: Icons.gps_fixed_rounded,
                  iconColor: AppColors.tertiary,
                  label: 'KM theo GPS',
                  value: trip.gpsDistanceKm.toStringAsFixed(1),
                  unit: 'km',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _tripMetricItem(
                  icon: Icons.speed_rounded,
                  iconColor: AppColors.accent,
                  label: 'Vận tốc TB',
                  value: trip.avgSpeedKmh.toStringAsFixed(1),
                  unit: 'km/h',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _tripMetricItem(
                  icon: Icons.electric_bolt_rounded,
                  iconColor: AppColors.amber,
                  label: 'Tốc độ tối đa',
                  value: trip.maxSpeedKmh.toStringAsFixed(0),
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
                  icon: Icons.battery_charging_full_rounded,
                  iconColor: AppColors.tertiary,
                  label: 'Pin tiêu hao',
                  value: '-${trip.usedPercent}',
                  unit: '%',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _tripMetricItem(
                  icon: Icons.satellite_alt_rounded,
                  iconColor: trip.gpsSignalLossCount > 0 ? AppColors.amber : AppColors.tertiary,
                  label: 'Tín hiệu GPS',
                  value: trip.gpsSignalLossCount > 0 ? '-${trip.gpsSignalLossCount}' : 'Ổn định',
                  unit: trip.gpsSignalLossCount > 0 ? 'mất sóng' : '',
                ),
              ),
            ],
          ),

          const SizedBox(height: 14),

          // Eco impact banner + Nút Bản đồ + Nút đặt lại Trip
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.tertiary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.tertiary.withValues(alpha: 0.25)),
            ),
            child: Row(
              children: [
                const Icon(Icons.eco_rounded, size: 16, color: AppColors.tertiary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Giảm ${(trip.distanceKm * 0.16).toStringAsFixed(1)} kg CO₂ so với xe xăng',
                    style: AppTypography.labelMd(
                      color: AppColors.tertiaryContainer,
                      fontWeight: FontWeight.w600,
                    ).copyWith(fontSize: 11.5, letterSpacing: 0),
                  ),
                ),
                InkWell(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const TripRouteScreen(),
                      ),
                    );
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    child: Row(
                      children: [
                        const Icon(Icons.map_rounded, size: 14, color: AppColors.primary),
                        const SizedBox(width: 4),
                        Text(
                          'Bản đồ',
                          style: AppTypography.labelMd(
                            color: AppColors.primary,
                            fontWeight: FontWeight.w700,
                          ).copyWith(fontSize: 11.5, letterSpacing: 0),
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
                        const Icon(Icons.refresh_rounded, size: 14, color: AppColors.tertiaryContainer),
                        const SizedBox(width: 4),
                        Text(
                          'Đặt lại',
                          style: AppTypography.labelMd(
                            color: AppColors.tertiaryContainer,
                            fontWeight: FontWeight.w700,
                          ).copyWith(fontSize: 11.5, letterSpacing: 0),
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
        color: AppColors.panelSecondary,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.panelBorder),
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
                  style: AppTypography.labelMd(
                    color: AppColors.textDim,
                    fontWeight: FontWeight.w500,
                  ).copyWith(fontSize: 11.5, letterSpacing: 0),
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
                style: AppTypography.headlineSm(color: AppColors.textPrimary).copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                unit,
                style: AppTypography.labelMd(
                  color: AppColors.textMuted,
                  fontWeight: FontWeight.w600,
                ).copyWith(letterSpacing: 0),
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
          style: AppTypography.bodyLg(color: AppColors.textPrimary).copyWith(fontWeight: FontWeight.w700),
        ),
        content: Text(
          'Hệ thống sẽ đặt lại quãng đường, thời gian lái và vận tốc trung bình của chuyến đi hiện tại về 0.',
          style: AppTypography.bodyMd(color: AppColors.textDim).copyWith(fontSize: 14, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('HỦY', style: AppTypography.labelLg(color: AppColors.textDim)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'ĐẶT LẠI',
              style: AppTypography.labelLg(color: AppColors.onPrimary, fontWeight: FontWeight.w700),
            ),
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
      backgroundColor: AppColors.panel,
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
          final weekGpsDist = weekTrips.fold<double>(0.0, (sum, t) => sum + (t.effectiveGpsDistanceKm() ?? 0.0));
          final hasWeekGps = weekTrips.any((t) => t.effectiveGpsDistanceKm() != null);
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
                    const SheetDragHandle(width: 40),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Lịch Sử Chuyến Đi',
                                style: AppTypography.bodyLg(color: AppColors.textPrimary).copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Tổng hợp hành trình & hiệu suất xe máy điện',
                                style: AppTypography.labelMd(
                                  color: AppColors.textDim,
                                  fontWeight: FontWeight.w400,
                                ).copyWith(letterSpacing: 0),
                              ),
                            ],
                          ),
                        ),
                        if (history.isNotEmpty)
                          IconButton(
                            tooltip: 'Xóa lịch sử chuyến đi',
                            icon: const Icon(Icons.delete_outline_rounded, color: AppColors.textMuted, size: 20),
                            onPressed: () async {
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (c) => AlertDialog(
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                                  title: Text(
                                    'Xóa Lịch Sử Chuyến Đi',
                                    style: AppTypography.bodyLg(color: AppColors.textPrimary).copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  content: Text(
                                    'Bạn có chắc chắn muốn xóa toàn bộ lịch sử chuyến đi đã lưu trên thiết bị này?',
                                    style: AppTypography.bodyMd(color: AppColors.textDim).copyWith(fontSize: 14),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(c, false),
                                      child: Text('HỦY', style: AppTypography.labelLg(color: AppColors.textDim)),
                                    ),
                                    FilledButton(
                                      style: FilledButton.styleFrom(backgroundColor: AppColors.red),
                                      onPressed: () => Navigator.pop(c, true),
                                      child: Text(
                                        'XÓA HẾT',
                                        style: AppTypography.labelLg(
                                          color: AppColors.onPrimary,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
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
                          icon: const Icon(Icons.close_rounded, color: AppColors.textDim),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Card Tổng hợp tuần này (Dữ liệu thật 100%)
                    Panel(
                      padding: const EdgeInsets.all(16),
                      borderRadius: 18,
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'TUẦN NÀY',
                                style: AppTypography.labelSm(
                                  color: AppColors.textDim,
                                  fontWeight: FontWeight.w700,
                                ).copyWith(letterSpacing: 1.0),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: AppColors.tertiary.withValues(alpha: 0.10),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: AppColors.tertiary.withValues(alpha: 0.30)),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.eco_rounded, size: 12, color: AppColors.tertiary),
                                    const SizedBox(width: 4),
                                    Text(
                                      '-${savedCo2.toStringAsFixed(1)} kg CO₂',
                                      style: AppTypography.labelSm(
                                        color: AppColors.tertiaryContainer,
                                        fontWeight: FontWeight.w700,
                                      ).copyWith(letterSpacing: 0),
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
                                child: _summaryStat(
                                  label: hasWeekGps ? 'ODO (GPS ${weekGpsDist.toStringAsFixed(1)})' : 'Tổng quãng đường',
                                  value: weekDist.toStringAsFixed(1),
                                  unit: 'km',
                                ),
                              ),
                              Container(width: 1, height: 32, color: AppColors.panelBorder),
                              Expanded(
                                child: _summaryStat(label: 'Số chuyến đi', value: '$weekCount', unit: 'chuyến'),
                              ),
                              Container(width: 1, height: 32, color: AppColors.panelBorder),
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
                      style: AppTypography.labelMd(
                        color: AppColors.textDim,
                        fontWeight: FontWeight.w700,
                      ).copyWith(letterSpacing: 1.0),
                    ),
                    const SizedBox(height: 12),

                    // Danh sách chuyến đi thực tế hoặc Empty State trung thực
                    if (history.isEmpty) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
                        decoration: BoxDecoration(
                          color: AppColors.panelSecondary,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: AppColors.panelBorderBright),
                        ),
                        child: Column(
                          children: [
                            const Icon(Icons.route_outlined, size: 44, color: AppColors.textMuted),
                            const SizedBox(height: 12),
                            Text(
                              'Chưa có chuyến đi nào được lưu',
                              style: AppTypography.labelLg(color: AppColors.textDim),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Hành trình chỉ bắt đầu khi xe vào mode chạy với tốc độ ECU > 4 km/h\nvà tự động kết thúc, lưu lịch sử (từ 1 km ODO) khi xe tắt nguồn, ngắt BLE hoặc bấm Đặt lại.',
                              style: AppTypography.labelMd(
                                color: AppColors.textMuted,
                                fontWeight: FontWeight.w400,
                              ).copyWith(height: 1.4, letterSpacing: 0),
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
                        final gpsKm = trip.effectiveGpsDistanceKm();

                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _tripHistoryItem(
                            title: 'Hành trình #${history.length - index}',
                            time: timeStr,
                            distance: '${trip.distanceKm.toStringAsFixed(1)} km',
                            gpsDistance: gpsKm != null ? 'GPS ${gpsKm.toStringAsFixed(1)} km' : null,
                            isRoadSnapped: trip.isGpsRoadSnapped,
                            gpsSignalLossCount: trip.gpsSignalLossCount,
                            avgSpeed: '${trip.avgSpeedKmh.toStringAsFixed(0)} km/h',
                            batteryUsed: trip.usedPercent > 0 ? '-${trip.usedPercent}%' : '--',
                            co2Saved: '$co2 kg',
                            isRecent: isRecent,
                            hasGps: trip.route.isNotEmpty,
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
                            onDelete: () async {
                              final tripNumber = history.length - index;
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (c) => AlertDialog(
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                                  title: Row(
                                    children: [
                                      const Icon(Icons.delete_forever_rounded, color: AppColors.red, size: 22),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          'Xóa Hành Trình #$tripNumber?',
                                          style: AppTypography.bodyLg(color: AppColors.textPrimary).copyWith(
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  content: Text(
                                    'Bạn có chắc chắn muốn xóa vĩnh viễn hành trình #$tripNumber (${trip.distanceKm.toStringAsFixed(1)} km) khỏi bộ nhớ thiết bị?',
                                    style: AppTypography.bodySm(color: AppColors.textDim).copyWith(fontSize: 13.5),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(c, false),
                                      child: Text('HỦY', style: AppTypography.labelLg(color: AppColors.textDim)),
                                    ),
                                    FilledButton(
                                      style: FilledButton.styleFrom(backgroundColor: AppColors.red),
                                      onPressed: () => Navigator.pop(c, true),
                                      child: Text(
                                        'XÓA',
                                        style: AppTypography.labelLg(
                                          color: AppColors.onPrimary,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                              if (confirm == true) {
                                await sheetRef.read(bleProvider.notifier).deleteTrip(trip);
                              }
                            },
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
              style: AppTypography.headlineSm(color: AppColors.textPrimary).copyWith(
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(width: 2),
            Text(
              unit,
              style: AppTypography.labelSm(
                color: AppColors.textDim,
                fontWeight: FontWeight.w600,
              ).copyWith(fontSize: 10.5, letterSpacing: 0),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: AppTypography.labelSm(color: AppColors.textDim).copyWith(fontSize: 10, letterSpacing: 0),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _tripHistoryItem({
    required String title,
    required String time,
    required String distance,
    String? gpsDistance,
    bool isRoadSnapped = false,
    int gpsSignalLossCount = 0,
    required String avgSpeed,
    required String batteryUsed,
    required String co2Saved,
    bool isRecent = false,
    bool hasGps = false,
    VoidCallback? onTap,
    VoidCallback? onDelete,
  }) {
    return Panel(
      padding: const EdgeInsets.all(14),
      borderRadius: 16,
      borderColor: isRecent ? AppColors.primary.withValues(alpha: 0.25) : AppColors.panelBorder,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              TemplateBadgeIcon(
                icon: Icons.two_wheeler_rounded,
                color: isRecent ? AppColors.primary : AppColors.textDim,
                size: 32,
                iconSize: 18,
                borderRadius: 10,
                bordered: false,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            style: AppTypography.labelLg(color: AppColors.textPrimary)
                                .copyWith(fontSize: 13.5, letterSpacing: 0),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        if (hasGps)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: AppColors.tertiary.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: AppColors.tertiary.withValues(alpha: 0.30)),
                            ),
                            child: Text(
                              'GPS',
                              style: AppTypography.headlineSm(color: AppColors.tertiaryContainer).copyWith(
                                fontSize: 9,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      time,
                      style: AppTypography.labelMd(
                        color: AppColors.textDim,
                        fontWeight: FontWeight.w400,
                      ).copyWith(fontSize: 11.5, letterSpacing: 0),
                    ),
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        distance,
                        style: AppTypography.headlineSm(color: AppColors.textPrimary).copyWith(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (gpsDistance != null)
                        Text(
                          gpsDistance,
                          style: AppTypography.labelSm(
                            color: AppColors.tertiaryContainer,
                            fontWeight: FontWeight.w700,
                          ).copyWith(fontSize: 10.5, letterSpacing: 0),
                        ),
                    ],
                  ),
                  if (onDelete != null) ...[
                    const SizedBox(width: 8),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onDelete,
                      child: Container(
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(
                          color: AppColors.red.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(
                          Icons.delete_outline_rounded,
                          size: 16,
                          color: AppColors.red,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _tripBadge(icon: Icons.speed_rounded, label: avgSpeed),
                    _tripBadge(
                      icon: Icons.battery_std_rounded,
                      label: batteryUsed,
                      color: AppColors.tertiary,
                    ),
                    _tripBadge(
                      icon: Icons.eco_rounded,
                      label: '-$co2Saved CO₂',
                      color: AppColors.tertiaryContainer,
                    ),
                    if (isRoadSnapped)
                      _tripBadge(
                        icon: Icons.alt_route_rounded,
                        label: 'Nắn đường',
                        color: AppColors.primary,
                      ),
                    if (gpsSignalLossCount > 0)
                      _tripBadge(
                        icon: Icons.signal_wifi_off_rounded,
                        label: '-$gpsSignalLossCount mất sóng',
                        color: AppColors.amber,
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Bản đồ & Replay',
                    style: AppTypography.labelSm(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w700,
                    ).copyWith(letterSpacing: 0),
                  ),
                  const SizedBox(width: 2),
                  const Icon(
                    Icons.chevron_right_rounded,
                    size: 16,
                    color: AppColors.primary,
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
    Color color = AppColors.textDim,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.panelSecondary,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.panelBorderBright),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: AppTypography.labelSm(
              color: AppColors.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ).copyWith(letterSpacing: 0),
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
              color: active
                  ? (activeColor ?? AppColors.primary.withValues(alpha: 0.08))
                  : AppColors.panelSecondary,
              border: Border.all(
                color: active
                    ? (activeBorderColor ?? AppColors.primary.withValues(alpha: 0.25))
                    : AppColors.panelBorder,
                width: 1,
              ),
              boxShadow: active
                  ? [
                      BoxShadow(
                        color: (activeBorderColor ?? AppColors.primary).withValues(alpha: 0.15),
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
            style: AppTypography.labelMd(
              color: active ? AppColors.textPrimary : AppColors.textDim,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            ).copyWith(fontSize: 11.5, letterSpacing: 0.2),
          ),
        ],
      ),
    );
  }
}
