import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../core/ble/ble_controller.dart' show TripRecord;
import '../../../core/services/trip_analytics_service.dart';
import '../../../core/utils/app_formatters.dart';
import '../../../ui/app_theme.dart';
import '../../../ui/widgets.dart';

/// Bottom sheet thống kê hành trình 7 ngày / 30 ngày theo phong cách Kinetic Stitch EV.
class TripStatsInsightsSheet extends StatefulWidget {
  final List<TripRecord> trips;

  const TripStatsInsightsSheet({
    super.key,
    required this.trips,
  });

  static Future<void> show(BuildContext context, List<TripRecord> trips) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => TripStatsInsightsSheet(trips: trips),
    );
  }

  @override
  State<TripStatsInsightsSheet> createState() => _TripStatsInsightsSheetState();
}

class _TripStatsInsightsSheetState extends State<TripStatsInsightsSheet> {
  int _selectedDays = 7;
  int? _selectedBucketIndex;

  @override
  Widget build(BuildContext context) {
    final summary = TripAnalyticsService.summarize(
      widget.trips,
      days: _selectedDays,
    );
    final buckets = summary.dailyBuckets;
    final activeIdx = (_selectedBucketIndex != null &&
            _selectedBucketIndex! >= 0 &&
            _selectedBucketIndex! < buckets.length)
        ? _selectedBucketIndex!
        : (buckets.isNotEmpty ? buckets.length - 1 : -1);
    final activeBucket = activeIdx >= 0 ? buckets[activeIdx] : null;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.86,
      ),
      decoration: const BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: AppColors.panelBorderBright)),
        boxShadow: AppColors.modalShadow,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetDragHandle(
            width: 44,
            margin: EdgeInsets.only(top: 10, bottom: 6),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 6, 12, 8),
            child: Row(
              children: [
                const TemplateBadgeIcon(
                  icon: Icons.bar_chart_rounded,
                  color: AppColors.primary,
                  size: 36,
                  iconSize: 20,
                  borderRadius: 10,
                  bordered: false,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'THỐNG KÊ HÀNH TRÌNH',
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
                        'Hiệu suất di chuyển & tiết kiệm năng lượng',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 11,
                          color: AppColors.textDim,
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

          // Segmented Toggle: 7 ngày / 30 ngày
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: AppColors.panelSecondary,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.panelBorderBright),
              ),
              child: Row(
                children: [
                  _buildSegmentTab(days: 7, label: '7 ngày'),
                  const SizedBox(width: 4),
                  _buildSegmentTab(days: 30, label: '30 ngày'),
                ],
              ),
            ),
          ),

          const Divider(color: AppColors.panelBorder, height: 1),

          Expanded(
            child: SafeArea(
              top: false,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
                children: [
                  // 2x2 KPI Cards
                  Row(
                    children: [
                      Expanded(
                        child: _buildKpiCard(
                          icon: Icons.route_rounded,
                          iconColor: AppColors.primary,
                          label: 'Tổng km xe (ODO)',
                          value: '${summary.totalDistanceKm.toStringAsFixed(1)} km',
                          subValue: summary.hasGpsDistance
                              ? 'GPS ${summary.totalGpsDistanceKm.toStringAsFixed(1)} km · TB ${summary.avgDistancePerTripKm.toStringAsFixed(1)} km'
                              : 'TB ${summary.avgDistancePerTripKm.toStringAsFixed(1)} km/chuyến',
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _buildKpiCard(
                          icon: Icons.two_wheeler_rounded,
                          iconColor: AppColors.secondary,
                          label: 'Số chuyến',
                          value: '${summary.tripCount}',
                          subValue: 'Max ${summary.maxSpeedKmh.toStringAsFixed(0)} km/h',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _buildKpiCard(
                          icon: Icons.timer_outlined,
                          iconColor: AppColors.amber,
                          label: 'Thời gian chạy',
                          value: AppFormatters.formatDurationReadable(
                            summary.totalMovingDurationSec,
                          ),
                          subValue: 'TB ${summary.avgSpeedKmh.toStringAsFixed(0)} km/h',
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _buildKpiCard(
                          icon: Icons.local_gas_station_outlined,
                          iconColor: AppColors.tertiary,
                          label: 'Tiết kiệm xăng',
                          value: AppFormatters.formatVndCompact(
                            summary.estimatedFuelSavedVnd,
                          ),
                          subValue: 'Giảm ${summary.co2SavedKg.toStringAsFixed(2)} kg CO₂',
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  // CO2 Highlight Pill
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: AppColors.tertiary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: AppColors.tertiary.withValues(alpha: 0.28),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.eco_rounded,
                          size: 18,
                          color: AppColors.tertiary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'CO₂ giảm thải: ${summary.co2SavedKg.toStringAsFixed(2)} kg · Tiết kiệm xăng ước tính ${AppFormatters.formatVndCompact(summary.estimatedFuelSavedVnd)}',
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 14),

                  // Daily km Bar Chart Card
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.panel,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: AppColors.panelBorderBright),
                      boxShadow: AppColors.cardShadow,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'BIỂU ĐỒ KM THEO NGÀY',
                                style: GoogleFonts.spaceGrotesk(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.4,
                                  color: AppColors.textPrimary,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (activeBucket != null)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.primary.withValues(alpha: 0.10),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  activeBucket.hasGpsDistance
                                      ? '${activeBucket.shortDayLabel} · ${activeBucket.distanceKm.toStringAsFixed(1)} km · GPS ${activeBucket.gpsDistanceKm.toStringAsFixed(1)} km'
                                      : '${activeBucket.shortDayLabel} · ${activeBucket.distanceKm.toStringAsFixed(1)} km',
                                  style: GoogleFonts.spaceGrotesk(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.primary,
                                    fontFeatures: const [FontFeature.tabularFigures()],
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),

                        _buildDailyBarChart(buckets, activeIdx),

                        if (summary.tripCount == 0) ...[
                          const SizedBox(height: 10),
                          Center(
                            child: Text(
                              'Chưa có chuyến đi nào trong $_selectedDays ngày qua.',
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 11.5,
                                color: AppColors.textDim,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSegmentTab({required int days, required String label}) {
    final isSelected = _selectedDays == days;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () {
          if (_selectedDays != days) {
            setState(() {
              _selectedDays = days;
              _selectedBucketIndex = null;
            });
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: isSelected ? AppColors.panel : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: isSelected
                ? Border.all(color: AppColors.panelBorderBright)
                : null,
            boxShadow: isSelected ? AppColors.cardShadow : null,
          ),
          child: Center(
            child: Text(
              label,
              style: GoogleFonts.spaceGrotesk(
                fontSize: 12.5,
                fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                color: isSelected ? AppColors.primary : AppColors.textDim,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildKpiCard({
    required IconData icon,
    required Color iconColor,
    required String label,
    required String value,
    required String subValue,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.panelBorderBright),
        boxShadow: AppColors.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              TemplateBadgeIcon(
                icon: icon,
                color: iconColor,
                size: 27,
                iconSize: 15,
                borderRadius: 8,
                bordered: false,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textDim,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: GoogleFonts.spaceGrotesk(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subValue,
            style: GoogleFonts.plusJakartaSans(
              fontSize: 10.5,
              color: AppColors.textDim,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildDailyBarChart(List<DailyTripBucket> buckets, int activeIdx) {
    if (buckets.isEmpty) {
      return const SizedBox(height: 110);
    }
    final maxKm = math.max(
      1.0,
      buckets.fold<double>(0.0, (m, b) => math.max(m, b.distanceKm)),
    );
    final isCompact30 = buckets.length > 10;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: isCompact30 ? 112 : 132,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: buckets.asMap().entries.map((entry) {
              final idx = entry.key;
              final bucket = entry.value;
              final isSelected = idx == activeIdx;
              final ratio = (bucket.distanceKm / maxKm).clamp(0.0, 1.0);
              final hasData = bucket.distanceKm > 0;

              return Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _selectedBucketIndex = idx),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: isCompact30 ? 1.0 : 4.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (!isCompact30)
                          SizedBox(
                            height: 14,
                            child: hasData
                                ? FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      bucket.distanceKm.toStringAsFixed(1),
                                      style: GoogleFonts.spaceGrotesk(
                                        fontSize: 9,
                                        fontWeight: FontWeight.w700,
                                        color: isSelected
                                            ? AppColors.primary
                                            : AppColors.textDim,
                                        fontFeatures: const [
                                          FontFeature.tabularFigures(),
                                        ],
                                      ),
                                    ),
                                  )
                                : const SizedBox.shrink(),
                          ),
                        Expanded(
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: hasData
                                ? FractionallySizedBox(
                                    heightFactor: math.max(0.08, ratio),
                                    widthFactor: 1.0,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: isSelected
                                            ? AppColors.primary
                                            : AppColors.secondary.withValues(alpha: 0.72),
                                        borderRadius: BorderRadius.vertical(
                                          top: Radius.circular(isCompact30 ? 3 : 6),
                                        ),
                                      ),
                                    ),
                                  )
                                : Container(
                                    height: 3,
                                    decoration: BoxDecoration(
                                      color: isSelected
                                          ? AppColors.primary.withValues(alpha: 0.4)
                                          : AppColors.surfaceContainerHigh,
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                          ),
                        ),
                        if (!isCompact30) ...[
                          const SizedBox(height: 6),
                          SizedBox(
                            height: 14,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                bucket.shortDayLabel,
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 9.5,
                                  fontWeight: isSelected
                                      ? FontWeight.w800
                                      : FontWeight.w600,
                                  color: isSelected
                                      ? AppColors.primary
                                      : AppColors.textDim,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        if (isCompact30) ...[
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              buckets.first,
              buckets[(buckets.length * 0.25).floor()],
              buckets[(buckets.length * 0.5).floor()],
              buckets[(buckets.length * 0.75).floor()],
              buckets.last,
            ].map((b) {
              return Text(
                b.shortDayLabel,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textDim,
                ),
              );
            }).toList(),
          ),
        ],
      ],
    );
  }
}
