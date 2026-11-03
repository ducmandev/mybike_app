// Kinetic Stitch EV Design System — Core Widgets
// Structural clarity, hyper-legibility, pure white cards on luminous canvas,
// hairline borders (#E2E8F0), soft ambient depth, Space Grotesk & Plus Jakarta Sans.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_theme.dart';

/// Thẻ Card chuẩn Level 1 của Kinetic Stitch EV:
/// Nền trắng tinh khiết, viền mảnh 1px #E2E8F0, góc bo 16px (rounded-lg),
/// đổ bóng vi mô mềm mại (hyper-diffused ambient shadow).
class Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final Color? borderColor;
  final double borderRadius;
  final bool hasActiveHalo;
  final VoidCallback? onTap;

  const Panel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.color,
    this.borderColor,
    this.borderRadius = 20,
    this.hasActiveHalo = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color ?? AppColors.panel,
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(
          color: borderColor ?? (hasActiveHalo ? AppColors.secondary : AppColors.panelBorder),
          width: 1,
        ),
        boxShadow: hasActiveHalo
            ? [
                ...AppColors.cardShadow,
                AppColors.activeHalo,
              ]
            : AppColors.cardShadow,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(borderRadius),
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// Status Pill / Chip: Bo tròn tuyệt đối (Stadium / Pill 9999px)
/// Nhãn in hoa với tracking 0.06em và điểm neon chỉ thị trạng thái.
class StatusPill extends StatelessWidget {
  final String label;
  final Color color;
  final bool pulse;
  final IconData? icon;

  const StatusPill({
    super.key,
    required this.label,
    required this.color,
    this.pulse = false,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(9999),
        border: Border.all(color: color.withValues(alpha: 0.35), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
          ] else if (pulse) ...[
            _PulsingDot(color: color),
            const SizedBox(width: 8),
          ] else ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Text(
              label.toUpperCase(),
              style: GoogleFonts.plusJakartaSans(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.06 * 11,
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
        ],
      ),
    );
  }
}

