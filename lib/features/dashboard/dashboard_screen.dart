// Dashboard — Bảng đồng hồ số kỹ thuật số (Digital Cockpit / HUD Mode)
// Thiết kế theo hệ thống Kinetic Stitch EV:
// 1. Tốc độ số + Đo công suất tức thời (kW Xả / kW Phanh tái sinh RECUP).
// 2. Chỉ báo xi-nhan Trái/Phải nhấp nháy + Cảnh báo chân chống trực quan.
// 3. Bản đồ nhiệt 3 điểm (Motor, BMS, ECU) & Bộ giải mã mã lỗi hệ thống OBD.
// 4. Máy tính chuyến đi (Trip Computer): Quãng đường, thời gian, Vmax, Vtb, % pin đã dùng.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/ble/ble_controller.dart';
import '../../core/proto/bike_log.dart';
import '../home/trip_route_screen.dart';
import '../../ui/app_theme.dart';
import '../../ui/gauge.dart';
import '../../ui/widgets.dart';
import 'widgets/cockpit_live_map.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  BikeLogMsg? _msg;
  DateTime? _last;
  StreamSubscription? _sub;
  bool _powerBusy = false;
  int _activeTab = 0; // 0: Cockpit & Chuyến đi, 1: Giám sát nhiệt & Lỗi

  @override
  void initState() {
    super.initState();
    _sub = ref.read(bleProvider.notifier).telemetry.listen((t) {
      if (!mounted) return;
      setState(() {
        _msg = t.bike;
        _last = t.at;
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _turnOnBike() async {
    setState(() => _powerBusy = true);
    try {
      await ref.read(bleProvider.notifier).turnOnBike();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('⚡ Đã gửi lệnh MỞ XE!'),
          backgroundColor: AppColors.tertiary,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Lỗi mở xe: $e'), backgroundColor: AppColors.error),
      );
    } finally {
      if (mounted) setState(() => _powerBusy = false);
    }
  }

  Future<void> _turnOffBike() async {
    final speed = _msg?.speed ?? ref.read(bleProvider).lastTelemetry?.speed ?? 0.0;
    if (speed > 0.5) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('⚠️ CẢNH BÁO AN TOÀN: Không thể tắt xe khi đang chạy (${speed.toStringAsFixed(1)} km/h)!'),
          backgroundColor: AppColors.error,
          duration: const Duration(seconds: 4),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: AppColors.amber, size: 26),
            const SizedBox(width: 10),
            Text(
              'Xác nhận tắt xe',
              style: GoogleFonts.spaceGrotesk(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        content: Text(
          'Bạn có chắc chắn muốn TẮT NGUỒN xe không?\nĐộng cơ sẽ ngắt và xe chuyển sang trạng thái chờ an toàn.',
          style: GoogleFonts.plusJakartaSans(color: AppColors.textDim, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'HỦY',
              style: GoogleFonts.plusJakartaSans(
                color: AppColors.textDim,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: const StadiumBorder(),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              'TẮT XE',
              style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _powerBusy = true);
    try {
      await ref.read(bleProvider.notifier).turnOffBike();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('🔒 Đã gửi lệnh TẮT XE!'), backgroundColor: AppColors.error),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Lỗi tắt xe: $e'), backgroundColor: AppColors.error),
      );
    } finally {
      if (mounted) setState(() => _powerBusy = false);
    }
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (h > 0) return '$h:$m:$s';
    return '$m:$s';
  }

  List<String> _decodeErrors(int errorCode) {
    if (errorCode == 0) return ['✅ Tất cả hệ thống hoạt động hoàn hảo'];
    final errors = <String>[];
    if ((errorCode & (1 << 0)) != 0) errors.add('⚠️ Lỗi cảm biến tay ga (Throttle Fault)');
    if ((errorCode & (1 << 1)) != 0) errors.add('⚠️ Lỗi cảm biến Hall động cơ (Motor Hall)');
    if ((errorCode & (1 << 2)) != 0) errors.add('⚠️ Lỗi quá dòng động cơ (Over-Current)');
    if ((errorCode & (1 << 3)) != 0) errors.add('⚠️ Lỗi quá nhiệt ECU (ECU Overheat)');
    if ((errorCode & (1 << 4)) != 0) errors.add('⚠️ Lỗi giao tiếp BMS (BMS Comm Fault)');
    if ((errorCode & (1 << 5)) != 0) errors.add('⚠️ Lỗi quá nhiệt Pin (Battery Overheat)');
    if ((errorCode & (1 << 6)) != 0) errors.add('⚠️ Cảnh báo điện áp pin thấp (Low Voltage)');
    if ((errorCode & (1 << 7)) != 0) errors.add('⚠️ Lỗi công tắc ngắt phanh (Brake Cutoff)');
    if (errors.isEmpty) errors.add('⚠️ Mã lỗi hệ thống: 0x${errorCode.toRadixString(16).toUpperCase()}');
    return errors;
  }

  String _stateName(BikeState s) => switch (s) {
        BikeState.off => 'TẮT NGUỒN',
        BikeState.standBy => 'CHỜ',
        BikeState.parking => 'ĐỖ XE',
        BikeState.drive => 'DRIVE',
        BikeState.super_ => 'SUPER',
        BikeState.cruiseControl => 'CRUISE',
        BikeState.reverse => 'LÙI',
        BikeState.lock => 'ĐÃ KHÓA',
        BikeState.turtle => 'TIẾT KIỆM (RÙA)',
      };

  Color _stateColor(BikeState s) => switch (s) {
        BikeState.super_ => AppColors.secondary,
        BikeState.drive => AppColors.primary,
        BikeState.parking => AppColors.amber,
        BikeState.off || BikeState.lock => AppColors.error,
        _ => AppColors.textDim,
      };

  @override
  Widget build(BuildContext context) {
    final ble = ref.watch(bleProvider);
    final m = _msg ??
        (ble.lastTelemetry ??
            (BikeLogMsg()
              ..model = (ble.bikeName ?? 'Dat Bike Quantum')
              ..version = '1.14.0'
              ..state = BikeState.standBy));

    final trip = ble.trip;
    final isEncrypted = ble.dashboardEncrypted;

    // Tính công suất tức thời kW: phase < 0 là XẢ (DRAW), phase > 0 là PHANH TÁI SINH (RECUP)
    final powerKw = (m.voltage > 0) ? ((m.voltage * m.phase) / 1000.0) : 0.0;
    final isDraw = powerKw < -0.05; // Đang xả điện chạy động cơ
    final isRecup = powerKw > 0.05; // Đang phanh tái sinh nạp ngược pin

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                boxShadow: const [
                  BoxShadow(color: Color(0x180F172A), blurRadius: 4, offset: Offset(0, 1)),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Image.asset(
                'assets/images/bike_logo_3d.png',
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const Icon(Icons.two_wheeler_rounded, color: AppColors.primary, size: 20),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                (ble.bikeName ?? 'Dat Bike EV').toUpperCase(),
                style: GoogleFonts.spaceGrotesk(
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                  letterSpacing: 0.5,
                  color: AppColors.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.battery_charging_full_rounded),
            tooltip: 'Bác Sĩ Pin & OBD 24-Cell',
            onPressed: () => Navigator.of(context).pushNamed('/battery'),
          ),
          IconButton(
            icon: const Icon(Icons.access_time_rounded),
            tooltip: 'Đồng bộ giờ Taplo xe',
            onPressed: () async {
              final res = await ref.read(bleProvider.notifier).syncTimeWithBike();
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(res),
                  backgroundColor: res.contains('thành công') ? AppColors.tertiary : AppColors.amber,
                  duration: const Duration(seconds: 3),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Đặt lại Trip A',
            onPressed: () {
              ref.read(bleProvider.notifier).resetTrip();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Đã đặt lại đồng hồ chuyến đi Trip A!'), duration: Duration(seconds: 2)),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.tune_rounded),
            tooltip: 'Cài đặt xe & Cảm giác lái',
            onPressed: () => Navigator.of(context).pushNamed('/settings'),
          ),
          IconButton(
            icon: const Icon(Icons.link_off_rounded),
            tooltip: 'Ngắt kết nối',
            onPressed: () async {
              await ref.read(bleProvider.notifier).disconnect();
              if (!context.mounted) return;
              Navigator.of(context).pushReplacementNamed('/scan');
            },
          ),
        ],
      ),
      body: OrientationBuilder(
        builder: (context, orientation) {
          if (orientation == Orientation.landscape) {
            return _buildLandscapeLayout(context, ble, m, trip, powerKw, isRecup, isDraw, isEncrypted);
          }
          return _buildPortraitLayout(context, ble, m, trip, powerKw, isRecup, isDraw, isEncrypted);
        },
      ),
    );
  }

  // ========== BẢN BỐ CỤC DỌC (PORTRAIT COCKPIT) ==========
  Widget _buildPortraitLayout(
    BuildContext context,
    BleState ble,
    BikeLogMsg m,
    TripData trip,
    double powerKw,
    bool isRecup,
    bool isDraw,
    bool isEncrypted,
  ) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 28),
      children: [
        if (ble.phase == BlePhase.reconnecting || ble.phase == BlePhase.disconnected) ...[
          NoticeBanner(
            color: ble.phase == BlePhase.reconnecting ? AppColors.amber : AppColors.error,
            text: ble.message ?? 'Mất kết nối — đang tự kết nối lại…',
            trailing: ble.phase == BlePhase.disconnected
                ? TextButton(
                    onPressed: () => ref.read(bleProvider.notifier).tryRestoreLastBike(),
                    child: Text(
                      'KẾT NỐI LẠI',
                      style: GoogleFonts.plusJakartaSans(
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                        color: AppColors.error,
                      ),
                    ),
                  )
                : null,
          ),
          const SizedBox(height: 10),
        ] else if (isEncrypted) ...[
          const NoticeBanner(
            color: AppColors.secondary,
            text: 'Đã thiết lập phiên làm việc an toàn với xe. Cụm điều khiển sẵn sàng.',
          ),
          const SizedBox(height: 10),
        ],

        // DƯƠNG = sạc vào pin (âm = xả) — verify session 20261022T212957
        if (m.charging != null || m.phase > 0.5) ...[
          NoticeBanner(
            color: AppColors.secondary,
            text: '⚡ Xe đang sạc (${m.charging?.power ?? (m.voltage * m.phase.abs()).round()}W) · Chạm để xem ETA',
            trailing: TextButton(
              onPressed: () => Navigator.of(context).pushNamed('/charging'),
              child: Text(
                'CHI TIẾT',
                style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  color: AppColors.secondary,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
        ],

        // 1. Thanh chỉ báo xi-nhan & trạng thái
        _buildTopIndicators(m),
        const SizedBox(height: 10),

        // 2. Cụm điều khiển nguồn chính
        _buildPowerControls(ble, m),
        const SizedBox(height: 12),

        // 3. Cockpit Gauge Card
        _buildSpeedGaugeCard(m, powerKw, isRecup, isDraw),
        const SizedBox(height: 12),

        // 4. Tab switcher: Chuyến đi & Bản đồ / Sức khỏe OBD
        _buildTabSwitcher(),
        const SizedBox(height: 12),

        // 5. Nội dung theo tab
        if (_activeTab == 0)
          _buildTripPanel(trip, m)
        else
          _buildDiagnosticsPanel(m),
        const SizedBox(height: 12),

        // 6. Thông tin phần cứng & dòng tải
        _buildHardwareInfo(m),
        const SizedBox(height: 14),

        // 7. Footer đồng bộ telemetry
        _buildSyncFooter(ble),
      ],
    );
  }

  // ========== BẢN BỐ CỤC NGANG (LANDSCAPE HUD COCKPIT CHO GIÁ ĐỠ GHI-ĐÔNG) ==========
  Widget _buildLandscapeLayout(
    BuildContext context,
    BleState ble,
    BikeLogMsg m,
    TripData trip,
    double powerKw,
    bool isRecup,
    bool isDraw,
    bool isEncrypted,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Cột trái: Đồng hồ tốc độ HUD lớn & Cụm bật/tắt/còi
        Expanded(
          flex: 48,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 6, 14),
            child: Column(
              children: [
                _buildTopIndicators(m),
                const SizedBox(height: 8),
                Expanded(
                  child: Panel(
                    padding: const EdgeInsets.all(8),
                    borderRadius: 18,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final size = (constraints.maxHeight * 0.72).clamp(110.0, 180.0);
                        return Center(
                          child: SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _buildGaugeWithSpeed(m, gaugeSize: size),
                                const SizedBox(height: 6),
                                _buildPowerBadge(powerKw, isRecup, isDraw),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                _buildPowerControls(ble, m),
              ],
            ),
          ),
        ),

        // Cột phải: Thông số, Thống kê Chuyến đi, Giám sát nhiệt & OBD
        Expanded(
          flex: 52,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(6, 4, 14, 24),
            children: [
              if (ble.phase == BlePhase.reconnecting || ble.phase == BlePhase.disconnected) ...[
                NoticeBanner(
                  color: ble.phase == BlePhase.reconnecting ? AppColors.amber : AppColors.error,
                  text: ble.message ?? 'Mất kết nối — đang tự kết nối lại…',
                  trailing: ble.phase == BlePhase.disconnected
                      ? TextButton(
                          onPressed: () => ref.read(bleProvider.notifier).tryRestoreLastBike(),
                          child: Text(
                            'KẾT NỐI LẠI',
                            style: GoogleFonts.plusJakartaSans(
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                              color: AppColors.error,
                            ),
                          ),
                        )
                      : null,
                ),
                const SizedBox(height: 8),
              ],
              _buildMetricsRow(m),
              const SizedBox(height: 10),
              _buildTabSwitcher(),
              const SizedBox(height: 10),
              if (_activeTab == 0)
                _buildTripPanel(trip, m)
              else
                _buildDiagnosticsPanel(m),
              const SizedBox(height: 10),
              _buildHardwareInfo(m),
              const SizedBox(height: 12),
              _buildSyncFooter(ble),
            ],
          ),
        ),
      ],
    );
  }

  // ========== CÁC WIDGET THÀNH PHẦN CHỐNG TRÀN RESPONSIVE ==========

  Widget _buildTopIndicators(BikeLogMsg m) {
    return Panel(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      borderRadius: 16,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Xi-nhan trái
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: m.left ? AppColors.primary.withValues(alpha: 0.15) : AppColors.panelSecondary,
              borderRadius: BorderRadius.circular(9999),
              border: Border.all(color: m.left ? AppColors.primary : AppColors.panelBorder),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.arrow_back_rounded, size: 13, color: m.left ? AppColors.primary : AppColors.textDim),
                const SizedBox(width: 4),
                Text(
                  'TRÁI',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                    color: m.left ? AppColors.primary : AppColors.textDim,
                  ),
                ),
              ],
            ),
          ),

          // Trạng thái chân chống / Chế độ lái (bọc Flexible + FittedBox chống bể)
          Flexible(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: m.parking
                    ? Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: AppColors.amber.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(9999),
                          border: Border.all(color: AppColors.amber.withValues(alpha: 0.35)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.warning_amber_rounded, size: 14, color: AppColors.amber),
                            const SizedBox(width: 5),
                            Text(
                              'CHÂN CHỐNG HẠ',
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.4,
                                color: AppColors.amber,
                              ),
                            ),
                          ],
                        ),
                      )
                    : StatusPill(label: _stateName(m.state), color: _stateColor(m.state), pulse: m.state == BikeState.drive),
              ),
            ),
          ),

          // Xi-nhan phải
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: m.right ? AppColors.primary.withValues(alpha: 0.15) : AppColors.panelSecondary,
              borderRadius: BorderRadius.circular(9999),
              border: Border.all(color: m.right ? AppColors.primary : AppColors.panelBorder),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'PHẢI',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                    color: m.right ? AppColors.primary : AppColors.textDim,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Icons.arrow_forward_rounded, size: 13, color: m.right ? AppColors.primary : AppColors.textDim),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPowerControls(BleState ble, BikeLogMsg m) {
    return Panel(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      borderRadius: 16,
      child: Row(
        children: [
          Expanded(
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.tertiary,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              icon: const Icon(Icons.power_settings_new_rounded, size: 18),
              label: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  'BẬT XE',
                  style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700, fontSize: 13.5, letterSpacing: 0.4),
                ),
              ),
              onPressed: _powerBusy ? null : _turnOnBike,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: m.speed > 0.5 ? AppColors.textDim : AppColors.error,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              icon: Icon(m.speed > 0.5 ? Icons.shield_rounded : Icons.power_off_rounded, size: 18),
              label: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  m.speed > 0.5 ? 'ĐANG CHẠY' : 'TẮT XE',
                  style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700, fontSize: 13.5, letterSpacing: 0.4),
                ),
              ),
              onPressed: _powerBusy ? null : _turnOffBike,
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            style: IconButton.styleFrom(
              backgroundColor: ble.isFindingBike ? AppColors.amber : AppColors.panelSecondary,
              foregroundColor: ble.isFindingBike ? Colors.black : AppColors.primary,
              padding: const EdgeInsets.all(11),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: ble.isFindingBike ? AppColors.amber : AppColors.panelBorder),
              ),
            ),
            tooltip: ble.isFindingBike ? 'Dừng còi' : 'Tìm xe (Đánh kèn)',
            icon: Icon(ble.isFindingBike ? Icons.notifications_active_rounded : Icons.volume_up_rounded, size: 19),
            onPressed: () async {
              if (ble.isFindingBike) {
                final res = await ref.read(bleProvider.notifier).stopFindBike();
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(res)));
              } else {
                final res = await ref.read(bleProvider.notifier).findBike();
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(res), backgroundColor: AppColors.amber, behavior: SnackBarBehavior.floating),
                );
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildGaugeWithSpeed(
    BikeLogMsg m, {
    required double gaugeSize,
  }) {
    return SpeedGauge(
      size: gaugeSize,
      speed: m.speed,
      center: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            m.speed.toStringAsFixed(1),
            style: GoogleFonts.spaceGrotesk(
              fontSize: (gaugeSize * 0.25).clamp(42.0, 56.0),
              fontWeight: FontWeight.w700,
              height: 1.0,
              color: AppColors.textPrimary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'KM / H',
            style: GoogleFonts.plusJakartaSans(
              color: AppColors.textDim,
              fontSize: (gaugeSize * 0.05).clamp(11.0, 13.0),
              fontWeight: FontWeight.w600,
              letterSpacing: 0.08 * 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPowerBadge(double powerKw, bool isRecup, bool isDraw) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: isRecup
            ? AppColors.tertiary.withValues(alpha: 0.12)
            : isDraw
                ? AppColors.secondary.withValues(alpha: 0.12)
                : AppColors.panelSecondary,
        borderRadius: BorderRadius.circular(9999),
        border: Border.all(
          color: isRecup
              ? AppColors.tertiary
              : isDraw
                  ? AppColors.secondary
                  : AppColors.panelBorder,
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isRecup
                ? Icons.recycling_rounded
                : isDraw
                    ? Icons.electric_bolt_rounded
                    : Icons.remove_rounded,
            size: 14,
            color: isRecup
                ? AppColors.tertiary
                : isDraw
                    ? AppColors.secondary
                    : AppColors.textDim,
          ),
          const SizedBox(width: 5),
          Text(
            isRecup
                ? '+${powerKw.toStringAsFixed(2)} kW RECUP'
                : isDraw
                    ? '${powerKw.abs().toStringAsFixed(2)} kW'
                    : '0.00 kW',
            style: GoogleFonts.spaceGrotesk(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: isRecup
                  ? AppColors.tertiary
                  : isDraw
                      ? AppColors.secondary
                      : AppColors.textDim,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSpeedGaugeCard(
    BikeLogMsg m,
    double powerKw,
    bool isRecup,
    bool isDraw,
  ) {
    return Panel(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 14),
      borderRadius: 20,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final gaugeSize = (constraints.maxWidth * 0.62).clamp(180.0, 230.0);
          return Column(
            children: [
              _buildGaugeWithSpeed(m, gaugeSize: gaugeSize),
              const SizedBox(height: 6),
              _buildPowerBadge(powerKw, isRecup, isDraw),
              const SizedBox(height: 14),
              _buildMetricsRow(m),
            ],
          );
        },
      ),
    );
  }

  Widget _buildMetricsRow(BikeLogMsg m) {
    return Row(
      children: [
        Expanded(
          child: MetricTile(
            icon: Icons.battery_charging_full_rounded,
            label: 'PIN (${m.percent}%)',
            value: m.kmLeft.toStringAsFixed(0),
            unit: 'km',
            valueColor: AppColors.primary,
            accentColor: AppColors.primary,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: MetricTile(
            icon: Icons.electric_bolt_rounded,
            label: 'ĐIỆN ÁP',
            value: m.voltage > 0 ? m.voltage.toStringAsFixed(1) : '—',
            unit: 'V',
            valueColor: AppColors.textPrimary,
            accentColor: AppColors.secondary,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: MetricTile(
            icon: Icons.route_rounded,
            label: 'TỔNG ODO',
            value: m.odo.toStringAsFixed(0),
            unit: 'km',
            accentColor: AppColors.tertiary,
          ),
        ),
      ],
    );
  }

  void _openFullScreenMap(TripData trip) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const TripRouteScreen(),
      ),
    );
  }

  Widget _buildTabSwitcher() {
    return Row(
      children: [
        // Tab 0: CHUYẾN ĐI (TRIP A) & BẢN ĐỒ LIVE
        Expanded(
          child: _tabButton(
            index: 0,
            icon: Icons.route_rounded,
            label: 'CHUYẾN ĐI (TRIP A)',
          ),
        ),
        const SizedBox(width: 8),
        // Tab 1: SỨC KHỎE & MÃ LỖI
        Expanded(
          child: _tabButton(
            index: 1,
            icon: Icons.health_and_safety_rounded,
            label: 'SỨC KHỎE & MÃ LỖI',
          ),
        ),
      ],
    );
  }

  Widget _tabButton({
    required int index,
    required IconData icon,
    required String label,
  }) {
    final isSelected = _activeTab == index;
    return InkWell(
      borderRadius: BorderRadius.circular(9999),
      onTap: () => setState(() => _activeTab = index),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFF0F9FF) : AppColors.panel,
          borderRadius: BorderRadius.circular(9999),
          border: Border.all(
            color: isSelected ? AppColors.secondary : AppColors.panelBorder,
            width: 1,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 13,
              color: isSelected ? AppColors.primary : AppColors.textDim,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  maxLines: 1,
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: isSelected ? AppColors.primary : AppColors.textDim,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTripPanel(TripData trip, BikeLogMsg m) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CockpitLiveMap(
          currentSpeedKmh: m.speed,
          onExpandFullScreen: () => _openFullScreenMap(trip),
        ),
        const SizedBox(height: 12),
        Panel(
          padding: const EdgeInsets.all(14),
          borderRadius: 20,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.timer_outlined, size: 18, color: AppColors.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'THỐNG KÊ CHUYẾN ĐI',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.05 * 12,
                        color: AppColors.textDim,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _formatDuration(trip.duration),
                    style: GoogleFonts.spaceGrotesk(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      color: AppColors.primary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: MetricTile(
                      icon: Icons.navigation_rounded,
                      label: 'QUÃNG ĐƯỜNG',
                      value: trip.distanceKm.toStringAsFixed(2),
                      unit: 'km',
                      valueColor: AppColors.primary,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: MetricTile(
                      icon: Icons.speed_rounded,
                      label: 'VẬN TỐC MAX',
                      value: trip.maxSpeedKmh.toStringAsFixed(1),
                      unit: 'km/h',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: MetricTile(
                      icon: Icons.timeline_rounded,
                      label: 'VẬN TỐC TB',
                      value: trip.avgSpeedKmh.toStringAsFixed(1),
                      unit: 'km/h',
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: MetricTile(
                      icon: Icons.battery_alert_rounded,
                      label: 'TIÊU HAO PIN',
                      value: '-${trip.usedPercent}',
                      unit: '% pin',
                      valueColor: AppColors.amber,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDiagnosticsPanel(BikeLogMsg m) {
    return Panel(
      padding: const EdgeInsets.all(14),
      borderRadius: 20,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle('GIÁM SÁT NHIỆT ĐỘ 3 ĐIỂM'),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: MetricTile(
                  icon: Icons.thermostat_rounded,
                  label: 'NHIỆT ECU',
                  value: '${m.ecu.toStringAsFixed(0)}°',
                  valueColor: m.ecu > 65 ? AppColors.error : (m.ecu > 55 ? AppColors.amber : AppColors.textPrimary),
                  accentColor: m.ecu > 65 ? AppColors.error : AppColors.secondary,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: MetricTile(
                  icon: Icons.device_thermostat_rounded,
                  label: 'NHIỆT MOTOR',
                  value: '${m.motor.toStringAsFixed(0)}°',
                  valueColor: m.motor > 75 ? AppColors.error : (m.motor > 60 ? AppColors.amber : AppColors.textPrimary),
                  accentColor: m.motor > 75 ? AppColors.error : AppColors.primary,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: MetricTile(
                  icon: Icons.battery_std_rounded,
                  label: 'NHIỆT BMS',
                  value: '${m.bmsTemp.toStringAsFixed(0)}°',
                  valueColor: m.bmsTemp > 50 ? AppColors.error : (m.bmsTemp > 45 ? AppColors.amber : AppColors.textPrimary),
                  accentColor: m.bmsTemp > 50 ? AppColors.error : AppColors.amber,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Divider(color: AppColors.panelBorder),
          const SizedBox(height: 12),

          const SectionTitle('CHẨN ĐOÁN & MÃ LỖI HỆ THỐNG'),
          const SizedBox(height: 8),
          for (final errLine in _decodeErrors(m.error))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(
                    m.error == 0 ? Icons.check_circle_rounded : Icons.error_outline_rounded,
                    size: 18,
                    color: m.error == 0 ? AppColors.tertiary : AppColors.error,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      errLine,
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: m.error == 0 ? AppColors.tertiary : AppColors.error,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primary,
                side: const BorderSide(color: AppColors.primary, width: 1.2),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              icon: const Icon(Icons.battery_charging_full_rounded, size: 18),
              label: Text(
                'MỞ BÁC SĨ PIN 24-CELL & OBD CHI TIẾT',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
              ),
              onPressed: () => Navigator.of(context).pushNamed('/battery'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHardwareInfo(BikeLogMsg m) {
    return Panel(
      padding: const EdgeInsets.symmetric(vertical: 4),
      borderRadius: 20,
      child: Column(
        children: [
          _infoRow('Dòng điện tải (Phase)', '${m.phase.toStringAsFixed(1)} A'),
          _divider(),
          _infoRow('Chân chống xe', m.parking ? 'Đang hạ (Đỗ xe)' : 'Đã gạt lên (Sẵn sàng)',
              valueColor: m.parking ? AppColors.amber : AppColors.tertiary),
          _divider(),
          _infoRow('Xi-nhan & Đèn',
              '${m.left ? "← Trái  " : ""}${m.right ? "Phải →  " : ""}${!m.left && !m.right ? "Tắt" : ""}'),
          _divider(),
          _infoRow('Số khung xe', m.frame.isEmpty ? '—' : m.frame),
          _divider(),
          _infoRow('Phiên bản Firmware', m.version.isEmpty ? '1.14.0' : m.version),
        ],
      ),
    );
  }

  Widget _buildSyncFooter(BleState ble) {
    final telemetryTime = _last == null
        ? 'Đang nhận telemetry…'
        : 'Telemetry: ${_last!.toLocal().toString().substring(11, 19)}';
    final taploTime = ble.lastTimeSynced == null
        ? ''
        : ' · Taplo: ${ble.lastTimeSynced!.hour.toString().padLeft(2, '0')}:${ble.lastTimeSynced!.minute.toString().padLeft(2, '0')}:${ble.lastTimeSynced!.second.toString().padLeft(2, '0')}';
    final rssiStr = ble.filteredRssi != null ? ' · Sóng: ${ble.filteredRssi} dBm' : '';

    return Text(
      '$telemetryTime$taploTime$rssiStr',
      textAlign: TextAlign.center,
      style: GoogleFonts.spaceGrotesk(
        fontSize: 11.5,
        color: AppColors.textDim,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }

  Widget _infoRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Text(label, style: GoogleFonts.plusJakartaSans(color: AppColors.textDim, fontSize: 13.5)),
          const Spacer(),
          Text(
            value,
            style: GoogleFonts.spaceGrotesk(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: valueColor ?? AppColors.textPrimary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider() => const Divider(height: 1, indent: 16, endIndent: 16, color: AppColors.panelBorder);
}
