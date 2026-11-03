import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../ui/app_theme.dart';

/// Đồng hồ định vị la bàn quang học & đo khoảng cách tiệm cận (Precision Radar Gauge)
/// Kế thừa phong cách thiết kế tinh tế của SpeedGauge trên Dashboard Cockpit.
class PrecisionRadarGauge extends StatefulWidget {
  final double distanceMeters;
  final double headingDegrees;
  final int? rssi;
  final bool isBleConnected;

  const PrecisionRadarGauge({
    super.key,
    required this.distanceMeters,
    required this.headingDegrees,
    this.rssi,
    this.isBleConnected = true,
  });

  @override
  State<PrecisionRadarGauge> createState() => _PrecisionRadarGaugeState();
}

class _PrecisionRadarGaugeState extends State<PrecisionRadarGauge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sonarController;

  @override
  void initState() {
    super.initState();
    _sonarController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    )..repeat();
  }

  @override
  void dispose() {
    _sonarController.dispose();
    super.dispose();
  }

  /// Tính toán tỉ lệ tiệm cận (1.0 = sát bên cạnh 0.5m, 0.0 = xa >= 25m)
  double get _proximityRatio {
    final clamped = widget.distanceMeters.clamp(0.5, 25.0);
    return 1.0 - ((clamped - 0.5) / 24.5);
  }

  (String, Color) _getStatusInfo() {
    if (!widget.isBleConnected || widget.distanceMeters > 25.0) {
      return ('DẪN ĐƯỜNG ĐI BỘ (GPS)', AppColors.textDim);
    }
    if (widget.distanceMeters <= 1.5) {
      return ('XE Ở NGAY BÊN CẠNH BẠN!', const Color(0xFFEA580C));
    }
    if (widget.distanceMeters <= 6.0) {
      return ('RẤT GẦN (< 6M)', AppColors.tertiary);
    }
    if (widget.distanceMeters <= 15.0) {
      return ('ĐANG LẠI GẦN', AppColors.primary);
    }
    return ('BẮT ĐƯỢC TÍN HIỆU SÓNG', AppColors.secondary);
  }

  String _getBearingString(double deg) {
    final d = (deg % 360 + 360) % 360;
    String dir = 'BẮC';
    if (d >= 23 && d < 68) {
      dir = 'ĐÔNG BẮC';
    } else if (d >= 68 && d < 113) {
      dir = 'ĐÔNG';
    } else if (d >= 113 && d < 158) {
      dir = 'ĐÔNG NAM';
    } else if (d >= 158 && d < 203) {
      dir = 'NAM';
    } else if (d >= 203 && d < 248) {
      dir = 'TÂY NAM';
    } else if (d >= 248 && d < 293) {
      dir = 'TÂY';
    } else if (d >= 293 && d < 338) {
      dir = 'TÂY BẮC';
    }
    return '${d.toStringAsFixed(0).padLeft(3, '0')}° $dir';
  }

  @override
  @override
  @override
  Widget build(BuildContext context) {
    final (statusTitle, statusColor) = _getStatusInfo();
    final distText = widget.distanceMeters >= 1.0
        ? widget.distanceMeters.toStringAsFixed(1)
        : (widget.distanceMeters * 100).toStringAsFixed(0);
    final unitText = widget.distanceMeters >= 1.0 ? 'MÉT' : 'CM';

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth.isFinite ? constraints.maxWidth : 340.0;
        final maxH = constraints.maxHeight.isFinite ? constraints.maxHeight : double.infinity;

        // Reserve space for top status title (~28px) and bottom telemetry (~40px)
        final availableCircleH = maxH.isFinite ? maxH - 68.0 : 320.0;
        final size = (maxH.isFinite ? (maxW < availableCircleH ? maxW : availableCircleH) : (maxW < 320.0 ? maxW : 320.0)).clamp(120.0, 320.0);
        final isCompact = size < 220.0;

        return Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 1. Chế độ trạng thái tiếp cận phía trên (không viền - chuẩn Mode Indicator)
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: Row(
                key: ValueKey(statusTitle),
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: isCompact ? 6 : 7,
                    height: isCompact ? 6 : 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: statusColor,
                      boxShadow: [
                        BoxShadow(
                          color: statusColor.withValues(alpha: 0.5),
                          blurRadius: 6,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      statusTitle,
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: isCompact ? 10.5 : 11.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                        color: statusColor,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: isCompact ? 6 : 12),

            // 2. Cụm Đồng hồ Vòng cung La bàn & Khoảng cách trung tâm
            SizedBox(
              width: size,
              height: size,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Vòng Sonar Apple Find My nhẹ nhàng phía sau
                  AnimatedBuilder(
                    animation: _sonarController,
                    builder: (context, _) {
                      return CustomPaint(
                        size: Size(size, size),
                        painter: _SubtleSonarPainter(
                          progress: _sonarController.value,
                          color: statusColor,
                        ),
                      );
                    },
                  ),

                  // Đồng hồ Vòng cung quang học + Vạch chia độ + Kim la bàn quỹ đạo
                  CustomPaint(
                    size: Size(size, size),
                    painter: _PrecisionDialPainter(
                      proximityRatio: _proximityRatio,
                      headingDegrees: widget.headingDegrees,
                      activeColor: statusColor,
                    ),
                  ),

                  // Con số khoảng cách trung tâm (Font 7xl Space Grotesk)
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Icon xe Dat Bike vector nhỏ gọn
                      Icon(
                        Icons.two_wheeler_rounded,
                        size: isCompact ? 16 : 22,
                        color: AppColors.textMuted,
                      ),
                      SizedBox(height: isCompact ? 1 : 2),

                      // Con số khoảng cách
                      Text(
                        distText,
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: size > 260 ? 56 : (isCompact ? 34 : 46),
                          fontWeight: FontWeight.w800,
                          height: 1.0,
                          letterSpacing: -1.5,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      SizedBox(height: isCompact ? 2 : 4),

                      // Đơn vị MÉT
                      Text(
                        unitText,
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: isCompact ? 9 : 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 2.0,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            SizedBox(height: isCompact ? 6 : 12),

            // 3. Thanh tín hiệu sóng BLE RSSI & La bàn viền mở (Borderless)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Sóng BLE RSSI
                      Flexible(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: widget.isBleConnected
                                    ? AppColors.primary
                                    : AppColors.textMuted,
                              ),
                            ),
                            const SizedBox(width: 5),
                            Flexible(
                              child: Text(
                                widget.isBleConnected && widget.rssi != null
                                    ? 'RSSI: ${widget.rssi} dBm'
                                    : 'DÒ BLE...',
                                style: GoogleFonts.spaceGrotesk(
                                  fontSize: isCompact ? 9.5 : 10.5,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.textPrimary,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 6),

                      // Góc la bàn
                      Text(
                        _getBearingString(widget.headingDegrees),
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: isCompact ? 9.5 : 10.5,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: isCompact ? 3 : 6),

                  // Dải đo sóng quang học 5 mức hairline
                  _buildRssiTrack(widget.rssi, statusColor),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildRssiTrack(int? rssi, Color activeColor) {
    final bars = _calculateBars(rssi);

    return Container(
      height: 5,
      padding: const EdgeInsets.all(1),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainer,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.surfaceContainerHigh),
      ),
      child: Row(
        children: List.generate(5, (index) {
          final isFilled = index < bars;
          return Expanded(
            child: Container(
              margin: EdgeInsets.only(right: index < 4 ? 2 : 0),
              decoration: BoxDecoration(
                color: isFilled ? activeColor : Colors.transparent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          );
        }),
      ),
    );
  }

  int _calculateBars(int? rssi) {
    if (!widget.isBleConnected || rssi == null) return 1;
    if (rssi >= -50) return 5;
    if (rssi >= -65) return 4;
    if (rssi >= -75) return 3;
    if (rssi >= -85) return 2;
    return 1;
  }
}

/// CustomPainter vẽ vòng cung la bàn, vạch chia độ và kim la bàn quỹ đạo xoay 360 độ
class _PrecisionDialPainter extends CustomPainter {
  final double proximityRatio;
  final double headingDegrees;
  final Color activeColor;

  _PrecisionDialPainter({
    required this.proximityRatio,
    required this.headingDegrees,
    required this.activeColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width / 2) - 24;

    // 1. Đường ray hairline xám nhạt nền
    final trackPaint = Paint()
      ..color = AppColors.surfaceContainerHigh.withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5.5
      ..strokeCap = StrokeCap.round;

    // Vòng cung mở góc dưới (từ 135° đến 405° = 270 độ)
    const startAngle = 135 * (math.pi / 180);
    const sweepAngle = 270 * (math.pi / 180);

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepAngle,
      false,
      trackPaint,
    );

    // 2. Vạch chia độ thể thao mỏng (Tick marks)
    final tickPaint = Paint()
      ..color = AppColors.surfaceContainerHighest
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    const tickCount = 36;
    for (int i = 0; i <= tickCount; i++) {
      final angle = startAngle + (i / tickCount) * sweepAngle;
      final outerR = radius + 11;
      final innerR = radius + 5;

      final p1 = Offset(
        center.dx + innerR * math.cos(angle),
        center.dy + innerR * math.sin(angle),
      );
      final p2 = Offset(
        center.dx + outerR * math.cos(angle),
        center.dy + outerR * math.sin(angle),
      );
      canvas.drawLine(p1, p2, tickPaint);
    }

    // 3. Cung tiến trình khoảng cách tiệm cận (Gradient quang học)
    if (proximityRatio > 0.01) {
      final activeSweep = sweepAngle * proximityRatio;
      final activePaint = Paint()
        ..shader = const LinearGradient(
          colors: [
            Color(0xFF38BDF8),
            Color(0xFFF97316),
            Color(0xFFEA580C),
          ],
        ).createShader(Rect.fromCircle(center: center, radius: radius))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6.5
        ..strokeCap = StrokeCap.round;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        activeSweep,
        false,
        activePaint,
      );
    }

    // 4. Kim la bàn khí động học quỹ đạo (Orbiting Navigation Arrow)
    final rad = (headingDegrees - 90) * (math.pi / 180);
    final needleR = radius + 16;
    final needleCenter = Offset(
      center.dx + needleR * math.cos(rad),
      center.dy + needleR * math.sin(rad),
    );

    canvas.save();
    canvas.translate(needleCenter.dx, needleCenter.dy);
    canvas.rotate(rad + math.pi / 2);

    final needlePaint = Paint()
      ..color = AppColors.primary
      ..style = PaintingStyle.fill;

    final needleShadowPaint = Paint()
      ..color = AppColors.primary.withValues(alpha: 0.3)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);

    final path = Path()
      ..moveTo(0, -9)
      ..lineTo(6, 7)
      ..lineTo(0, 4)
      ..lineTo(-6, 7)
      ..close();

    canvas.drawPath(path, needleShadowPaint);
    canvas.drawPath(path, needlePaint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PrecisionDialPainter oldDelegate) {
    return oldDelegate.proximityRatio != proximityRatio ||
        oldDelegate.headingDegrees != headingDegrees ||
        oldDelegate.activeColor != activeColor;
  }
}

/// Hiệu ứng vòng Sonar Apple Find My mờ nhẹ
class _SubtleSonarPainter extends CustomPainter {
  final double progress;
  final Color color;

  _SubtleSonarPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = (size.width / 2) - 10;

    for (int i = 0; i < 3; i++) {
      final ringProgress = (progress + (i * 0.33)) % 1.0;
      final currentR = 50 + (ringProgress * (maxRadius - 50));
      final opacity = (1.0 - ringProgress).clamp(0.0, 1.0) * 0.22;

      final paint = Paint()
        ..color = color.withValues(alpha: opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;

      canvas.drawCircle(center, currentR, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SubtleSonarPainter oldDelegate) => true;
}
