import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/ble/ble_controller.dart';
import '../../core/models/maintenance_item.dart';
import '../../core/services/maintenance_storage_service.dart';
import '../../ui/app_theme.dart';
import '../../ui/widgets.dart';

typedef _MaintenanceBleSlice = ({
  String bikeId,
  String bikeName,
  bool isConnected,
  bool hasLiveOdo,
  double currentOdo,
});

/// Màn hình Nhật ký Bảo dưỡng Định kỳ (Maintenance Log) theo phong cách Kinetic Stitch EV.
class MaintenanceLogScreen extends ConsumerStatefulWidget {
  const MaintenanceLogScreen({super.key});

  @override
  ConsumerState<MaintenanceLogScreen> createState() =>
      _MaintenanceLogScreenState();
}

class _MaintenanceLogScreenState extends ConsumerState<MaintenanceLogScreen> {
  List<MaintenanceItem> _items = const [];
  bool _isLoading = true;
  String? _loadedBikeId;
  double? _manualOdoOverride;

  @override
  void initState() {
    super.initState();
    final slice = _readSlice(ref.read(bleProvider));
    _loadItems(slice.bikeId, initialOdo: slice.currentOdo);
  }

  static _MaintenanceBleSlice _readSlice(BleState state) {
    final bikes = state.savedBikes;
    final activeId = state.activeBikeId?.trim();
    final resolvedBikeId = (activeId != null && activeId.isNotEmpty)
        ? activeId
        : (bikes.isNotEmpty
            ? bikes.first.id
            : MaintenanceStorageService.defaultBikeId);

    SavedBike? activeSavedBike;
    for (final bike in bikes) {
      if (bike.id.toLowerCase() == resolvedBikeId.toLowerCase()) {
        activeSavedBike = bike;
        break;
      }
    }
    activeSavedBike ??= bikes.isNotEmpty ? bikes.first : null;

    final bikeName = (state.bikeName != null && state.bikeName!.trim().isNotEmpty)
        ? state.bikeName!.trim()
        : (activeSavedBike?.name ?? 'Xe Dat Bike');

    final hasLiveOdo =
        state.phase == BlePhase.connected && state.lastTelemetry != null;
    final currentOdo =
        state.lastTelemetry?.odo ?? activeSavedBike?.lastOdo ?? 0.0;

    return (
      bikeId: resolvedBikeId,
      bikeName: bikeName,
      isConnected: state.phase == BlePhase.connected,
      hasLiveOdo: hasLiveOdo,
      currentOdo: currentOdo,
    );
  }

  Future<void> _loadItems(String bikeId, {double initialOdo = 0.0}) async {
    _loadedBikeId = bikeId;
    final items = await MaintenanceStorageService.instance.loadItems(
      bikeId,
      initialOdo: initialOdo,
    );
    if (!mounted || _loadedBikeId != bikeId) return;
    setState(() {
      _items = items;
      _isLoading = false;
    });
  }

  String _formatKm(double value) {
    if (!value.isFinite) return '0';
    final normalized = value.abs() < 0.05 ? 0.0 : value;
    if ((normalized - normalized.roundToDouble()).abs() < 0.05) {
      return normalized.round().toString();
    }
    return normalized.toStringAsFixed(1);
  }

  String _formatDate(DateTime date) {
    final d = date.day.toString().padLeft(2, '0');
    final m = date.month.toString().padLeft(2, '0');
    return '$d/$m/${date.year}';
  }

