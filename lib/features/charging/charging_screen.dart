// Screen 2: Power Control (Charging) — Chuyên biệt hóa cho Xe Máy Điện Dat Bike
// Đồng bộ 100% với Telemetry thật từ xe (điện áp, dòng điện, công suất)
// và tích hợp chọn Profile sạc Era (8a2b0d10) + Nút mở Bác Sĩ Pin 24-Cell.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ble/ble_controller.dart';
import '../../ui/app_theme.dart';
import '../../ui/widgets.dart';
import '../battery/battery_diagnostics_screen.dart';

class ChargingScreen extends ConsumerStatefulWidget {
  const ChargingScreen({super.key});

  @override
  ConsumerState<ChargingScreen> createState() => _ChargingScreenState();
}

class _ChargingScreenState extends ConsumerState<ChargingScreen> {
  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: AppTypography.bodySm(color: AppColors.onPrimary)),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(
      bleProvider.select(
        (s) => (
          phase: s.phase,
          chargingProfile: s.chargingProfile,
          bikeModel: s.bikeModel,
          hasTelemetry: s.lastTelemetry != null,
          percent: s.lastTelemetry?.percent,
          voltage: s.lastTelemetry?.voltage,
          telemetryPhase: s.lastTelemetry?.phase,
          kmLeft: s.lastTelemetry?.kmLeft,
          isChargingPresent: s.lastTelemetry?.charging != null,
          etaSec: s.lastTelemetry?.charging?.etaSec,
          bmsTemp: s.lastTelemetry?.bmsTemp,
        ),
      ),
    );
    final connected = data.phase == BlePhase.connected;
    final hasTelemetry = connected && data.hasTelemetry;

    final isCharging = hasTelemetry && (data.isChargingPresent || (data.telemetryPhase ?? 0.0) > 0.5);
    final percent = data.percent;
    final percentStr = (hasTelemetry && percent != null) ? '$percent' : '--';
    final voltage = data.voltage ?? 0.0;
    final currentA = (data.telemetryPhase ?? 0.0).abs();
    final powerKw = (voltage * currentA / 1000.0);
    final rawKmLeft = data.kmLeft ?? 0.0;
    final kmLeftVal = (hasTelemetry && rawKmLeft > 0)
        ? rawKmLeft.round()
        : (percent != null ? ((percent / 100.0) * 270).round() : null);
    final kmLeftStr = (hasTelemetry && kmLeftVal != null) ? '$kmLeftVal' : '--';

    final etaSec = data.etaSec ?? 0;
    final remainingTimeStr = isCharging
        ? (etaSec > 0 ? '${(etaSec / 60).round()} phút' : 'Đang sạc...')
        : '---';
    final bmsTemp = data.bmsTemp ?? 0.0;

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20, color: AppColors.textPrimary),
          onPressed: () {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            }
          },
        ),
        centerTitle: true,
        title: Text(
          'Power Control',
          style: AppTypography.headlineSm(color: AppColors.textPrimary).copyWith(
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 10),

              // ══════════════════════════════════════════════════════════════
              // 1. HIỂN THỊ QUÃNG ĐƯỜNG DỰ TÍNH (Font rộng)
              // ══════════════════════════════════════════════════════════════
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    kmLeftStr,
                    style: AppTypography.displayLg(color: AppColors.textPrimary).copyWith(
                      fontSize: 54,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -1.0,
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
                ],
              ),

              const SizedBox(height: 18),

              // ══════════════════════════════════════════════════════════════
              // 2. TRUNG TÂM: XE MÁY ĐIỆN 3D X-RAY TRONG SUỐT LỘ PIN
              // ══════════════════════════════════════════════════════════════
              Panel(
                padding: EdgeInsets.zero,
                borderRadius: 24,
                hasActiveHalo: isCharging,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(23),
                  child: SizedBox(
                    width: double.infinity,
                    height: 235,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Image.asset(
                          'assets/images/bike_xray.jpg',
                          fit: BoxFit.cover,
                          width: double.infinity,
                          height: double.infinity,
                          errorBuilder: (context, error, stackTrace) => const Center(
                            child: TemplateBadgeIcon(
                              icon: Icons.bolt_rounded,
                              color: AppColors.mint,
                              size: 72,
                              iconSize: 42,
                              borderRadius: 20,
                            ),
                          ),
                        ),
                        Positioned(
                          bottom: 24,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            decoration: BoxDecoration(
                              color: (isCharging ? AppColors.mint : AppColors.textPrimary)
                                  .withValues(alpha: 0.90),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isCharging
                                    ? AppColors.mint.withValues(alpha: 0.55)
                                    : AppColors.onSurfaceVariant,
                                width: 1.5,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: (isCharging ? AppColors.mint : AppColors.textPrimary)
                                      .withValues(alpha: isCharging ? 0.35 : 0.20),
                                  blurRadius: 16,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  isCharging ? Icons.bolt_rounded : Icons.battery_charging_full_rounded,
                                  size: 16,
                                  color: AppColors.onPrimary,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '$percentStr%',
                                  style: AppTypography.headlineSm(color: AppColors.onPrimary).copyWith(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 18),

              // ══════════════════════════════════════════════════════════════
              // 3. TRẠNG THÁI KẾT NỐI SẠC THẬT TỪ XE
              // ══════════════════════════════════════════════════════════════
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 10,
                runSpacing: 8,
                children: [
                  StatusPill(
                    color: isCharging ? AppColors.mint : AppColors.textMuted,
                    pulse: isCharging,
                    label: isCharging
                        ? 'Đang sạc an toàn'
                        : (connected ? 'Chưa cắm sạc' : 'Chưa kết nối xe'),
                  ),
                  StatusPill(
                    color: AppColors.primary,
                    icon: Icons.bolt_rounded,
                    label: isCharging ? 'Cổng sạc Dat Charge' : 'Chuẩn sạc 72V Li-ion',
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // ══════════════════════════════════════════════════════════════
              // 4. BOTTOM CARD: CHARGING DETAILS
              // ══════════════════════════════════════════════════════════════
              Panel(
                padding: const EdgeInsets.all(22),
                borderRadius: 22,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SectionTitle(
                      'Charging Details',
                      action: TemplateBadgeIcon(
                        icon: Icons.ev_station_rounded,
                        color: isCharging ? AppColors.mint : AppColors.primary,
                        size: 32,
                        iconSize: 18,
                        borderRadius: 10,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Hàng 1: Thời gian còn lại
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            'Remaining Time',
                            style: AppTypography.bodyMd(color: AppColors.textDim).copyWith(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Flexible(
                          child: Text(
                            remainingTimeStr,
                            textAlign: TextAlign.end,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.headlineSm(color: AppColors.textPrimary).copyWith(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),

                    const Divider(color: AppColors.panelBorder, height: 26, thickness: 1),

                    // Hàng 2: Dòng điện, Áp, Công suất thật từ BMS
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Flexible(
                          child: Text(
                            'Current / Power',
                            style: AppTypography.bodyMd(color: AppColors.textDim).copyWith(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Flexible(
                          flex: 2,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                                margin: const EdgeInsets.only(right: 8),
                                decoration: BoxDecoration(
                                  color: isCharging
                                      ? AppColors.mint.withValues(alpha: 0.14)
                                      : AppColors.panelBorder,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  'DC',
                                  style: AppTypography.labelSm(
                                    color: isCharging ? AppColors.tertiaryContainer : AppColors.textDim,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              Flexible(
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerRight,
                                  child: Text(
                                    hasTelemetry
                                        ? '${powerKw.toStringAsFixed(2)} kW · ${currentA.toStringAsFixed(1)} A · ${voltage.toStringAsFixed(1)} V'
                                        : '---',
                                    style: AppTypography.headlineSm(color: AppColors.textPrimary).copyWith(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),

                    const Divider(color: AppColors.panelBorder, height: 26, thickness: 1),

                    // Hàng 3: Nhiệt độ pack Pin
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            'Nhiệt độ BMS / Pin',
                            style: AppTypography.bodyMd(color: AppColors.textDim).copyWith(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Flexible(
                          child: Text(
                            hasTelemetry ? '${bmsTemp.toStringAsFixed(1)} °C' : '---',
                            textAlign: TextAlign.end,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.headlineSm(color: AppColors.textPrimary).copyWith(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),

                    const Divider(color: AppColors.panelBorder, height: 26, thickness: 1),

                    // Hàng 4: Chọn Profile sạc Era (8a2b0d10)
                    Text(
                      'Cấu Hình Profile Sạc (Era 8a2b0d10)',
                      style: AppTypography.labelLg(color: AppColors.textPrimary).copyWith(
                        fontSize: 13.5,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        _profilePill('Tiêu Chuẩn', 'Standard', data.chargingProfile == 0, connected, () async {
                          ref.read(bleProvider.notifier).setChargingProfile(0);
                          final res = await ref.read(bleProvider.notifier).setFwChargingProfile(0);
                          _showSnack(res);
                        }),
                        const SizedBox(width: 8),
                        _profilePill('Sạc Nhanh', 'Fast', data.chargingProfile == 1, connected, () async {
                          ref.read(bleProvider.notifier).setChargingProfile(1);
                          final res = await ref.read(bleProvider.notifier).setFwChargingProfile(1);
                          _showSnack(res);
                        }),
                        const SizedBox(width: 8),
                        _profilePill('Tăng Tốc', 'Boost', data.chargingProfile == 2, connected, () async {
                          ref.read(bleProvider.notifier).setChargingProfile(2);
                          final res = await ref.read(bleProvider.notifier).setFwChargingProfile(2);
                          _showSnack(res);
                        }),
                      ],
                    ),

                    const SizedBox(height: 20),

                    // Hàng 5: Nút mở Bác Sĩ Pin 24-Cell
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.mint,
                          foregroundColor: AppColors.onTertiary,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        icon: const Icon(Icons.medical_services_outlined, size: 20),
                        label: Text(
                          'Bác Sĩ Pin & Chẩn Đoán 24 Cell',
                          style: AppTypography.labelLg(
                            color: AppColors.onTertiary,
                            fontWeight: FontWeight.w700,
                          ).copyWith(fontSize: 15, letterSpacing: 0.3),
                        ),
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const BatteryDiagnosticsScreen()),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 28),
            ],
          ),
        ),
      ),
    );
  }

  Widget _profilePill(String label, String sub, bool selected, bool connected, VoidCallback onTap) {
    return Expanded(
      child: InkWell(
        onTap: connected ? onTap : null,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
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
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.labelMd(
                  color: selected ? AppColors.primary : AppColors.textPrimary,
                  fontWeight: FontWeight.w700,
                ).copyWith(letterSpacing: 0),
              ),
              const SizedBox(height: 2),
              Text(
                sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.headlineSm(
                  color: selected ? AppColors.primary : AppColors.textDim,
                ).copyWith(fontSize: 10, fontWeight: FontWeight.w500, height: 1.2),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
