// Logs — Xem & Export file log BLE (JSONL) (Kinetic Stitch EV).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/ble/ble_logger.dart';
import '../../ui/app_theme.dart';
import '../../ui/widgets.dart';

class LogsScreen extends ConsumerStatefulWidget {
  const LogsScreen({super.key});

  @override
  ConsumerState<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends ConsumerState<LogsScreen> {
  static const _exportChannel = MethodChannel('vn.datbike/export');

  List<File> _files = [];
  String? _preview;
  String? _dirPath;
  File? _selected;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    BleLogger.dirPath().then((p) {
      if (mounted) setState(() => _dirPath = p);
    });
    _refresh();
  }

  Future<void> _refresh() async {
    final files = await BleLogger.listSessions();
    setState(() => _files = files.cast<File>());
  }

  Future<void> _open(File f) async {
    final len = f.lengthSync();
    final cap = 20 * 1024 * 1024;
    final start = len > cap ? len - cap : 0;
    final content = await File(f.path)
        .openRead(start, len)
        .transform(systemEncoding.decoder)
        .join();
    setState(() {
      _selected = f;
      _preview = (start > 0 ? '…(bỏ $start byte đầu)\n' : '') + content;
    });
  }

  Future<void> _share(File f) async {
    await SharePlus.instance.share(
      ShareParams(files: [XFile(f.path)], text: 'BLE session log — Dat Bike'),
    );
  }

