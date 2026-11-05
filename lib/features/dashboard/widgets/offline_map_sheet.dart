import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/services/offline_map_service.dart';
import '../../../core/services/map_tile_service.dart';
import '../../../core/services/trip_gps_tracker.dart';
import '../../../ui/app_theme.dart';

/// Bottom Sheet Cho Phép Chọn Vùng & Tải Dữ Liệu Bản Đồ Offline
/// Tinh gọn chỉ 3 khu vực (5km, 10km, vùng màn hình hiện tại)
/// Hỗ trợ tải ngầm minh bạch và Tiếp Tục Tải (Resume) khi thoát/mở lại app.
class OfflineMapSheet extends StatefulWidget {
  final LatLngBounds? currentMapBounds;

  const OfflineMapSheet({
    super.key,
    this.currentMapBounds,
  });

  static Future<void> show(BuildContext context, {LatLngBounds? currentMapBounds}) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => OfflineMapSheet(currentMapBounds: currentMapBounds),
    );
  }

  @override
  State<OfflineMapSheet> createState() => _OfflineMapSheetState();
}

class _OfflineMapSheetState extends State<OfflineMapSheet> {
  final _service = OfflineMapService.instance;

  String _selectedRegionKey = 'my_location_5km';
  int _minZoom = 13;
  int _maxZoom = 15;

  LatLng? _myLocation;
  ({int tileCount, int totalBytes, String sizeText}) _cacheStats =
      (tileCount: 0, totalBytes: 0, sizeText: '0.0 MB');

