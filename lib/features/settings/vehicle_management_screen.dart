// Màn hình Quản Lý Nhà Xe (Garage) — Quản lý toàn diện: Thêm, Xóa, Sửa, Xem & Điều khiển Multi Xe
// Chuẩn phong cách thiết kế Kinetic Stitch EV / Geely Electric Vehicle.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ble/ble_controller.dart';
import '../../ui/app_theme.dart';
import '../../ui/widgets.dart';
import '../scan/scan_screen.dart';

class VehicleManagementScreen extends ConsumerStatefulWidget {
  const VehicleManagementScreen({super.key});

  @override
  ConsumerState<VehicleManagementScreen> createState() => _VehicleManagementScreenState();
}

class _VehicleManagementScreenState extends ConsumerState<VehicleManagementScreen> {
  void _snack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          msg,
          style: AppTypography.bodySm(color: AppColors.onPrimary).copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        backgroundColor: isError ? AppColors.red : AppColors.textPrimary,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// Hộp thoại thêm xe mới (chọn quét BLE hoặc nhập thủ công)
  void _showAddBikeOptions() {
    KineticBottomSheet.show(
      context: context,
      builder: (ctx) => KineticBottomSheet(
        title: 'Thêm Xe Dat Bike',
        subtitle: 'Chọn phương thức thêm xe vào nhà xe của bạn',
        child: Panel(
          padding: EdgeInsets.zero,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              PanelActionRow(
                leading: const TemplateBadgeIcon(
                  icon: Icons.bluetooth_searching_rounded,
                  color: AppColors.primary,
                  size: 44,
                  borderRadius: 12,
                ),
                title: 'Quét Bluetooth BLE (Khuyên dùng)',
                subtitle: 'Tự động tìm kiếm và ghép đôi xe Dat Bike đang ở gần',
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ScanScreen()),
                  );
                },
              ),
              const PanelDivider(indent: 72, endIndent: 16),
              PanelActionRow(
                leading: const TemplateBadgeIcon(
                  icon: Icons.edit_note_rounded,
                  color: AppColors.textDim,
                  size: 44,
                  borderRadius: 12,
                ),
                title: 'Nhập thông tin thủ công',
                subtitle: 'Nhập địa chỉ MAC / Bluetooth ID và thông tin xe',
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                onTap: () {
                  Navigator.pop(ctx);
                  _showManualAddDialog();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Hộp thoại nhập xe thủ công
  void _showManualAddDialog() {
    final idController = TextEditingController();
    final nameController = TextEditingController();
    final plateController = TextEditingController();
    final noteController = TextEditingController();
    final pwdController = TextEditingController();
    String selectedModel = 'Quantum';
    final models = ['Quantum S1', 'Quantum', 'Weaver++', 'Weaver 200', 'Weaver'];

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlgState) => AlertDialog(
          backgroundColor: AppColors.panel,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text(
            'Thêm Xe Thủ Công',
            style: AppTypography.headlineSm(color: AppColors.textPrimary).copyWith(
              fontWeight: FontWeight.w700,
              fontSize: 17,
            ),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _formLabel('Địa chỉ Bluetooth (MAC hoặc iOS UUID) *'),
                TextField(
                  controller: idController,
                  decoration: _inputDecoration('vd: CC:BA:F9:12:34:56 hoặc UUID'),
                  style: AppTypography.bodySm(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 12),
                _formLabel('Tên hiển thị xe *'),
                TextField(
                  controller: nameController,
                  decoration: _inputDecoration('vd: Xe Đi Làm - Quantum S1'),
                  style: AppTypography.bodySm(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 12),
                _formLabel('Dòng xe (Model)'),
                DropdownButtonFormField<String>(
                  initialValue: selectedModel,
                  items: models
                      .map((m) => DropdownMenuItem(
                            value: m,
                            child: Text(m, style: AppTypography.bodySm(color: AppColors.textPrimary)),
                          ))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setDlgState(() => selectedModel = v);
                  },
                  decoration: _inputDecoration(''),
                ),
                const SizedBox(height: 12),
                _formLabel('Biển số xe (Tùy chọn)'),
                TextField(
                  controller: plateController,
                  decoration: _inputDecoration('vd: 29-A1 999.99'),
                  style: AppTypography.bodySm(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 12),
                _formLabel('Mật khẩu kết nối Bluetooth (Tùy chọn)'),
                TextField(
                  controller: pwdController,
                  obscureText: true,
                  decoration: _inputDecoration('Để trống nếu chưa đặt'),
                  style: AppTypography.bodySm(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 12),
                _formLabel('Ghi chú'),
                TextField(
                  controller: noteController,
                  decoration: _inputDecoration('Ghi chú cá nhân...'),
                  style: AppTypography.bodySm(color: AppColors.textPrimary),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('HỦY', style: AppTypography.labelLg(color: AppColors.textDim)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () async {
                final id = idController.text.trim();
                final name = nameController.text.trim();
                if (id.isEmpty) {
                  _snack('Vui lòng nhập địa chỉ Bluetooth MAC hoặc UUID', isError: true);
                  return;
                }
                Navigator.pop(ctx);
                final newBike = SavedBike(
                  id: id,
                  name: name.isNotEmpty ? name : 'Dat Bike $selectedModel',
                  model: selectedModel,
                  licensePlate: plateController.text.trim().isNotEmpty ? plateController.text.trim() : null,
                  password: pwdController.text.trim().isNotEmpty ? pwdController.text.trim() : null,
                  note: noteController.text.trim().isNotEmpty ? noteController.text.trim() : null,
                  lastConnectedAt: DateTime.now(),
                );
                await ref.read(bleProvider.notifier).addBike(newBike);
                _snack('Đã thêm ${newBike.name} vào nhà xe thành công!');
              },
              child: Text(
                'LƯU XE',
                style: AppTypography.labelLg(color: AppColors.onPrimary, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Hộp thoại chỉnh sửa thông tin xe
  void _showEditBikeDialog(SavedBike bike) {
    final nameController = TextEditingController(text: bike.name);
    final plateController = TextEditingController(text: bike.licensePlate ?? '');
    final colorController = TextEditingController(text: bike.color ?? '');
    final noteController = TextEditingController(text: bike.note ?? '');
    final pwdController = TextEditingController(text: bike.password ?? '');
    String selectedModel = bike.model ?? 'Quantum';
    final models = ['Quantum S1', 'Quantum', 'Weaver++', 'Weaver 200', 'Weaver'];
    if (!models.contains(selectedModel)) models.add(selectedModel);

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlgState) => AlertDialog(
          backgroundColor: AppColors.panel,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text(
            'Chỉnh Sửa Thông Tin Xe',
            style: AppTypography.headlineSm(color: AppColors.textPrimary).copyWith(
              fontWeight: FontWeight.w700,
              fontSize: 17,
            ),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _formLabel('Tên hiển thị xe *'),
                TextField(
                  controller: nameController,
                  decoration: _inputDecoration('vd: Quantum Của Tôi'),
                  style: AppTypography.bodySm(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 12),
                _formLabel('Dòng xe (Model)'),
                DropdownButtonFormField<String>(
                  initialValue: selectedModel,
                  items: models
                      .map((m) => DropdownMenuItem(
                            value: m,
                            child: Text(m, style: AppTypography.bodySm(color: AppColors.textPrimary)),
                          ))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setDlgState(() => selectedModel = v);
                  },
                  decoration: _inputDecoration(''),
                ),
                const SizedBox(height: 12),
                _formLabel('Biển số xe'),
                TextField(
                  controller: plateController,
                  decoration: _inputDecoration('vd: 29-A1 999.99'),
                  style: AppTypography.bodySm(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 12),
                _formLabel('Màu sắc xe'),
                TextField(
                  controller: colorController,
                  decoration: _inputDecoration('vd: Trắng Ngọc, Đen Nhám...'),
                  style: AppTypography.bodySm(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 12),
                _formLabel('Mật khẩu Bluetooth riêng xe này'),
                TextField(
                  controller: pwdController,
                  obscureText: true,
                  decoration: _inputDecoration('Để trống nếu không đổi'),
                  style: AppTypography.bodySm(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 12),
                _formLabel('Ghi chú'),
                TextField(
                  controller: noteController,
                  decoration: _inputDecoration('Ghi chú bảo dưỡng, phụ kiện...'),
                  style: AppTypography.bodySm(color: AppColors.textPrimary),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('HỦY', style: AppTypography.labelLg(color: AppColors.textDim)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () async {
                final newName = nameController.text.trim();
                if (newName.isEmpty) {
                  _snack('Tên xe không được để trống', isError: true);
                  return;
                }
                Navigator.pop(ctx);
                final updated = bike.copyWith(
                  name: newName,
                  model: selectedModel,
                  licensePlate: plateController.text.trim().isNotEmpty ? plateController.text.trim() : null,
                  color: colorController.text.trim().isNotEmpty ? colorController.text.trim() : null,
                  note: noteController.text.trim().isNotEmpty ? noteController.text.trim() : null,
                  password: pwdController.text.trim().isNotEmpty ? pwdController.text.trim() : bike.password,
                );
                await ref.read(bleProvider.notifier).updateBike(updated);
                _snack('Đã cập nhật thông tin ${updated.name}');
              },
              child: Text(
                'CẬP NHẬT',
                style: AppTypography.labelLg(color: AppColors.onPrimary, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Hộp thoại xác nhận xóa xe
  void _confirmDeleteBike(SavedBike bike) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Xóa xe khỏi danh sách?',
          style: AppTypography.headlineSm(color: AppColors.red).copyWith(
            fontWeight: FontWeight.w700,
            fontSize: 17,
          ),
        ),
        content: Text(
          'Bạn có chắc chắn muốn xóa "${bike.name}" (${bike.id}) khỏi nhà xe không?\n'
          'Các dữ liệu cài đặt riêng và mật khẩu liên kết của xe này sẽ được gỡ bỏ.',
          style: AppTypography.bodySm(color: AppColors.textDim).copyWith(fontSize: 13.5, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('HỦY', style: AppTypography.labelLg(color: AppColors.textDim)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.red,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () async {
              Navigator.pop(ctx);
              await ref.read(bleProvider.notifier).deleteBike(bike.id);
              if (!mounted) return;
              final isIos = Theme.of(context).platform == TargetPlatform.iOS;
              if (isIos) {
                _snack('Đã xóa ${bike.name} khỏi ứng dụng. Nếu muốn quên hoàn toàn ghép đôi hệ thống trên iPhone, hãy vào Cài đặt iOS > Bluetooth > chọn biểu tượng (i) cạnh tên xe > Quên thiết bị này.');
              } else {
                _snack('Đã xóa ${bike.name} khỏi nhà xe');
              }
            },
            child: Text(
              'XÁC NHẬN XÓA',
              style: AppTypography.labelLg(color: AppColors.onPrimary, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  /// Hộp thoại xác nhận xóa toàn bộ xe
  void _confirmDeleteAllBikes() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: AppColors.red, size: 24),
            const SizedBox(width: 8),
            Text(
              'Xóa toàn bộ xe?',
              style: AppTypography.headlineSm(color: AppColors.red).copyWith(
                fontWeight: FontWeight.w700,
                fontSize: 17,
              ),
            ),
          ],
        ),
        content: Text(
          'Bạn có chắc chắn muốn xóa TOÀN BỘ xe khỏi nhà xe không?\n'
          'Toàn bộ cấu hình, vị trí đỗ, và mật khẩu liên kết sẽ bị xóa sạch khỏi ứng dụng.',
          style: AppTypography.bodySm(color: AppColors.textDim).copyWith(fontSize: 13.5, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('HỦY', style: AppTypography.labelLg(color: AppColors.textDim)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.red,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () async {
              Navigator.pop(ctx);
              await ref.read(bleProvider.notifier).deleteAllSavedBikes();
              if (!mounted) return;
              final isIos = Theme.of(context).platform == TargetPlatform.iOS;
              if (isIos) {
                _snack('Đã xóa toàn bộ xe khỏi ứng dụng. Nếu muốn quên hoàn toàn ghép đôi hệ thống trên iPhone, hãy vào Cài đặt iOS > Bluetooth > chọn biểu tượng (i) cạnh tên xe > Quên thiết bị này.');
              } else {
                _snack('Đã xóa toàn bộ xe khỏi nhà xe');
              }
            },
            child: Text(
              'XÓA TẤT CẢ',
              style: AppTypography.labelLg(color: AppColors.onPrimary, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: AppTypography.bodySm(color: AppColors.textMuted).copyWith(fontSize: 12.5),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      filled: true,
      fillColor: AppColors.panelSecondary,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.panelBorderBright),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.panelBorderBright),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
      ),
    );
  }

  Widget _formLabel(String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        label,
        style: AppTypography.labelMd(color: AppColors.onSurfaceVariant, fontWeight: FontWeight.w700)
            .copyWith(letterSpacing: 0),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ble = ref.watch(bleProvider);
    final bikes = ble.savedBikes;
    final currentConnectedId = (ble.phase == BlePhase.connected) ? ble.device?.remoteId.str.toLowerCase() : null;
    final currentActiveId = ble.activeBikeId?.toLowerCase() ?? currentConnectedId;

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.panel,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Nhà Xe Của Bạn',
              style: AppTypography.headlineSm(color: AppColors.textPrimary).copyWith(
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
            Text(
              '${bikes.length} xe máy điện đã lưu · Điều khiển đa xe',
              style: AppTypography.bodySm(color: AppColors.textDim).copyWith(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        actions: [
          if (bikes.isNotEmpty)
            IconButton(
              tooltip: 'Xóa toàn bộ xe đã lưu',
              icon: const TemplateBadgeIcon(
                icon: Icons.delete_sweep_rounded,
                color: AppColors.red,
                size: 34,
                iconSize: 20,
                borderRadius: 10,
              ),
              onPressed: _confirmDeleteAllBikes,
            ),
          IconButton(
            tooltip: 'Thêm xe mới',
            icon: const TemplateBadgeIcon(
              icon: Icons.add_rounded,
              color: AppColors.primary,
              size: 34,
              iconSize: 20,
              borderRadius: 10,
            ),
            onPressed: _showAddBikeOptions,
          ),
          const SizedBox(width: 8),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: AppColors.panelBorder, height: 1),
        ),
      ),
      body: bikes.isEmpty
          ? _buildEmptyState()
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                  child: SectionTitle('Quản Lý Nhà Xe (${bikes.length} xe)'),
                ),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    itemCount: bikes.length,
                    itemBuilder: (context, index) {
                      final bike = bikes[index];
                      final isConnected = currentConnectedId == bike.id.toLowerCase();
                      final isActive = currentActiveId == bike.id.toLowerCase();
                      return _buildBikeCard(bike, isActive: isActive, isConnected: isConnected);
                    },
                  ),
                ),
              ],
            ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.panel,
          border: const Border(top: BorderSide(color: AppColors.panelBorder, width: 1)),
          boxShadow: [
            BoxShadow(
              color: AppColors.textPrimary.withValues(alpha: 0.025),
              blurRadius: 10,
              offset: const Offset(0, -3),
            ),
          ],
        ),
        child: SafeArea(
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    side: BorderSide(color: AppColors.primary.withValues(alpha: 0.25)),
                    backgroundColor: AppColors.primary.withValues(alpha: 0.08),
                  ),
                  icon: const Icon(Icons.bluetooth_searching_rounded, size: 18, color: AppColors.primary),
                  label: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      'QUÉT XE',
                      style: AppTypography.labelLg(
                        color: AppColors.primary,
                        fontWeight: FontWeight.w700,
                      ).copyWith(fontSize: 12.5),
                    ),
                  ),
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const ScanScreen()),
                    );
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  icon: const Icon(Icons.add_rounded, size: 18, color: AppColors.onPrimary),
                  label: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      'THÊM XE',
                      style: AppTypography.labelLg(
                        color: AppColors.onPrimary,
                        fontWeight: FontWeight.w700,
                      ).copyWith(fontSize: 12.5),
                    ),
                  ),
                  onPressed: _showAddBikeOptions,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const TemplateBadgeIcon(
              icon: Icons.two_wheeler_outlined,
              color: AppColors.primary,
              size: 80,
              iconSize: 40,
              borderRadius: 40,
            ),
            const SizedBox(height: 20),
            Text(
              'Nhà Xe Đang Trống',
              style: AppTypography.headlineSm(color: AppColors.textPrimary).copyWith(
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Bạn chưa lưu chiếc xe Dat Bike nào.\nBấm nút bên dưới để quét kết nối Bluetooth và đưa xe vào nhà xe!',
              textAlign: TextAlign.center,
              style: AppTypography.bodySm(color: AppColors.textDim).copyWith(height: 1.5),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              icon: const Icon(Icons.bluetooth_searching_rounded, size: 20),
              label: Text(
                'TÌM & KẾT NỐI XE NGAY',
                style: AppTypography.labelLg(
                  color: AppColors.onPrimary,
                  fontWeight: FontWeight.w700,
                ).copyWith(fontSize: 13.5),
              ),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ScanScreen()),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBikeCard(SavedBike bike, {required bool isActive, required bool isConnected}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Panel(
        padding: EdgeInsets.zero,
        borderRadius: 20,
        borderColor: isConnected
            ? AppColors.primary
            : (isActive ? AppColors.secondary : AppColors.panelBorderBright),
        hasActiveHalo: isConnected,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header thẻ xe
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
              child: Row(
                children: [
                  // Logo xe 3D
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppColors.panelSecondary,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.panelBorderBright),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Image.asset(
                      'assets/images/bike_logo_3d.png',
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const Icon(
                        Icons.two_wheeler_rounded,
                        size: 24,
                        color: AppColors.primary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              bike.name,
                              style: AppTypography.bodyMd(color: AppColors.textPrimary).copyWith(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (bike.isDefault)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppColors.amber.withValues(alpha: 0.14),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: AppColors.amber.withValues(alpha: 0.45)),
                                ),
                                child: Text(
                                  'MẶC ĐỊNH',
                                  style: AppTypography.labelSm(
                                    color: AppColors.amber,
                                    fontWeight: FontWeight.w800,
                                  ).copyWith(fontSize: 8.5),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Model: ${bike.model ?? "Dat Bike"} · ${bike.color ?? "Tiêu chuẩn"}',
                          style: AppTypography.bodySm(color: AppColors.textDim).copyWith(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Huy hiệu trạng thái kết nối
                  StatusPill(
                    label: isConnected
                        ? 'KẾT NỐI'
                        : (isActive ? 'ĐANG CHỌN' : 'OFFLINE'),
                    color: isConnected
                        ? AppColors.mint
                        : (isActive ? AppColors.primary : AppColors.textDim),
                    pulse: isConnected,
                  ),
                ],
              ),
            ),

            const PanelDivider(indent: 16, endIndent: 16),

            // Thông tin kỹ thuật & Biển số
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  // Biển số xe (nếu có)
                  if (bike.licensePlate != null && bike.licensePlate!.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppColors.panel,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: AppColors.textPrimary, width: 1.2),
                        boxShadow: AppColors.cardShadow,
                      ),
                      child: Text(
                        bike.licensePlate!,
                        style: AppTypography.headlineSm(color: AppColors.textPrimary).copyWith(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.8,
                          height: 1.2,
                        ),
                      ),
                    ),

                  // Địa chỉ Bluetooth MAC/UUID
                  InkWell(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: bike.id));
                      _snack('Đã sao chép mã Bluetooth: ${bike.id}');
                    },
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.bluetooth_rounded, size: 14, color: AppColors.textDim),
                          const SizedBox(width: 4),
                          Text(
                            bike.id.length > 17 ? '${bike.id.substring(0, 17)}...' : bike.id,
                            style: AppTypography.bodySm(color: AppColors.textDim).copyWith(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(width: 3),
                          const Icon(Icons.copy_rounded, size: 12, color: AppColors.textMuted),
                        ],
                      ),
                    ),
                  ),

                  // Mức pin lần cuối
                  if (bike.lastBatteryPercent != null)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.battery_charging_full_rounded, size: 15, color: AppColors.mint),
                        const SizedBox(width: 4),
                        Text(
                          '${bike.lastBatteryPercent}% pin',
                          style: AppTypography.labelMd(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w600,
                          ).copyWith(fontSize: 11.5, letterSpacing: 0),
                        ),
                      ],
                    ),

                  // Odo lần cuối
                  if (bike.lastOdo != null && bike.lastOdo! > 0)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.speed_rounded, size: 14, color: AppColors.primaryContainer),
                        const SizedBox(width: 4),
                        Text(
                          '${bike.lastOdo!.toStringAsFixed(0)} km ODO',
                          style: AppTypography.labelMd(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w600,
                          ).copyWith(fontSize: 11.5, letterSpacing: 0),
                        ),
                      ],
                    ),
                ],
              ),
            ),

            if (bike.note != null && bike.note!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  '📝 ${bike.note!}',
                  style: AppTypography.bodySm(color: AppColors.textDim).copyWith(
                    fontSize: 11.5,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),

            // Thanh hành động (Chuyển xe, Sửa, Đặt mặc định, Xóa)
            Container(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              decoration: const BoxDecoration(
                color: AppColors.panelSecondary,
                borderRadius: BorderRadius.vertical(bottom: Radius.circular(19)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Hàng 1: Nút hành động chính (Kết nối / Chuyển xe / Ngắt kết nối)
                  SizedBox(
                    width: double.infinity,
                    child: isConnected
                        ? OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 9),
                              side: const BorderSide(color: AppColors.surfaceContainerHighest),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              backgroundColor: AppColors.panel,
                            ),
                            icon: const Icon(Icons.link_off_rounded, size: 16, color: AppColors.textDim),
                            label: Text(
                              'NGẮT KẾT NỐI',
                              style: AppTypography.labelMd(
                                color: AppColors.textDim,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            onPressed: () async {
                              await ref.read(bleProvider.notifier).disconnect();
                              _snack('Đã ngắt kết nối với ${bike.name}');
                            },
                          )
                        : FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: AppColors.primary,
                              padding: const EdgeInsets.symmetric(vertical: 9),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              elevation: 0,
                            ),
                            icon: const Icon(Icons.swap_horiz_rounded, size: 17),
                            label: Text(
                              'ĐIỀU KHIỂN XE',
                              style: AppTypography.labelMd(
                                color: AppColors.onPrimary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            onPressed: () async {
                              await ref.read(bleProvider.notifier).switchBike(bike, autoConnect: true);
                              _snack('Đang chuyển điều khiển sang ${bike.name}...');
                            },
                          ),
                  ),
                  const SizedBox(height: 8),
                  // Hàng 2: Các thao tác phụ (Mặc định, Sửa, Xóa)
                  Row(
                    children: [
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: !bike.isDefault
                              ? InkWell(
                                  onTap: () async {
                                    await ref.read(bleProvider.notifier).setDefaultBike(bike.id);
                                    _snack('Đã đặt ${bike.name} làm xe mặc định khi mở app');
                                  },
                                  borderRadius: BorderRadius.circular(6),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(Icons.star_outline_rounded, size: 16, color: AppColors.textDim),
                                        const SizedBox(width: 4),
                                        Flexible(
                                          child: Text(
                                            'Đặt mặc định',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: AppTypography.labelMd(
                                              color: AppColors.textDim,
                                              fontWeight: FontWeight.w600,
                                            ).copyWith(fontSize: 11.5, letterSpacing: 0),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                )
                              : Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.star_rounded, size: 16, color: AppColors.amber),
                                      const SizedBox(width: 4),
                                      Flexible(
                                        child: Text(
                                          'Xe mặc định',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: AppTypography.labelMd(
                                            color: AppColors.amber,
                                            fontWeight: FontWeight.w600,
                                          ).copyWith(fontSize: 11.5, letterSpacing: 0),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      // Nút sửa
                      InkWell(
                        onTap: () => _showEditBikeDialog(bike),
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.edit_outlined, size: 15, color: AppColors.primary),
                              const SizedBox(width: 4),
                              Text(
                                'Sửa',
                                style: AppTypography.labelMd(
                                  color: AppColors.primary,
                                  fontWeight: FontWeight.w600,
                                ).copyWith(fontSize: 11.5, letterSpacing: 0),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Nút xóa
                      InkWell(
                        onTap: () => _confirmDeleteBike(bike),
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.delete_outline_rounded, size: 15, color: AppColors.red),
                              const SizedBox(width: 4),
                              Text(
                                'Xóa',
                                style: AppTypography.labelMd(
                                  color: AppColors.red,
                                  fontWeight: FontWeight.w700,
                                ).copyWith(fontSize: 11.5, letterSpacing: 0),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