  Future<void> _exportAll() async {
    if (_files.isEmpty) return;
    setState(() => _exporting = true);
    try {
      if (Platform.isAndroid) {
        final storage = await Permission.storage.request();
        if (storage.isPermanentlyDenied) {
          if (!mounted) return;
          _openStorageSettingsDialog();
          return;
        }
        if (!storage.isGranted) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Thiếu quyền lưu trữ — cấp quyền rồi thử lại')),
          );
          return;
        }
      }
      final exported = await _exportChannel.invokeMethod<List<dynamic>>(
        'exportToDownloads',
        {'paths': _files.map((f) => f.path).toList()},
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Đã export ${exported?.length ?? 0} file → Downloads/DatBikeLogs'),
          backgroundColor: AppColors.tertiary,
        ),
      );
    } on PlatformException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Export thất bại: ${e.message}\nDùng nút chia sẻ từng file'),
          backgroundColor: AppColors.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _openStorageSettingsDialog() {
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: AppColors.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text('Cần quyền lưu trữ', style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w600)),
        content: Text(
          'Quyền bị từ chối vĩnh viễn. Mở Cài đặt → Ứng dụng → Quyền → Bộ nhớ để cấp lại.',
          style: GoogleFonts.plusJakartaSans(color: AppColors.textDim),
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

  Future<void> _deleteAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: AppColors.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text('Xóa tất cả nhật ký log?', style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w600)),
        content: Text(
          'Toàn bộ session log BLE sẽ bị xóa khỏi bộ nhớ máy.',
          style: GoogleFonts.plusJakartaSans(color: AppColors.textDim),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text('HỦY', style: GoogleFonts.plusJakartaSans(color: AppColors.textDim)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: Colors.white,
              shape: const StadiumBorder(),
            ),
            onPressed: () => Navigator.pop(c, true),
            child: Text('XÓA HẾT', style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await BleLogger.deleteAll();
      setState(() {
        _files = [];
        _preview = null;
        _selected = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: Text(
          'NHẬT KÝ BLUETOOTH',
          style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700, fontSize: 18),
        ),
        actions: [
          if (_files.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_rounded),
              tooltip: 'Xóa toàn bộ log',
              onPressed: _deleteAll,
            ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Làm mới',
            onPressed: _refresh,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Panel(
              padding: const EdgeInsets.all(16),
              borderRadius: 18,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.description_rounded, size: 20, color: AppColors.primary),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'DỮ LIỆU TELEMETRY & GATT',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.05 * 11,
                          color: AppColors.textDim,
                        ),
                      ),
                      const Spacer(),
                      StatusPill(
                        label: '${_files.length} FILES',
                        color: AppColors.secondary,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Mỗi lần kết nối tạo 1 file JSONL ghi lại bảng GATT, telemetry hex, '
                    'trạng thái handshake và quá trình giữ kết nối để chẩn đoán xe.',
                    style: GoogleFonts.plusJakartaSans(fontSize: 12.5, color: AppColors.textDim, height: 1.4),
                  ),
                  if (_dirPath != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Thư mục: $_dirPath',
                      style: GoogleFonts.plusJakartaSans(fontSize: 11, color: AppColors.textMuted),
                    ),
                  ],
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      shape: const StadiumBorder(),
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                    ),
                    icon: _exporting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation<Color>(Colors.white)),
                          )
                        : const Icon(Icons.download_rounded, size: 18),
                    label: Text(
                      'Export toàn bộ → Downloads/DatBikeLogs',
                      style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w600, fontSize: 13),
                    ),
                    onPressed: _files.isEmpty || _exporting ? null : _exportAll,
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            flex: _preview == null ? 2 : 1,
            child: _files.isEmpty
                ? Center(
                    child: Text(
                      'Chưa có log — kết nối xe để bắt đầu ghi lại phiên.',
                      style: GoogleFonts.plusJakartaSans(color: AppColors.textDim, fontSize: 13),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _files.length,
                    itemBuilder: (ctx, idx) {
                      final f = _files[idx];
                      final isSelected = _selected?.path == f.path;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Panel(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          borderRadius: 14,
                          borderColor: isSelected ? AppColors.secondary : null,
                          hasActiveHalo: isSelected,
                          onTap: () => _open(f),
                          child: Row(
                            children: [
                              Icon(
                                isSelected ? Icons.article_rounded : Icons.article_outlined,
                                color: isSelected ? AppColors.primary : AppColors.textDim,
                                size: 22,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      f.uri.pathSegments.last,
                                      style: GoogleFonts.spaceGrotesk(
                                        fontSize: 13.5,
                                        fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                                        color: isSelected ? AppColors.primary : AppColors.textPrimary,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${(f.lengthSync() / 1024).toStringAsFixed(1)} KB · '
                                      '${f.statSync().modified.toLocal().toString().substring(0, 19)}',
                                      style: GoogleFonts.plusJakartaSans(
                                        fontSize: 11,
                                        color: AppColors.textDim,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.share_rounded, size: 18),
                                color: AppColors.primary,
                                onPressed: () => _share(f),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          if (_preview != null)
            Expanded(
              flex: 2,
              child: Container(
                width: double.infinity,
                decoration: const BoxDecoration(
                  color: AppColors.panel,
                  border: Border(top: BorderSide(color: AppColors.panelBorder, width: 1)),
                ),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: const BoxDecoration(
                        color: AppColors.panelSecondary,
                        border: Border(bottom: BorderSide(color: AppColors.panelBorder, width: 1)),
                      ),
                      child: Row(
                        children: [
                          Text(
                            'NỘI DUNG LOG CHI TIẾT',
                            style: GoogleFonts.plusJakartaSans(
                              fontWeight: FontWeight.w700,
                              fontSize: 11,
                              letterSpacing: 0.05 * 11,
                              color: AppColors.textDim,
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            icon: const Icon(Icons.copy_rounded, size: 18),
                            tooltip: 'Copy toàn bộ',
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: _preview!));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Đã sao chép log vào clipboard!')),
                              );
                            },
                          ),
                          IconButton(
                            icon: const Icon(Icons.share_rounded, size: 18),
                            tooltip: 'Chia sẻ file',
                            onPressed: () => _selected != null ? _share(_selected!) : null,
                          ),
                          IconButton(
                            icon: const Icon(Icons.close_rounded, size: 18),
                            tooltip: 'Đóng xem trước',
                            onPressed: () => setState(() => _preview = null),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(12),
                        child: SelectableText(
                          _preview!,
                          style: GoogleFonts.jetBrainsMono(
                            fontSize: 11,
                            color: AppColors.textPrimary,
                            height: 1.4,
                          ),
                        ),
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
}
