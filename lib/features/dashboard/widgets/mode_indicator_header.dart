import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../core/proto/bike_log.dart';
import '../../../ui/app_theme.dart';

/// Hiển thị Chế độ Lái (Ride Mode) đặt ở chính giữa phía trên taplo tốc độ
/// Thiết kế không viền (borderless) với hiệu ứng trượt ngang mờ dần (Slide & Fade) khi đổi mode.
class ModeIndicatorHeader extends StatelessWidget {
  final BikeState state;
  final bool isParking;
  final bool isLocked;

  const ModeIndicatorHeader({
    super.key,
    required this.state,
    this.isParking = false,
    this.isLocked = false,
  });

  (String, Color) _getModeInfo() {
    if (isLocked) {
      return ('ĐÃ KHÓA XE (LOCKED)', AppColors.error);
    }
    if (isParking) {
      return ('CHÂN CHỐNG HẠ', AppColors.amber);
    }
    return switch (state) {
      BikeState.super_ => ('SPORT (S)', const Color(0xFFEA580C)),
      BikeState.drive => ('DRIVE (D)', AppColors.primary),
      BikeState.turtle => ('ECO (E)', AppColors.tertiary),
      BikeState.parking => ('ĐỖ XE (PARKING)', AppColors.amber),
      BikeState.reverse => ('LÙI (REVERSE)', const Color(0xFF8B5CF6)),
      BikeState.cruiseControl => ('CRUISE CONTROL', AppColors.secondary),
      BikeState.standBy => ('SẴN SÀNG (STANDBY)', AppColors.primary),
      BikeState.off => ('TẮT MÁY (OFF)', AppColors.textDim),
      BikeState.lock => ('ĐÃ KHÓA XE', AppColors.error),
    };
  }

  @override
  Widget build(BuildContext context) {
    final (title, color) = _getModeInfo();

    return Center(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 320),
        transitionBuilder: (child, animation) {
          final slide = Tween<Offset>(
            begin: const Offset(0.12, 0.0),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic));

          return SlideTransition(
            position: slide,
            child: FadeTransition(opacity: animation, child: child),
          );
        },
        child: FittedBox(
          key: ValueKey(title),
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color,
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: 0.45),
                      blurRadius: 6,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Text(
                title,
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
