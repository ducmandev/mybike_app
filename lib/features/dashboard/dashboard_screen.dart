// Dashboard — Bảng đồng hồ số kỹ thuật số (Digital Cockpit / HUD Mode)
// Thiết kế theo hệ thống Kinetic Stitch EV - Phiên bản Cockpit v6:
// 1. Tốc độ số + Đo công suất tức thời (Luminous Energy Beam RECUP/PWR loang màu quang học, không border).
// 2. Vết ánh sáng tỏa ra của xi-nhan cam đỏ nhẹ (Optical Ambient Light Bloom).
// 3. Chế độ lái (Mode) nằm ở chính giữa phía trên taplo tốc độ (không viền, hiệu ứng trượt mờ dần).
// 4. Bố cục ngang (Landscape) chuẩn 70% Cụm đồng hồ tốc độ / 30% Bản đồ GPS & 3 nút Bật/Tắt/Khóa xe (ẩn còi).
// 5. Bản đồ GPS tích hợp mũi tên la bàn xoay tự động và đồ thị tốc độ GPS độc lập (Sparkline).

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
import 'widgets/luminous_energy_bar.dart';
import 'widgets/mode_indicator_header.dart';
import 'widgets/optical_signal_bloom.dart';

/// Chế độ hiển thị phóng to độc lập của màn hình Cockpit:
/// - normal: Mặc định chia 2 phần (Dọc: Scrollable tab; Ngang: 70/30)
/// - speedometer: Phóng to toàn màn hình Cụm đồng hồ tốc độ (Speedometer HUD)
/// - map: Phóng to toàn màn hình Bản đồ GPS trực tiếp (Cockpit Live Map)
enum DashboardFocusMode {
  normal,
  speedometer,
  map,
}

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
  DashboardFocusMode _focusMode = DashboardFocusMode.normal;

  void _toggleSpeedZoom() {
    setState(() {
      _focusMode = _focusMode == DashboardFocusMode.speedometer
          ? DashboardFocusMode.normal
          : DashboardFocusMode.speedometer;
    });
  }

  void _toggleMapZoom() {
    setState(() {
      _focusMode = _focusMode == DashboardFocusMode.map
          ? DashboardFocusMode.normal
          : DashboardFocusMode.map;
    });
  }

  Widget _miniGlassActionBtn({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.panel.withValues(alpha: 0.94),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.panelBorderBright, width: 1),
              boxShadow: AppColors.cardShadow,
            ),
            child: Icon(icon, size: 20, color: AppColors.textPrimary),
          ),
        ),
      ),
    );
  }

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

  String _cleanErrorMsg(dynamic e) {
    final s = e.toString();
    return s.replaceFirst(RegExp(r'^(Exception|TimeoutException):\s*'), '');
  }

  Future<void> _turnOnBike() async {
    setState(() => _powerBusy = true);
    try {
      await ref.read(bleProvider.notifier).turnOnBike().timeout(
        const Duration(seconds: 6),
        onTimeout: () => throw TimeoutException('Lệnh mở xe quá thời gian phản hồi (6s). Vui lòng thử lại.'),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('⚡ Đã gửi lệnh MỞ XE (READY)!'),
          backgroundColor: AppColors.tertiary,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Lỗi mở xe: ${_cleanErrorMsg(e)}'), backgroundColor: AppColors.error),
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
      await ref.read(bleProvider.notifier).turnOffBike().timeout(
        const Duration(seconds: 6),
        onTimeout: () => throw TimeoutException('Lệnh tắt xe quá thời gian phản hồi (6s). Vui lòng thử lại.'),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🔒 Đã gửi lệnh TẮT XE an toàn!'),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Lỗi tắt xe: ${_cleanErrorMsg(e)}'), backgroundColor: AppColors.error),
      );
    } finally {
      if (mounted) setState(() => _powerBusy = false);
    }
  }

  Future<void> _toggleLockBike(BleState ble, BikeLogMsg m) async {
    if (!ble.bikeModel.supportsImmobilizerLock) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Dòng xe ${ble.bikeModel.displayName} không hỗ trợ khóa chống trộm điện tử.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    final currentlyLocked = ble.isLocked || m.state == BikeState.lock;
    setState(() => _powerBusy = true);
    try {
      if (currentlyLocked) {
        final res = await ref.read(bleProvider.notifier).unlockBike().timeout(
          const Duration(seconds: 6),
          onTimeout: () => 'Lệnh mở khóa quá thời gian chờ (6s). Vui lòng thử lại.',
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('🔓 $res'),
            backgroundColor: AppColors.tertiary,
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else {
        final res = await ref.read(bleProvider.notifier).lockBike().timeout(
          const Duration(seconds: 6),
          onTimeout: () => 'Lệnh khóa xe quá thời gian chờ (6s). Vui lòng thử lại.',
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('🔒 $res'),
            backgroundColor: AppColors.amber,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Lỗi thao tác khóa xe: ${_cleanErrorMsg(e)}'), backgroundColor: AppColors.error),
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
              child: Text.rich(
                TextSpan(
                  text: (ble.bikeName ?? 'Dat Bike EV').toUpperCase(),
                  style: GoogleFonts.spaceGrotesk(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                    letterSpacing: 0.5,
                    color: AppColors.textPrimary,
                  ),
                  children: [
                    const WidgetSpan(child: SizedBox(width: 6)),
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(5),
                          border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
                        ),
                        child: Text(
                          ble.bikeModel.code,
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                    ),
                  ],
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

  // =========================================================================
  // ========== BẢN BỐ CỤC DỌC (PORTRAIT COCKPIT) =============================
  // =========================================================================
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
    final isLocked = ble.isLocked || m.state == BikeState.lock;

    if (_focusMode == DashboardFocusMode.speedometer) {
      return _buildPortraitSpeedZoomLayout(
        context, ble, m, trip, powerKw, isRecup, isDraw, isLocked,
      );
    }

    if (_focusMode == DashboardFocusMode.map) {
      return _buildPortraitMapZoomLayout(
        context, ble, m, trip, isLocked,
      );
    }

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


        // 1. Cụm 3 nút điều khiển chính nằm 1 hàng ngang (Bật, Tắt, Khóa - ẩn còi)
        _buildControlButtonsRow(ble, m),
        const SizedBox(height: 10),

        // 2. Cockpit Speedometer Card với hiệu ứng quang học:
        // - Vết ánh sáng tỏa ra của xi-nhan cam đỏ nhẹ (OpticalSignalBloom).
        // - Mode xe nằm ở chính giữa phía trên taplo (không border).
        // - SpeedGauge trung tâm.
        // - LuminousEnergyBar nạp xả loang màu không border.
        // - Metric row: PIN, ĐIỆN ÁP, TỔNG ODO.
        OpticalSignalBloom(
          isLeft: m.left,
          isRight: m.right,
          child: Panel(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
            borderRadius: 22,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final gaugeSize = (constraints.maxWidth * 0.60).clamp(170.0, 225.0);

                return Column(
                  children: [
                    // Top row: 3D Bike Logo + Tên xe bên trái & Nút phóng to bên phải (Rõ ràng, không bị che khuất)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Flexible(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 26,
                                height: 26,
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
                                  errorBuilder: (_, _, _) => const Icon(Icons.two_wheeler_rounded, color: AppColors.primary, size: 18),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  (ble.bikeName ?? 'Dat Bike EV').toUpperCase(),
                                  style: GoogleFonts.spaceGrotesk(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.5,
                                    color: AppColors.textPrimary,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (m.parking) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: AppColors.amber.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(9999),
                                  ),
                                  child: Text(
                                    'CHỐNG',
                                    style: GoogleFonts.plusJakartaSans(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.amber,
                                    ),
                                  ),
                                ),
                              ],
                              if (isLocked) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: AppColors.error.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(9999),
                                  ),
                                  child: Text(
                                    'ĐÃ KHÓA',
                                    style: GoogleFonts.plusJakartaSans(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.error,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        _miniGlassActionBtn(
                          icon: Icons.fullscreen_rounded,
                          tooltip: 'Phóng to đồng hồ tốc độ',
                          onTap: _toggleSpeedZoom,
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),

                    // Mode xe nằm ở chính giữa phía trên taplo tốc độ
                    ModeIndicatorHeader(
                      state: m.state,
                      isParking: m.parking,
                      isLocked: isLocked,
                    ),
                    const SizedBox(height: 6),

                    // Vòng cung tốc độ
                    _buildGaugeWithSpeed(m, gaugeSize: gaugeSize),
                    const SizedBox(height: 6),

                    // Thanh nạp xả loang màu không border
                    SizedBox(
                      width: constraints.maxWidth.clamp(160.0, 360.0),
                      child: LuminousEnergyBar(
                        powerKw: powerKw,
                        isRecup: isRecup,
                        isDraw: isDraw,
                        phaseAmps: m.phase,
                        voltage: m.voltage > 0 ? m.voltage : null,
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Hàng metric: Pin, Điện áp, ODO
                    _buildMetricsRow(m),
                  ],
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 12),

        // 3. Tab switcher: Chuyến đi & Bản đồ / Sức khỏe OBD
        _buildTabSwitcher(),
        const SizedBox(height: 12),

        // 4. Nội dung theo tab
        if (_activeTab == 0)
          _buildTripPanel(trip, m)
        else
          _buildDiagnosticsPanel(m),
        const SizedBox(height: 12),

        // 5. Thông tin phần cứng & dòng tải
        _buildHardwareInfo(m),
        const SizedBox(height: 14),

        // 6. Footer đồng bộ telemetry
        _buildSyncFooter(ble),
      ],
    );
  }

  // =========================================================================
  // ========== BẢN BỐ CỤC NGANG (LANDSCAPE HUD COCKPIT 70% / 30%) ============
  // =========================================================================
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
    final isLocked = ble.isLocked || m.state == BikeState.lock;

    if (_focusMode == DashboardFocusMode.speedometer) {
      return _buildLandscapeSpeedZoomLayout(
        context, ble, m, trip, powerKw, isRecup, isDraw, isLocked,
      );
    }

    if (_focusMode == DashboardFocusMode.map) {
      return _buildLandscapeMapZoomLayout(
        context, ble, m, trip, isLocked,
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ==================== 70% BÊN TRÁI: CỤM ĐỒNG HỒ TỐC ĐỘ ====================
          Expanded(
            flex: 70,
            child: OpticalSignalBloom(
              isLeft: m.left,
              isRight: m.right,
              child: Panel(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                borderRadius: 22,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final gaugeSize = (constraints.maxHeight * 0.50).clamp(115.0, 175.0);

                    return Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // 1. Top row: Tên xe, Chân chống, Khóa + PIN & Volt
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: SizedBox(
                            width: constraints.maxWidth,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Flexible(
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        width: 7,
                                        height: 7,
                                        decoration: const BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: AppColors.tertiary,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Flexible(
                                        child: Text(
                                          (ble.bikeName ?? 'Dat Bike EV').toUpperCase(),
                                          style: GoogleFonts.spaceGrotesk(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                            color: AppColors.textPrimary,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      if (m.parking) ...[
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: AppColors.amber.withValues(alpha: 0.15),
                                            borderRadius: BorderRadius.circular(9999),
                                          ),
                                          child: Text(
                                            'CHỐNG',
                                            style: GoogleFonts.plusJakartaSans(
                                              fontSize: 9,
                                              fontWeight: FontWeight.w700,
                                              color: AppColors.amber,
                                            ),
                                          ),
                                        ),
                                      ],
                                      if (isLocked) ...[
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: AppColors.error.withValues(alpha: 0.15),
                                            borderRadius: BorderRadius.circular(9999),
                                          ),
                                          child: Text(
                                            'ĐÃ KHÓA',
                                            style: GoogleFonts.plusJakartaSans(
                                              fontSize: 9,
                                              fontWeight: FontWeight.w700,
                                              color: AppColors.error,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                // Pin & Range & Phóng to
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      'PIN: ',
                                      style: GoogleFonts.plusJakartaSans(fontSize: 11, color: AppColors.textDim),
                                    ),
                                    Text(
                                      '${m.percent}%',
                                      style: GoogleFonts.spaceGrotesk(
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w800,
                                        color: AppColors.tertiary,
                                        fontFeatures: const [FontFeature.tabularFigures()],
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      '(${m.kmLeft.toStringAsFixed(0)} km)',
                                      style: GoogleFonts.plusJakartaSans(fontSize: 11, color: AppColors.textDim),
                                    ),
                                    const SizedBox(width: 8),
                                    _miniGlassActionBtn(
                                      icon: Icons.fullscreen_rounded,
                                      tooltip: 'Phóng to đồng hồ tốc độ',
                                      onTap: _toggleSpeedZoom,
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),

                        // 2. KHU VỰC TRUNG TÂM: MODE Ở GIỮA PHÍA TRÊN + GAUGE + LUMINOUS ENERGY BAR
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ModeIndicatorHeader(
                              state: m.state,
                              isParking: m.parking,
                              isLocked: isLocked,
                            ),
                            const SizedBox(height: 4),

                            _buildGaugeWithSpeed(m, gaugeSize: gaugeSize),
                            const SizedBox(height: 4),

                            SizedBox(
                              width: constraints.maxWidth.clamp(160.0, 340.0),
                              child: LuminousEnergyBar(
                                powerKw: powerKw,
                                isRecup: isRecup,
                                isDraw: isDraw,
                                phaseAmps: m.phase,
                                voltage: m.voltage > 0 ? m.voltage : null,
                              ),
                            ),
                          ],
                        ),

                        // 3. Dòng đáy: Trip A & ODO
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: SizedBox(
                              width: constraints.maxWidth,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    'TRIP A: ${trip.distanceKm.toStringAsFixed(1)} km (${_formatDuration(trip.duration)})',
                                    style: GoogleFonts.spaceGrotesk(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.textDim,
                                      fontFeatures: const [FontFeature.tabularFigures()],
                                    ),
                                  ),
                                  Text(
                                    'TỔNG ODO: ${m.odo.toStringAsFixed(0)} km',
                                    style: GoogleFonts.spaceGrotesk(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.textDim,
                                      fontFeatures: const [FontFeature.tabularFigures()],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),

          const SizedBox(width: 10),

          // ==================== 30% BÊN PHẢI: CHIA 2 ====================
          // Phần trên: Bản đồ thông tin GPS (Live map + GPS Speed sparkline)
          // Phần dưới: 3 nút Bật, Tắt, Khóa xe (Ẩn còi)
          Expanded(
            flex: 30,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 62,
                  child: CockpitLiveMap(
                    currentSpeedKmh: m.speed,
                    onExpandFullScreen: _toggleMapZoom,
                  ),
                ),
                const SizedBox(height: 8),

                _buildControlButtonsRow(ble, m),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // =========================================================================
  // ========== CỤM 3 NÚT ĐIỀU KHIỂN CHÍNH NẰM CÙNG 1 HÀNG (ẨN CÒI) ===========
  // =========================================================================
  Widget _buildControlButtonsRow(BleState ble, BikeLogMsg m) {
    final isLocked = ble.isLocked || m.state == BikeState.lock;
    final isRunning = m.speed > 0.5;

    return Panel(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      borderRadius: 18,
      child: Row(
        children: [
          // 1. BẬT XE (READY)
          Expanded(
            child: Tooltip(
              message: 'Bật máy (Ready)',
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.tertiary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: _powerBusy ? null : _turnOnBike,
                child: const Icon(Icons.power_settings_new_rounded, size: 22),
              ),
            ),
          ),
          const SizedBox(width: 8),

          // 2. TẮT XE
          Expanded(
            child: Tooltip(
              message: isRunning ? 'Đang chạy' : 'Tắt nguồn xe',
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: isRunning ? AppColors.surfaceContainerHigh : AppColors.error,
                  foregroundColor: isRunning ? AppColors.textDim : Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: (_powerBusy || isRunning) ? null : _turnOffBike,
                child: Icon(isRunning ? Icons.shield_rounded : Icons.power_off_rounded, size: 22),
              ),
            ),
          ),
          const SizedBox(width: 8),

          // 3. KHÓA XE (LOCK / UNLOCK - ẨN CÒI - CHỈ CHO DÒNG CÓ HỖ TRỢ KHÓA ĐIỆN TỬ)
          if (ble.bikeModel.supportsImmobilizerLock)
            Expanded(
              child: Tooltip(
                message: isLocked ? 'Mở khóa an toàn' : 'Khóa xe (Anti-theft)',
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isLocked ? AppColors.error : AppColors.surfaceContainerHigh,
                    foregroundColor: isLocked ? Colors.white : AppColors.textPrimary,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: _powerBusy ? null : () => _toggleLockBike(ble, m),
                  child: Icon(
                    isLocked ? Icons.lock_open_rounded : Icons.lock_outline_rounded,
                    size: 22,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // =========================================================================
  // ========== BẢN BỐ CỤC PHÓNG TO ĐỘC LẬP (INDEPENDENT ZOOM MODES) =========
  // =========================================================================

  /// 1. Phóng to riêng Cụm đồng hồ tốc độ ở chế độ dọc (Portrait Speedometer Zoom)
  Widget _buildPortraitSpeedZoomLayout(
    BuildContext context,
    BleState ble,
    BikeLogMsg m,
    TripData trip,
    double powerKw,
    bool isRecup,
    bool isDraw,
    bool isLocked,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 18),
      child: Column(
        children: [
          Expanded(
            child: OpticalSignalBloom(
              isLeft: m.left,
              isRight: m.right,
              child: Panel(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                borderRadius: 22,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final gaugeSize = (constraints.maxHeight * 0.44).clamp(180.0, 280.0);
                    return Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // Top bar inside panel: Vehicle name & Exit zoom button
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Flexible(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 26,
                                    height: 26,
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
                                      errorBuilder: (_, _, _) => const Icon(Icons.two_wheeler_rounded, color: AppColors.primary, size: 18),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      (ble.bikeName ?? 'Dat Bike EV').toUpperCase(),
                                      style: GoogleFonts.spaceGrotesk(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.textPrimary,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (m.parking) ...[
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: AppColors.amber.withValues(alpha: 0.15),
                                        borderRadius: BorderRadius.circular(9999),
                                      ),
                                      child: Text(
                                        'CHỐNG',
                                        style: GoogleFonts.plusJakartaSans(
                                          fontSize: 9.5,
                                          fontWeight: FontWeight.w700,
                                          color: AppColors.amber,
                                        ),
                                      ),
                                    ),
                                  ],
                                  if (isLocked) ...[
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: AppColors.error.withValues(alpha: 0.15),
                                        borderRadius: BorderRadius.circular(9999),
                                      ),
                                      child: Text(
                                        'ĐÃ KHÓA',
                                        style: GoogleFonts.plusJakartaSans(
                                          fontSize: 9.5,
                                          fontWeight: FontWeight.w700,
                                          color: AppColors.error,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            _miniGlassActionBtn(
                              icon: Icons.fullscreen_exit_rounded,
                              tooltip: 'Thu nhỏ về mặc định',
                              onTap: _toggleSpeedZoom,
                            ),
                          ],
                        ),

                        // Center: Mode + Large Gauge + Energy bar
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ModeIndicatorHeader(
                              state: m.state,
                              isParking: m.parking,
                              isLocked: isLocked,
                            ),
                            const SizedBox(height: 8),
                            _buildGaugeWithSpeed(m, gaugeSize: gaugeSize),
                            const SizedBox(height: 8),
                            SizedBox(
                              width: constraints.maxWidth.clamp(180.0, 360.0),
                              child: LuminousEnergyBar(
                                powerKw: powerKw,
                                isRecup: isRecup,
                                isDraw: isDraw,
                                phaseAmps: m.phase,
                                voltage: m.voltage > 0 ? m.voltage : null,
                              ),
                            ),
                          ],
                        ),

                        // Bottom: Metrics row
                        _buildMetricsRow(m),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          _buildControlButtonsRow(ble, m),
        ],
      ),
    );
  }

  /// 2. Phóng to riêng Bản đồ GPS ở chế độ dọc (Portrait Map Zoom)
  Widget _buildPortraitMapZoomLayout(
    BuildContext context,
    BleState ble,
    BikeLogMsg m,
    TripData trip,
    bool isLocked,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 18),
      child: CockpitLiveMap(
        height: double.infinity,
        isFullScreen: true,
        currentSpeedKmh: m.speed,
        batteryPercent: m.percent,
        voltage: m.voltage > 0 ? m.voltage : null,
        onExpandFullScreen: _toggleMapZoom,
      ),
    );
  }

  /// 3. Phóng to riêng Cụm đồng hồ tốc độ ở chế độ ngang (Landscape Speedometer Zoom - 100% full-width)
  Widget _buildLandscapeSpeedZoomLayout(
    BuildContext context,
    BleState ble,
    BikeLogMsg m,
    TripData trip,
    double powerKw,
    bool isRecup,
    bool isDraw,
    bool isLocked,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      child: OpticalSignalBloom(
        isLeft: m.left,
        isRight: m.right,
        child: Panel(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          borderRadius: 22,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final gaugeSize = (constraints.maxHeight * 0.52).clamp(130.0, 195.0);
              return Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Top row: Bike info, Lock status, PIN & Exit zoom button
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 24,
                              height: 24,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(6),
                                boxShadow: const [
                                  BoxShadow(color: Color(0x180F172A), blurRadius: 3, offset: Offset(0, 1)),
                                ],
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: Image.asset(
                                'assets/images/bike_logo_3d.png',
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => const Icon(Icons.two_wheeler_rounded, color: AppColors.primary, size: 16),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                (ble.bikeName ?? 'Dat Bike EV').toUpperCase(),
                                style: GoogleFonts.spaceGrotesk(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.textPrimary,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (m.parking) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppColors.amber.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(9999),
                                ),
                                child: Text(
                                  'CHỐNG',
                                  style: GoogleFonts.plusJakartaSans(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.amber,
                                  ),
                                ),
                              ),
                            ],
                            if (isLocked) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppColors.error.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(9999),
                                ),
                                child: Text(
                                  'ĐÃ KHÓA',
                                  style: GoogleFonts.plusJakartaSans(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.error,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('PIN: ', style: GoogleFonts.plusJakartaSans(fontSize: 11, color: AppColors.textDim)),
                          Text(
                            '${m.percent}%',
                            style: GoogleFonts.spaceGrotesk(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w800,
                              color: AppColors.tertiary,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text('(${m.kmLeft.toStringAsFixed(0)} km)', style: GoogleFonts.plusJakartaSans(fontSize: 11, color: AppColors.textDim)),
                          const SizedBox(width: 10),
                          _miniGlassActionBtn(
                            icon: Icons.fullscreen_exit_rounded,
                            tooltip: 'Thu nhỏ về mặc định',
                            onTap: _toggleSpeedZoom,
                          ),
                        ],
                      ),
                    ],
                  ),

                  // Center: Mode + Gauge + Energy bar
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ModeIndicatorHeader(
                        state: m.state,
                        isParking: m.parking,
                        isLocked: isLocked,
                      ),
                      const SizedBox(height: 4),
                      _buildGaugeWithSpeed(m, gaugeSize: gaugeSize),
                      const SizedBox(height: 4),
                      SizedBox(
                        width: constraints.maxWidth.clamp(180.0, 420.0),
                        child: LuminousEnergyBar(
                          powerKw: powerKw,
                          isRecup: isRecup,
                          isDraw: isDraw,
                          phaseAmps: m.phase,
                          voltage: m.voltage > 0 ? m.voltage : null,
                        ),
                      ),
                    ],
                  ),

                  // Bottom: Trip A & ODO
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'TRIP A: ${trip.distanceKm.toStringAsFixed(1)} km (${_formatDuration(trip.duration)})',
                          style: GoogleFonts.spaceGrotesk(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textDim,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        Text(
                          'TỔNG ODO: ${m.odo.toStringAsFixed(0)} km',
                          style: GoogleFonts.spaceGrotesk(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textDim,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// 4. Phóng to riêng Bản đồ GPS ở chế độ ngang (Landscape Map Zoom - 100% full-width)
  Widget _buildLandscapeMapZoomLayout(
    BuildContext context,
    BleState ble,
    BikeLogMsg m,
    TripData trip,
    bool isLocked,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      child: CockpitLiveMap(
        height: double.infinity,
        isFullScreen: true,
        currentSpeedKmh: m.speed,
        batteryPercent: m.percent,
        voltage: m.voltage > 0 ? m.voltage : null,
        onExpandFullScreen: _toggleMapZoom,
      ),
    );
  }

  // =========================================================================
  // ========== CÁC WIDGET THÀNH PHẦN ========================================
  // =========================================================================

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
            m.speed.toStringAsFixed(0),
            style: GoogleFonts.spaceGrotesk(
              fontSize: (gaugeSize * 0.28).clamp(36.0, 56.0),
              fontWeight: FontWeight.w700,
              height: 1.0,
              color: AppColors.textPrimary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 3),
          Text(
            'KM / H',
            style: GoogleFonts.plusJakartaSans(
              color: AppColors.textDim,
              fontSize: (gaugeSize * 0.05).clamp(10.0, 12.0),
              fontWeight: FontWeight.w700,
              letterSpacing: 0.08 * 12,
            ),
          ),
        ],
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
        Expanded(
          child: _tabButton(
            index: 0,
            icon: Icons.route_rounded,
            label: 'CHUYẾN ĐI (TRIP A)',
          ),
        ),
        const SizedBox(width: 8),
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
          onExpandFullScreen: _toggleMapZoom,
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
                  Tooltip(
                    message: 'Xem toàn bộ lộ trình chi tiết',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => _openFullScreenMap(trip),
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(Icons.open_in_new_rounded, size: 16, color: AppColors.primary),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
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