  Future<void> _markServiced(
    String bikeId,
    MaintenanceItem item,
    double effectiveOdo,
  ) async {
    final updated = await MaintenanceStorageService.instance.markServiced(
      bikeId,
      item.id,
      effectiveOdo,
    );
    if (!mounted) return;
    setState(() => _items = updated);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Đã cập nhật bảo dưỡng "${item.title}" tại ${_formatKm(effectiveOdo)} km',
          style: GoogleFonts.plusJakartaSans(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        backgroundColor: AppColors.tertiary,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _deleteItem(
    String bikeId,
    MaintenanceItem item,
    double effectiveOdo,
  ) async {
    final updated = await MaintenanceStorageService.instance.deleteItem(
      bikeId,
      item.id,
      initialOdo: effectiveOdo,
    );
    if (!mounted) return;
    setState(() => _items = updated);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Đã xóa hạng mục "${item.title}"',
          style: GoogleFonts.plusJakartaSans(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        backgroundColor: AppColors.textPrimary,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _showEditOdoDialog(double syncedOdo, double effectiveOdo) async {
    final controller = TextEditingController(
      text: _formatKm(effectiveOdo),
    );
    final formKey = GlobalKey<FormState>();

    final result = await showDialog<double?>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.panel,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: AppColors.panelBorderBright),
        ),
        title: Text(
          'Cập nhật ODO tạm thời',
          style: GoogleFonts.plusJakartaSans(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        content: SingleChildScrollView(
          child: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Nhập số km hiện tại khi chưa kết nối BLE với xe.',
                  style: AppTypography.bodySm(),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: controller,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Số ODO hiện tại (km)',
                    suffixText: 'km',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  validator: (value) {
                    final parsed = double.tryParse(
                      (value ?? '').trim().replaceAll(',', '.'),
                    );
                    if (parsed == null || parsed < 0) {
                      return 'Vui lòng nhập số ODO hợp lệ (>= 0)';
                    }
                    return null;
                  },
                ),
              ],
            ),
          ),
        ),
        actions: [
          if (_manualOdoOverride != null)
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(-1.0),
              child: const Text('Dùng ODO xe'),
            ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Hủy'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                final parsed = double.parse(
                  controller.text.trim().replaceAll(',', '.'),
                );
                Navigator.of(ctx).pop(parsed);
              }
            },
            child: const Text('Áp dụng'),
          ),
        ],
      ),
    );

    if (!mounted || result == null) return;
    setState(() {
      _manualOdoOverride = result < 0 ? null : result;
    });
  }

  Future<void> _showAddItemDialog(String bikeId, double effectiveOdo) async {
    final titleController = TextEditingController();
    final categoryController = TextEditingController(text: 'Tùy chỉnh');
    final intervalController = TextEditingController(text: '2000');
    final lastOdoController = TextEditingController(
      text: _formatKm(effectiveOdo),
    );
    final notesController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    final newItem = await showDialog<MaintenanceItem>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.panel,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: AppColors.panelBorderBright),
        ),
        title: Text(
          'Thêm hạng mục bảo dưỡng',
          style: GoogleFonts.plusJakartaSans(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        content: SingleChildScrollView(
          child: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: titleController,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: 'Tên hạng mục',
                    hintText: 'Ví dụ: Thay dầu hộp số',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) {
                      return 'Vui lòng nhập tên hạng mục';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: categoryController,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: 'Phân loại',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: intervalController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: 'Chu kỳ lặp lại (km)',
                    suffixText: 'km',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  validator: (v) {
                    final parsed = double.tryParse(
                      (v ?? '').trim().replaceAll(',', '.'),
                    );
                    if (parsed == null || parsed <= 0) {
                      return 'Chu kỳ phải lớn hơn 0 km';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: lastOdoController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: 'ODO lần bảo dưỡng gần nhất',
                    suffixText: 'km',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  validator: (v) {
                    final parsed = double.tryParse(
                      (v ?? '').trim().replaceAll(',', '.'),
                    );
                    if (parsed == null || parsed < 0) {
                      return 'ODO phải >= 0 km';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: notesController,
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: 'Ghi chú (tùy chọn)',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Hủy'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
            onPressed: () {
              if (!(formKey.currentState?.validate() ?? false)) return;
              final intervalKm = double.parse(
                intervalController.text.trim().replaceAll(',', '.'),
              );
              final lastOdo = double.parse(
                lastOdoController.text.trim().replaceAll(',', '.'),
              );
              final category = categoryController.text.trim().isEmpty
                  ? 'Tùy chỉnh'
                  : categoryController.text.trim();
              final notes = notesController.text.trim();

              Navigator.of(ctx).pop(
                MaintenanceItem(
                  id: 'custom_${DateTime.now().microsecondsSinceEpoch}',
                  bikeId: bikeId,
                  title: titleController.text.trim(),
                  category: category,
                  intervalKm: intervalKm,
                  lastServiceOdo: lastOdo,
                  notes: notes.isEmpty ? null : notes,
                  isDefault: false,
                ),
              );
            },
            child: const Text('Lưu'),
          ),
        ],
      ),
    );

    if (newItem == null || !mounted) return;
    final updated = await MaintenanceStorageService.instance.addItem(
      bikeId,
      newItem,
      initialOdo: effectiveOdo,
    );
    if (!mounted) return;
    setState(() => _items = updated);
  }

  @override
  Widget build(BuildContext context) {
    final slice = ref.watch(bleProvider.select(_readSlice));

    if (_loadedBikeId != slice.bikeId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _isLoading = true;
          _manualOdoOverride = null;
        });
        _loadItems(slice.bikeId, initialOdo: slice.currentOdo);
      });
    }

    final effectiveOdo = _manualOdoOverride ?? slice.currentOdo;
    final isLiveOdo = slice.hasLiveOdo && _manualOdoOverride == null;
    final dueCount = _items
        .where((item) =>
            item.isOverdue(effectiveOdo) || item.isDueSoon(effectiveOdo))
        .length;

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_ios_new_rounded,
            size: 20,
            color: AppColors.textPrimary,
          ),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Nhật ký bảo dưỡng',
              style: GoogleFonts.plusJakartaSans(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              slice.bikeName,
              style: AppTypography.bodySm(color: AppColors.textDim),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddItemDialog(slice.bikeId, effectiveOdo),
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.onPrimary,
        elevation: 2,
        icon: const Icon(Icons.add_rounded),
        label: Text(
          'Thêm hạng mục',
          style: GoogleFonts.plusJakartaSans(
            fontWeight: FontWeight.w700,
            fontSize: 13.5,
          ),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
              children: [
                _SummaryCard(
                  effectiveOdo: effectiveOdo,
                  formattedOdo: _formatKm(effectiveOdo),
                  dueCount: dueCount,
                  totalCount: _items.length,
                  isLiveOdo: isLiveOdo,
                  isManualOverride: _manualOdoOverride != null,
                  onEditOdo: () =>
                      _showEditOdoDialog(slice.currentOdo, effectiveOdo),
                ),
                const SizedBox(height: 18),
                SectionTitle(
                  'Hạng mục bảo dưỡng',
                  action: Text(
                    '${_items.length} mục',
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textDim,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                if (_items.isEmpty)
                  Panel(
                    borderColor: AppColors.panelBorderBright,
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        const Icon(
                          Icons.build_circle_outlined,
                          size: 36,
                          color: AppColors.textMuted,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Chưa có hạng mục bảo dưỡng nào',
                          style: AppTypography.labelLg(),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Nhấn "Thêm hạng mục" để tạo lịch nhắc bảo dưỡng theo km.',
                          style: AppTypography.bodySm(),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  )
                else
                  ..._items.map(
                    (item) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _MaintenanceItemCard(
                        item: item,
                        currentOdo: effectiveOdo,
                        formatKm: _formatKm,
                        formatDate: _formatDate,
                        onMarkServiced: () =>
                            _markServiced(slice.bikeId, item, effectiveOdo),
                        onDelete: item.isDefault
                            ? null
                            : () => _deleteItem(slice.bikeId, item, effectiveOdo),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final double effectiveOdo;
  final String formattedOdo;
  final int dueCount;
  final int totalCount;
  final bool isLiveOdo;
  final bool isManualOverride;
  final VoidCallback onEditOdo;

  const _SummaryCard({
    required this.effectiveOdo,
    required this.formattedOdo,
    required this.dueCount,
    required this.totalCount,
    required this.isLiveOdo,
    required this.isManualOverride,
    required this.onEditOdo,
  });

  @override
  Widget build(BuildContext context) {
    final pillColor = isLiveOdo ? AppColors.tertiary : AppColors.accent;
    final dueColor = dueCount > 0 ? AppColors.amber : AppColors.tertiary;

    return Panel(
      borderColor: AppColors.panelBorderBright,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              StatusPill(
                label: isLiveOdo ? 'ODO LIVE' : 'ODO ĐÃ LƯU',
                color: pillColor,
                pulse: isLiveOdo,
              ),
              InkWell(
                onTap: onEditOdo,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.edit_outlined,
                        size: 14,
                        color: AppColors.primary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        isManualOverride ? 'Đang nhập tay' : 'Chỉnh ODO',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    formattedOdo,
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 34,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                'km',
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textDim,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(color: AppColors.panelBorder, height: 1),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Cần bảo dưỡng',
                      style: AppTypography.labelMd(color: AppColors.textDim),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$dueCount / $totalCount hạng mục',
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: dueColor,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: dueColor.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: dueColor.withValues(alpha: 0.25),
                  ),
                ),
                child: Text(
                  dueCount > 0 ? 'Cần chú ý' : 'Ổn định',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: dueColor,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MaintenanceItemCard extends StatelessWidget {
  final MaintenanceItem item;
  final double currentOdo;
  final String Function(double) formatKm;
  final String Function(DateTime) formatDate;
  final VoidCallback onMarkServiced;
  final VoidCallback? onDelete;

  const _MaintenanceItemCard({
    required this.item,
    required this.currentOdo,
    required this.formatKm,
    required this.formatDate,
    required this.onMarkServiced,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final rem = item.remainingKm(currentOdo);
    final overdue = item.isOverdue(currentOdo);
    final dueSoon = item.isDueSoon(currentOdo);
    final progressValue = item.progress(currentOdo);

    final Color badgeColor;
    final String badgeText;
    if (overdue) {
      badgeColor = AppColors.red;
      final overdueKm = rem <= 0 ? -rem : 0.0;
      badgeText = 'Quá hạn ${formatKm(overdueKm)} km';
    } else if (dueSoon) {
      badgeColor = AppColors.amber;
      badgeText = 'Còn ${formatKm(rem)} km';
    } else {
      badgeColor = AppColors.tertiary;
      badgeText = 'Còn ${formatKm(rem)} km';
    }

    return Panel(
      borderColor: overdue
          ? AppColors.red.withValues(alpha: 0.35)
          : (dueSoon
              ? AppColors.amber.withValues(alpha: 0.35)
              : AppColors.panelBorderBright),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  item.category.toUpperCase(),
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    color: AppColors.textDim,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(9999),
                  border: Border.all(
                    color: badgeColor.withValues(alpha: 0.35),
                  ),
                ),
                child: Text(
                  badgeText,
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: badgeColor,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            item.title,
            style: GoogleFonts.plusJakartaSans(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(9999),
            child: LinearProgressIndicator(
              value: progressValue,
              minHeight: 8,
              backgroundColor: AppColors.surfaceContainer,
              valueColor: AlwaysStoppedAnimation<Color>(
                overdue
                    ? AppColors.red
                    : (dueSoon ? AppColors.amber : AppColors.primary),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              Text(
                'Bảo dưỡng gần nhất: ${formatKm(item.lastServiceOdo)} km',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textDim,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                'Mốc kế tiếp: ${formatKm(item.nextDueOdo)} km',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          if (item.lastServiceAt != null) ...[
            const SizedBox(height: 4),
            Text(
              'Ngày thực hiện: ${formatDate(item.lastServiceAt!)}',
              style: AppTypography.bodySm(color: AppColors.textMuted),
            ),
          ],
          if (item.notes != null && item.notes!.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              item.notes!,
              style: AppTypography.bodySm(),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onMarkServiced,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    side: BorderSide(
                      color: AppColors.primary.withValues(alpha: 0.35),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                  icon: const Icon(Icons.check_circle_outline_rounded, size: 18),
                  label: Text(
                    'Đã bảo dưỡng',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              if (onDelete != null) ...[
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Xóa hạng mục',
                  onPressed: onDelete,
                  icon: const Icon(
                    Icons.delete_outline_rounded,
                    color: AppColors.red,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
