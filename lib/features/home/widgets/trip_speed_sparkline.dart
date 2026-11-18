import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/services/map_tile_service.dart';
import '../../../ui/app_theme.dart';

/// Interactive speed profile sparkline scrubber supporting tap & horizontal drag seeking.
class TripSpeedSparkline extends StatelessWidget {
  final List<double> speeds;
  final double progress;
  final ValueChanged<double>? onSeekProgress;
  final bool useMonoHighlight;
  final double height;

  const TripSpeedSparkline({
    super.key,
    required this.speeds,
    required this.progress,
    this.onSeekProgress,
    this.useMonoHighlight = false,
    this.height = 28,
  });

  @override
  Widget build(BuildContext context) {
    if (speeds.length < 2) {
      return SizedBox(height: height);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        void seekFromDx(double dx) {
          if (onSeekProgress == null) return;
          final w = constraints.maxWidth;
          if (w <= 0) return;
          onSeekProgress!((dx / w).clamp(0.0, 1.0));
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: onSeekProgress != null ? (d) => seekFromDx(d.localPosition.dx) : null,
          onHorizontalDragUpdate: onSeekProgress != null ? (d) => seekFromDx(d.localPosition.dx) : null,
          child: SizedBox(
            height: height,
            width: double.infinity,
            child: CustomPaint(
              painter: _SpeedSparklinePainter(
                speeds: speeds,
                progress: progress.clamp(0.0, 1.0),
                useMonoHighlight: useMonoHighlight,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SpeedSparklinePainter extends CustomPainter {
  final List<double> speeds;
  final double progress;
  final bool useMonoHighlight;

  const _SpeedSparklinePainter({
    required this.speeds,
    required this.progress,
    this.useMonoHighlight = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final n = speeds.length;
    if (n < 2 || size.width <= 0 || size.height <= 0) return;

    double maxSpeed = 20.0;
    for (final s in speeds) {
      if (s > maxSpeed) maxSpeed = s;
    }

    final sampleCount = math.min(n, 160);
    final offsets = <Offset>[];
    for (int i = 0; i < sampleCount; i++) {
      final pointIdx = sampleCount == n
          ? i
          : ((i / (sampleCount - 1)) * (n - 1)).round().clamp(0, n - 1);
      final x = (i / (sampleCount - 1)) * size.width;
      final spd = speeds[pointIdx].clamp(0.0, maxSpeed);
      final normalized = spd / maxSpeed;
      final y = size.height - 2.0 - normalized * (size.height - 5.0);
      offsets.add(Offset(x, y));
    }

    final fullLinePath = Path()..moveTo(offsets.first.dx, offsets.first.dy);
    for (int i = 1; i < offsets.length; i++) {
      fullLinePath.lineTo(offsets[i].dx, offsets[i].dy);
    }

    final unplayedStroke = Paint()
      ..color = AppColors.textMuted.withValues(alpha: 0.40)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(fullLinePath, unplayedStroke);

    final progressRatio = progress.clamp(0.0, 1.0);
    final cursorIdx = (progressRatio * (n - 1)).round().clamp(0, n - 1);
    final cursorX = progressRatio * size.width;
    final cursorSpd = speeds[cursorIdx].clamp(0.0, maxSpeed);
    final cursorY = size.height - 2.0 - (cursorSpd / maxSpeed) * (size.height - 5.0);

    final playedColor = useMonoHighlight
        ? AppColors.primary
        : MapTileService.getHighContrastSpeedColor(cursorSpd);

    if (cursorX > 0.5) {
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(0, 0, cursorX, size.height));

      final fillPath = Path.from(fullLinePath)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close();

      final fillPaint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            playedColor.withValues(alpha: 0.28),
            playedColor.withValues(alpha: 0.03),
          ],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
      canvas.drawPath(fillPath, fillPaint);

      final playedStroke = Paint()
        ..color = playedColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      canvas.drawPath(fullLinePath, playedStroke);

      canvas.restore();
    }

    final cursorLinePaint = Paint()
      ..color = AppColors.primary.withValues(alpha: 0.85)
      ..strokeWidth = 1.5;
    canvas.drawLine(
      Offset(cursorX, 0),
      Offset(cursorX, size.height),
      cursorLinePaint,
    );

    final dotPaint = Paint()..color = AppColors.primary;
    final dotBorderPaint = Paint()
      ..color = AppColors.panel
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawCircle(Offset(cursorX, cursorY), 3.2, dotPaint);
    canvas.drawCircle(Offset(cursorX, cursorY), 3.2, dotBorderPaint);
  }

  @override
  bool shouldRepaint(covariant _SpeedSparklinePainter oldDelegate) {
    return progress != oldDelegate.progress ||
        useMonoHighlight != oldDelegate.useMonoHighlight ||
        speeds != oldDelegate.speeds ||
        speeds.length != oldDelegate.speeds.length;
  }
}
