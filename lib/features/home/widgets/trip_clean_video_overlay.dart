import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../ui/app_theme.dart';

/// Compact Clean Video Overlay HUD pill displaying speed, distance, and elapsed/clock time.
class TripCleanVideoOverlay extends StatelessWidget {
  final double speedKmh;
  final double distanceKm;
  final double? gpsDistanceKm;
  final String durationText;
  final bool isLive;
  final VoidCallback onExit;

  const TripCleanVideoOverlay({
    super.key,
    required this.speedKmh,
    required this.distanceKm,
    this.gpsDistanceKm,
    required this.durationText,
    this.isLive = false,
    required this.onExit,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTap: onExit,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width - 28,
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.textPrimary.withValues(alpha: 0.90),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: AppColors.primary.withValues(alpha: 0.45),
                ),
                boxShadow: AppColors.modalShadow,
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isLive) ...[
                      Container(
                        width: 7,
                        height: 7,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.tertiary,
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    Text(
                      '${speedKmh.toStringAsFixed(0)} km/h',
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: AppColors.secondaryContainer,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      width: 1,
                      height: 14,
                      color: AppColors.panelBorder.withValues(alpha: 0.24),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      (gpsDistanceKm != null && gpsDistanceKm! > 0)
                          ? '${distanceKm.toStringAsFixed(1)} km · GPS ${gpsDistanceKm!.toStringAsFixed(1)} km'
                          : '${distanceKm.toStringAsFixed(1)} km',
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.panel,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      width: 1,
                      height: 14,
                      color: AppColors.panelBorder.withValues(alpha: 0.24),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      durationText,
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.panel.withValues(alpha: 0.72),
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: onExit,
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppColors.panel.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            'Thoát',
                            style: GoogleFonts.spaceGrotesk(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppColors.panel,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
