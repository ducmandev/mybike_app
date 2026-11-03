import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../ui/app_theme.dart';

/// Thanh năng lượng tiêu hao và phanh tái sinh (Luminous Energy Beam)
/// Thiết kế không viền (borderless) với hiệu ứng vệt sáng quang học tỏa ra mượt mà:
/// - Phía trái: RECUP (phanh tái sinh nạp ngược pin) tỏa màu xanh bạc hà / mint-emerald.
/// - Phía phải: PWR (xả ga kéo tải) tỏa màu xanh cyan chuyển cam đào Dat Bike.
/// - Đầu vệt sáng tan mờ dần tự nhiên (feathered dispersion).
class LuminousEnergyBar extends StatelessWidget {
  final double powerKw;
  final bool isRecup;
  final bool isDraw;
  final double? phaseAmps;
  final double? voltage;
  final double maxKw;

  const LuminousEnergyBar({
    super.key,
    required this.powerKw,
    required this.isRecup,
    required this.isDraw,
    this.phaseAmps,
    this.voltage,
    this.maxKw = 6.0,
  });

  @override
  Widget build(BuildContext context) {
    final absPower = powerKw.abs();
    final pwrColor = isRecup
        ? AppColors.tertiary
        : isDraw
            ? const Color(0xFFEA580C)
            : AppColors.textDim;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 1. Dòng nhãn trên: RECUP / kW Trung tâm / PWR
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: SizedBox(
              width: 320,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // RECUP Indicator
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isRecup ? AppColors.tertiary : AppColors.panelBorderBright,
                          boxShadow: isRecup
                              ? [
                                  BoxShadow(
                                    color: AppColors.tertiary.withValues(alpha: 0.5),
                                    blurRadius: 6,
                                  ),
                                ]
                              : null,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '◀ RECUP',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: isRecup ? AppColors.tertiary : AppColors.textDim,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ],
                  ),

                  // Công suất kW trung tâm
                  Text(
                    '${absPower.toStringAsFixed(2)} kW',
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: pwrColor,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),

                  // PWR Indicator
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'PWR ▶',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: isDraw ? const Color(0xFFEA580C) : AppColors.textDim,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isDraw ? const Color(0xFFEA580C) : AppColors.panelBorderBright,
                          boxShadow: isDraw
                              ? [
                                  BoxShadow(
                                    color: const Color(0xFFEA580C).withValues(alpha: 0.5),
                                    blurRadius: 6,
                                  ),
                                ]
                              : null,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),

        const SizedBox(height: 6),

        // 2. Dải tia sáng quang học nạp xả không có border (Luminous Beam Canvas)
        SizedBox(
          height: 18,
          child: CustomPaint(
            size: const Size(double.infinity, 18),
            painter: _LuminousBeamPainter(
              powerKw: powerKw,
              isRecup: isRecup,
              isDraw: isDraw,
              maxKw: maxKw,
            ),
          ),
        ),

        const SizedBox(height: 5),

        // 3. Thông số phụ: Dòng xả & Điện áp
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (phaseAmps != null) ...[
                Text(
                  'Dòng tải: ',
                  style: GoogleFonts.plusJakartaSans(fontSize: 10, color: AppColors.textDim),
                ),
                Text(
                  '${phaseAmps!.abs().toStringAsFixed(1)} A',
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
              if (phaseAmps != null && voltage != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text('·', style: GoogleFonts.plusJakartaSans(color: AppColors.textDim)),
                ),
              if (voltage != null) ...[
                Text(
                  'Điện áp: ',
                  style: GoogleFonts.plusJakartaSans(fontSize: 10, color: AppColors.textDim),
                ),
                Text(
                  '${voltage!.toStringAsFixed(1)} V',
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _LuminousBeamPainter extends CustomPainter {
  final double powerKw;
  final bool isRecup;
  final bool isDraw;
  final double maxKw;

  _LuminousBeamPainter({
    required this.powerKw,
    required this.isRecup,
    required this.isDraw,
    required this.maxKw,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final centerX = size.width / 2;
    final centerY = size.height / 2;
    final halfWidth = size.width / 2;

    // 1. Mốc Zero ở giữa (thanh hairline mảnh thanh nhã)
    final zeroDivider = Paint()
      ..color = AppColors.panelBorderBright
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(centerX, centerY - 6),
      Offset(centerX, centerY + 6),
      zeroDivider,
    );

    // Tính tỉ lệ phần trăm công suất (0.0 -> 1.0)
    final ratio = (powerKw.abs() / maxKw).clamp(0.0, 1.0);
    if (ratio < 0.01) return;

    if (isRecup) {
      // ===== PHANH TÁI SINH (RECUP): Vệt sáng lan sang trái =====
      final fillWidth = halfWidth * ratio;
      final startX = centerX;
      final endX = centerX - fillWidth;

      final beamRect = Rect.fromLTRB(endX, centerY - 8, startX, centerY + 8);

      // Layer 1: Hào quang khuếch tán (Ambient Halo Glow)
      final haloPaint = Paint()
        ..shader = const LinearGradient(
          begin: Alignment.centerRight,
          end: Alignment.centerLeft,
          colors: [
            Color(0x9910B981), // Emerald
            Color(0x5534D399), // Mint
            Color(0x0010B981), // Tan mờ tự nhiên ở chóp
          ],
          stops: [0.0, 0.6, 1.0],
        ).createShader(beamRect)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(endX, centerY - 4.5, startX, centerY + 4.5),
          const Radius.circular(8),
        ),
        haloPaint,
      );

      // Layer 2: Tia sáng lõi (Core Luminous Filament)
      final corePaint = Paint()
        ..shader = const LinearGradient(
          begin: Alignment.centerRight,
          end: Alignment.centerLeft,
          colors: [
            Color(0xFF10B981),
            Color(0xFF34D399),
            Color(0x00A7F3D0),
          ],
          stops: [0.0, 0.7, 1.0],
        ).createShader(beamRect);

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(endX, centerY - 1.5, startX, centerY + 1.5),
          const Radius.circular(3),
        ),
        corePaint,
      );
    } else if (isDraw) {
      // ===== XẢ TẢI (PWR): Vệt sáng lan sang phải =====
      final fillWidth = halfWidth * ratio;
      final startX = centerX;
      final endX = centerX + fillWidth;

      final beamRect = Rect.fromLTRB(startX, centerY - 8, endX, centerY + 8);

      // Layer 1: Hào quang khuếch tán (Ambient Halo Glow)
      final haloPaint = Paint()
        ..shader = const LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            Color(0x8838BDF8), // Cyan
            Color(0x77FB923C), // Peach
            Color(0x00F97316), // Tan mờ ở chóp
          ],
          stops: [0.0, 0.65, 1.0],
        ).createShader(beamRect)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(startX, centerY - 4.5, endX, centerY + 4.5),
          const Radius.circular(8),
        ),
        haloPaint,
      );

      // Layer 2: Tia sáng lõi (Core Luminous Filament)
      final corePaint = Paint()
        ..shader = const LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            Color(0xFF38BDF8),
            Color(0xFFF97316),
            Color(0x00EA580C),
          ],
          stops: [0.0, 0.7, 1.0],
        ).createShader(beamRect);

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(startX, centerY - 1.5, endX, centerY + 1.5),
          const Radius.circular(3),
        ),
        corePaint,
      );
    }
  }

  @override
  bool shouldRepaint(_LuminousBeamPainter old) =>
      old.powerKw != powerKw ||
      old.isRecup != isRecup ||
      old.isDraw != isDraw ||
      old.maxKw != maxKw;
}