  Map<String, dynamic>? _pendingTask;
  bool _isLoadingStats = true;

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    final stats = await _service.getCacheStats();
    final pos = await TripGpsTracker.instance.getCurrentLocation();
    final task = await _service.getPendingTask();
    if (!mounted) return;
    setState(() {
      _cacheStats = stats;
      if (pos != null) {
        _myLocation = LatLng(pos.latitude, pos.longitude);
      }
      _pendingTask = task;
      _isLoadingStats = false;
    });
  }

  String _getSelectedRegionName() {
    if (_selectedRegionKey == 'my_location_5km') {
      return 'Quanh vị trí xe (Bán kính 5 km)';
    }
    if (_selectedRegionKey == 'my_location_10km') {
      return 'Quanh vị trí xe (Bán kính 10 km)';
    }
    return 'Vùng Màn Hình Hiện Tại';
  }

  LatLngBounds _getSelectedBounds() {
    final center = _myLocation ?? const LatLng(10.7719, 106.7195);
    if (_selectedRegionKey == 'my_location_5km') {
      return OfflineMapService.createRadiusBounds(center, 5.0);
    }
    if (_selectedRegionKey == 'my_location_10km') {
      return OfflineMapService.createRadiusBounds(center, 10.0);
    }
    if (_selectedRegionKey == 'current_viewport' && widget.currentMapBounds != null) {
      return widget.currentMapBounds!;
    }
    return OfflineMapService.createRadiusBounds(center, 5.0);
  }

  int _calculateEstimatedTiles() {
    final bounds = _getSelectedBounds();
    return _service.calculateTileList(
      bounds: bounds,
      minZoom: _minZoom,
      maxZoom: _maxZoom,
    ).length;
  }

  String _estimateSizeText(int tileCount) {
    final mb = (tileCount * 25) / 1024.0;
    return '~${mb.toStringAsFixed(1)} MB';
  }

  Future<void> _startDownload() async {
    final bounds = _getSelectedBounds();
    final regionName = _getSelectedRegionName();

    await _service.downloadRegion(
      bounds: bounds,
      minZoom: _minZoom,
      maxZoom: _maxZoom,
      regionName: regionName,
      urlTemplate: MapTileService.defaultUrlTemplate,
    );

    final stats = await _service.getCacheStats();
    final task = await _service.getPendingTask();
    if (!mounted) return;
    setState(() {
      _cacheStats = stats;
      _pendingTask = task;
    });
  }

  Future<void> _resumeDownload() async {
    await _service.resumeDownload();
    final stats = await _service.getCacheStats();
    final task = await _service.getPendingTask();
    if (!mounted) return;
    setState(() {
      _cacheStats = stats;
      _pendingTask = task;
    });
  }

  Future<void> _clearPendingTask() async {
    await _service.clearPendingTask();
    setState(() => _pendingTask = null);
  }

  Future<void> _clearCache() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Xóa Bản Đồ Offline?',
          style: GoogleFonts.spaceGrotesk(
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        content: Text(
          'Toàn bộ ${_cacheStats.tileCount} gạch bản đồ (${_cacheStats.sizeText}) đã lưu trên thiết bị sẽ bị xóa để giải phóng bộ nhớ.',
          style: GoogleFonts.plusJakartaSans(color: AppColors.textDim, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('HỦY', style: GoogleFonts.plusJakartaSans(color: AppColors.textDim, fontWeight: FontWeight.w700)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.red,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('XÓA HẾT', style: GoogleFonts.plusJakartaSans(color: Colors.white, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _service.clearCache();
      final stats = await _service.getCacheStats();
      if (!mounted) return;
      setState(() => _cacheStats = stats);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Đã dọn dẹp bộ nhớ đệm bản đồ offline.'),
          backgroundColor: AppColors.tertiary,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<DownloadProgress>(
      valueListenable: _service.progressNotifier,
      builder: (context, progress, _) {
        final isDownloading = progress.isRunning;
        final estTiles = _calculateEstimatedTiles();
        final estSize = _estimateSizeText(estTiles);

        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.88,
          ),
          decoration: const BoxDecoration(
            color: AppColors.panel,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            border: Border(
              top: BorderSide(color: AppColors.panelBorderBright, width: 1),
            ),
            boxShadow: AppColors.modalShadow,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag handle
              Container(
                margin: const EdgeInsets.only(top: 10, bottom: 6),
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),

              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 16, 12),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.downloading_rounded, color: AppColors.primary, size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'TẢI BẢN ĐỒ OFFLINE',
                            style: GoogleFonts.spaceGrotesk(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: AppColors.textPrimary,
                              letterSpacing: 0.5,
                            ),
                          ),
                          Text(
                            '0ms latency · Xem bản đồ khi mất sóng 4G/LTE',
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 11,
                              color: AppColors.textDim,
                            ),
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

              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                  children: [
                    // Banner Phát hiện tác vụ dở dang có thể Resume
                    if (_pendingTask != null && !isDownloading) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFEF3C7),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: AppColors.amber),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.history_rounded, color: AppColors.amber, size: 20),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'LẦN TẢI CHƯA HOÀN TẤT',
                                    style: GoogleFonts.spaceGrotesk(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w800,
                                      color: const Color(0xFF92400E),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Phát hiện tác vụ tải trước đó chưa xong: "${_pendingTask!['regionName']}". Bạn có thể tiếp tục tải lại các ô còn thiếu.',
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 11.5,
                                color: const Color(0xFF78350F),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: AppColors.amber,
                                      foregroundColor: Colors.white,
                                      elevation: 0,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                    ),
                                    onPressed: _resumeDownload,
                                    icon: const Icon(Icons.play_arrow_rounded, size: 18),
                                    label: Text(
                                      'TIẾP TỤC TẢI',
                                      style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700, fontSize: 11.5),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                TextButton(
                                  onPressed: _clearPendingTask,
                                  child: Text(
                                    'BỎ QUA',
                                    style: GoogleFonts.plusJakartaSans(color: const Color(0xFF92400E), fontWeight: FontWeight.w700, fontSize: 11.5),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],

                    // 1. Thẻ dung lượng cache hiện có
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.panelSecondary,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: AppColors.panelBorderBright),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.storage_rounded, color: AppColors.tertiary, size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'BỘ NHỚ OFFLINE ĐÃ LƯU TRÊN MÁY',
                                  style: GoogleFonts.plusJakartaSans(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.textDim,
                                  ),
                                ),
                                Text(
                                  _isLoadingStats
                                      ? 'Đang kiểm tra…'
                                      : '${_cacheStats.sizeText} (${_cacheStats.tileCount} gạch bản đồ)',
                                  style: GoogleFonts.spaceGrotesk(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (_cacheStats.tileCount > 0 && !isDownloading)
                            TextButton.icon(
                              onPressed: _clearCache,
                              icon: const Icon(Icons.delete_outline_rounded, size: 16, color: AppColors.red),
                              label: Text(
                                'XÓA',
                                style: GoogleFonts.plusJakartaSans(
                                  color: AppColors.red,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

                    // 2. CHỌN KHU VỰC CẦN TẢI (CHỈ 3 KHU VỰC)
                    Text(
                      'CHỌN KHU VỰC CẦN TẢI',
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                        color: AppColors.textDim,
                      ),
                    ),
                    const SizedBox(height: 8),

                    _regionOption(
                      keyId: 'my_location_5km',
                      icon: Icons.my_location_rounded,
                      title: 'Quanh vị trí xe (5 km)',
                      subtitle: _myLocation != null
                          ? 'Tọa độ: ${_myLocation!.latitude.toStringAsFixed(3)}°, ${_myLocation!.longitude.toStringAsFixed(3)}°'
                          : 'Khu vực xe đang dừng đỗ hàng ngày',
                    ),
                    _regionOption(
                      keyId: 'my_location_10km',
                      icon: Icons.radar_rounded,
                      title: 'Quanh vị trí xe (10 km)',
                      subtitle: 'Bao quát toàn bộ quận huyện và vành đai',
                    ),
                    _regionOption(
                      keyId: 'current_viewport',
                      icon: Icons.crop_free_rounded,
                      title: 'Vùng màn hình hiện tại',
                      subtitle: widget.currentMapBounds != null
                          ? 'Theo đúng khung hình bạn đang xem trên bản đồ'
                          : 'Tọa độ tâm bản đồ hiện hành',
                    ),

                    const SizedBox(height: 16),

                    // 3. Mức độ chi tiết
                    Text(
                      'MỨC ĐỘ CHI TIẾT BẢN ĐỒ',
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                        color: AppColors.textDim,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: _zoomOption(
                            title: 'Tiêu Chuẩn',
                            subtitle: 'Đại lộ, quốc lộ (Z13-14)',
                            selected: _maxZoom == 14,
                            onTap: () => setState(() {
                              _minZoom = 13;
                              _maxZoom = 14;
                            }),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _zoomOption(
                            title: 'Chi Tiết (Khuyên dùng)',
                            subtitle: 'Tên đường & ngõ hẻm (Z13-15)',
                            selected: _maxZoom == 15,
                            onTap: () => setState(() {
                              _minZoom = 13;
                              _maxZoom = 15;
                            }),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 16),

                    // 4. Tiến trình tải thời gian thực
                    if (isDownloading || progress.isCompleted || progress.isPaused) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: progress.isCompleted
                              ? const Color(0xFFECFDF5)
                              : (progress.isPaused ? const Color(0xFFFEF3C7) : const Color(0xFFEFF6FF)),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: progress.isCompleted
                                ? AppColors.tertiary
                                : (progress.isPaused ? AppColors.amber : AppColors.primary),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Row(
                                    children: [
                                      if (isDownloading) ...[
                                        const SizedBox(
                                          width: 14,
                                          height: 14,
                                          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                                        ),
                                        const SizedBox(width: 8),
                                      ],
                                      Expanded(
                                        child: Text(
                                          progress.isCompleted
                                              ? '✅ ĐÃ HOÀN TẤT TẢI'
                                              : (progress.isPaused ? '⏸️ ĐÃ TẠM DỪNG' : 'ĐANG TẢI BẢN ĐỒ…'),
                                          style: GoogleFonts.spaceGrotesk(
                                            fontSize: 11.5,
                                            fontWeight: FontWeight.w800,
                                            color: progress.isCompleted
                                                ? AppColors.tertiary
                                                : (progress.isPaused ? AppColors.amber : AppColors.primary),
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '${progress.percentInt}%',
                                  style: GoogleFonts.spaceGrotesk(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w800,
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(9999),
                              child: LinearProgressIndicator(
                                value: progress.percent,
                                minHeight: 8,
                                backgroundColor: AppColors.surfaceContainer,
                                valueColor: AlwaysStoppedAnimation(
                                  progress.isCompleted
                                      ? AppColors.tertiary
                                      : (progress.isPaused ? AppColors.amber : AppColors.primary),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'Đã nạp ${progress.current}/${progress.total} gạch (${progress.sizeMbText})',
                                  style: GoogleFonts.plusJakartaSans(
                                    fontSize: 11,
                                    color: AppColors.textDim,
                                  ),
                                ),
                                if (isDownloading)
                                  Text(
                                    'Có thể đóng màn hình này',
                                    style: GoogleFonts.plusJakartaSans(
                                      fontSize: 10,
                                      color: AppColors.primary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],

                    // 5. Nút điều khiển: Bắt đầu tải / Tạm dừng / Tiếp tục / Hủy
                    if (isDownloading) ...[
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.amber,
                                side: const BorderSide(color: AppColors.amber),
                                padding: const EdgeInsets.symmetric(vertical: 13),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                              ),
                              onPressed: () => _service.pauseDownload(),
                              icon: const Icon(Icons.pause_circle_outline_rounded, size: 20),
                              label: Text(
                                'TẠM DỪNG',
                                style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700, fontSize: 12),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.red,
                                side: const BorderSide(color: AppColors.red),
                                padding: const EdgeInsets.symmetric(vertical: 13),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                              ),
                              onPressed: () => _service.cancelDownload(),
                              icon: const Icon(Icons.stop_circle_outlined, size: 20),
                              label: Text(
                                'HỦY TẢI',
                                style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700, fontSize: 12),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ] else if (progress.isPaused) ...[
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          elevation: 0,
                        ),
                        onPressed: _resumeDownload,
                        icon: const Icon(Icons.play_arrow_rounded, size: 20),
                        label: Text(
                          'TIẾP TỤC TẢI',
                          style: GoogleFonts.plusJakartaSans(
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ),
                    ] else ...[
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          elevation: 0,
                        ),
                        onPressed: _startDownload,
                        icon: const Icon(Icons.download_rounded, size: 20),
                        label: Text(
                          'TẢI VÙNG ĐÃ CHỌN (~$estSize)',
                          style: GoogleFonts.plusJakartaSans(
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _regionOption({
    required String keyId,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final isSelected = _selectedRegionKey == keyId;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isSelected ? const Color(0xFFEFF6FF) : AppColors.panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isSelected ? AppColors.primary : AppColors.panelBorderBright,
          width: isSelected ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => setState(() => _selectedRegionKey = keyId),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(
                icon,
                color: isSelected ? AppColors.primary : AppColors.textDim,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: isSelected ? AppColors.primary : AppColors.textPrimary,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 10.5,
                        color: AppColors.textDim,
                      ),
                    ),
                  ],
                ),
              ),
              if (isSelected)
                const Icon(Icons.check_circle_rounded, color: AppColors.primary, size: 18),
            ],
          ),
        ),
      ),
    );
  }

  Widget _zoomOption({
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: selected ? const Color(0xFFEFF6FF) : AppColors.panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selected ? AppColors.primary : AppColors.panelBorderBright,
          width: selected ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    selected ? Icons.radio_button_checked : Icons.radio_button_off,
                    size: 15,
                    color: selected ? AppColors.primary : AppColors.textDim,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        title,
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: selected ? AppColors.primary : AppColors.textPrimary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 10,
                  color: AppColors.textDim,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
