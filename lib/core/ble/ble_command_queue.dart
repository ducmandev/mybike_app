import 'dart:async';

/// Hàng đợi tuần tự các thao tác BLE GATT kèm cơ chế ưu tiên lệnh người dùng
/// và tự động nhường băng thông cho tác vụ đọc nền.
class BleCommandQueue {
  BleCommandQueue({
    this.onBackgroundError,
    this.manualCooldown = const Duration(milliseconds: 600),
    this.automationCooldown = const Duration(milliseconds: 250),
  });

  /// Callback ghi nhận lỗi khi tác vụ đọc nền thất bại (không phải bị preempt).
  final void Function(String tag, Object error)? onBackgroundError;

  /// Khoảng thời gian chặn tác vụ nền sau lệnh thủ công của người dùng.
  final Duration manualCooldown;

  /// Khoảng thời gian chặn tác vụ nền sau lệnh tự động hóa.
  final Duration automationCooldown;

  Future<void>? _gattChain;
  int _pendingUserCommands = 0;
  DateTime? _lastUserCommandAt;
  bool _lastCommandWasManual = false;

  /// Số lượng lệnh ưu tiên đang chờ hoặc đang thực thi trong hàng đợi.
  int get pendingUserCommands => _pendingUserCommands;

  /// Thời điểm lệnh gần nhất được kích hoạt.
  DateTime? get lastUserCommandAt => _lastUserCommandAt;

  /// `true` nếu lệnh gần nhất là thao tác thủ công của người dùng.
  bool get lastCommandWasManual => _lastCommandWasManual;

  /// Trả về `true` nếu đang có lệnh ưu tiên hoặc vẫn trong cửa sổ cooldown.
  bool get hasPendingUserCommand {
    if (_pendingUserCommands > 0) return true;
    final last = _lastUserCommandAt;
    if (last == null) return false;
    final cooldown = _lastCommandWasManual ? manualCooldown : automationCooldown;
    return DateTime.now().difference(last) < cooldown;
  }

  /// Đánh dấu mốc thời gian lệnh vừa gửi để tác vụ nền tạm nhường băng thông.
  void markCommandTimestamp({required bool isAutomation, DateTime? now}) {
    _lastUserCommandAt = now ?? DateTime.now();
    _lastCommandWasManual = !isAutomation;
  }

  /// Đưa một thao tác GATT read/write vào hàng đợi tuần tự với explicit timeout.
  Future<T> enqueueGatt<T>(
    Future<T> Function() action, {
    Duration timeout = const Duration(milliseconds: 3500),
  }) {
    final prev = _gattChain ?? Future.value();
    final completer = Completer<T>();
    _gattChain = prev.catchError((_) {}).then((_) async {
      try {
        final res = await action().timeout(
          timeout,
          onTimeout: () => throw TimeoutException(
            'GATT operation timed out after ${timeout.inMilliseconds}ms',
          ),
        );
        completer.complete(res);
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// Hàng đợi ưu tiên cho lệnh điều khiển của người dùng hoặc automation.
  Future<T> enqueueUserCommand<T>(
    Future<T> Function() action, {
    String tag = 'UserCmd',
    Duration timeout = const Duration(milliseconds: 2500),
    bool isAutomation = false,
  }) async {
    _pendingUserCommands++;
    markCommandTimestamp(isAutomation: isAutomation);
    try {
      return await enqueueGatt(action, timeout: timeout);
    } finally {
      if (_pendingUserCommands > 0) {
        _pendingUserCommands--;
      }
    }
  }

  /// Hàng đợi tác vụ đọc nền; trả về `null` ngay nếu bị lệnh ưu tiên chặn
  /// hoặc [shouldProceed] trả về `false`.
  Future<T?> enqueueBackgroundRead<T>(
    Future<T> Function() action, {
    String tag = 'BgRead',
    Duration timeout = const Duration(milliseconds: 1500),
    bool Function()? shouldProceed,
  }) async {
    bool canRun() =>
        !hasPendingUserCommand && (shouldProceed == null || shouldProceed());
    if (!canRun()) {
      return null;
    }
    return enqueueGatt<T?>(() async {
      if (!canRun()) {
        throw StateError('Preempted by user command');
      }
      return await action();
    }, timeout: timeout).catchError((e) {
      if (e is! StateError) {
        onBackgroundError?.call(tag, e);
      }
      return null;
    });
  }

  /// Đặt lại trạng thái hàng đợi và bộ đếm lệnh khi ngắt kết nối / teardown.
  void reset() {
    _gattChain = null;
    _pendingUserCommands = 0;
    _lastUserCommandAt = null;
    _lastCommandWasManual = false;
  }
}
