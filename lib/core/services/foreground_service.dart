import 'dart:io';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Quản lý Foreground Service gốc trên Android và Background Keep-Alive trên iOS
/// để giữ kết nối BLE sống liên tục trong nền (ngay cả khi vuốt đóng app hay tắt màn hình).
class ForegroundService {
  static const _channel = MethodChannel('vn.datbike/export');
  static const MethodChannel _iosChannel =
      MethodChannel('com.datbike.mybike/ios_background');

  /// Bật Foreground Service với thông báo thường trực (Android) hoặc Keep-Alive (iOS)
  static Future<void> start({required String title, required String text}) async {
    if (Platform.isIOS) {
      try {
        await _iosChannel.invokeMethod('startBackgroundKeepAlive', {
          'title': title,
          'text': text,
        });
      } catch (_) {}
      return;
    }
    if (!Platform.isAndroid) return;
    try {
      final status = await Permission.notification.status;
      if (status.isDenied) {
        await Permission.notification.request();
      }
      final args = <String, dynamic>{
        'title': title,
        'text': text,
      };
      await _channel.invokeMethod('startForegroundService', args);
    } catch (_) {}
  }

  /// Cập nhật nội dung Foreground Service (Android) hoặc Keep-Alive (iOS)
  static Future<void> update({required String title, required String text}) async {
    if (Platform.isIOS) {
      try {
        await _iosChannel.invokeMethod('updateBackgroundKeepAlive', {
          'title': title,
          'text': text,
        });
      } catch (_) {}
      return;
    }
    if (!Platform.isAndroid) return;
    try {
      final args = <String, dynamic>{
        'title': title,
        'text': text,
      };
      await _channel.invokeMethod('updateForegroundService', args);
    } catch (_) {}
  }

  /// Tắt Foreground Service khi người dùng chủ động ngắt kết nối
  static Future<void> stop() async {
    if (Platform.isIOS) {
      try {
        await _iosChannel.invokeMethod('stopBackgroundKeepAlive');
      } catch (_) {}
      return;
    }
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('stopForegroundService');
    } catch (_) {}
  }
}
