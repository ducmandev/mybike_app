// Scan — Quét BLE tìm xe Dat Bike (Kinetic Stitch EV).
// Xe dùng RPA (MAC xoay vòng) và tên quảng bá thay đổi ('dat.bik3' / 'Dat Bike Quantum S1'),
// hỗ trợ nhận diện qua Service UUID và xử lý tối ưu trên cả Android và iOS.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/ble/ble_controller.dart';
import '../../core/ble/ble_logger.dart';
import '../../core/ble/ble_permissions.dart';
import '../../core/ble/gatt.dart';
import '../../ui/app_theme.dart';
import '../../ui/widgets.dart';

class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({super.key});

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen> {
  final _results = <ScanResult>[];
  StreamSubscription? _sub;
  bool _scanning = false;
  String? _error;
  bool _showAll = false;
  String? _lastBikeId;
  String? _lastBikeName;
  bool _directConnecting = false;

  // Tập hợp các Service UUID đặc trưng của xe Dat Bike
  static final _bikeServiceGuids = {
    Gatt.dashboardService.toLowerCase(),
    Gatt.authService.toLowerCase(),
    Gatt.infoService.toLowerCase(),
    Gatt.otaService.toLowerCase(),
    Gatt.programmingService.toLowerCase(),
    Gatt.chargingService.toLowerCase(),
    '0000ffe0-0000-1000-8000-00805f9b34fb',
    '0000180a-0000-1000-8000-00805f9b34fb',
    '00001800-0000-1000-8000-00805f9b34fb',
    '6e400001-b5a3-f393-e0a9-e50e24dcca9e',
    'ffe0',
    '180a',
    '1800',
  };

  @override
  void initState() {
    super.initState();
    ref.read(bleProvider.notifier).lastBikeId().then((id) async {
      if (!mounted) return;
      final name = await ref.read(bleProvider.notifier).lastBikeName();
      setState(() {
        _lastBikeId = id;
        _lastBikeName = name;
      });
    });
    _scan();
  }

  @override
  void dispose() {
    _sub?.cancel();
    if (FlutterBluePlus.isScanningNow) {
      FlutterBluePlus.stopScan();
    }
    super.dispose();
  }

  bool _isBike(ScanResult r) {
    // 0. Nếu trùng với ID xe đã lưu trước đó
    if (_lastBikeId != null && r.device.remoteId.str.toLowerCase() == _lastBikeId!.toLowerCase()) {
      return true;
    }

    // 1. Nhận diện qua Service UUID trong gói tin quảng bá hoặc serviceData (chuẩn nhất cho xe Dat Bike)
    for (final uuid in r.advertisementData.serviceUuids) {
      final s128 = uuid.str128.toLowerCase();
      final s = uuid.str.toLowerCase();
      if (_bikeServiceGuids.contains(s128) || _bikeServiceGuids.contains(s)) {
        return true;
      }
    }
    for (final uuid in r.advertisementData.serviceData.keys) {
      final s128 = uuid.str128.toLowerCase();
      final s = uuid.str.toLowerCase();
      if (_bikeServiceGuids.contains(s128) || _bikeServiceGuids.contains(s)) {
        return true;
      }
    }

    // 2. Nhận diện qua Tên quảng bá hoặc Tên hệ thống (CoreBluetooth / Android)
    final adv = r.advertisementData.advName.trim().toLowerCase();
    final plat = r.device.platformName.trim().toLowerCase();
    final combined = '$adv $plat'.replaceAll('.', ' ');

    return combined.contains('dat bik') ||
        combined.contains('datbike') ||
        combined.contains('quantum') ||
        combined.contains('weaver') ||
        combined.contains('era') ||
        combined.contains('dat.bik') ||
        combined.startsWith('db-') ||
        combined.startsWith('db ') ||
        combined.contains('db-quantum') ||
        combined.contains('stitch') ||
        combined.contains('kinetic');
  }

  /// Quét các thiết bị đã kết nối với hệ thống iOS hoặc đang kết nối
  Future<void> _fetchSystemAndConnectedDevices() async {
    final searchServices = [
      Guid(Gatt.dashboardService),
      Guid(Gatt.authService),
      Guid(Gatt.infoService),
      Guid(Gatt.otaService),
      Guid(Gatt.programmingService),
      Guid(Gatt.chargingService),
      Guid('0000ffe0-0000-1000-8000-00805f9b34fb'),
      Guid('0000180a-0000-1000-8000-00805f9b34fb'),
      Guid('00001800-0000-1000-8000-00805f9b34fb'),
      Guid('6e400001-b5a3-f393-e0a9-e50e24dcca9e'),
    ];

    List<BluetoothDevice> sysList = [];
    try {
      sysList = await FlutterBluePlus.systemDevices(searchServices);
    } catch (_) {}

    final connList = FlutterBluePlus.connectedDevices;
    final all = <BluetoothDevice>{...sysList, ...connList};

    if (all.isEmpty || !mounted) return;

    setState(() {
      for (final dev in all) {
        final existingIdx = _results.indexWhere((r) => r.device.remoteId == dev.remoteId);
        final name = dev.platformName.isNotEmpty ? dev.platformName : 'Xe Dat Bike (Hệ thống)';
        final synthetic = ScanResult(
          device: dev,
          advertisementData: AdvertisementData(
            advName: name,
            txPowerLevel: null,
            appearance: null,
            connectable: true,
            manufacturerData: {},
            serviceData: {},
            serviceUuids: [Guid(Gatt.authService), Guid(Gatt.dashboardService)],
          ),
          rssi: -45,
          timeStamp: DateTime.now(),
        );

        if (existingIdx >= 0) {
          _results[existingIdx] = synthetic;
        } else {
          _results.insert(0, synthetic);
        }
      }
    });
  }

  Future<void> _scan() async {
    setState(() {
      _error = null;
      _scanning = true;
    });

    if (kIsWeb) {
      await Future.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      setState(() => _scanning = false);
      return;
    }

    // 1. Kiểm tra quyền BLE
    final ok = await BlePermissions.ensure();
    if (!ok) {
      setState(() {
        _scanning = false;
        _error = 'Thiếu quyền Bluetooth hoặc Vị trí để quét thiết bị.';
      });
      if (await BlePermissions.permanentlyDenied() && mounted) {
        _openSettingsDialog();
      }
      return;
    }

    // 2. Đợi Bluetooth Adapter sẵn sàng (Trên iOS, CoreBluetooth cần thời gian khởi tạo bất đồng bộ)
    var adapter = FlutterBluePlus.adapterStateNow;
    if (adapter == BluetoothAdapterState.unknown) {
      try {
        adapter = await FlutterBluePlus.adapterState
            .where((s) => s != BluetoothAdapterState.unknown)
            .first
            .timeout(const Duration(seconds: 5));
      } catch (_) {
        adapter = FlutterBluePlus.adapterStateNow;
      }
    }

    if (adapter == BluetoothAdapterState.unauthorized) {
      setState(() {
        _scanning = false;
        _error = 'Ứng dụng chưa được cấp quyền Bluetooth. Vui lòng mở Cài đặt iPhone để cấp quyền.';
      });
      if (mounted) _openSettingsDialog();
      return;
    }

    if (adapter == BluetoothAdapterState.off) {
      setState(() {
        _scanning = false;
        _error = 'Bluetooth đang tắt — hãy bật Bluetooth trong Trung tâm điều khiển/Cài đặt rồi quét lại.';
      });
      return;
    }

    if (!BleLogger.instance.active) await BleLogger.instance.startSession();

    _results.clear();
    await _sub?.cancel();

    // 2.1. Lấy ngay các thiết bị đã kết nối hệ thống / iOS (đặc biệt quan trọng với iPhone đã từng pair)
    await _fetchSystemAndConnectedDevices();

    // 3. Đăng ký nhận kết quả trước khi phát lệnh scan để không bị sót gói tin
    _sub = FlutterBluePlus.scanResults.listen((rs) {
      BleLogger.instance.event('scan_batch', {
        'count': rs.length,
        'devices': [
          for (final r in rs)
            {
              'id': r.device.remoteId.str,
              'adv_name': r.advertisementData.advName,
              'platform_name': r.device.platformName,
              'rssi': r.rssi,
              'services': r.advertisementData.serviceUuids.map((u) => u.str128).toList(),
            }
        ],
      });
      if (!mounted) return;
      setState(() {
        final sysItems = _results.where((existing) => !rs.any((r) => r.device.remoteId == existing.device.remoteId)).toList();
        _results
          ..clear()
          ..addAll(sysItems)
          ..addAll(rs);
      });
    });

    // 4. Bắt đầu quét BLE (bật continuousUpdates: true để iOS liên tục cập nhật tên và RSSI)
    try {
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 20),
        androidScanMode: AndroidScanMode.lowLatency,
        continuousUpdates: true,
      );
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Lỗi khởi động quét: $e');
      }
    }

    // Refresh lại system devices sau khi scan khởi động
    await _fetchSystemAndConnectedDevices();

    try {
      await FlutterBluePlus.isScanning.where((s) => !s).first;
    } catch (_) {}
    if (mounted) setState(() => _scanning = false);
  }

  void _connect(ScanResult r) {
    FlutterBluePlus.stopScan();
    final name = r.advertisementData.advName.isNotEmpty
        ? r.advertisementData.advName
        : r.device.platformName;
    Navigator.of(context).pushReplacementNamed('/connecting', arguments: {
      'device': r.device,
      'bikeName': name.isNotEmpty ? name : 'Xe Dat Bike',
      'name': name.isNotEmpty ? name : 'Xe Dat Bike',
    });
  }

  Future<void> _connectDirect() async {
    if (_lastBikeId == null) return;
    setState(() => _directConnecting = true);
    final dev = BluetoothDevice.fromId(_lastBikeId!);
    Navigator.of(context).pushReplacementNamed('/connecting', arguments: {
      'device': dev,
      'bikeName': _lastBikeName ?? 'Xe Dat Bike',
      'name': _lastBikeName ?? 'Xe Dat Bike',
    });
  }

  void _openSettingsDialog() {
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: AppColors.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text(
          Platform.isIOS ? 'Cần cấp quyền Bluetooth' : 'Cần quyền Bluetooth & Vị trí',
          style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w600, fontSize: 18),
        ),
        content: Text(
          Platform.isIOS
              ? 'Quyền truy cập Bluetooth đang bị tắt trong Cài đặt iPhone. Vui lòng mở Cài đặt để cho phép ứng dụng quét và kết nối với xe.'
              : 'Quyền Bluetooth/Vị trí bị từ chối. Mở Cài đặt hệ thống → Ứng dụng → Quyền để cấp lại.',
          style: GoogleFonts.plusJakartaSans(color: AppColors.textDim, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: Text('HỦY', style: GoogleFonts.plusJakartaSans(color: AppColors.textDim)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: const StadiumBorder(),
            ),
            onPressed: () {
              openAppSettings();
              Navigator.pop(c);
            },
            child: Text('MỞ CÀI ĐẶT', style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  String _rssiBars(int rssi) {
    if (rssi >= -55) return '▂▄▆█';
    if (rssi >= -70) return '▂▄▆_';
    if (rssi >= -85) return '▂▄__';
    return '▂___';
  }

  String _getDeviceDisplayName(ScanResult r) {
    if (r.advertisementData.advName.isNotEmpty) return r.advertisementData.advName;
    if (r.device.platformName.isNotEmpty) return r.device.platformName;
    final id = r.device.remoteId.str;
    return 'Thiết bị BLE (${id.length > 8 ? id.substring(0, 8) : id})';
  }

  @override
  Widget build(BuildContext context) {
    final bikes = _results.where(_isBike).toList();
    final others = _results.where((r) => !_isBike(r)).toList();
    others.sort((a, b) => b.rssi.compareTo(a.rssi));

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: Text(
          'TÌM XE BLUETOOTH',
          style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700, fontSize: 18),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _scan,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
          children: [
            // Kết nối lại xe đã nhớ
            if (_lastBikeId != null) ...[
              Panel(
                onTap: _directConnecting ? null : _connectDirect,
                padding: const EdgeInsets.all(16),
                borderRadius: 20,
                hasActiveHalo: true,
                child: Row(
                  children: [
                    Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
                      ),
                      child: const Icon(Icons.history_rounded, color: AppColors.primary, size: 26),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _lastBikeName ?? 'Xe đã kết nối gần nhất',
                            style: GoogleFonts.spaceGrotesk(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'Bấm để kết nối trực tiếp không cần chờ quét',
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 12,
                              color: AppColors.textDim,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _directConnecting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.arrow_forward_ios_rounded, size: 16, color: AppColors.primary),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            if (_error != null) ...[
              NoticeBanner(color: AppColors.error, text: _error!),
              const SizedBox(height: 14),
            ],

            // Xe tìm thấy khớp bộ lọc
            if (bikes.isNotEmpty) ...[
              const SectionTitle('XE CỦA BẠN PHÁT HIỆN ĐƯỢC'),
              const SizedBox(height: 10),
              for (final r in bikes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Panel(
                    onTap: () => _connect(r),
                    padding: const EdgeInsets.all(16),
                    borderRadius: 20,
                    child: Row(
                      children: [
                        Container(
                          width: 50,
                          height: 50,
                          decoration: BoxDecoration(
                            color: AppColors.secondary.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: AppColors.secondary.withValues(alpha: 0.25)),
                          ),
                          child: const Icon(Icons.electric_moped_rounded, color: AppColors.secondary, size: 28),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _getDeviceDisplayName(r),
                                style: GoogleFonts.spaceGrotesk(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 16,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Text(
                                    _rssiBars(r.rssi),
                                    style: const TextStyle(
                                      color: AppColors.tertiary,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w900,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    '${r.rssi} dBm · ${r.device.remoteId.str}',
                                    style: GoogleFonts.plusJakartaSans(
                                      fontSize: 12,
                                      color: AppColors.textDim,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.arrow_forward_ios_rounded, size: 16, color: AppColors.primary),
                      ],
                    ),
                  ),
                ),
            ],

            // Xe mô phỏng trên Web Preview
            if (kIsWeb) ...[
              const SectionTitle('XE CỦA BẠN PHÁT HIỆN ĐƯỢC (BLE)'),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Panel(
                  onTap: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Đã xác thực & ghép đôi chìa khóa số BLE xe Dat Bike Quantum S1!',
                          style: GoogleFonts.plusJakartaSans(),
                        ),
                        backgroundColor: const Color(0xFF10B981),
                        behavior: SnackBarBehavior.floating,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    );
                    Navigator.of(context).pop();
                  },
                  padding: const EdgeInsets.all(16),
                  borderRadius: 20,
                  child: Row(
                    children: [
                      Container(
                        width: 50,
                        height: 50,
                        decoration: BoxDecoration(
                          color: AppColors.secondary.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: AppColors.secondary.withValues(alpha: 0.25)),
                        ),
                        child: const Icon(Icons.electric_moped_rounded, color: AppColors.secondary, size: 28),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Dat Bike Quantum S1',
                              style: GoogleFonts.spaceGrotesk(
                                fontWeight: FontWeight.w700,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                const Text(
                                  '▂▄▆█',
                                  style: TextStyle(
                                    color: AppColors.tertiary,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w900,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '-58 dBm · RL9C4NGSSSCC00187',
                                  style: GoogleFonts.plusJakartaSans(
                                    fontSize: 12,
                                    color: AppColors.textDim,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.arrow_forward_ios_rounded, size: 16, color: AppColors.primary),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],

            // Gợi ý khi hoàn toàn không tìm thấy thiết bị nào
            if (bikes.isEmpty && others.isEmpty && !_scanning && !kIsWeb) ...[
              Panel(
                padding: const EdgeInsets.all(24),
                borderRadius: 20,
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.08),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.bluetooth_searching_rounded, size: 36, color: AppColors.primary),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Chưa tìm thấy thiết bị ở gần',
                      style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700, fontSize: 16),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '• Đảm bảo xe đã bật nguồn hoặc mở khóa sẵn\n'
                      '• Đứng gần xe trong bán kính 2-5 mét\n'
                      '• Kiểm tra Bluetooth trên điện thoại đang bật',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 13,
                        color: AppColors.textDim,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        shape: const StadiumBorder(),
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      ),
                      icon: const Icon(Icons.radar, size: 18),
                      label: Text('Quét lại', style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w600)),
                      onPressed: _scan,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Danh sách thiết bị Bluetooth ở gần
            if (others.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  SectionTitle(bikes.isEmpty ? 'THIẾT BỊ BLUETOOTH Ở GẦN' : 'THIẾT BỊ KHÁC'),
                  const Spacer(),
                  Text(
                    '${others.length} thiết bị',
                    style: GoogleFonts.plusJakartaSans(fontSize: 12, color: AppColors.textDim),
                  ),
                  const SizedBox(width: 8),
                  if (bikes.isNotEmpty)
                    Switch(
                      value: _showAll,
                      onChanged: (v) => setState(() => _showAll = v),
                    ),
                ],
              ),
              if (bikes.isEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  'Nếu xe của bạn đã đổi tên riêng hoặc tên chưa kịp phân giải trên iOS, hãy chọn thiết bị có sóng mạnh nhất (dBm gần 0 nhất) ở bên dưới để kết nối trực tiếp:',
                  style: GoogleFonts.plusJakartaSans(fontSize: 12, color: AppColors.textDim, height: 1.4),
                ),
                const SizedBox(height: 10),
              ],
              if (_showAll || bikes.isEmpty)
                for (final r in others)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Panel(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      borderRadius: 14,
                      onTap: () => _connect(r),
                      child: Row(
                        children: [
                          const Icon(Icons.bluetooth_rounded, size: 20, color: AppColors.textDim),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _getDeviceDisplayName(r),
                                  style: GoogleFonts.plusJakartaSans(fontSize: 13.5, fontWeight: FontWeight.w600),
                                ),
                                Row(
                                  children: [
                                    Text(
                                      _rssiBars(r.rssi),
                                      style: const TextStyle(
                                        color: AppColors.tertiary,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w900,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      '${r.rssi} dBm · ${r.device.remoteId.str}',
                                      style: GoogleFonts.plusJakartaSans(fontSize: 11.5, color: AppColors.textDim),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right, size: 18, color: AppColors.textDim),
                        ],
                      ),
                    ),
                  ),
            ],
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        elevation: 2,
        shape: const StadiumBorder(),
        onPressed: _scanning ? null : _scan,
        icon: _scanning
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation<Color>(Colors.white)),
              )
            : const Icon(Icons.radar),
        label: Text(
          _scanning ? 'Đang quét…' : 'Quét xe',
          style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}
