// Vehicle Settings & Customization Screen — Cài Đặt Hiệu Năng & Cá Nhân Hóa Xe
// Chuẩn thiết kế Kinetic Stitch EV:
// 1. Tinh chỉnh cảm giác lái: Mức phanh tái sinh RECUP, Độ nhạy tay ga, Giới hạn tốc độ an toàn.
// 2. Chế độ âm thanh còi tìm xe: Mẫu nhịp tiêu chuẩn, Nhịp đôi Staccato, Báo động dồn dập SOS.
// 3. Thông tin xe & Serial khung sườn từ firmware xe (deviceSerialChar).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/ble/ble_controller.dart';
import '../../ui/app_theme.dart';
import '../../ui/widgets.dart';
import '../firmware_lab/firmware_lab_screen.dart';
import '../logs/logs_screen.dart';

class VehicleSettingsScreen extends ConsumerStatefulWidget {
  const VehicleSettingsScreen({super.key});

  @override
  ConsumerState<VehicleSettingsScreen> createState() => _VehicleSettingsScreenState();
}

class _VehicleSettingsScreenState extends ConsumerState<VehicleSettingsScreen> {
  bool _isReadingSerial = false;
  bool _isSyncingTime = false;
  bool _isRefreshingDiagnostics = false;

  @override
  void initState() {
    super.initState();
    // Mở screen khi đang kết nối → đọc giá trị settings THẬT từ xe
    // (đè cache local trong prefs — giá trị xe là chuẩn).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ble = ref.read(bleProvider);
      if (ble.phase == BlePhase.connected) {
        unawaited(ref.read(bleProvider.notifier).refreshFwSettings());
      }
    });
  }

  Future<void> _readSerial() async {
    setState(() => _isReadingSerial = true);
    final serial = await ref.read(bleProvider.notifier).readDeviceSerial();
    if (mounted) {
      setState(() => _isReadingSerial = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(serial != null ? '✅ Đã đọc số Serial xe: $serial' : 'Không thể đọc số Serial lúc này.'),
          backgroundColor: serial != null ? AppColors.tertiary : AppColors.amber,
        ),
      );
    }
  }

  Future<void> _refreshDiagnostics() async {
    setState(() => _isRefreshingDiagnostics = true);
    await ref.read(bleProvider.notifier).fetchVehicleDiagnostics();
    if (mounted) {
      setState(() => _isRefreshingDiagnostics = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ Đã làm mới thông tin phần cứng & snapshot VESC'),
          backgroundColor: AppColors.tertiary,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _syncTime() async {
    setState(() => _isSyncingTime = true);
    final res = await ref.read(bleProvider.notifier).syncTimeWithBike();
    if (mounted) {
      setState(() => _isSyncingTime = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(res),
          backgroundColor: res.contains('thành công') ? AppColors.tertiary : AppColors.amber,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ble = ref.watch(bleProvider);
    final connected = ble.phase == BlePhase.connected;
    final telemetry = ble.lastTelemetry;

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20, color: Color(0xFF0F172A)),
          onPressed: () {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            }
          },
        ),
        centerTitle: true,
        title: Text(
          'Cài đặt xe',
          style: GoogleFonts.plusJakartaSans(
            fontWeight: FontWeight.w700,
            fontSize: 18,
            color: const Color(0xFF0F172A),
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Nhật ký Bluetooth',
            icon: const Icon(Icons.receipt_long_rounded, size: 22, color: Color(0xFF6366F1)),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LogsScreen())),
          ),
          IconButton(
            tooltip: 'Phòng Lab Firmware',
            icon: const Icon(Icons.science_rounded, size: 22, color: Color(0xFF8B5CF6)),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const FirmwareLabScreen())),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          // 1. Thông Tin Xe & Serial Khung
          _buildVehicleInfoCard(ble, connected, telemetry?.version ?? '1.14.0'),
          const SizedBox(height: 16),

          // 2. Đồng Hồ Taplo & Thời Gian Thực
          const SectionTitle('ĐỒNG HỒ TAPLO'),
          const SizedBox(height: 10),
          _buildTimeSyncCard(ble, connected),
          const SizedBox(height: 16),

          // 3. An toàn & điều khiển — đã verify trên xe thật
          const SectionTitle('AN TOÀN & ĐIỀU KHIỂN'),
          const SizedBox(height: 10),
          _buildSpeedLimiterCard(ble),
          const SizedBox(height: 12),
          _buildLockLightsCard(ble, connected),
          const SizedBox(height: 16),

          // 4. Tiện ích & Tự động hóa ECU
          const SectionTitle('TIỆN ÍCH & TỰ ĐỘNG'),
          const SizedBox(height: 10),
          _buildUtilityCard(ble, connected),
          const SizedBox(height: 16),

          // 5. Mẫu âm thanh còi tìm xe
          const SectionTitle('ÂM BÁO TÌM XE'),
          const SizedBox(height: 10),
          _buildSoundPatternCard(ble, connected),
          const SizedBox(height: 16),

          // 6. Nâng cao (lệnh nặng)
          _buildAdvancedSection(ble, connected),
        ],
      ),
    );
  }

  void _showResult(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message, style: GoogleFonts.plusJakartaSans(fontSize: 12.5)),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
      ));
  }

  // ========== THẺ 1: THÔNG TIN XE & SERIAL ==========
  Widget _buildVehicleInfoCard(BleState ble, bool connected, String fwVersion) {
    final telemetry = ble.lastTelemetry;
    final displaySerial = (ble.frameSerial != null && ble.frameSerial!.trim().isNotEmpty)
        ? ble.frameSerial!.trim()
        : (telemetry != null && telemetry.frame.trim().isNotEmpty ? telemetry.frame.trim() : null);

    return Panel(
      padding: const EdgeInsets.all(18),
      borderRadius: 20,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Image.asset(
                    'assets/images/bike_logo_3d.png',
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const Icon(Icons.two_wheeler_rounded, color: AppColors.primary, size: 28),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      ble.bikeName ?? 'Dat Bike EV',
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    Text(
                      'Firmware: $fwVersion · ${connected ? "Đang kết nối" : "Chưa kết nối"}',
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 12,
                        color: connected ? AppColors.tertiary : AppColors.textDim,
                      ),
                    ),
                  ],
                ),
              ),
              StatusPill(
                label: connected ? 'ONLINE' : 'OFFLINE',
                color: connected ? AppColors.tertiary : AppColors.textDim,
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Divider(color: AppColors.panelBorder, height: 1),
          const SizedBox(height: 12),

          // KHUNG SỐ SERIAL KHUNG XE (FRAME / VIN) CHUYÊN DỤNG — Kinetic Stitch EV
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.panelSecondary,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.panelBorder, width: 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Icon(Icons.numbers_rounded, size: 14, color: AppColors.primary),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'SỐ SERIAL KHUNG XE (FRAME / VIN)',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: AppColors.textDim,
                        ),
                      ),
                    ),
                    if (displaySerial != null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.tertiary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: AppColors.tertiary.withValues(alpha: 0.3),
                            width: 0.8,
                          ),
                        ),
                        child: Text(
                          'ĐÃ ĐỒNG BỘ',
                          style: GoogleFonts.spaceGrotesk(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5,
                            color: AppColors.tertiary,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        physics: const BouncingScrollPhysics(),
                        child: Text(
                          displaySerial ?? 'Chưa đọc từ firmware xe',
                          style: GoogleFonts.spaceGrotesk(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            letterSpacing: displaySerial != null ? 1.0 : 0.2,
                            color: displaySerial != null ? AppColors.textPrimary : AppColors.textDim,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (displaySerial != null)
                      IconButton(
                        tooltip: 'Sao chép số Serial',
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                        icon: const Icon(Icons.copy_rounded, size: 16, color: AppColors.textDim),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: displaySerial));
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('✅ Đã sao chép số Serial: $displaySerial'),
                              duration: const Duration(seconds: 2),
                              backgroundColor: AppColors.panel,
                            ),
                          );
                        },
                      ),
                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: connected && !_isReadingSerial ? _readSerial : null,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: connected ? AppColors.primary.withValues(alpha: 0.12) : AppColors.surface,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: connected ? AppColors.primary.withValues(alpha: 0.3) : AppColors.panelBorder,
                            width: 1,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_isReadingSerial)
                              const SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(strokeWidth: 1.8, color: AppColors.primary),
                              )
                            else
                              Icon(
                                Icons.refresh_rounded,
                                size: 14,
                                color: connected ? AppColors.primary : AppColors.textDim,
                              ),
                            const SizedBox(width: 4),
                            Text(
                              _isReadingSerial ? 'Đang đọc...' : 'Đọc lại',
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                                color: connected ? AppColors.primary : AppColors.textDim,
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
          const SizedBox(height: 12),

          // THẺ CHẨN ĐOÁN PHẦN CỨNG & SNAPSHOT VESC (Task 2.4)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.panelSecondary,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.panelBorder, width: 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF8B5CF6).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Icon(Icons.memory_rounded, size: 14, color: Color(0xFF8B5CF6)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'ĐỊNH DANH PHẦN CỨNG & SNAPSHOT VESC',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: AppColors.textDim,
                        ),
                      ),
                    ),
                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: connected && !_isRefreshingDiagnostics ? _refreshDiagnostics : null,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: connected ? const Color(0xFF8B5CF6).withValues(alpha: 0.12) : AppColors.surface,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: connected ? const Color(0xFF8B5CF6).withValues(alpha: 0.3) : AppColors.panelBorder,
                            width: 0.8,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_isRefreshingDiagnostics)
                              const SizedBox(
                                width: 10,
                                height: 10,
                                child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF8B5CF6)),
                              )
                            else
                              const Icon(Icons.refresh_rounded, size: 12, color: Color(0xFF8B5CF6)),
                            const SizedBox(width: 4),
                            Text(
                              _isRefreshingDiagnostics ? 'Đang đọc...' : 'Làm mới',
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                color: connected ? const Color(0xFF8B5CF6) : AppColors.textDim,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                // Model & Manifest
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          'Model: ',
                          style: GoogleFonts.plusJakartaSans(fontSize: 11, color: AppColors.textDim),
                        ),
                        Text(
                          ble.bikeModelCode ?? 'QT_S1',
                          style: GoogleFonts.spaceGrotesk(fontSize: 11.5, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Text(
                          'Manifest: ',
                          style: GoogleFonts.plusJakartaSans(fontSize: 11, color: AppColors.textDim),
                        ),
                        Expanded(
                          child: Text(
                            ble.boardManifest ?? '—',
                            style: GoogleFonts.spaceGrotesk(fontSize: 10.5, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // VESC 3x float
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.panelBorder, width: 0.8),
                  ),
                  child: Row(
                    children: [
                      _vescMetric('Dòng VESC', '${(ble.vescCurrent ?? 0.0).toStringAsFixed(2)} A'),
                      Container(width: 1, height: 20, color: AppColors.panelBorder),
                      _vescMetric('Điện Áp', '${(ble.vescVoltage ?? 0.0).toStringAsFixed(1)} V'),
                      Container(width: 1, height: 20, color: AppColors.panelBorder),
                      _vescMetric('Duty Cycle', '${((ble.vescDutyCycle ?? 0.0) * 100).toStringAsFixed(1)}%'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _vescMetric(String label, String value) {
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(label, style: GoogleFonts.plusJakartaSans(fontSize: 9.5, color: AppColors.textDim)),
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(value, style: GoogleFonts.spaceGrotesk(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          ),
        ],
      ),
    );
  }

  // ========== THẺ: ĐỒNG HỒ TAPLO & THỜI GIAN THỰC ==========
  Widget _buildTimeSyncCard(BleState ble, bool connected) {
    final lastSync = ble.lastTimeSynced;
    final lastSyncStr = lastSync != null
        ? '${lastSync.hour.toString().padLeft(2, '0')}:${lastSync.minute.toString().padLeft(2, '0')}:${lastSync.second.toString().padLeft(2, '0')} (${lastSync.day}/${lastSync.month})'
        : 'Chưa đồng bộ phiên này';

    return Panel(
      padding: const EdgeInsets.all(18),
      borderRadius: 20,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.access_time_filled_rounded, color: AppColors.primary, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Đồng Hồ Màn Hình Taplo',
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Lần cuối: $lastSyncStr',
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 12,
                        color: lastSync != null ? AppColors.tertiary : AppColors.textDim,
                        fontWeight: lastSync != null ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: connected ? AppColors.primary : AppColors.surface,
                  foregroundColor: connected ? Colors.white : AppColors.textDim,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                icon: _isSyncingTime
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.sync_rounded, size: 16),
                label: Text(
                  _isSyncingTime ? 'Đang gửi...' : 'Đồng bộ',
                  style: GoogleFonts.plusJakartaSans(fontSize: 12, fontWeight: FontWeight.w700),
                ),
                onPressed: (connected && !_isSyncingTime) ? _syncTime : null,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Gửi tổng số giây trong ngày theo giờ địa phương (0–86399) qua kênh Protected Write (0x44E2BDE6) vào đồng hồ RTC của xe, khắc phục lỗi lệch giờ khi xe ngắt bình hoặc đỗ lâu ngày.',
            style: GoogleFonts.plusJakartaSans(fontSize: 11.5, color: AppColors.textDim, height: 1.4),
          ),
        ],
      ),
    );
  }



  // ========== THẺ 3: MẪU ÂM THANH CÒI TÌM XE ==========
  Widget _buildSoundPatternCard(BleState ble, bool connected) {
    return Panel(
      padding: const EdgeInsets.all(18),
      borderRadius: 20,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Ghi chú kỹ thuật về tính năng còi tìm xe
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.secondary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.secondary.withValues(alpha: 0.3)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline_rounded, color: AppColors.secondary, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Đặc tả BLE (RE2 verified): Khi xe đang tắt máy, ghi Plain \'1\' vào kênh 0x350D9A82 sẽ phát 1 tiếng còi đánh thức MCU mà không đóng relay nguồn. Kênh 0x87EFAB0D (setBeepUUID) trong fw 1.14.0 chỉ lưu NVS chứ không có hàm phát còi.',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 11.5,
                      color: AppColors.textPrimary,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Chọn mẫu nhịp chuông kèn khi bấm "Tìm xe" trong bãi đỗ:',
            style: GoogleFonts.plusJakartaSans(fontSize: 12.5, color: AppColors.textDim),
          ),
          const SizedBox(height: 14),

          _buildPatternRadioTile(
            patternId: 0,
            title: 'Nhịp Tiêu Chuẩn (Single Beep)',
            subtitle: 'Bíp đơn cách nhau 1.1 giây — nhã nhặn, vang xa',
            isSelected: ble.findBikePattern == 0,
            onTap: () => ref.read(bleProvider.notifier).setFindBikePattern(0),
          ),
          const SizedBox(height: 8),
          _buildPatternRadioTile(
            patternId: 1,
            title: 'Nhịp Đôi Thể Thao (Double Staccato)',
            subtitle: 'Bíp kép (bíp-bíp... bíp-bíp) — dễ phân biệt trong bãi xe đông',
            isSelected: ble.findBikePattern == 1,
            onTap: () => ref.read(bleProvider.notifier).setFindBikePattern(1),
          ),
          const SizedBox(height: 8),
          _buildPatternRadioTile(
            patternId: 2,
            title: 'Báo Động Dồn Dập (Urgent SOS)',
            subtitle: 'Bíp liên hồi chu kỳ ngắn 450ms — định vị tức thời',
            isSelected: ble.findBikePattern == 2,
            onTap: () => ref.read(bleProvider.notifier).setFindBikePattern(2),
          ),
          const SizedBox(height: 14),

          // Nút thử âm thanh còi
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: ble.isFindingBike ? AppColors.amber : AppColors.secondary,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              icon: Icon(
                ble.isFindingBike ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                size: 20,
              ),
              label: Text(
                ble.isFindingBike ? 'DỪNG THỬ CÒI' : 'THỬ ÂM THANH NÀY (3 GIÂY)',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
              ),
              onPressed: connected
                  ? () async {
                      if (ble.isFindingBike) {
                        await ref.read(bleProvider.notifier).stopFindBike();
                      } else {
                        await ref.read(bleProvider.notifier).findBike(timeout: const Duration(seconds: 3));
                      }
                    }
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPatternRadioTile({
    required int patternId,
    required String title,
    required String subtitle,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.primary.withValues(alpha: 0.06) : AppColors.panelSecondary,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? AppColors.primary : AppColors.panelBorder,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              isSelected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
              color: isSelected ? AppColors.primary : AppColors.textDim,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 13,
                      fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                      color: isSelected ? AppColors.primary : AppColors.textPrimary,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: GoogleFonts.plusJakartaSans(fontSize: 11.5, color: AppColors.textDim),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ========== THẺ 3: GIỚI HẠN TỐC ĐỘ AN TOÀN & VẬN HÀNH ĐỘNG CƠ ==========
  Widget _buildSpeedLimiterCard(BleState ble) {
    final connected = ble.phase == BlePhase.connected;
    return Panel(
      padding: const EdgeInsets.all(18),
      borderRadius: 20,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: AppColors.tertiary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.tertiary.withValues(alpha: 0.35)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.verified_rounded, color: AppColors.tertiary, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '✅ Đã verify trên xe 24/10: ECE là "cổng" của giới hạn — cần bật ECE thì trần 60 km/h mới có hiệu lực. App luôn ghi đồng bộ cả ECE + SpeedLimit.',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.tertiary,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Text(
            connected ? 'Tùy chọn tốc độ an toàn (ghi xuống xe ngay):' : 'Kết nối xe để ghi giới hạn tốc độ xuống firmware:',
            style: GoogleFonts.plusJakartaSans(fontSize: 12.5, color: AppColors.textDim),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              StatusPill(
                label: 'ECE: ${ble.eceMode == 1 ? "Mở" : "Đóng (Mặc định)"}',
                color: ble.eceMode == 1 ? AppColors.amber : AppColors.tertiary,
              ),
              StatusPill(
                label: 'TỐC ĐỘ: ${ble.speedLimitMode == 1 ? "Giới hạn 60 km/h" : "Full Power"}',
                color: ble.speedLimitMode == 1 ? AppColors.primary : AppColors.textDim,
              ),
              if (ble.fwSpeedLimitRaw != null)
                StatusPill(
                  label: 'RAW: ${ble.fwSpeedLimitRaw}',
                  color: AppColors.secondary,
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _buildSegmentOption(
                label: 'Không giới hạn',
                desc: 'Full Power',
                isSelected: ble.speedLimitMode == 0,
                onTap: () async {
                  if (ble.speedLimitMode == 0) return;
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      backgroundColor: AppColors.panel,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                      title: Row(
                        children: [
                          const Icon(Icons.warning_amber_rounded, color: AppColors.amber, size: 22),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Tắt Giới Hạn Tốc Độ?',
                              style: GoogleFonts.spaceGrotesk(fontSize: 16, fontWeight: FontWeight.w700),
                            ),
                          ),
                        ],
                      ),
                      content: Text(
                        'Khi muốn tắt giới hạn về Full Power, bạn cần tắt máy xe và bật lại để bộ điều tốc VESC giải phóng bộ nhớ RAM.\n\n'
                        'App sẽ gửi lệnh tắt giới hạn tốc độ và chế độ ECE ngay bây giờ. Sau khi tắt, xe sẽ cho chuyển mode lái trở lại (khi ECE bật, xe KHÔNG cho chuyển mode — verified 24/10).',
                        style: GoogleFonts.plusJakartaSans(fontSize: 13, height: 1.45, color: AppColors.textPrimary),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: Text('HỦY', style: GoogleFonts.spaceGrotesk(color: AppColors.textDim)),
                        ),
                        FilledButton(
                          style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
                          onPressed: () => Navigator.pop(ctx, true),
                          child: Text('XÁC NHẬN TẮT', style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700)),
                        ),
                      ],
                    ),
                  );
                  if (confirm != true) return;
                  final res = await ref.read(bleProvider.notifier).setSafeSpeedLimit60(false);
                  _showResult(res);
                },
              ),
              const SizedBox(width: 8),
              _buildSegmentOption(
                label: 'Giới hạn 60 km/h',
                desc: 'An toàn đô thị',
                isSelected: ble.speedLimitMode == 1,
                onTap: () async {
                  if (ble.speedLimitMode == 1) return;
                  final res = await ref.read(bleProvider.notifier).setSafeSpeedLimit60(true);
                  _showResult(res);
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.amber.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.amber.withValues(alpha: 0.3)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline_rounded, color: AppColors.amber, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '📌 Cơ chế ngầm tự động: Để kích hoạt giới hạn 60 km/h, app sẽ tự động mở cổng ECE → ghi trần tốc độ → đóng cổng ECE lại về mặc định. Nhờ đó, giới hạn tốc độ vẫn hoạt động nhưng xe KHÔNG bị khóa đèn và vẫn chuyển chế độ lái (D/S) bình thường.',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppColors.amber,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const Divider(color: AppColors.panelBorder, height: 1),
          const SizedBox(height: 14),

          // Chế độ Grab / Chở tải (a1d8e7c4 — MASTER_CONFIG_SERVICE)
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('CHẾ ĐỘ GRAB (XE DỊCH VỤ / CHỞ TẢI)',
                        style: GoogleFonts.spaceGrotesk(fontSize: 12, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(
                      'Điều chỉnh độ nhạy ga mượt mà, chở người hay hàng hóa không bị giật (kênh 0xa1d8e7c4)',
                      style: GoogleFonts.plusJakartaSans(fontSize: 11, color: AppColors.textDim),
                    ),
                  ],
                ),
              ),
              StatusPill(
                label: ble.grabMode == 1 ? 'GRAB: BẬT' : 'GRAB: TẮT',
                color: ble.grabMode == 1 ? AppColors.tertiary : AppColors.textDim,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _buildSegmentOption(
                label: 'Cá nhân',
                desc: 'Ga nhạy',
                isSelected: ble.grabMode == 0,
                onTap: connected ? () async {
                  ref.read(bleProvider.notifier).setGrabMode(0);
                  _showResult(await ref.read(bleProvider.notifier).setFwGrabMode(false));
                } : null,
              ),
              const SizedBox(width: 8),
              _buildSegmentOption(
                label: 'Dịch vụ / Tải',
                desc: 'Ga êm mượt',
                isSelected: ble.grabMode == 1,
                onTap: connected ? () async {
                  ref.read(bleProvider.notifier).setGrabMode(1);
                  _showResult(await ref.read(bleProvider.notifier).setFwGrabMode(true));
                } : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Tiện ích xe & Tự động hóa ECU: Tự tắt khi đỗ + Tự bật/tắt theo khoảng cách + Đặt tên + Thẻ NFC.
  Widget _buildUtilityCard(BleState ble, bool connected) {
    final distLabel = ble.distanceRawU16 != null ? '${ble.distanceRawU16}' : 'Mặc định (8)';

    return Panel(
      padding: const EdgeInsets.all(18),
      borderRadius: 20,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Cấu hình tiện ích & tự động hóa trực tiếp bởi ECU:',
                  style: GoogleFonts.plusJakartaSans(fontSize: 12.5, color: AppColors.textDim),
                ),
              ),
              if (connected)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Đọc giá trị thật từ xe',
                  icon: const Icon(Icons.sync_rounded, size: 18, color: AppColors.textDim),
                  onPressed: () async {
                    await ref.read(bleProvider.notifier).refreshFwSettings();
                    _showResult('Đã đồng bộ giá trị settings từ xe (xem log fw_settings_synced).');
                  },
                ),
            ],
          ),
          const SizedBox(height: 14),

          // 1. Tự tắt khi đỗ (69c79762)
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('TỰ TẮT KHI ĐỖ', style: GoogleFonts.spaceGrotesk(fontSize: 12, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text('Xe tự tắt nguồn sau khi đỗ lâu (idling turn-off 69c79762)',
                        style: GoogleFonts.plusJakartaSans(fontSize: 11, color: AppColors.textDim)),
                  ],
                ),
              ),
              Switch(
                value: ble.idlingTurnOff,
                activeThumbColor: AppColors.primary,
                onChanged: connected ? (v) async {
                  ref.read(bleProvider.notifier).setIdlingTurnOff(v);
                  _showResult(await ref.read(bleProvider.notifier).setFwIdlingTurnOff(v));
                } : null,
              ),
            ],
          ),
          const Divider(color: AppColors.panelBorder, height: 24),

          // 2. Tự bật/tắt theo khoảng cách bởi ECU (5d681587)
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('TỰ BẬT/TẮT THEO KHOẢNG CÁCH (ECU 5d681587)',
                        style: GoogleFonts.spaceGrotesk(fontSize: 12, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(
                      'ECU tự mở khi lại gần & ngắt khi rời xa · Ngưỡng NVS: $distLabel',
                      style: GoogleFonts.plusJakartaSans(fontSize: 11, color: AppColors.textDim),
                    ),
                  ],
                ),
              ),
              StatusPill(
                label: ble.distanceMode > 0 ? 'BẬT (NVS: $distLabel)' : 'TẮT',
                color: ble.distanceMode > 0 ? AppColors.tertiary : AppColors.textDim,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _buildSegmentOption(
                label: 'Tắt',
                desc: 'Thủ công',
                isSelected: ble.distanceMode == 0,
                onTap: connected ? () async {
                  ref.read(bleProvider.notifier).setDistanceMode(0);
                  _showResult(await ref.read(bleProvider.notifier).setFwDistanceMode(false));
                } : null,
              ),
              const SizedBox(width: 8),
              _buildSegmentOption(
                label: 'Bật',
                desc: 'NVS $distLabel',
                isSelected: ble.distanceMode > 0,
                onTap: connected ? () async {
                  ref.read(bleProvider.notifier).setDistanceMode(1);
                  _showResult(await ref.read(bleProvider.notifier).setFwDistanceMode(true));
                } : null,
              ),
            ],
          ),
          const Divider(color: AppColors.panelBorder, height: 24),

          // 3. Đặt tên xe — ghi THẬT xuống flash qua char 88c30d2c
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primary,
                side: BorderSide(color: AppColors.primary.withValues(alpha: 0.5)),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              icon: const Icon(Icons.drive_file_rename_outline_rounded, size: 18),
              label: Text(
                'ĐẶT TÊN XE (lưu flash 88c30d2c)',
                style: GoogleFonts.spaceGrotesk(fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 0.3),
              ),
              onPressed: connected ? () async {
                final current = await ref.read(bleProvider.notifier).readFwBikeName();
                if (!mounted) return;
                final ctrl = TextEditingController(
                    text: current ?? ref.read(bleProvider).bikeName ?? '');
                final name = await showDialog<String>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: AppColors.panel,
                    title: Text('Đặt tên xe', style: GoogleFonts.spaceGrotesk(fontSize: 16)),
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextField(
                          controller: ctrl,
                          maxLength: 20,
                          autofocus: true,
                          decoration: const InputDecoration(
                            hintText: 'Vd: Dat Bike Quantum S1',
                            counterStyle: TextStyle(color: Colors.white54, fontSize: 11),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Tên được lưu vào flash xe (firmware setName, tối đa 20 ký tự). '
                          'Đọc lại tự động sau khi ghi để xác nhận.',
                          style: GoogleFonts.plusJakartaSans(fontSize: 11.5, color: AppColors.textDim),
                        ),
                      ],
                    ),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, null), child: const Text('Hủy')),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                        child: const Text('Lưu'),
                      ),
                    ],
                  ),
                );
                if (name != null && name.isNotEmpty) {
                  _showResult(await ref.read(bleProvider.notifier).setFwBikeName(name));
                }
              } : null,
            ),
          ),
          const SizedBox(height: 12),

          // 4. Thêm thẻ NFC mới (c75ebe03 — AUTH_SERVICE)
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              icon: const Icon(Icons.credit_card_rounded, size: 18),
              label: Text(
                'THÊM THẺ NFC MỚI (c75ebe03)',
                style: GoogleFonts.spaceGrotesk(fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 0.3),
              ),
              onPressed: connected ? () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: AppColors.panel,
                    title: Text('Thêm thẻ NFC mới?', style: GoogleFonts.spaceGrotesk(fontSize: 16)),
                    content: Text(
                      'App gửi lệnh đăng ký thẻ xuống xe qua cổng c75ebe03 → bạn quẹt THẺ MỚI vào đầu đọc trên xe trong ~10 giây. Firmware sẽ lưu thẻ vào danh sách mở khóa.',
                      style: GoogleFonts.plusJakartaSans(fontSize: 12.5, height: 1.4),
                    ),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Hủy')),
                      FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Bắt đầu')),
                    ],
                  ),
                );
                if (ok == true) {
                  _showResult(await ref.read(bleProvider.notifier).startAddNfcCard());
                }
              } : null,
            ),
          ),
        ],
      ),
    );
  }

  /// Khóa an toàn + Cổng cứu hộ b0ca953d — Cả hai đã verify trên xe thật (LAB).
  Widget _buildLockLightsCard(BleState ble, bool connected) {
    return Panel(
      padding: const EdgeInsets.all(18),
      borderRadius: 20,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Khóa an toàn (ARM qua eec8fd7f — LAB 23/10 xác minh)
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('KHÓA AN TOÀN (CHỐNG TRỘM)', style: GoogleFonts.spaceGrotesk(fontSize: 12, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(
                      ble.isLocked
                          ? 'Đang khóa: cần QUẸT THẺ NFC để mở · Còi hú khi đá chống'
                          : 'Xe phải TẮT mới khóa — app sẽ tự tắt xe. Sau khóa: quẹt thẻ NFC để mở, còi hú báo động khi xe bị động vào',
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 11,
                        color: ble.isLocked ? AppColors.error : AppColors.textDim,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: ble.isLocked,
                activeThumbColor: AppColors.error,
                onChanged: connected ? (v) async {
                  if (v) {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        backgroundColor: AppColors.bg,
                        title: Text('Khóa an toàn xe?', style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700)),
                        content: Text(
                          'Quy trình khóa (chuẩn hóa):\n• Nếu xe đang BẬT → app TẮT xe trước\n• Xe KHÓA an toàn — KHÔNG kết nối/mở lại qua app cho đến khi QUẸT THẺ NFC\n• Còi sẽ HÚ khi có người động vào xe (đá chống)\n\nChắc chắn thẻ NFC của bạn đang trong tay?',
                          style: GoogleFonts.plusJakartaSans(fontSize: 13),
                        ),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('HỦY')),
                          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('KHÓA')),
                        ],
                      ),
                    );
                    if (ok != true) return;
                    _showResult(await ref.read(bleProvider.notifier).lockBike());
                  } else {
                    _showResult(await ref.read(bleProvider.notifier).unlockBike());
                  }
                } : null,
              ),
            ],
          ),
          const Divider(color: AppColors.panelBorder, height: 24),

          // Cảnh báo an toàn b0ca953d & Nút cứu hộ khôi phục (RE2 Task [6.5])
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'CỔNG b0ca953d (VESC PROGRAMMING)',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: ble.vescProgActive ? AppColors.error : AppColors.amber,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  StatusPill(
                    label: ble.vescProgActive ? 'ĐANG KẸT DEV MODE (0x01)' : 'BÌNH THƯỜNG (0x00)',
                    color: ble.vescProgActive ? AppColors.error : AppColors.tertiary,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Đính chính RE2: b0ca953d là công tắc đảo bit (XOR) cờ nạp VESC (cfg+0x62), làm ngắt vescPollTask (IM=0). Khi kẹt ở 0x01, xe sẽ ngừng nhận telemetry động cơ.',
                style: GoogleFonts.plusJakartaSans(fontSize: 11, color: AppColors.textDim),
              ),
              if (ble.vescProgActive) ...[
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.error,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: const Icon(Icons.restore_rounded, size: 18),
                    label: Text(
                      'KHÔI PHỤC VỀ NORMAL (0x00)',
                      style: GoogleFonts.spaceGrotesk(fontSize: 12.5, fontWeight: FontWeight.w700),
                    ),
                    onPressed: connected
                        ? () async {
                            try {
                              final res = await ref.read(bleProvider.notifier).recoverFromVescProgrammingMode();
                              _showResult(res);
                            } catch (e) {
                              _showResult('Lỗi cứu hộ: $e');
                            }
                          }
                        : null,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// NÂNG CAO (LỆNH NẶNG NGUY HIỂM) — chỉ dành cho kỹ thuật viên
  Widget _buildAdvancedSection(BleState ble, bool connected) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.textDim.withValues(alpha: 0.3)),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: Material(
          color: Colors.transparent,
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 14),
            childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            iconColor: AppColors.textDim,
            title: Text(
              'NÂNG CAO (LỆNH NẶNG NGUY HIỂM)',
              style: GoogleFonts.spaceGrotesk(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.textDim),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                'Tắt hẳn BMS (đỗ lâu) · Khôi phục cài đặt gốc BLE (Factory Reset)',
                style: GoogleFonts.plusJakartaSans(fontSize: 10.5, color: AppColors.textDim),
              ),
            ),
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: AppColors.amber.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.amber.withValues(alpha: 0.25)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.warning_amber_rounded, size: 16, color: AppColors.amber),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Các thao tác dưới đây có tác động trực tiếp đến nguồn pin và kết nối của xe — chỉ thực hiện khi thực sự cần thiết.',
                        style: GoogleFonts.plusJakartaSans(fontSize: 11, color: AppColors.textDim, height: 1.35),
                      ),
                    ),
                  ],
                ),
              ),

              // Tắt BMS + Factory reset
              _buildAdvancedCard(ble, connected),
            ],
          ),
        ),
      ),
    );
  }

  /// Nâng cao: Tắt BMS + Factory reset BLE.
  Widget _buildAdvancedCard(BleState ble, bool connected) {
    return Panel(
      padding: const EdgeInsets.all(18),
      borderRadius: 20,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Các lệnh nặng — chỉ dùng khi hiểu rõ hậu quả:',
            style: GoogleFonts.plusJakartaSans(fontSize: 12.5, color: AppColors.textDim),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.amber,
                side: BorderSide(color: AppColors.amber.withValues(alpha: 0.5)),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              icon: const Icon(Icons.battery_alert_rounded, size: 18),
              label: Text(
                'TẮT HẲN BMS (ĐỖ LÂU)',
                style: GoogleFonts.spaceGrotesk(fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 0.3),
              ),
              onPressed: connected ? () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: AppColors.panel,
                    title: Text('Tắt hẳn BMS?', style: GoogleFonts.spaceGrotesk(fontSize: 16)),
                    content: Text(
                      'Pin sẽ ngắt hoàn toàn — xe KHÔNG phản hồi Bluetooth cho đến khi bạn bật lại nguồn xe vật lý. Chỉ dùng khi đỗ lâu ngày để bảo toàn pin.',
                      style: GoogleFonts.plusJakartaSans(fontSize: 12.5, height: 1.4),
                    ),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Hủy')),
                      FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: AppColors.error),
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Tắt BMS'),
                      ),
                    ],
                  ),
                );
                if (ok == true) {
                  _showResult(await ref.read(bleProvider.notifier).turnOffBms());
                }
              } : null,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.error,
                side: BorderSide(color: AppColors.error.withValues(alpha: 0.5)),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              icon: const Icon(Icons.restart_alt_rounded, size: 18),
              label: Text(
                'FACTORY RESET CÀI ĐẶT BLE',
                style: GoogleFonts.spaceGrotesk(fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 0.3),
              ),
              onPressed: connected ? () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: AppColors.panel,
                    title: Text('Factory reset BLE?', style: GoogleFonts.spaceGrotesk(fontSize: 16)),
                    content: Text(
                      'Xóa toàn bộ cài đặt Bluetooth của xe (bond, password, thẻ…? — theo firmware "Factory reset BLE settings"). Sau reset có thể phải ghép lại từ đầu. KHÔNG hoàn tác được.',
                      style: GoogleFonts.plusJakartaSans(fontSize: 12.5, height: 1.4),
                    ),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Hủy')),
                      FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: AppColors.error),
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Reset'),
                      ),
                    ],
                  ),
                );
                if (ok == true) {
                  _showResult(await ref.read(bleProvider.notifier).factoryResetBle());
                }
              } : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSegmentOption({
    required String label,
    required String desc,
    required bool isSelected,
    VoidCallback? onTap,
  }) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isSelected ? AppColors.primary : AppColors.panelSecondary,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected ? AppColors.primary : AppColors.panelBorder,
              width: 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: isSelected ? Colors.white : AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                desc,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 9.5,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                  color: isSelected ? Colors.white.withValues(alpha: 0.85) : AppColors.textDim,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