class _PulsingDot extends StatefulWidget {
  final Color color;
  const _PulsingDot({required this.color});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.35, end: 1.0)
          .animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut)),
      child: Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(
          color: widget.color,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// Ô số liệu Metric Tile:
/// Tiêu đề label-sm muted, số liệu Space Grotesk quá khổ với Tabular Figures.
class MetricTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final String? unit;
  final Color? valueColor;
  final Color? accentColor;
  final String? delta;
  final bool deltaPositive;
  final EdgeInsetsGeometry? padding;

  const MetricTile({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.unit,
    this.valueColor,
    this.accentColor,
    this.delta,
    this.deltaPositive = true,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    return Panel(
      padding: padding ?? const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      borderRadius: 16,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: (accentColor ?? AppColors.primary).withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 15, color: accentColor ?? AppColors.primary),
              ),
              if (delta != null)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      deltaPositive ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
                      size: 11,
                      color: deltaPositive ? AppColors.tertiary : AppColors.error,
                    ),
                    const SizedBox(width: 2),
                    Text(
                      delta!,
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: deltaPositive ? AppColors.tertiary : AppColors.error,
                      ),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              label.toUpperCase(),
              maxLines: 1,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.04 * 10.5,
                color: AppColors.textDim,
              ),
            ),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value,
                  maxLines: 1,
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: valueColor ?? AppColors.textPrimary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                if (unit != null) ...[
                  const SizedBox(width: 4),
                  Text(
                    unit!,
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textDim,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Nút điều khiển xe Vehicle Command Button lớn:
/// 56px height, bo tròn 16px (rounded-lg), Space Grotesk title, subtext kỹ thuật.
class VehicleCommandButton extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onPressed;
  final Color backgroundColor;
  final Color foregroundColor;
  final bool isLoading;

  const VehicleCommandButton({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onPressed,
    this.backgroundColor = AppColors.primary,
    this.foregroundColor = Colors.white,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: backgroundColor,
          foregroundColor: foregroundColor,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        onPressed: isLoading ? null : onPressed,
        child: isLoading
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor: AlwaysStoppedAnimation<Color>(foregroundColor),
                ),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 22),
                  const SizedBox(width: 10),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.2,
                        ),
                      ),
                      if (subtitle != null) ...[
                        Text(
                          subtitle!,
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 11,
                            fontWeight: FontWeight.w400,
                            color: foregroundColor.withValues(alpha: 0.8),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

/// Điều khiển thao tác nhanh dạng pill / dock (thay thế nút tròn cũ).
class RoundControl extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback? onTap;
  final Color? activeColor;

  const RoundControl({
    super.key,
    required this.icon,
    required this.label,
    required this.enabled,
    this.onTap,
    this.activeColor,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveColor = activeColor ?? AppColors.primary;
    return Column(
      children: [
        Opacity(
          opacity: enabled ? 1.0 : 0.45,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: enabled ? onTap : null,
              child: Container(
                width: 58,
                height: 54,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: AppColors.panel,
                  border: Border.all(
                    color: enabled
                        ? effectiveColor.withValues(alpha: 0.4)
                        : AppColors.panelBorder,
                    width: 1.2,
                  ),
                  boxShadow: AppColors.cardShadow,
                ),
                child: Center(
                  child: Icon(
                    icon,
                    size: 24,
                    color: enabled ? effectiveColor : AppColors.textDim,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            label,
            maxLines: 1,
            style: GoogleFonts.plusJakartaSans(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: enabled ? AppColors.textPrimary : AppColors.textDim,
            ),
          ),
        ),
      ],
    );
  }
}

/// Thanh trạng thái Pin & Quãng đường dạng Capsule (EV Exclusive)
class BatteryRangeCapsule extends StatelessWidget {
  final int percent;
  final double kmLeft;
  final bool isCharging;
  final VoidCallback? onTap;

  const BatteryRangeCapsule({
    super.key,
    required this.percent,
    required this.kmLeft,
    this.isCharging = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = isCharging
        ? AppColors.secondary
        : (percent < 20
            ? AppColors.error
            : (percent > 60 ? AppColors.tertiary : AppColors.primary));

    return Panel(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      borderRadius: 16,
      hasActiveHalo: isCharging,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isCharging ? Icons.bolt_rounded : Icons.battery_charging_full_rounded,
                color: color,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                isCharging ? 'ĐANG SẠC PIN' : 'TRẠNG THÁI PIN & CỰ LY',
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.05 * 11,
                  color: AppColors.textDim,
                ),
              ),
              const Spacer(),
              Text(
                '$percent%',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: color,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Capsule Progress Bar
          ClipRRect(
            borderRadius: BorderRadius.circular(9999),
            child: Container(
              height: 10,
              color: AppColors.panelSecondary,
              child: Stack(
                children: [
                  FractionallySizedBox(
                    widthFactor: (percent / 100.0).clamp(0.0, 1.0),
                    child: Container(
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(9999),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Ước tính quãng đường còn lại',
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 12,
                  color: AppColors.textDim,
                ),
              ),
              Text(
                '${kmLeft.toStringAsFixed(1)} km',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          if (onTap != null) ...[
            const SizedBox(height: 10),
            const Divider(color: AppColors.panelBorder, height: 1),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Bác Sĩ Pin & Chẩn đoán OBD 24-Cell',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primary,
                  ),
                ),
                const Icon(Icons.arrow_forward_ios_rounded, size: 12, color: AppColors.primary),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Banner thông báo chuẩn Kinetic Stitch EV:
/// Viền hairline mảnh, nền màu nhạt độ sáng cao, chữ dễ đọc.
class NoticeBanner extends StatelessWidget {
  final Color color;
  final String text;
  final Widget? trailing;

  const NoticeBanner({
    super.key,
    required this.color,
    required this.text,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.30), width: 1),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: color,
                height: 1.3,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Tiêu đề phân mục cấu trúc (Section Title)
class SectionTitle extends StatelessWidget {
  final String text;
  final Widget? action;

  const SectionTitle(this.text, {super.key, this.action});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 3.5,
            height: 14,
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              color: AppColors.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: Text(
              text.toUpperCase(),
              style: GoogleFonts.plusJakartaSans(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          if (action != null) ...[
            const SizedBox(width: 8),
            action!,
          ],
        ],
      ),
    );
  }
}
