// BLE logger — ghi toàn bộ giao tiếp app↔xe ra file JSONL theo session.
//
// Mục đích: trích xuất dữ liệu kết nối thật (bảng GATT, notification, giá trị
// characteristic) để hoàn thiện bản đồ UUID và đối chiếu giao thức — xem
// docs/uuid_map.md. Mỗi dòng: {"ts": ISO8601, "type": "...", ...payload}.
// File lưu ở <documents>/ble_logs/session_YYYYMMDD_HHMMSS.jsonl.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Bump mỗi lần build release — để đối chiếu log với code chính xác.
const appBuild = '20261102a';

class BleLogger {
  BleLogger._();
  static final BleLogger instance = BleLogger._();

  IOSink? _sink;
  File? _file;
  int _eventCount = 0;
  bool _isFlushing = false;
  final List<String> _pendingLines = [];

  bool get active => _sink != null;
  File? get file => _file;
  int get eventCount => _eventCount;

  void _safeFlush() {
    final sink = _sink;
    if (sink == null || _isFlushing) return;
    _isFlushing = true;
    sink.flush().catchError((_) {}).whenComplete(() {
      _isFlushing = false;
      if (_pendingLines.isNotEmpty && _sink != null) {
        for (final l in _pendingLines) {
          _sink!.writeln(l);
        }
        _pendingLines.clear();
        _safeFlush();
      }
    });
  }

  Future<File?> startSession() async {
    try {
      await close();
      _pendingLines.clear();
      final dir = await _logDir();
      final ts = DateTime.now()
          .toIso8601String()
          .substring(0, 19)
          .replaceAll(':', '')
          .replaceAll('-', '');
      _file = File('${dir.path}/session_$ts.jsonl');
      _sink = _file!.openWrite(mode: FileMode.append);
      _eventCount = 0;
      event('session_start', {
        'app': 'datbike_flutter',
        'platform': Platform.operatingSystem,
        'build': appBuild,
      });
      return _file;
    } catch (_) {
      return null;
    }
  }

  Future<void> close() async {
    final sink = _sink;
    _sink = null;
    try {
      if (!_isFlushing && _pendingLines.isNotEmpty && sink != null) {
        for (final l in _pendingLines) {
          sink.writeln(l);
        }
        _pendingLines.clear();
      }
      await sink?.flush();
      await sink?.close();
    } catch (_) {}
  }

  /// Ghi lỗi app (crash / exception chưa được bắt) ra app_errors.jsonl.
  /// Hoạt động LUÔN, không phụ thuộc session BLE — để truy vết lỗi xảy ra
  /// trước/khi connect. Không bao giờ throw.
  static Future<void> logAppError(String kind, Object error,
      [StackTrace? stackTrace]) async {
    try {
      final dir = await _logDir();
      final sink =
          File('${dir.path}/app_errors.jsonl').openWrite(mode: FileMode.append);
      sink.writeln(jsonEncode({
        'ts': DateTime.now().toIso8601String(),
        'build': appBuild,
        'kind': kind,
        'error': error.toString(),
        if (stackTrace != null)
          'stack': stackTrace.toString().split('\n').take(40).join('\n'),
      }));
      unawaited(() async {
        try {
          await sink.flush();
          await sink.close();
        } catch (_) {}
      }());
    } catch (_) {
      // path_provider chưa sẵn sàng (quá sớm lúc khởi động) — bỏ qua.
    }
  }

  /// Ghi 1 event — không bao giờ throw (log không được làm rớt BLE).
  /// Flush ngay sau mỗi dòng: app bị kill đột ngột không mất dữ liệu.
  void event(String type, [Map<String, Object?> data = const {}]) {
    final sink = _sink;
    if (sink == null) return;
    try {
      final line = jsonEncode({
        'ts': DateTime.now().toIso8601String(),
        'type': type,
        ...data,
      });
      _eventCount++;
      if (_isFlushing) {
        _pendingLines.add(line);
      } else {
        sink.writeln(line);
        _safeFlush();
      }
    } catch (_) {
      // Encode lỗi cũng phải để lại dấu vết — không được im lặng mất event
      try {
        final errLine = jsonEncode({
          'ts': DateTime.now().toIso8601String(),
          'type': type,
          'log_err': 'encode_failed',
        });
        if (_isFlushing) {
          _pendingLines.add(errLine);
        } else {
          sink.writeln(errLine);
          _safeFlush();
        }
      } catch (_) {}
    }
  }

  /// Hex dump gọn cho payload nhị phân.
  static String hex(List<int> bytes, {int maxBytes = 256}) {
    final show = bytes.length > maxBytes ? bytes.sublist(0, maxBytes) : bytes;
    final hex = show.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    return bytes.length > maxBytes ? '$hex …(+${bytes.length - maxBytes}B)' : hex;
  }

  /// Thử decode bytes thành chuỗi in được (để đọc giá trị characteristic).
  static String? tryUtf8(List<int> bytes) {
    try {
      final s = utf8.decode(bytes, allowMalformed: false);
      return s.codeUnits.every((c) => c >= 32 && c <= 126) ? s : null;
    } catch (_) {
      return null;
    }
  }

  static Future<Directory> _logDir() async {
    // Ưu tiên bộ nhớ ngoài app-specific trên Android: /storage/emulated/0/Android/data/
    // vn.datbike.datbike_app/files/ble_logs — xem được bằng file manager/USB.
    // Lưu ý: Trên iOS, getExternalStorageDirectory() ném UnsupportedError!
    Directory? ext;
    if (Platform.isAndroid) {
      try {
        ext = await getExternalStorageDirectory();
      } catch (_) {}
    }
    final base = ext?.path ?? (await getApplicationDocumentsDirectory()).path;
    final dir = Directory('$base/ble_logs');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  static Future<List<FileSystemEntity>> listSessions() async {
    try {
      final dir = await _logDir();
      final files = dir.existsSync()
          ? dir.listSync().whereType<File>().toList()
          : <File>[];
      files.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      return files;
    } catch (_) {
      return <File>[];
    }
  }

  /// Đường dẫn thư mục log để hiển thị cho user.
  static Future<String> dirPath() async {
    try {
      return (await _logDir()).path;
    } catch (_) {
      return '';
    }
  }

  static Future<void> deleteAll() async {
    try {
      final dir = await _logDir();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {}
  }
}
