import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../core/ble/ble_controller.dart' show TripRecord;
import '../../../core/models/merged_trip_session.dart';
import '../../../core/services/trip_export_service.dart';
import '../../../ui/app_theme.dart';

/// Bottom sheet allowing users to export & share a trip session in GPX 1.1, CSV, or KML 2.2 format.
class TripExportSheet extends StatefulWidget {
  final MergedTripSession session;
  final TripRecord? singleTrip;

  const TripExportSheet({
    super.key,
    required this.session,
    this.singleTrip,
  });

  static Future<void> show(
    BuildContext context, {
    required MergedTripSession session,
    TripRecord? singleTrip,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => TripExportSheet(
        session: session,
        singleTrip: singleTrip,
      ),
    );
  }

  @override
  State<TripExportSheet> createState() => _TripExportSheetState();
}

class _TripExportSheetState extends State<TripExportSheet> {
  TripExportFormat? _exportingFormat;

  MergedTripSession get _effectiveSession {
    if (widget.session.allPoints.isEmpty && widget.singleTrip != null) {
      return TripExportService.instance.sessionFromSingleTrip(
        widget.singleTrip!,
        widget.singleTrip!.route,
      );
    }
    return widget.session;
  }

  Future<void> _handleExport(TripExportFormat format) async {
    if (_exportingFormat != null) return;
    setState(() => _exportingFormat = format);
    try {
      await TripExportService.instance.shareSessionExport(_effectiveSession, format);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() => _exportingFormat = null);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Không thể xuất file: $e'),
            backgroundColor: AppColors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = _effectiveSession;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.80,
      ),
      decoration: const BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: AppColors.panelBorderBright)),
        boxShadow: AppColors.modalShadow,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 6, 12, 10),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.ios_share_rounded,
                      color: AppColors.primary,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'XUẤT LỘ TRÌNH & TELEMETRY',
                          style: GoogleFonts.spaceGrotesk(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                            color: AppColors.textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '${session.title} · ${session.totalDistanceKm.toStringAsFixed(1)} km · ${session.allPoints.length} điểm GPS',
                          style: AppTypography.labelSm(color: AppColors.textDim).copyWith(
                            letterSpacing: 0,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: AppColors.textDim),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(color: AppColors.panelBorder, height: 1),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _ExportOptionCard(
                      badge: 'GPX',
                      badgeColor: AppColors.primary,
                      title: 'GPX 1.1 (Relive / Strava / Telemetry Overlay)',
                      subtitle:
                          'Chuẩn GPS đa chặng (<trkseg>) giữ nguyên điểm nghỉ và tốc độ từng giây, tương thích Relive, Strava & video map overlay.',
                      isLoading: _exportingFormat == TripExportFormat.gpx,
                      isDisabled: _exportingFormat != null,
                      onTap: () => _handleExport(TripExportFormat.gpx),
                    ),
                    const SizedBox(height: 10),
                    _ExportOptionCard(
                      badge: 'CSV',
                      badgeColor: AppColors.tertiary,
                      title: 'CSV Telemetry (GoPro / Insta360 / DashWare HUD)',
                      subtitle:
                          'Dữ liệu timestamp, vận tốc, góc hướng & quãng đường tích lũy từng điểm để ghép đồng hồ HUD lên video.',
                      isLoading: _exportingFormat == TripExportFormat.csv,
                      isDisabled: _exportingFormat != null,
                      onTap: () => _handleExport(TripExportFormat.csv),
                    ),
                    const SizedBox(height: 10),
                    _ExportOptionCard(
                      badge: 'KML',
                      badgeColor: AppColors.amber,
                      title: 'KML 3D (Google Earth)',
                      subtitle:
                          'Tuyến đường 3D trực quan kèm ghim điểm đầu/cuối và các điểm dừng nghỉ P1..Pn.',
                      isLoading: _exportingFormat == TripExportFormat.kml,
                      isDisabled: _exportingFormat != null,
                      onTap: () => _handleExport(TripExportFormat.kml),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExportOptionCard extends StatelessWidget {
  final String badge;
  final Color badgeColor;
  final String title;
  final String subtitle;
  final bool isLoading;
  final bool isDisabled;
  final VoidCallback onTap;

  const _ExportOptionCard({
    required this.badge,
    required this.badgeColor,
    required this.title,
    required this.subtitle,
    required this.isLoading,
    required this.isDisabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: isDisabled ? null : onTap,
      child: Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: AppColors.panelSecondary,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.panelBorderBright),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: badgeColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: badgeColor.withValues(alpha: 0.3)),
              ),
              child: Center(
                child: Text(
                  badge,
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: badgeColor,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: AppTypography.labelSm(color: AppColors.textDim).copyWith(
                      height: 1.35,
                      letterSpacing: 0,
                      fontWeight: FontWeight.w400,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    Icons.share_rounded,
                    size: 18,
                    color: isDisabled ? AppColors.textMuted : badgeColor,
                  ),
          ],
        ),
      ),
    );
  }
}
