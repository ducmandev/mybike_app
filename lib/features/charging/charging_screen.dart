// Screen 2: Power Control (Charging) — Chuyên biệt hóa cho Xe Máy Điện Dat Bike
// Đồng bộ 100% với Telemetry thật từ xe (điện áp, dòng điện, công suất)
// và tích hợp chọn Profile sạc Era (8a2b0d10) + Nút mở Bác Sĩ Pin 24-Cell.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/ble/ble_controller.dart';
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
        content: Text(message, style: GoogleFonts.plusJakartaSans(fontSize: 13)),
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
      backgroundColor: const Color(0xFFF8F9FA),
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
          'Power Control',
          style: GoogleFonts.plusJakartaSans(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: const Color(0xFF0F172A),
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
                ],
              ),

              const SizedBox(height: 18),

              // ══════════════════════════════════════════════════════════════
              // 2. TRUNG TÂM: XE MÁY ĐIỆN 3D X-RAY TRONG SUỐT LỘ PIN
              // ══════════════════════════════════════════════════════════════
              Container(
                width: double.infinity,
                height: 235,
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
                      'assets/images/bike_xray.jpg',
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: double.infinity,
                      errorBuilder: (context, error, stackTrace) => const Center(
                        child: Icon(Icons.bolt_rounded, size: 80, color: Color(0xFF10B981)),
                      ),
                    ),

                    Positioned(
                      bottom: 24,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: isCharging ? const Color(0xE622C55E) : const Color(0xE60F172A),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isCharging ? const Color(0xFF86EFAC) : const Color(0xFF334155),
                            width: 1.5,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: isCharging ? const Color(0x6622C55E) : const Color(0x33000000),
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
                              color: Colors.white,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '$percentStr%',
                              style: GoogleFonts.spaceGrotesk(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                                letterSpacing: 0.5,
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 18),

              // ══════════════════════════════════════════════════════════════
              // 3. TRẠNG THÁI KẾT NỐI SẠC THẬT TỪ XE
              // ══════════════════════════════════════════════════════════════
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _statusBullet(
                    color: isCharging ? const Color(0xFF22C55E) : const Color(0xFF94A3B8),
                    label: isCharging ? 'Đang sạc an toàn' : (connected ? 'Chưa cắm sạc' : 'Chưa kết nối xe'),
                  ),
                  const SizedBox(width: 18),
                  _statusBullet(
                    color: const Color(0xFF2563EB),
                    label: isCharging ? 'Cổng sạc Dat Charge' : 'Chuẩn sạc 72V Li-ion',
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // ══════════════════════════════════════════════════════════════
              // 4. BOTTOM CARD: CHARGING DETAILS
              // ══════════════════════════════════════════════════════════════
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(22),
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
                    Text(
                      'Charging Details',
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFF0F172A),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Hàng 1: Thời gian còn lại
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Remaining Time',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: const Color(0xFF64748B),
                          ),
                        ),
                        Text(
                          remainingTimeStr,
                          style: GoogleFonts.spaceGrotesk(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: const Color(0xFF0F172A),
                          ),
                        ),
                      ],
                    ),

                    const Divider(color: Color(0xFFF1F5F9), height: 26, thickness: 1),

                    // Hàng 2: Dòng điện, Áp, Công suất thật từ BMS
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Current / Power',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: const Color(0xFF64748B),
                          ),
                        ),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                              margin: const EdgeInsets.only(right: 8),
                              decoration: BoxDecoration(
                                color: isCharging ? const Color(0xFFDCFCE7) : const Color(0xFFF1F5F9),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                'DC',
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: isCharging ? const Color(0xFF16A34A) : const Color(0xFF64748B),
                                ),
                              ),
                            ),
                            Text(
                              hasTelemetry
                                  ? '${powerKw.toStringAsFixed(2)} kW · ${currentA.toStringAsFixed(1)} A · ${voltage.toStringAsFixed(1)} V'
                                  : '---',
                              style: GoogleFonts.spaceGrotesk(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: const Color(0xFF0F172A),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),

                    const Divider(color: Color(0xFFF1F5F9), height: 26, thickness: 1),

                    // Hàng 3: Nhiệt độ pack Pin
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Nhiệt độ BMS / Pin',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: const Color(0xFF64748B),
                          ),
                        ),
                        Text(
                          hasTelemetry ? '${bmsTemp.toStringAsFixed(1)} °C' : '---',
                          style: GoogleFonts.spaceGrotesk(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: const Color(0xFF0F172A),
                          ),
                        ),
                      ],
                    ),

                    const Divider(color: Color(0xFFF1F5F9), height: 26, thickness: 1),

                    // Hàng 4: Chọn Profile sạc Era (8a2b0d10)
                    Text(
                      'Cấu Hình Profile Sạc (Era 8a2b0d10)',
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF0F172A),
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
                          backgroundColor: const Color(0xFF10B981),
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        icon: const Icon(Icons.medical_services_outlined, size: 20),
                        label: Text(
                          'Bác Sĩ Pin & Chẩn Đoán 24 Cell',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.3,
                          ),
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
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: selected ? const Color(0xFF2563EB) : const Color(0xFF0F172A),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                sub,
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  color: selected ? const Color(0xFF2563EB) : const Color(0xFF64748B),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusBullet({required Color color, required String label}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: GoogleFonts.plusJakartaSans(
            fontSize: 12.5,
            fontWeight: FontWeight.w500,
            color: const Color(0xFF0F172A),
          ),
        ),
      ],
    );
  }
}
