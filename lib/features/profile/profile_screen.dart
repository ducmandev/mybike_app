// Screen 4: User Profile — Hồ sơ Chủ Xe Máy Điện Dat Bike
// Thiết kế tham chiếu Geely "Edit your personalized information" tinh chỉnh cho Dat Bike:
// - Icon QR (quét mã ghép nối NFC / BLE xe máy) & Chat hỗ trợ Dat Care 24/7.
// - Avatar tròn đen chữ J (hoặc D).
// - Lời chào lớn Hello, Dat Bike User (font rộng), ID DB-QUANTUM-0187, nút Edit Profile ->.
// - Danh sách cài đặt thiết thực cho xe máy điện trên nền trắng:
//     1. Cài đặt xe & Chế độ lái (Regen Braking, Giới hạn tốc độ)
//     2. Bác Sĩ Pin & Chẩn đoán 24-Cell BMS
//     3. Cập nhật phần mềm xe qua mạng (OTA Firmware)
//     4. Thông tin ứng dụng (About)
//     5. Đăng xuất (Log Out)

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/ble/ble_controller.dart';
import '../battery/battery_diagnostics_screen.dart';
import '../ota/ota_screen.dart';
import '../scan/scan_screen.dart';
import '../settings/vehicle_settings_screen.dart';
import '../settings/vehicle_management_screen.dart';
import '../logs/logs_screen.dart';
import '../firmware_lab/firmware_lab_screen.dart';
import '../dashboard/widgets/offline_map_sheet.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  bool _showDevMenu = false;
  int _aboutTapCount = 0;
  DateTime? _lastTapTime;

  void _handleAboutTap(BuildContext context) {
    final now = DateTime.now();
    if (_lastTapTime == null || now.difference(_lastTapTime!) > const Duration(seconds: 2)) {
      _aboutTapCount = 1;
    } else {
      _aboutTapCount++;
    }
    _lastTapTime = now;

    if (_aboutTapCount >= 5) {
      _aboutTapCount = 0;
      setState(() {
        _showDevMenu = !_showDevMenu;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _showDevMenu
                ? '🔓 Đã mở khóa Menu Kỹ thuật viên (Nhật ký BLE & Phòng Lab)'
                : '🔒 Đã ẩn Menu Kỹ thuật viên',
            style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600),
          ),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }

    _showAbout(context);
  }

  void _showAbout(BuildContext context) {
    showAboutDialog(
      context: context,
      applicationName: 'Dat Bike Companion',
      applicationVersion: 'v2.6.30',
      applicationIcon: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.asset(
          'assets/images/bike_logo_3d.png',
          width: 44,
          height: 44,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const Icon(Icons.two_wheeler_rounded, size: 36, color: Color(0xFF2563EB)),
        ),
      ),
      children: [
        Text(
          'Ứng dụng điều khiển xe máy điện Dat Bike (Quantum & Weaver series) tối ưu hóa kết nối BLE và quản lý thông số pin thông minh.',
          style: GoogleFonts.plusJakartaSans(fontSize: 13),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ble = ref.watch(bleProvider);

    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ══════════════════════════════════════════════════════════════
              // 1. THANH TRẠNG THÁI TIÊU ĐỀ & PHÍM TẮT TÌM XE BLE
              // ══════════════════════════════════════════════════════════════
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'TÀI KHOẢN & XE',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.0,
                      color: const Color(0xFF64748B),
                    ),
                  ),
                  InkWell(
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const ScanScreen()),
                      );
                    },
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEFF6FF),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: const Color(0xFFBFDBFE)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.bluetooth_searching_rounded, size: 16, color: Color(0xFF2563EB)),
                          const SizedBox(width: 6),
                          Text(
                            'Tìm Xe BLE',
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: const Color(0xFF2563EB),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 18),

              // ══════════════════════════════════════════════════════════════
              // 2. AVATAR CHỦ XE DAT BIKE (CHỮ CÁI ĐẦU TIÊN TỪ TÊN)
              // ══════════════════════════════════════════════════════════════
              Container(
                width: 60,
                height: 60,
                decoration: const BoxDecoration(
                  color: Color(0xFF1E293B),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  (ble.userName?.trim().isNotEmpty == true)
                      ? ble.userName!.trim()[0].toUpperCase()
                      : 'D',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // ══════════════════════════════════════════════════════════════
              // 3. LỜI CHÀO LỚN Hello, [Tên chủ xe]
              // ══════════════════════════════════════════════════════════════
              Text(
                'Hello,\n${(ble.userName?.trim().isNotEmpty == true) ? ble.userName!.trim() : "Dat Bike User"}',
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 32,
                  fontWeight: FontWeight.w800,
                  height: 1.15,
                  letterSpacing: -0.5,
                  color: const Color(0xFF0F172A),
                ),
              ),

              const SizedBox(height: 10),

              // 4. MÃ ĐỊNH DANH XE MÁY ĐIỆN: SERIAL KHUNG / MODEL / TRẠNG THÁI
              Text(
                (ble.frameSerial != null && ble.frameSerial!.isNotEmpty)
                    ? ble.frameSerial!
                    : (ble.bikeModelCode != null
                        ? 'Model: ${ble.bikeModelCode}'
                        : 'Chưa đồng bộ số khung (Kết nối xe để đọc)'),
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFF94A3B8),
                  letterSpacing: 0.3,
                ),
              ),

              const SizedBox(height: 14),

              // 5. NÚT Edit Profile -> Mở hộp thoại chỉnh sửa
              InkWell(
                onTap: () => _showEditProfileDialog(context, ref, ble),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Chỉnh sửa hồ sơ',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFF2563EB),
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Icon(
                        Icons.edit_outlined,
                        size: 16,
                        color: Color(0xFF2563EB),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 32),

              // ══════════════════════════════════════════════════════════════
              // 6. DANH SÁCH CÀI ĐẶT THIẾT YẾU CHO XE MÁY ĐIỆN TRÊN NỀN TRẮNG
              // ══════════════════════════════════════════════════════════════
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFFF1F5F9)),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x060F172A),
                      blurRadius: 16,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    // 0. Quản lý Nhà Xe (Garage)
                    _profileListItem(
                      icon: const Icon(Icons.garage_rounded, size: 22, color: Color(0xFF2563EB)),
                      title: 'Nhà xe của tôi (${ble.savedBikes.length} xe)',
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const VehicleManagementScreen()),
                        );
                      },
                    ),

                    const Divider(color: Color(0xFFF1F5F9), height: 1, thickness: 1, indent: 56, endIndent: 20),

                    // 0.1 Ghép đôi xe mới
                    _profileListItem(
                      icon: const Icon(Icons.bluetooth_searching_rounded, size: 22, color: Color(0xFF0F172A)),
                      title: 'Ghép đôi xe mới',
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const ScanScreen()),
                        );
                      },
                    ),

                    const Divider(color: Color(0xFFF1F5F9), height: 1, thickness: 1, indent: 56, endIndent: 20),

                    // 1. Cài đặt xe & Phanh tái sinh
                    _profileListItem(
                      icon: const Icon(Icons.tune_rounded, size: 22, color: Color(0xFF0F172A)),
                      title: 'Cài đặt xe & Phanh',
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const VehicleSettingsScreen()),
                        );
                      },
                    ),

                    const Divider(color: Color(0xFFF1F5F9), height: 1, thickness: 1, indent: 56, endIndent: 20),

                    // 2. Bác Sĩ Pin & Chẩn đoán 24-Cell BMS
                    _profileListItem(
                      icon: const Icon(Icons.medical_services_outlined, size: 22, color: Color(0xFF10B981)),
                      title: 'Bác sĩ pin & BMS',
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const BatteryDiagnosticsScreen()),
                        );
                      },
                    ),

                    const Divider(color: Color(0xFFF1F5F9), height: 1, thickness: 1, indent: 56, endIndent: 20),

                    // 3. Cập nhật phần mềm xe qua mạng (OTA)
                    _profileListItem(
                      icon: const Icon(Icons.system_update_rounded, size: 22, color: Color(0xFF2563EB)),
                      title: 'Cập nhật phần mềm (OTA)',
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const OtaScreen()),
                        );
                      },
                    ),

                    const Divider(color: Color(0xFFF1F5F9), height: 1, thickness: 1, indent: 56, endIndent: 20),

                    // 3.1 Bản đồ Offline & Xóa bộ nhớ đệm
                    _profileListItem(
                      icon: const Icon(Icons.map_outlined, size: 22, color: Color(0xFF0F172A)),
                      title: 'Bản đồ offline & Bộ nhớ đệm',
                      onTap: () {
                        OfflineMapSheet.show(context);
                      },
                    ),

                    const Divider(color: Color(0xFFF1F5F9), height: 1, thickness: 1, indent: 56, endIndent: 20),

                    if (_showDevMenu) ...[
                      const Divider(color: Color(0xFFF1F5F9), height: 1, thickness: 1, indent: 56, endIndent: 20),
                      // 4. Nhật ký BLE & Xuất Log (Ẩn mặc định)
                      _profileListItem(
                        icon: const Icon(Icons.receipt_long_rounded, size: 22, color: Color(0xFF6366F1)),
                        title: 'Nhật ký Bluetooth (Kỹ thuật)',
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const LogsScreen()),
                          );
                        },
                      ),
                      const Divider(color: Color(0xFFF1F5F9), height: 1, thickness: 1, indent: 56, endIndent: 20),
                      // 5. Phòng Kiểm Nghiệm Firmware Lab (Ẩn mặc định)
                      _profileListItem(
                        icon: const Icon(Icons.science_rounded, size: 22, color: Color(0xFF8B5CF6)),
                        title: 'Phòng thí nghiệm Lab (Kỹ thuật)',
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const FirmwareLabScreen()),
                          );
                        },
                      ),
                    ],

                    const Divider(color: Color(0xFFF1F5F9), height: 1, thickness: 1, indent: 56, endIndent: 20),

                    // 6. Thông tin ứng dụng (About - Chạm 5 lần để bật/tắt menu kỹ thuật viên)
                    _profileListItem(
                      icon: const Icon(Icons.info_outline_rounded, size: 22, color: Color(0xFF0F172A)),
                      title: 'Thông tin ứng dụng',
                      onTap: () => _handleAboutTap(context),
                    ),

                    const Divider(color: Color(0xFFF1F5F9), height: 1, thickness: 1, indent: 56, endIndent: 20),

                    // 7. Ngắt kết nối xe
                    _profileListItem(
                      icon: const Icon(Icons.link_off_rounded, size: 22, color: Color(0xFFEF4444)),
                      title: 'Ngắt kết nối xe',
                      onTap: () {
                        showDialog(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                            title: Text('Ngắt Kết Nối Xe', style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700)),
                            content: Text(
                              'Bạn có chắc chắn muốn ngắt kết nối Bluetooth khỏi xe ${ble.bikeName ?? "Dat Bike"}?',
                              style: GoogleFonts.plusJakartaSans(fontSize: 14),
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
                                  await ref.read(bleProvider.notifier).disconnect();
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('Đã ngắt kết nối Bluetooth')),
                                    );
                                  }
                                },
                                child: Text('NGẮT KẾT NỐI', style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700)),
                              ),
                            ],
                          ),
                        );
                      },
                    ),

                    const Divider(color: Color(0xFFF1F5F9), height: 1, thickness: 1, indent: 56, endIndent: 20),

                    // 8. Xóa / Quên xe đã kết nối
                    _profileListItem(
                      icon: const Icon(Icons.delete_forever_rounded, size: 22, color: Color(0xFFEF4444)),
                      title: 'Xóa / Quên xe đã kết nối',
                      textColor: const Color(0xFFEF4444),
                      onTap: () {
                        showDialog(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                            title: Text('Quên Xe Đã Kết Nối', style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700, color: const Color(0xFFEF4444))),
                            content: Text(
                              'Hành động này sẽ ngắt kết nối và xóa thông tin xe "${ble.bikeName ?? "hiện tại"}" khỏi ứng dụng.\n\nTrên iOS: Hãy vào Cài đặt > Bluetooth > Quên thiết bị này để hủy ghép đôi hệ thống hoàn toàn.',
                              style: GoogleFonts.plusJakartaSans(fontSize: 14),
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
                                  await ref.read(bleProvider.notifier).forgetBike();
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('Đã xóa thông tin xe đã kết nối')),
                                    );
                                  }
                                },
                                child: Text('XÓA / QUÊN XE', style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700)),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  void _showEditProfileDialog(BuildContext context, WidgetRef ref, BleState ble) {
    final userController = TextEditingController(text: ble.userName ?? '');
    final bikeController = TextEditingController(text: ble.bikeName ?? '');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Chỉnh Sửa Hồ Sơ',
          style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700, fontSize: 18),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Tên hiển thị chủ xe',
                style: GoogleFonts.plusJakartaSans(fontSize: 12, fontWeight: FontWeight.w600, color: const Color(0xFF64748B)),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: userController,
                decoration: InputDecoration(
                  hintText: 'Nhập tên của bạn',
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Tên gọi của xe',
                style: GoogleFonts.plusJakartaSans(fontSize: 12, fontWeight: FontWeight.w600, color: const Color(0xFF64748B)),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: bikeController,
                decoration: InputDecoration(
                  hintText: 'VD: Dat Bike Quantum S1',
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              if (ble.phase == BlePhase.connected) ...[
                const SizedBox(height: 8),
                Text(
                  '💡 Tên xe sẽ được lưu vào flash xe qua cổng Bluetooth.',
                  style: GoogleFonts.plusJakartaSans(fontSize: 11, color: const Color(0xFF10B981)),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'HỦY',
              style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600, color: const Color(0xFF64748B)),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () async {
              final newUserName = userController.text.trim();
              final newBikeName = bikeController.text.trim();
              Navigator.pop(ctx);

              if (newUserName.isNotEmpty) {
                await ref.read(bleProvider.notifier).setUserName(newUserName);
              }
              if (newBikeName.isNotEmpty && newBikeName != ble.bikeName) {
                if (ble.phase == BlePhase.connected) {
                  await ref.read(bleProvider.notifier).setFwBikeName(newBikeName);
                } else {
                  await ref.read(bleProvider.notifier).setLocalBikeName(newBikeName);
                }
              }

              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Đã cập nhật hồ sơ thành công!', style: GoogleFonts.plusJakartaSans()),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            },
            child: Text(
              'LƯU HỒ SƠ',
              style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _profileListItem({
    required Widget icon,
    required String title,
    required VoidCallback onTap,
    Color? textColor,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 17),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: Center(child: icon),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                title,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 14.5,
                  fontWeight: textColor != null ? FontWeight.w600 : FontWeight.w500,
                  color: textColor ?? const Color(0xFF0F172A),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 22,
              color: textColor?.withValues(alpha: 0.6) ?? const Color(0xFF94A3B8),
            ),
          ],
        ),
      ),
    );
  }
}
