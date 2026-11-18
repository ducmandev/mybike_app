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

import '../../core/ble/ble_controller.dart';
import '../../ui/app_theme.dart';
import '../../ui/widgets.dart';
import '../battery/battery_diagnostics_screen.dart';
import '../ota/ota_screen.dart';
import '../scan/scan_screen.dart';
import '../settings/vehicle_settings_screen.dart';
import '../settings/vehicle_management_screen.dart';
import '../settings/maintenance_log_screen.dart';
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
            style: AppTypography.labelLg(color: AppColors.onPrimary),
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
      applicationVersion: 'v2.6.48',
      applicationIcon: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.asset(
          'assets/images/bike_logo_3d.png',
          width: 44,
          height: 44,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const Icon(
            Icons.two_wheeler_rounded,
            size: 36,
            color: AppColors.primary,
          ),
        ),
      ),
      children: [
        Text(
          'Ứng dụng điều khiển xe máy điện Dat Bike (Quantum & Weaver series) tối ưu hóa kết nối BLE và quản lý thông số pin thông minh.',
          style: AppTypography.bodySm(color: AppColors.textDim),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(
      bleProvider.select(
        (s) => (
          phase: s.phase,
          bikeName: s.bikeName,
          userName: s.userName,
          bikeModel: s.bikeModel,
          savedBikesCount: s.savedBikes.length,
        ),
      ),
    );
    final trimmedUserName = profile.userName?.trim() ?? '';

    return Scaffold(
      backgroundColor: AppColors.bg,
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
                  Expanded(
                    child: Text(
                      'TÀI KHOẢN & XE',
                      style: AppTypography.labelMd(color: AppColors.textDim).copyWith(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.0,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  InkWell(
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const ScanScreen()),
                      );
                    },
                    borderRadius: BorderRadius.circular(9999),
                    child: const StatusPill(
                      label: 'Tìm Xe BLE',
                      color: AppColors.primary,
                      icon: Icons.bluetooth_searching_rounded,
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
                  color: AppColors.onSurface,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  trimmedUserName.isNotEmpty
                      ? trimmedUserName[0].toUpperCase()
                      : 'D',
                  style: AppTypography.evWide(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: AppColors.onPrimary,
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // ══════════════════════════════════════════════════════════════
              // 3. LỜI CHÀO LỚN Hello, [Tên chủ xe]
              // ══════════════════════════════════════════════════════════════
              Text(
                'Hello,\n${trimmedUserName.isNotEmpty ? trimmedUserName : "Dat Bike User"}',
                style: AppTypography.evWide(
                  fontSize: 32,
                  fontWeight: FontWeight.w800,
                  height: 1.15,
                  letterSpacing: -0.5,
                  color: AppColors.textPrimary,
                ),
              ),

              const SizedBox(height: 10),

              // 4. MÃ ĐỊNH DANH XE MÁY ĐIỆN: SERIAL KHUNG / MODEL / TRẠNG THÁI
              Consumer(
                builder: (context, idRef, _) {
                  final frameInfo = idRef.watch(
                    bleProvider.select((s) => (s.frameSerial, s.bikeModelCode)),
                  );
                  final frameSerial = frameInfo.$1;
                  final bikeModelCode = frameInfo.$2;
                  return Text(
                    (frameSerial != null && frameSerial.isNotEmpty)
                        ? frameSerial
                        : (bikeModelCode != null
                            ? 'Model: $bikeModelCode (${profile.bikeModel.displayName})'
                            : 'Chưa đồng bộ số khung (Kết nối xe để đọc)'),
                    style: AppTypography.headlineSm(color: AppColors.textMuted).copyWith(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.3,
                      height: 1.4,
                    ),
                  );
                },
              ),

              const SizedBox(height: 14),

              // 5. NÚT Edit Profile -> Mở hộp thoại chỉnh sửa
              InkWell(
                onTap: () => _showEditProfileDialog(
                  context,
                  ref,
                  phase: profile.phase,
                  bikeName: profile.bikeName,
                  userName: profile.userName,
                ),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Chỉnh sửa hồ sơ',
                        style: AppTypography.labelLg(color: AppColors.primary).copyWith(
                          fontSize: 14.5,
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Icon(
                        Icons.edit_outlined,
                        size: 16,
                        color: AppColors.primary,
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 32),

              // ══════════════════════════════════════════════════════════════
              // 6. DANH SÁCH CÀI ĐẶT THIẾT YẾU CHO XE MÁY ĐIỆN TRÊN NỀN TRẮNG
              // ══════════════════════════════════════════════════════════════
              Panel(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    // 0. Quản lý Nhà Xe (Garage)
                    PanelActionRow(
                      icon: Icons.garage_rounded,
                      iconColor: AppColors.primary,
                      title: 'Nhà xe của tôi (${profile.savedBikesCount} xe)',
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const VehicleManagementScreen()),
                        );
                      },
                    ),

                    const PanelDivider(),

                    // 0.1 Ghép đôi xe mới
                    PanelActionRow(
                      icon: Icons.bluetooth_searching_rounded,
                      iconColor: AppColors.textPrimary,
                      title: 'Ghép đôi xe mới',
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const ScanScreen()),
                        );
                      },
                    ),

                    const PanelDivider(),

                    // 1. Cài đặt xe
                    PanelActionRow(
                      icon: Icons.tune_rounded,
                      iconColor: AppColors.textPrimary,
                      title: 'Cài đặt xe',
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const VehicleSettingsScreen()),
                        );
                      },
                    ),

                    const PanelDivider(),

                    // 2. Bác Sĩ Pin & Chẩn đoán 24-Cell BMS
                    PanelActionRow(
                      icon: Icons.medical_services_outlined,
                      iconColor: AppColors.mint,
                      title: 'Bác sĩ pin & BMS',
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const BatteryDiagnosticsScreen()),
                        );
                      },
                    ),

                    const PanelDivider(),

                    // 2.1 Sổ bảo dưỡng theo ODO
                    PanelActionRow(
                      icon: Icons.build_circle_outlined,
                      iconColor: AppColors.amber,
                      title: 'Sổ bảo dưỡng theo ODO',
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const MaintenanceLogScreen()),
                        );
                      },
                    ),

                    const PanelDivider(),

                    // 3. Cập nhật phần mềm xe qua mạng (OTA)
                    PanelActionRow(
                      icon: Icons.system_update_rounded,
                      iconColor: AppColors.primary,
                      title: 'Cập nhật phần mềm (OTA)',
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const OtaScreen()),
                        );
                      },
                    ),

                    const PanelDivider(),

                    // 3.1 Bản đồ Offline & Xóa bộ nhớ đệm
                    PanelActionRow(
                      icon: Icons.map_outlined,
                      iconColor: AppColors.textPrimary,
                      title: 'Bản đồ offline & Bộ nhớ đệm',
                      onTap: () {
                        OfflineMapSheet.show(context);
                      },
                    ),

                    if (_showDevMenu) ...[
                      const PanelDivider(),
                      // 4. Nhật ký BLE & Xuất Log (Ẩn mặc định)
                      PanelActionRow(
                        icon: Icons.receipt_long_rounded,
                        iconColor: AppColors.primaryContainer,
                        title: 'Nhật ký Bluetooth (Kỹ thuật)',
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const LogsScreen()),
                          );
                        },
                      ),
                      const PanelDivider(),
                      // 5. Phòng Kiểm Nghiệm Firmware Lab (Ẩn mặc định)
                      PanelActionRow(
                        icon: Icons.science_rounded,
                        iconColor: AppColors.accent,
                        title: 'Phòng thí nghiệm Lab (Kỹ thuật)',
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const FirmwareLabScreen()),
                          );
                        },
                      ),
                    ],

                    const PanelDivider(),

                    // 6. Thông tin ứng dụng (About - Chạm 5 lần để bật/tắt menu kỹ thuật viên)
                    PanelActionRow(
                      icon: Icons.info_outline_rounded,
                      iconColor: AppColors.textPrimary,
                      title: 'Thông tin ứng dụng',
                      onTap: () => _handleAboutTap(context),
                    ),

                    const PanelDivider(),

                    // 7. Ngắt kết nối xe
                    PanelActionRow(
                      icon: Icons.link_off_rounded,
                      iconColor: AppColors.red,
                      title: 'Ngắt kết nối xe',
                      onTap: () {
                        showDialog(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                            title: Text(
                              'Ngắt Kết Nối Xe',
                              style: AppTypography.headlineSm(color: AppColors.textPrimary)
                                  .copyWith(fontWeight: FontWeight.w700),
                            ),
                            content: Text(
                              'Bạn có chắc chắn muốn ngắt kết nối Bluetooth khỏi xe ${profile.bikeName ?? "Dat Bike"}?',
                              style: AppTypography.bodyMd(color: AppColors.textDim)
                                  .copyWith(fontSize: 14),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx),
                                child: Text(
                                  'HỦY',
                                  style: AppTypography.labelLg(color: AppColors.textDim),
                                ),
                              ),
                              FilledButton(
                                style: FilledButton.styleFrom(
                                  backgroundColor: AppColors.red,
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
                                child: Text(
                                  'NGẮT KẾT NỐI',
                                  style: AppTypography.labelLg(
                                    color: AppColors.onPrimary,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),

                    const PanelDivider(),

                    // 8. Xóa / Quên xe đã kết nối
                    PanelActionRow(
                      icon: Icons.delete_forever_rounded,
                      iconColor: AppColors.red,
                      title: 'Xóa / Quên xe đã kết nối',
                      titleColor: AppColors.red,
                      onTap: () {
                        showDialog(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                            title: Text(
                              'Quên Xe Đã Kết Nối',
                              style: AppTypography.headlineSm(color: AppColors.red)
                                  .copyWith(fontWeight: FontWeight.w700),
                            ),
                            content: Text(
                              'Hành động này sẽ ngắt kết nối và xóa thông tin xe "${profile.bikeName ?? "hiện tại"}" khỏi ứng dụng.\n\nTrên iOS: Hãy vào Cài đặt > Bluetooth > Quên thiết bị này để hủy ghép đôi hệ thống hoàn toàn.',
                              style: AppTypography.bodyMd(color: AppColors.textDim)
                                  .copyWith(fontSize: 14),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx),
                                child: Text(
                                  'HỦY',
                                  style: AppTypography.labelLg(color: AppColors.textDim),
                                ),
                              ),
                              FilledButton(
                                style: FilledButton.styleFrom(
                                  backgroundColor: AppColors.red,
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
                                child: Text(
                                  'XÓA / QUÊN XE',
                                  style: AppTypography.labelLg(
                                    color: AppColors.onPrimary,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
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

  void _showEditProfileDialog(
    BuildContext context,
    WidgetRef ref, {
    required BlePhase phase,
    String? bikeName,
    String? userName,
  }) {
    final userController = TextEditingController(text: userName ?? '');
    final bikeController = TextEditingController(text: bikeName ?? '');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Chỉnh Sửa Hồ Sơ',
          style: AppTypography.headlineSm(color: AppColors.textPrimary).copyWith(
            fontWeight: FontWeight.w700,
            fontSize: 18,
          ),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Tên hiển thị chủ xe',
                style: AppTypography.labelMd(color: AppColors.textDim),
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
                style: AppTypography.labelMd(color: AppColors.textDim),
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
              if (phase == BlePhase.connected) ...[
                const SizedBox(height: 8),
                Text(
                  '💡 Tên xe sẽ được lưu vào flash xe qua cổng Bluetooth.',
                  style: AppTypography.labelSm(color: AppColors.mint),
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
              style: AppTypography.labelLg(color: AppColors.textDim),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () async {
              final newUserName = userController.text.trim();
              final newBikeName = bikeController.text.trim();
              Navigator.pop(ctx);

              if (newUserName.isNotEmpty) {
                await ref.read(bleProvider.notifier).setUserName(newUserName);
              }
              if (newBikeName.isNotEmpty && newBikeName != bikeName) {
                if (phase == BlePhase.connected) {
                  await ref.read(bleProvider.notifier).setFwBikeName(newBikeName);
                } else {
                  await ref.read(bleProvider.notifier).setLocalBikeName(newBikeName);
                }
              }

              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Đã cập nhật hồ sơ thành công!',
                      style: AppTypography.bodySm(color: AppColors.onPrimary),
                    ),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            },
            child: Text(
              'LƯU HỒ SƠ',
              style: AppTypography.labelLg(
                color: AppColors.onPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
