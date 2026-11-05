// Màn hình Quản Lý Nhà Xe (Garage) — Quản lý toàn diện: Thêm, Xóa, Sửa, Xem & Điều khiển Multi Xe
// Chuẩn phong cách thiết kế Kinetic Stitch EV / Geely Electric Vehicle.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/ble/ble_controller.dart';
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
          style: GoogleFonts.plusJakartaSans(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        backgroundColor: isError ? const Color(0xFFEF4444) : const Color(0xFF0F172A),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// Hộp thoại thêm xe mới (chọn quét BLE hoặc nhập thủ công)
  void _showAddBikeOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFCBD5E1),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Thêm Xe Dat Bike',
              style: GoogleFonts.plusJakartaSans(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: const Color(0xFF0F172A),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Chọn phương thức thêm xe vào nhà xe của bạn',
              style: GoogleFonts.plusJakartaSans(
                fontSize: 12.5,
                color: const Color(0xFF64748B),
              ),
            ),
            const SizedBox(height: 20),
            ListTile(
              leading: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF6FF),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFBFDBFE)),
                ),
                child: const Icon(Icons.bluetooth_searching_rounded, color: Color(0xFF2563EB)),
              ),
              title: Text(
                'Quét Bluetooth BLE (Khuyên dùng)',
                style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700, fontSize: 14),
              ),
              subtitle: Text(
                'Tự động tìm kiếm và ghép đôi xe Dat Bike đang ở gần',
                style: GoogleFonts.plusJakartaSans(fontSize: 11.5, color: const Color(0xFF64748B)),
              ),
              trailing: const Icon(Icons.chevron_right_rounded, color: Color(0xFF94A3B8)),
              contentPadding: EdgeInsets.zero,
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ScanScreen()),
                );
              },
            ),
            const Divider(color: Color(0xFFF1F5F9), height: 16),
            ListTile(
              leading: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: const Icon(Icons.edit_note_rounded, color: Color(0xFF475569)),
              ),
              title: Text(
                'Nhập thông tin thủ công',
                style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700, fontSize: 14),
              ),
              subtitle: Text(
                'Nhập địa chỉ MAC / Bluetooth ID và thông tin xe',
                style: GoogleFonts.plusJakartaSans(fontSize: 11.5, color: const Color(0xFF64748B)),
              ),
              trailing: const Icon(Icons.chevron_right_rounded, color: Color(0xFF94A3B8)),
              contentPadding: EdgeInsets.zero,
              onTap: () {
                Navigator.pop(ctx);
                _showManualAddDialog();
              },
            ),
          ],
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
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text(
            'Thêm Xe Thủ Công',
            style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700, fontSize: 17),
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
                  style: GoogleFonts.plusJakartaSans(fontSize: 13),
                ),
                const SizedBox(height: 12),
                _formLabel('Tên hiển thị xe *'),
                TextField(
                  controller: nameController,
                  decoration: _inputDecoration('vd: Xe Đi Làm - Quantum S1'),
                  style: GoogleFonts.plusJakartaSans(fontSize: 13),
                ),
                const SizedBox(height: 12),
                _formLabel('Dòng xe (Model)'),
                DropdownButtonFormField<String>(
                  initialValue: selectedModel,
                  items: models.map((m) => DropdownMenuItem(value: m, child: Text(m, style: GoogleFonts.plusJakartaSans(fontSize: 13)))).toList(),
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
                  style: GoogleFonts.plusJakartaSans(fontSize: 13),
                ),
                const SizedBox(height: 12),
                _formLabel('Mật khẩu kết nối Bluetooth (Tùy chọn)'),
                TextField(
                  controller: pwdController,
                  obscureText: true,
                  decoration: _inputDecoration('Để trống nếu chưa đặt'),
                  style: GoogleFonts.plusJakartaSans(fontSize: 13),
                ),
                const SizedBox(height: 12),
                _formLabel('Ghi chú'),
                TextField(
                  controller: noteController,
                  decoration: _inputDecoration('Ghi chú cá nhân...'),
                  style: GoogleFonts.plusJakartaSans(fontSize: 13),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('HỦY', style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600, color: const Color(0xFF64748B))),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF2563EB),
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
              child: Text('LƯU XE', style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700)),
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
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text(
            'Chỉnh Sửa Thông Tin Xe',
            style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700, fontSize: 17),
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
                  style: GoogleFonts.plusJakartaSans(fontSize: 13),
                ),
                const SizedBox(height: 12),
                _formLabel('Dòng xe (Model)'),
                DropdownButtonFormField<String>(
                  initialValue: selectedModel,
                  items: models.map((m) => DropdownMenuItem(value: m, child: Text(m, style: GoogleFonts.plusJakartaSans(fontSize: 13)))).toList(),
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
                  style: GoogleFonts.plusJakartaSans(fontSize: 13),
                ),
                const SizedBox(height: 12),
                _formLabel('Màu sắc xe'),
                TextField(
                  controller: colorController,
                  decoration: _inputDecoration('vd: Trắng Ngọc, Đen Nhám...'),
                  style: GoogleFonts.plusJakartaSans(fontSize: 13),
                ),
                const SizedBox(height: 12),
                _formLabel('Mật khẩu Bluetooth riêng xe này'),
                TextField(
                  controller: pwdController,
                  obscureText: true,
                  decoration: _inputDecoration('Để trống nếu không đổi'),
                  style: GoogleFonts.plusJakartaSans(fontSize: 13),
                ),
                const SizedBox(height: 12),
                _formLabel('Ghi chú'),
                TextField(
                  controller: noteController,
                  decoration: _inputDecoration('Ghi chú bảo dưỡng, phụ kiện...'),
                  style: GoogleFonts.plusJakartaSans(fontSize: 13),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('HỦY', style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600, color: const Color(0xFF64748B))),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF2563EB),
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
              child: Text('CẬP NHẬT', style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700)),
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
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Xóa xe khỏi danh sách?',
          style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700, fontSize: 17, color: const Color(0xFFEF4444)),
        ),
        content: Text(
          'Bạn có chắc chắn muốn xóa "${bike.name}" (${bike.id}) khỏi nhà xe không?\n'
          'Các dữ liệu cài đặt riêng và mật khẩu liên kết của xe này sẽ được gỡ bỏ.',
          style: GoogleFonts.plusJakartaSans(fontSize: 13.5, color: const Color(0xFF475569), height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('HỦY', style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600, color: const Color(0xFF64748B))),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFEF4444),
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
            child: Text('XÁC NHẬN XÓA', style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700)),
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
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Color(0xFFEF4444), size: 24),
            const SizedBox(width: 8),
            Text(
              'Xóa toàn bộ xe?',
              style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700, fontSize: 17, color: const Color(0xFFEF4444)),
            ),
          ],
        ),
        content: Text(
          'Bạn có chắc chắn muốn xóa TOÀN BỘ xe khỏi nhà xe không?\n'
          'Toàn bộ cấu hình, vị trí đỗ, và mật khẩu liên kết sẽ bị xóa sạch khỏi ứng dụng.',
          style: GoogleFonts.plusJakartaSans(fontSize: 13.5, color: const Color(0xFF475569), height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('HỦY', style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600, color: const Color(0xFF64748B))),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFEF4444),
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
            child: Text('XÓA TẤT CẢ', style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: GoogleFonts.plusJakartaSans(fontSize: 12.5, color: const Color(0xFF94A3B8)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      filled: true,
      fillColor: const Color(0xFFF8FAFC),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF2563EB), width: 1.5)),
    );
  }

  Widget _formLabel(String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        label,
        style: GoogleFonts.plusJakartaSans(fontSize: 12, fontWeight: FontWeight.w700, color: const Color(0xFF334155)),
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
      backgroundColor: const Color(0xFFF8F9FA),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Nhà Xe Của Bạn',
              style: GoogleFonts.plusJakartaSans(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: const Color(0xFF0F172A),
              ),
            ),
            Text(
              '${bikes.length} xe máy điện đã lưu · Điều khiển đa xe',
              style: GoogleFonts.plusJakartaSans(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                color: const Color(0xFF64748B),
              ),
            ),
          ],
        ),
        actions: [
          if (bikes.isNotEmpty)
            IconButton(
              tooltip: 'Xóa toàn bộ xe đã lưu',
              icon: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEE2E2),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFFECACA)),
                ),
                child: const Icon(Icons.delete_sweep_rounded, color: Color(0xFFEF4444), size: 20),
              ),
              onPressed: _confirmDeleteAllBikes,
            ),
          IconButton(
            tooltip: 'Thêm xe mới',
            icon: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFFEFF6FF),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFBFDBFE)),
              ),
              child: const Icon(Icons.add_rounded, color: Color(0xFF2563EB), size: 20),
            ),
            onPressed: _showAddBikeOptions,
          ),
          const SizedBox(width: 8),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: const Color(0xFFF1F5F9), height: 1),
        ),
      ),
      body: bikes.isEmpty
          ? _buildEmptyState()
          : ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              itemCount: bikes.length,
              itemBuilder: (context, index) {
                final bike = bikes[index];
                final isConnected = currentConnectedId == bike.id.toLowerCase();
                final isActive = currentActiveId == bike.id.toLowerCase();
                return _buildBikeCard(bike, isActive: isActive, isConnected: isConnected);
              },
            ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFF1F5F9), width: 1)),
          boxShadow: [
            BoxShadow(color: Color(0x060F172A), blurRadius: 10, offset: Offset(0, -3)),
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
                    side: const BorderSide(color: Color(0xFFBFDBFE)),
                    backgroundColor: const Color(0xFFEFF6FF),
                  ),
                  icon: const Icon(Icons.bluetooth_searching_rounded, size: 18, color: Color(0xFF2563EB)),
                  label: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      'QUÉT XE',
                      style: GoogleFonts.plusJakartaSans(fontSize: 12.5, fontWeight: FontWeight.w700, color: const Color(0xFF2563EB)),
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
                    backgroundColor: const Color(0xFF2563EB),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  icon: const Icon(Icons.add_rounded, size: 18, color: Colors.white),
                  label: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      'THÊM XE',
                      style: GoogleFonts.plusJakartaSans(fontSize: 12.5, fontWeight: FontWeight.w700, color: Colors.white),
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
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: const Color(0xFFEFF6FF),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFFBFDBFE), width: 2),
              ),
              child: const Icon(Icons.two_wheeler_outlined, size: 40, color: Color(0xFF2563EB)),
            ),
            const SizedBox(height: 20),
            Text(
              'Nhà Xe Đang Trống',
              style: GoogleFonts.plusJakartaSans(fontSize: 18, fontWeight: FontWeight.w800, color: const Color(0xFF0F172A)),
            ),
            const SizedBox(height: 8),
            Text(
              'Bạn chưa lưu chiếc xe Dat Bike nào.\nBấm nút bên dưới để quét kết nối Bluetooth và đưa xe vào nhà xe!',
              textAlign: TextAlign.center,
              style: GoogleFonts.plusJakartaSans(fontSize: 13, color: const Color(0xFF64748B), height: 1.5),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF2563EB),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              icon: const Icon(Icons.bluetooth_searching_rounded, size: 20),
              label: Text('TÌM & KẾT NỐI XE NGAY', style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700, fontSize: 13.5)),
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
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isConnected
              ? const Color(0xFF2563EB)
              : (isActive ? const Color(0xFF93C5FD) : const Color(0xFFE2E8F0)),
          width: isConnected ? 2.0 : (isActive ? 1.5 : 1.0),
        ),
        boxShadow: [
          BoxShadow(
            color: isConnected ? const Color(0x122563EB) : const Color(0x060F172A),
            blurRadius: isConnected ? 16 : 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
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
                    color: const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Image.asset(
                    'assets/images/bike_logo_3d.png',
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const Icon(Icons.two_wheeler_rounded, size: 24, color: Color(0xFF2563EB)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              bike.name,
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                color: const Color(0xFF0F172A),
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (bike.isDefault) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFEF3C7),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: const Color(0xFFFCD34D)),
                              ),
                              child: Text(
                                'MẶC ĐỊNH',
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 8.5,
                                  fontWeight: FontWeight.w800,
                                  color: const Color(0xFFB45309),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Model: ${bike.model ?? "Dat Bike"} · ${bike.color ?? "Tiêu chuẩn"}',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: const Color(0xFF64748B),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // Huy hiệu trạng thái kết nối
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: isConnected
                        ? const Color(0xFFECFDF5)
                        : (isActive ? const Color(0xFFEFF6FF) : const Color(0xFFF1F5F9)),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isConnected
                          ? const Color(0xFFA7F3D0)
                          : (isActive ? const Color(0xFFBFDBFE) : const Color(0xFFE2E8F0)),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isConnected
                              ? const Color(0xFF10B981)
                              : (isActive ? const Color(0xFF2563EB) : const Color(0xFF94A3B8)),
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        isConnected
                            ? 'KẾT NỐI'
                            : (isActive ? 'ĐANG CHỌN' : 'OFFLINE'),
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: isConnected
                              ? const Color(0xFF047857)
                              : (isActive ? const Color(0xFF1D4ED8) : const Color(0xFF64748B)),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Divider mờ
          const Divider(color: Color(0xFFF1F5F9), height: 1, indent: 16, endIndent: 16),

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
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFF0F172A), width: 1.2),
                      boxShadow: const [
                        BoxShadow(color: Color(0x0A0F172A), blurRadius: 4, offset: Offset(0, 1)),
                      ],
                    ),
                    child: Text(
                      bike.licensePlate!,
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.8,
                        color: const Color(0xFF0F172A),
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
                        const Icon(Icons.bluetooth_rounded, size: 14, color: Color(0xFF64748B)),
                        const SizedBox(width: 4),
                        Text(
                          bike.id.length > 17 ? '${bike.id.substring(0, 17)}...' : bike.id,
                          style: GoogleFonts.jetBrainsMono(
                            fontSize: 11,
                            color: const Color(0xFF64748B),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(width: 3),
                        const Icon(Icons.copy_rounded, size: 12, color: Color(0xFF94A3B8)),
                      ],
                    ),
                  ),
                ),

                // Mức pin lần cuối
                if (bike.lastBatteryPercent != null)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.battery_charging_full_rounded, size: 15, color: Color(0xFF10B981)),
                      const SizedBox(width: 4),
                      Text(
                        '${bike.lastBatteryPercent}% pin',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFF0F172A),
                        ),
                      ),
                    ],
                  ),

                // Odo lần cuối
                if (bike.lastOdo != null && bike.lastOdo! > 0)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.speed_rounded, size: 14, color: Color(0xFF6366F1)),
                      const SizedBox(width: 4),
                      Text(
                        '${bike.lastOdo!.toStringAsFixed(0)} km ODO',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFF0F172A),
                        ),
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
                style: GoogleFonts.plusJakartaSans(fontSize: 11.5, fontStyle: FontStyle.italic, color: const Color(0xFF64748B)),
              ),
            ),

          // Thanh hành động (Chuyển xe, Sửa, Đặt mặc định, Xóa)
          Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            decoration: const BoxDecoration(
              color: Color(0xFFF8FAFC),
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
                            side: const BorderSide(color: Color(0xFFCBD5E1)),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            backgroundColor: Colors.white,
                          ),
                          icon: const Icon(Icons.link_off_rounded, size: 16, color: Color(0xFF64748B)),
                          label: Text(
                            'NGẮT KẾT NỐI',
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: const Color(0xFF64748B),
                            ),
                          ),
                          onPressed: () async {
                            await ref.read(bleProvider.notifier).disconnect();
                            _snack('Đã ngắt kết nối với ${bike.name}');
                          },
                        )
                      : FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF2563EB),
                            padding: const EdgeInsets.symmetric(vertical: 9),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            elevation: 0,
                          ),
                          icon: const Icon(Icons.swap_horiz_rounded, size: 17),
                          label: Text(
                            'ĐIỀU KHIỂN XE',
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 12,
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
                    if (!bike.isDefault)
                      InkWell(
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
                              const Icon(Icons.star_outline_rounded, size: 16, color: Color(0xFF64748B)),
                              const SizedBox(width: 4),
                              Text(
                                'Đặt mặc định',
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 11.5,
                                  color: const Color(0xFF64748B),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.star_rounded, size: 16, color: Color(0xFFD97706)),
                            const SizedBox(width: 4),
                            Text(
                              'Xe mặc định',
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 11.5,
                                color: const Color(0xFFD97706),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    const Spacer(),
                    // Nút sửa
                    InkWell(
                      onTap: () => _showEditBikeDialog(bike),
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.edit_outlined, size: 15, color: Color(0xFF2563EB)),
                            const SizedBox(width: 4),
                            Text(
                              'Sửa',
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: const Color(0xFF2563EB),
                              ),
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
                            const Icon(Icons.delete_outline_rounded, size: 15, color: Color(0xFFEF4444)),
                            const SizedBox(width: 4),
                            Text(
                              'Xóa',
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                                color: const Color(0xFFEF4444),
                              ),
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
    );
  }
}
