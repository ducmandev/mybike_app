// BLE controller — kết nối ổn định cho Phase 1.
//
// Chiến lược ổn định (khắc phục điểm yếu của app gốc):
// - Nhớ xe kết nối lần cuối (shared_preferences) → tự kết nối lại khi mở app.
// - Nghe connectionState → khi đứt ngoài ý muốn, tự reconnect với backoff
//   2→4→8→16→30s, tối đa 5 lần.
// - Sau 2 lần reconnect fail liên tiếp: nghi bond mismatch → removeBond()
//   rồi thử lại (app gốc bắt user vào Settings xoá bond thủ công).
// - MTU 517 re-request mỗi lần kết nối (chunk 244 byte như app gốc).

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../proto/bike_log.dart';
import '../models/trip_gps_point.dart';
import '../services/foreground_service.dart';
import '../services/trip_gps_tracker.dart';
import '../session/bike_session_crypto.dart';
import '../utils/kalman_filter.dart';
import 'ble_logger.dart';
import 'ble_permissions.dart';
import 'gatt.dart';

export '../models/trip_gps_point.dart';

enum BlePhase { idle, scanning, connecting, connected, reconnecting, disconnected }

class BikeTelemetry {
  final BikeLogMsg? bike;
  final DateTime at;
  BikeTelemetry(this.bike, this.at);
}

class TripData {
  final double distanceKm;
  final Duration duration;
  final double avgSpeedKmh;
  final double maxSpeedKmh;
  final int usedPercent;
  final double powerKw;

  const TripData({
    this.distanceKm = 0.0,
    this.duration = Duration.zero,
    this.avgSpeedKmh = 0.0,
    this.maxSpeedKmh = 0.0,
    this.usedPercent = 0,
    this.powerKw = 0.0,
  });

  TripData copyWith({
    double? distanceKm,
    Duration? duration,
    double? avgSpeedKmh,
    double? maxSpeedKmh,
    int? usedPercent,
    double? powerKw,
  }) =>
      TripData(
        distanceKm: distanceKm ?? this.distanceKm,
        duration: duration ?? this.duration,
        avgSpeedKmh: avgSpeedKmh ?? this.avgSpeedKmh,
        maxSpeedKmh: maxSpeedKmh ?? this.maxSpeedKmh,
        usedPercent: usedPercent ?? this.usedPercent,
        powerKw: powerKw ?? this.powerKw,
      );
}

/// Bản ghi một chuyến đi thực tế được lưu vào bộ nhớ bền vững (SharedPreferences)
class TripRecord {
  final DateTime startTime;
  final DateTime endTime;
  final double distanceKm;
  final int durationSec;
  final double avgSpeedKmh;
  final double maxSpeedKmh;
  final int usedPercent;
  final double? startOdo;
  final double? endOdo;
  final List<TripGpsPoint> route;

  const TripRecord({
    required this.startTime,
    required this.endTime,
    required this.distanceKm,
    required this.durationSec,
    required this.avgSpeedKmh,
    required this.maxSpeedKmh,
    required this.usedPercent,
    this.startOdo,
    this.endOdo,
    this.route = const [],
  });

  Map<String, dynamic> toJson() => {
    'startTime': startTime.toIso8601String(),
    'endTime': endTime.toIso8601String(),
    'distanceKm': distanceKm,
    'durationSec': durationSec,
    'avgSpeedKmh': avgSpeedKmh,
    'maxSpeedKmh': maxSpeedKmh,
    'usedPercent': usedPercent,
    if (startOdo != null) 'startOdo': startOdo,
    if (endOdo != null) 'endOdo': endOdo,
    if (route.isNotEmpty) 'route': route.map((e) => e.toJson()).toList(),
  };

  factory TripRecord.fromJson(Map<String, dynamic> json) => TripRecord(
    startTime: DateTime.tryParse(json['startTime'] as String? ?? '') ?? DateTime.now(),
    endTime: DateTime.tryParse(json['endTime'] as String? ?? '') ?? DateTime.now(),
    distanceKm: (json['distanceKm'] as num?)?.toDouble() ?? 0.0,
    durationSec: (json['durationSec'] as num?)?.toInt() ?? 0,
    avgSpeedKmh: (json['avgSpeedKmh'] as num?)?.toDouble() ?? 0.0,
    maxSpeedKmh: (json['maxSpeedKmh'] as num?)?.toDouble() ?? 0.0,
    usedPercent: (json['usedPercent'] as num?)?.toInt() ?? 0,
    startOdo: (json['startOdo'] as num?)?.toDouble(),
    endOdo: (json['endOdo'] as num?)?.toDouble(),
    route: (json['route'] as List?)
            ?.map((e) => TripGpsPoint.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [],
  );
}

/// Kết quả 1 thao tác lab (đọc/ghi) — trả về UI kèm đủ raw + decrypt + lỗi.
class LabIoResult {
  final String op; // read | write_plain | write_protected
  final String uuid;
  final bool ok;
  final List<int> payload; // read: bytes xe trả · write: frame đã gửi
  final List<int>? decrypted; // read protected: payload sau giải mã
  final String? text; // utf8 của decrypted (hoặc raw nếu plain)
  final String? parsed; // giải mã cấu trúc đặc thù (3x float VESC, 4x uint32 log buffer, ...)
  final String? error;
  final int elapsedMs;
  const LabIoResult({
    required this.op,
    required this.uuid,
    required this.ok,
    this.payload = const [],
    this.decrypted,
    this.text,
    this.parsed,
    this.error,
    this.elapsedMs = 0,
  });
}

class BleState {
  final BlePhase phase;
  final BluetoothDevice? device;
  final String? bikeName;
  final int reconnectAttempt;
  final String? message;
  final bool dashboardEncrypted; // decode liên tục thất bại → cần handshake
  final List<BluetoothCharacteristic> characteristics;
  final bool isAuthorized;
  final Uint8List? sessionKey;
  final BikeLogMsg? lastTelemetry;
  final BatteryLogMsg? lastBattery;
  final bool isFindingBike;
  final TripData trip;
  final List<TripRecord> tripHistory;
  final String? userName;
  final bool autoLockWalkAway; // Auto-Secure: rời xa → tắt xe → BẬT khóa an toàn
  final bool walkUpUnlock; // Đến rất gần (RSSI mạnh ~1-2m) → tự MỞ khóa an toàn
  final bool walkUpAutoPowerOn; // Tính năng phụ: Tự BẬT NGUỒN XE sẵn khi tới rất gần
  final double? walkUpRssiThreshold; // Ngưỡng RSSI tùy chỉnh khi lại gần (-45 .. -72 dBm, mặc định -55.0)
  final double? autoLockRssiThreshold; // Ngưỡng RSSI tùy chỉnh khi rời xa (-68 .. -95 dBm, mặc định -83.0)
  final bool antiTheft5m; // Chống trộm: rời xa ≥5m → TẮT xe bất kể trạng thái → khóa
  final bool antiForgetAlert;
  final int autoLockDistance; // 0: Gần (~-75dBm), 1: Vừa (~-85dBm), 2: Xa (~-92dBm)
  final int antiForgetDistance; // 0: Gần (~-75dBm), 1: Vừa (~-85dBm), 2: Xa (~-92dBm)
  final int? rssi;
  final int? filteredRssi;
  final DateTime? lastTimeSynced;
  final int findBikePattern; // 0: Tiêu chuẩn, 1: Nhịp đôi, 2: Báo động
  final int recupLevel; // 0: Nhẹ, 1: Tiêu chuẩn, 2: Mạnh (One-pedal)
  final int throttleResponse; // 0: Êm ái, 1: Tiêu chuẩn, 2: Thể thao
  final int speedLimitMode; // 0: Không giới hạn, 1: 50 km/h, 2: 30 km/h
  final String? frameSerial;
  final int eceMode; // 0: Tắt, 1: Chuẩn, 2: Mạnh (firmware ECE_MODE)
  final int grabMode; // 0: Cá nhân, 1-2: dịch vụ (firmware GRAB_MODE)
  final bool idlingTurnOff; // tự tắt khi đỗ (firmware IDLING_TURN_OFF)
  final int distanceMode; // 0=Tắt, 1=Gần, 2=Vừa, 3=Xa hơn (firmware DISTANCE)
  final int chargingProfile; // 0=Standard, 1=Fast, 2=Boost (firmware CHARGING)
  final bool isLocked; // Khóa chống trộm / Immobilizer (char 7f13fe5c: kháng lực bánh)
  final bool autoReconnect; // Tự động quét & kết nối lại xe khi mất sóng / mở app
  final bool continuousScan; // Chế độ quét liên tục không giới hạn số lần
  final int reconnectMaxAttempts; // Số lần thử quét/kết nối lại tối đa (mặc định 5)
  final int reconnectIntervalSeconds; // Chu kỳ quét / thời gian giữa các lần thử (mặc định 5s)
  final String? bikeModelCode; // từ 4aae98e9 (vd: "QT_S1")
  final String? boardManifest; // từ 73d50009 (vd: "1adadba-#-8c02b07-896e9a7")
  final double? vescCurrent; // từ 35a9b4f6 float[0] (A)
  final double? vescVoltage; // từ 35a9b4f6 float[1] (V)
  final double? vescDutyCycle; // từ 35a9b4f6 float[2] (0.0..1.0)
  final int? fwSpeedLimitRaw; // u8 từ 0a19a49a
  final int? distanceRawU16; // u16 LE từ 5d681587
  final bool vescProgActive; // bool từ b0ca953d

  const BleState({
    required this.phase,
    this.device,
    this.bikeName,
    this.reconnectAttempt = 0,
    this.message,
    this.dashboardEncrypted = false,
    this.characteristics = const [],
    this.isAuthorized = false,
    this.sessionKey,
    this.lastTelemetry,
    this.lastBattery,
    this.isFindingBike = false,
    this.trip = const TripData(),
    this.tripHistory = const [],
    this.userName,
    this.autoLockWalkAway = false,
    this.walkUpUnlock = false,
    this.walkUpAutoPowerOn = false,
    this.walkUpRssiThreshold,
    this.autoLockRssiThreshold,
    this.antiTheft5m = false,
    this.antiForgetAlert = true,
    this.autoLockDistance = 1,
    this.antiForgetDistance = 1,
    this.rssi,
    this.filteredRssi,
    this.lastTimeSynced,
    this.findBikePattern = 0,
    this.recupLevel = 1,
    this.throttleResponse = 1,
    this.speedLimitMode = 0,
    this.eceMode = 0,
    this.grabMode = 0,
    this.idlingTurnOff = false,
    this.distanceMode = 0,
    this.chargingProfile = 0,
    this.isLocked = false,
    this.autoReconnect = true,
    this.continuousScan = false,
    this.reconnectMaxAttempts = 5,
    this.reconnectIntervalSeconds = 5,
    this.frameSerial,
    this.bikeModelCode,
    this.boardManifest,
    this.vescCurrent,
    this.vescVoltage,
    this.vescDutyCycle,
    this.fwSpeedLimitRaw,
    this.distanceRawU16,
    this.vescProgActive = false,
  });

  BleState copyWith({
    BlePhase? phase,
    BluetoothDevice? device,
    String? bikeName,
    int? reconnectAttempt,
    String? message,
    bool? dashboardEncrypted,
    List<BluetoothCharacteristic>? characteristics,
    bool? isAuthorized,
    Uint8List? sessionKey,
    BikeLogMsg? lastTelemetry,
    BatteryLogMsg? lastBattery,
    bool? isFindingBike,
    TripData? trip,
    List<TripRecord>? tripHistory,
    String? userName,
    bool? autoLockWalkAway,
    bool? walkUpUnlock,
    bool? walkUpAutoPowerOn,
    double? walkUpRssiThreshold,
    double? autoLockRssiThreshold,
    bool? antiTheft5m,
    bool? antiForgetAlert,
    int? autoLockDistance,
    int? antiForgetDistance,
    int? rssi,
    int? filteredRssi,
    DateTime? lastTimeSynced,
    int? findBikePattern,
    int? recupLevel,
    int? throttleResponse,
    int? speedLimitMode,
    int? eceMode,
    int? grabMode,
    bool? idlingTurnOff,
    int? distanceMode,
    int? chargingProfile,
    bool? isLocked,
    bool? autoReconnect,
    bool? continuousScan,
    int? reconnectMaxAttempts,
    int? reconnectIntervalSeconds,
    String? frameSerial,
    String? bikeModelCode,
    String? boardManifest,
    double? vescCurrent,
    double? vescVoltage,
    double? vescDutyCycle,
    int? fwSpeedLimitRaw,
    int? distanceRawU16,
    bool? vescProgActive,
  }) =>
      BleState(
        phase: phase ?? this.phase,
        device: device ?? this.device,
        bikeName: bikeName ?? this.bikeName,
        reconnectAttempt: reconnectAttempt ?? this.reconnectAttempt,
        message: message,
        dashboardEncrypted: dashboardEncrypted ?? this.dashboardEncrypted,
        characteristics: characteristics ?? this.characteristics,
        isAuthorized: isAuthorized ?? this.isAuthorized,
        sessionKey: sessionKey ?? this.sessionKey,
        lastTelemetry: lastTelemetry ?? this.lastTelemetry,
        lastBattery: lastBattery ?? this.lastBattery,
        isFindingBike: isFindingBike ?? this.isFindingBike,
        trip: trip ?? this.trip,
        tripHistory: tripHistory ?? this.tripHistory,
        userName: userName ?? this.userName,
        autoLockWalkAway: autoLockWalkAway ?? this.autoLockWalkAway,
        walkUpUnlock: walkUpUnlock ?? this.walkUpUnlock,
        walkUpAutoPowerOn: walkUpAutoPowerOn ?? this.walkUpAutoPowerOn,
        walkUpRssiThreshold: walkUpRssiThreshold ?? this.walkUpRssiThreshold,
        autoLockRssiThreshold: autoLockRssiThreshold ?? this.autoLockRssiThreshold,
        antiTheft5m: antiTheft5m ?? this.antiTheft5m,
        antiForgetAlert: antiForgetAlert ?? this.antiForgetAlert,
        autoLockDistance: autoLockDistance ?? this.autoLockDistance,
        antiForgetDistance: antiForgetDistance ?? this.antiForgetDistance,
        rssi: rssi ?? this.rssi,
        filteredRssi: filteredRssi ?? this.filteredRssi,
        lastTimeSynced: lastTimeSynced ?? this.lastTimeSynced,
        findBikePattern: findBikePattern ?? this.findBikePattern,
        recupLevel: recupLevel ?? this.recupLevel,
        throttleResponse: throttleResponse ?? this.throttleResponse,
        speedLimitMode: speedLimitMode ?? this.speedLimitMode,
        eceMode: eceMode ?? this.eceMode,
        grabMode: grabMode ?? this.grabMode,
        idlingTurnOff: idlingTurnOff ?? this.idlingTurnOff,
        distanceMode: distanceMode ?? this.distanceMode,
        chargingProfile: chargingProfile ?? this.chargingProfile,
        isLocked: isLocked ?? this.isLocked,
        autoReconnect: autoReconnect ?? this.autoReconnect,
        continuousScan: continuousScan ?? this.continuousScan,
        reconnectMaxAttempts: reconnectMaxAttempts ?? this.reconnectMaxAttempts,
        reconnectIntervalSeconds: reconnectIntervalSeconds ?? this.reconnectIntervalSeconds,
        frameSerial: frameSerial ?? this.frameSerial,
        bikeModelCode: bikeModelCode ?? this.bikeModelCode,
        boardManifest: boardManifest ?? this.boardManifest,
        vescCurrent: vescCurrent ?? this.vescCurrent,
        vescVoltage: vescVoltage ?? this.vescVoltage,
        vescDutyCycle: vescDutyCycle ?? this.vescDutyCycle,
        fwSpeedLimitRaw: fwSpeedLimitRaw ?? this.fwSpeedLimitRaw,
        distanceRawU16: distanceRawU16 ?? this.distanceRawU16,
        vescProgActive: vescProgActive ?? this.vescProgActive,
      );
}

class BleController extends Notifier<BleState> {
  static const _kLastBikeId = 'last_bike_id';
  static const _kBikePassword = 'bike_password'; // password đã self-register
  static const _kLastBikeName = 'last_bike_name';
  static const _backoff = [2, 4, 8, 16, 30]; // giây

  StreamSubscription? _connSub;
  StreamSubscription? _notifySub;
  Timer? _reconnectTimer;
  Timer? _pollTimer;
  BluetoothCharacteristic? _dashChar;
  BluetoothCharacteristic? _batteryChar;
  int _batteryPollCounter = 0;
  bool _manualDisconnect = false;
  bool _reconnectPending = false;
  int _reconnectAttempts = 0;
  int _failStreak = 0;
  int _decodeFailStreak = 0;
  int _plainLogCount = 0;

  // Keepalive — chu trình 1,2s của app gốc (log vendor 13/10):
  //   WRITE 16B auth response -> WRITE 12B password -> READ nonce moi.
  // Giu session song KHONG can the NFC + re-derive sessionKey moi chu ky
  // (firmware derive lai + reset writeCounter tai moi auth write hop le).
  Timer? _keepaliveTimer;
  Uint8List? _lastAuthNonce15;
  String _activePassword = '';
  int _keepaliveCount = 0;
  bool _keepaliveBusy = false;
  bool _establishBusy = false; // mutex: 1 handshake/lúc — chống double-flow
  bool _restoreBusy = false; // mutex: 1 restore/lúc — chống khởi động song song
  bool _isCommandBusy = false; // mutex: chống gửi dồn dập nhiều lệnh tới BMS
  DateTime? _lastCommandCompletedAt; // mốc hoàn tất lệnh trước (cooldown bus CAN/BMS)

  /// KEEPALIVE TẮT MẶC ĐỊNH (2026-10-20): bản log 13h49 giữ được session
  /// khi tháo thẻ CHỈ với poll dashboard 700ms — không cần chu trình auth
  /// 1,2s. Keepalive (thêm ở bản e+) là nghi phạm làm đứt link: nếu trả lời
  /// nonce cũ (do lần đọc nào đó xoay nonce) xe coi là vi phạm bảo mật.
  /// Bật lại = true nếu cần thử nghiệm.
  static const enableKeepalive = false;
  bool _recoveryDisconnect = false; // disconnect trong recovery: ĐỪNG đóng logger
  Uint8List? _sessionKey;
  int _writeCounter = 0;
  String? _lastRawStatusSig;

  final _telemetry = StreamController<BikeTelemetry>.broadcast();

  static const _kAutoLockWalkAway = 'auto_lock_walk_away';
  static const _kWalkUpUnlock = 'walk_up_unlock';
  static const _kWalkUpAutoPowerOn = 'walk_up_auto_power_on';
  static const _kWalkUpRssiThreshold = 'walk_up_rssi_threshold';
  static const _kAutoLockRssiThreshold = 'auto_lock_rssi_threshold';
  static const _kAntiTheft5m = 'anti_theft_5m';
  static const _kAutoReconnect = 'auto_reconnect_enabled';
  static const _kContinuousScan = 'continuous_scan_enabled';
  static const _kReconnectMaxAttempts = 'reconnect_max_attempts';
  static const _kReconnectIntervalSeconds = 'reconnect_interval_seconds';
  static const _kAntiForgetAlert = 'anti_forget_alert';
  static const _kAutoLockDistance = 'auto_lock_distance';
  static const _kAntiForgetDistance = 'anti_forget_distance';
  static const _kFindBikePattern = 'find_bike_pattern';
  static const _kRecupLevel = 'recup_level';
  static const _kThrottleResponse = 'throttle_response';
  static const _kSpeedLimitMode = 'speed_limit_mode';
  static const _kEceMode = 'fw_ece_mode';
  static const _kGrabMode = 'fw_grab_mode';
  static const _kIdlingTurnOff = 'fw_idling_turn_off';
  static const _kDistanceMode = 'fw_distance_mode';
  static const _kChargingProfile = 'fw_charging_profile';
  static const _kTripHistory = 'trip_history_v1';
  static const _kUserName = 'user_profile_name';

  final _rssiKalman = KalmanFilter1D(processNoise: 0.008, measurementNoise: 4.0);
  double? _smoothedRssi;
  int _autoLockCounter = 0;
  int _theftCounter = 0;
  int _unlockNearCounter = 0;
  bool _autoSecureBusy = false; // đang chạy chuỗi tắt→ARM (chống chạy chồng)
  DateTime? _lastUserCommandAt; // user-intent-first: ngừng automation 10s sau thao tác chủ động
  int _antiForgetCounter = 0;
  bool _walkUpTriggered = false;
  DateTime? _connectedAt;
  bool _hasBeenNearBike = false;

  double? _tripStartOdo;
  DateTime? _tripStartTime;
  int? _tripStartPercent;
  double _tripMaxSpeed = 0.0;
  double _tripSpeedSum = 0.0;
  int _tripSpeedSamples = 0;

  @override
  BleState build() {
    ref.onDispose(_teardown);
    _initSavedBike();
    return const BleState(phase: BlePhase.idle);
  }

  void _initSavedBike() async {
    final SharedPreferences prefs;
    try {
      prefs = await _prefs;
    } catch (e, st) {
      if (!ref.mounted) return;
      // shared_preferences hỏng (vd NoSuchMethodError getAll khi cài đè APK
      // bẩn) — phải báo rõ là lỗi bộ nhớ app, không để đội lố lỗi Bluetooth.
      await BleLogger.logAppError('prefs_init', e, st);
      state = state.copyWith(
        message: 'Lỗi bộ nhớ app (không đọc được cài đặt đã lưu): $e\n'
            '→ Gỡ app rồi cài lại APK mới.',
      );
      return;
    }
    if (!ref.mounted) return;
    final savedName = prefs.getString(_kLastBikeName);
    final savedId = prefs.getString(_kLastBikeId);
    final autoLock = prefs.getBool(_kAutoLockWalkAway) ?? false;
    final walkUp = prefs.getBool(_kWalkUpUnlock) ?? false;
    final walkUpPowerOn = prefs.getBool(_kWalkUpAutoPowerOn) ?? true;
    final walkUpRssi = prefs.getDouble(_kWalkUpRssiThreshold);
    final autoLockRssi = prefs.getDouble(_kAutoLockRssiThreshold);
    final theft5m = prefs.getBool(_kAntiTheft5m) ?? false;
    final antiForget = prefs.getBool(_kAntiForgetAlert) ?? true;
    final autoLockDist = prefs.getInt(_kAutoLockDistance) ?? 1;
    final antiForgetDist = prefs.getInt(_kAntiForgetDistance) ?? 1;
    final findBikePat = prefs.getInt(_kFindBikePattern) ?? 0;
    final recup = prefs.getInt(_kRecupLevel) ?? 1;
    final throttle = prefs.getInt(_kThrottleResponse) ?? 1;
    final speedLimit = prefs.getInt(_kSpeedLimitMode) ?? 0;
    final eceM = prefs.getInt(_kEceMode) ?? 0;
    final grabM = prefs.getInt(_kGrabMode) ?? 0;
    final idlingOff = prefs.getBool(_kIdlingTurnOff) ?? false;
    final distM = prefs.getInt(_kDistanceMode) ?? 0;
    final chargeP = prefs.getInt(_kChargingProfile) ?? 0;
    final savedUserName = prefs.getString(_kUserName);
    final autoReconn = prefs.getBool(_kAutoReconnect) ?? true;
    final contScan = prefs.getBool(_kContinuousScan) ?? false;
    final reconnMax = prefs.getInt(_kReconnectMaxAttempts) ?? 5;
    final reconnInterval = prefs.getInt(_kReconnectIntervalSeconds) ?? 5;

    List<TripRecord> loadedHistory = [];
    final tripHistJson = prefs.getString(_kTripHistory);
    if (tripHistJson != null && tripHistJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(tripHistJson) as List<dynamic>;
        loadedHistory = decoded
            .map((e) => TripRecord.fromJson(e as Map<String, dynamic>))
            .where((e) => e.distanceKm >= 0.1 || e.route.isNotEmpty)
            .toList();
      } catch (_) {}
    }

    state = state.copyWith(
      bikeName: (savedId != null && savedName != null) ? savedName : (savedId == null ? null : state.bikeName),
      userName: savedUserName,
      tripHistory: loadedHistory,
      autoLockWalkAway: autoLock,
      walkUpUnlock: walkUp,
      walkUpAutoPowerOn: walkUpPowerOn,
      walkUpRssiThreshold: walkUpRssi,
      autoLockRssiThreshold: autoLockRssi,
      antiTheft5m: theft5m,
      antiForgetAlert: antiForget,
      autoLockDistance: autoLockDist,
      antiForgetDistance: antiForgetDist,
      findBikePattern: findBikePat,
      recupLevel: recup,
      throttleResponse: throttle,
      speedLimitMode: speedLimit,
      eceMode: eceM,
      grabMode: grabM,
      idlingTurnOff: idlingOff,
      distanceMode: distM,
      chargingProfile: chargeP,
      autoReconnect: autoReconn,
      continuousScan: contScan,
      reconnectMaxAttempts: reconnMax,
      reconnectIntervalSeconds: reconnInterval,
    );
    // Tự động khôi phục dữ liệu GPS hành trình dở dang nếu trước đó app bị vuốt tắt
    unawaited(TripGpsTracker.instance.restoreUnsavedPoints());
    // Tự động kết nối ngay khi mở app nếu đã từng kết nối xe trước đó
    if (savedId != null && savedId.isNotEmpty && autoReconn) {
      unawaited(tryRestoreLastBike());
    }
  }

  /// Cập nhật tên chủ xe hiển thị
  Future<void> setUserName(String name) async {
    final trimmed = name.trim();
    final prefs = await _prefs;
    await prefs.setString(_kUserName, trimmed);
    state = state.copyWith(userName: trimmed);
    BleLogger.instance.event('user_name_updated', {'name': trimmed});
  }

  /// Xóa toàn bộ lịch sử chuyến đi
  Future<void> clearTripHistory() async {
    state = state.copyWith(tripHistory: const []);
    try {
      final prefs = await _prefs;
      await prefs.remove(_kTripHistory);
      BleLogger.instance.event('trip_history_cleared', {});
    } catch (_) {}
  }

  /// Xóa một chuyến đi cụ thể khỏi lịch sử hành trình
  Future<void> deleteTrip(TripRecord trip) async {
    final updated = state.tripHistory.where((t) =>
      !(t.startTime.millisecondsSinceEpoch == trip.startTime.millisecondsSinceEpoch &&
        (t.distanceKm - trip.distanceKm).abs() < 0.001)
    ).toList();
    state = state.copyWith(tripHistory: updated);
    try {
      final prefs = await _prefs;
      if (updated.isEmpty) {
        await prefs.remove(_kTripHistory);
      } else {
        final jsonStr = jsonEncode(updated.map((e) => e.toJson()).toList());
        await prefs.setString(_kTripHistory, jsonStr);
      }
      BleLogger.instance.event('trip_deleted', {
        'start_time': trip.startTime.toIso8601String(),
        'distance_km': trip.distanceKm,
        'remaining': updated.length,
      });
    } catch (e) {
      BleLogger.instance.event('trip_delete_error', {'error': '$e'});
    }
  }

  /// Tự động lưu chuyến đi hiện tại vào lịch sử.
  /// QUY TẮC: Chỉ lưu hành trình nếu quãng đường di chuyển từ 1km trở lên (>= 1.0 km).
  /// Nếu di chuyển dưới 1km (< 1.0 km) thì tuyệt đối không lưu hành trình.
  Future<void> _archiveCurrentTripIfMeaningful() async {
    final trip = state.trip;
    final durSec = trip.duration.inSeconds;
    final gpsDistKm = TripGpsTracker.instance.totalDistanceKm;
    // Lấy quãng đường lớn hơn giữa ODO xe và GPS
    final effectiveDistKm = trip.distanceKm > 0 ? trip.distanceKm : gpsDistKm;
    final currentRoute = TripGpsTracker.instance.getCurrentRoute();

    // Bỏ qua nếu quãng đường quá ngắn (< 100m) VÀ không có điểm GPS thực tế nào được ghi nhận
    if ((effectiveDistKm < 0.1 && currentRoute.isEmpty) || _tripStartTime == null) {
      BleLogger.instance.event('trip_skipped_under_100m', {
        'distance_km': effectiveDistKm,
        'odo_dist_km': trip.distanceKm,
        'gps_dist_km': gpsDistKm,
        'duration_sec': durSec,
      });
      // Dừng tracking và giải phóng bộ nhớ GPS của cuốc đi ngắn
      TripGpsTracker.instance.stopTracking();
      TripGpsTracker.instance.clear();
      // Reset mốc chuyến đi hiện tại để cuốc tiếp theo tính mới
      final curTele = state.lastTelemetry;
      _tripStartOdo = curTele?.odo;
      _tripStartTime = null;
      _tripStartPercent = curTele?.percent;
      _tripMaxSpeed = 0.0;
      _tripSpeedSum = 0.0;
      _tripSpeedSamples = 0;
      state = state.copyWith(
        trip: TripData(powerKw: state.trip.powerKw),
      );
      return;
    }

    final now = DateTime.now();
    final recordedRoute = TripGpsTracker.instance.stopTracking();
    final record = TripRecord(
      startTime: _tripStartTime!,
      endTime: now,
      distanceKm: double.parse(effectiveDistKm.toStringAsFixed(2)),
      durationSec: durSec,
      avgSpeedKmh: trip.avgSpeedKmh,
      maxSpeedKmh: trip.maxSpeedKmh,
      usedPercent: trip.usedPercent,
      startOdo: _tripStartOdo,
      endOdo: state.lastTelemetry?.odo,
      route: recordedRoute,
    );

    final updated = [record, ...state.tripHistory].take(50).toList();
    // Reset bộ đếm chuyến hiện tại ngay sau khi đã lưu để không bị lưu trùng lần 2 khi Tắt máy -> Ngắt BLE
    final curTele = state.lastTelemetry;
    _tripStartOdo = curTele?.odo;
    _tripStartTime = null;
    _tripStartPercent = curTele?.percent;
    _tripMaxSpeed = 0.0;
    _tripSpeedSum = 0.0;
    _tripSpeedSamples = 0;
    state = state.copyWith(
      tripHistory: updated,
      trip: TripData(powerKw: state.trip.powerKw),
    );

    try {
      final prefs = await _prefs;
      final jsonStr = jsonEncode(updated.map((e) => e.toJson()).toList());
      await prefs.setString(_kTripHistory, jsonStr);
      await TripGpsTracker.instance.clearSavedCache();
      BleLogger.instance.event('trip_archived', {
        'dist_km': record.distanceKm,
        'dur_sec': record.durationSec,
        'avg_speed': record.avgSpeedKmh,
        'route_points': record.route.length,
      });
    } catch (e) {
      BleLogger.instance.event('trip_archive_error', {'error': '$e'});
    }
  }

  Future<void> setFindBikePattern(int val) async {
    final prefs = await _prefs;
    await prefs.setInt(_kFindBikePattern, val);
    state = state.copyWith(findBikePattern: val);
  }

  /// Lưu hồ sơ mức phanh tái sinh RECUP cá nhân trên ứng dụng.
  /// LƯU Ý: Firmware v1.14.0 hiện tại chưa hỗ trợ ghi cấu hình RECUP qua BLE xuống xe.
  Future<void> setRecupLevel(int val) async {
    final prefs = await _prefs;
    await prefs.setInt(_kRecupLevel, val);
    state = state.copyWith(recupLevel: val);
    BleLogger.instance.event('driver_profile_recup_set_local', {'level': val});
  }

  /// Lưu hồ sơ độ nhạy tay ga cá nhân trên ứng dụng.
  /// LƯU Ý: Firmware v1.14.0 hiện tại chưa hỗ trợ ghi cấu hình bướm ga qua BLE xuống xe.
  Future<void> setThrottleResponse(int val) async {
    final prefs = await _prefs;
    await prefs.setInt(_kThrottleResponse, val);
    state = state.copyWith(throttleResponse: val);
    BleLogger.instance.event('driver_profile_throttle_set_local', {'response': val});
  }

  /// Lưu hồ sơ giới hạn tốc độ khuyến nghị cá nhân trên ứng dụng.
  /// CẢNH BÁO: Firmware v1.14.0 KHÔNG hỗ trợ khóa tốc độ xe từ Bluetooth!
  /// Cài đặt này chỉ mang tính tham khảo trên giao diện và KHÔNG hãm tốc độ thực tế của xe.
  /// Cache local cho UI (ghi thật xuống xe = setFwEceMode).
  Future<void> setEceMode(int val) async {
    final prefs = await _prefs;
    await prefs.setInt(_kEceMode, val);
    state = state.copyWith(eceMode: val);
  }

  Future<void> setGrabMode(int val) async {
    final prefs = await _prefs;
    await prefs.setInt(_kGrabMode, val);
    state = state.copyWith(grabMode: val);
  }

  Future<void> setIdlingTurnOff(bool val) async {
    final prefs = await _prefs;
    await prefs.setBool(_kIdlingTurnOff, val);
    state = state.copyWith(idlingTurnOff: val);
  }

  Future<void> setChargingProfile(int val) async {
    final prefs = await _prefs;
    await prefs.setInt(_kChargingProfile, val);
    state = state.copyWith(chargingProfile: val);
  }

  Future<void> setDistanceMode(int val) async {
    final prefs = await _prefs;
    await prefs.setInt(_kDistanceMode, val);
    state = state.copyWith(distanceMode: val);
  }

  Future<void> setSpeedLimitMode(int val) async {
    final prefs = await _prefs;
    await prefs.setInt(_kSpeedLimitMode, val);
    state = state.copyWith(speedLimitMode: val);
    BleLogger.instance.event('driver_profile_speed_mode_set_local', {'mode': val});
  }

  // ------------------------------------------------------------------
  // GATT Command Queue & Expected Length Table (Phase 1 normalization)
  // ------------------------------------------------------------------

  Future<void>? _gattChain;

  /// Hàng đợi tuần tự các thao tác GATT read/write chống đụng độ lỗi 129 / 133
  Future<T> _enqueueGatt<T>(Future<T> Function() action) {
    final prev = _gattChain ?? Future.value();
    final completer = Completer<T>();
    _gattChain = prev.catchError((_) {}).then((_) async {
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// Bảng expectedLength chuẩn theo Ghidra RE2 để cắt Stale-Tail buffer
  static int? expectedLengthForUuid(String uuid) {
    final clean = uuid.replaceAll('-', '').toLowerCase();
    if (clean.startsWith('6d2eb205')) return 41; // dashboard
    if (clean.startsWith('018e6a6f')) return 108; // bikeLog identity
    if (clean.startsWith('84c7be0b')) return 207; // batteryLog
    if (clean.startsWith('2c73e84e')) return 16;  // logBufferStats (4x uint32 LE)
    if (clean.startsWith('35a9b4f6')) return 12;  // vescSnapshot (3x float32 LE)
    if (clean.startsWith('4cb05df8')) return 12;  // legacyAppAuth
    if (clean.startsWith('5d681587')) return 2;   // distance (uint16 LE)
    if (clean.startsWith('c75ebe03')) return 2;   // addCard
    if (clean.startsWith('0a19a49a') ||
        clean.startsWith('3b56ac38') ||
        clean.startsWith('a1d8e7c4') ||
        clean.startsWith('69c79762') ||
        clean.startsWith('b0ca953d') ||
        clean.startsWith('8a2b0d10') ||
        clean.startsWith('91e84eb0')) {
      return 1;
    }
    return null;
  }

  // ------------------------------------------------------------------
  // SETTINGS THẬT — service MASTER_CONFIG f7e2c8a1 (protected write)
  // ------------------------------------------------------------------

  /// Ghi 1 lệnh setting xuống xe: protected write [counter][data][tag4]
  /// lên char trong service MASTER_CONFIG. Đọc giá trị hiện tại trước,
  /// ghi, rồi ĐỌC LẠI verify (disasm 23/10: các handler chỉ nhận '0'/'1'
  /// ASCII — giá trị lưu raw u8/u16). Trả về thông điệp kết quả cho UI.
  Future<String> _writeSetting(String uuid, List<int> data, String label) async {
    if (state.phase != BlePhase.connected || !state.isAuthorized) {
      return 'Xe chưa kết nối/xác thực — không ghi được $label';
    }
    final c = _findCharacteristic(uuid);
    if (c == null) {
      BleLogger.instance.event('setting_write_err', {
        'char': uuid, 'label': label, 'error': 'char not found',
      });
      return 'Xe không expose characteristic $label';
    }
    if (_sessionKey == null) {
      return 'Chưa có session key — không ghi được $label';
    }
    return _enqueueGatt(() async {
      // Đọc giá trị hiện tại để log đối chiếu (char trả cipher khi session sống)
      String oldHex = '';
      try {
        final cur = await c.read().timeout(
            const Duration(milliseconds: 1200), onTimeout: () => Uint8List(0));
        final dec = (cur.length >= 4)
            ? BikeSessionCrypto.decryptProtectedRead(
                sessionKey: _sessionKey!,
                characteristicUuid: uuid,
                response: cur,
                expectedLength: expectedLengthForUuid(uuid),
              )
            : Uint8List(0);
        oldHex = dec.isEmpty ? '' : BleLogger.hex(dec, maxBytes: 16);
        BleLogger.instance.event('setting_read_current', {
          'char': uuid,
          'label': label,
          'hex': BleLogger.hex(cur, maxBytes: 48),
          'dec_hex': dec.isEmpty ? '' : BleLogger.hex(dec, maxBytes: 48),
          'dec_utf8': BleLogger.tryUtf8(dec) ?? '',
        });
      } catch (_) {}
      try {
        final frame = BikeSessionCrypto.buildProtectedWrite(
          sessionKey: _sessionKey!,
          counter: _writeCounter++,
          characteristicUuid: uuid,
          data: data,
        );
        await c.write(frame, withoutResponse: false);
        BleLogger.instance.event('setting_write', {
          'char': uuid,
          'label': label,
          'data': String.fromCharCodes(data),
          'counter': _writeCounter - 1,
        });
        // Đọc lại verify — firmware parse xong mới trả giá trị mới (đợi ~150ms)
        await Future.delayed(const Duration(milliseconds: 150));
        String newHex = '';
        try {
          final re = await c.read().timeout(
              const Duration(milliseconds: 1200), onTimeout: () => Uint8List(0));
          final dec = (re.length >= 4)
              ? BikeSessionCrypto.decryptProtectedRead(
                  sessionKey: _sessionKey!,
                  characteristicUuid: uuid,
                  response: re,
                  expectedLength: expectedLengthForUuid(uuid),
                )
              : Uint8List(0);
          newHex = dec.isEmpty ? '' : BleLogger.hex(dec, maxBytes: 16);
          BleLogger.instance.event('setting_verify_read', {
            'char': uuid,
            'label': label,
            'hex': BleLogger.hex(re, maxBytes: 48),
            'dec_hex': dec.isEmpty ? '' : BleLogger.hex(dec, maxBytes: 48),
            'old': oldHex,
            'new': newHex,
          });
        } catch (e) {
          BleLogger.instance.event('setting_verify_read_err', {
            'char': uuid, 'label': label, 'error': '$e',
          });
        }
        final tail = newHex.isEmpty
            ? ''
            : (newHex == oldHex
                ? ' — xe vẫn trả $newHex (giá trị chưa đổi)'
                : ' — xe xác nhận: $oldHex → $newHex');
        return 'Đã ghi $label xuống xe (${String.fromCharCodes(data)})$tail';
      } catch (e) {
        BleLogger.instance.event('setting_write_err', {
          'char': uuid, 'label': label, 'error': '$e',
        });
        return 'Lỗi ghi $label: $e';
      }
    });
  }

  /// Giới hạn tốc độ an toàn (60 km/h) — cơ chế chuỗi ngầm tự động (ECE Gateway Sequence).
  ///
  /// NGUYÊN LÝ FIRMWARE:
  /// - ECE là "CỔNG" cấu hình: muốn cấu hình giới hạn tốc độ thì ECE bắt buộc phải mở (= 1).
  /// - Khi ECE đang mở (= 1), firmware xe sẽ KHÓA các tính năng khác: không cho bật/tắt đèn, không cho chuyển mode lái D/S.
  /// - Nhưng khi đóng ECE lại (= 0), controller xe (VESC) vẫn GIỮ trần giới hạn tốc độ đã thiết lập trong RAM!
  ///
  /// QUY TRÌNH BẬT TỰ ĐỘNG CHẠY NGẦM (on == true):
  /// 1. Mở cổng ECE: Ghi eceModeChar = '1'
  /// 2. Ghi giới hạn tốc độ: Ghi speedLimitChar = '1' (60 km/h)
  /// 3. Đóng cổng ECE: Ghi eceModeChar = '0' (trả về mặc định để đèn và chuyển mode lái hoạt động bình thường)
  ///
  /// QUY TRÌNH TẮT TỰ ĐỘNG CHẠY NGẦM (on == false):
  /// 1. Mở cổng ECE: Ghi eceModeChar = '1'
  /// 2. Trả giới hạn tốc độ về mặc định (Full Power): Ghi speedLimitChar = '0'
  /// 3. Đóng cổng ECE: Ghi eceModeChar = '0'
  Future<String> setSafeSpeedLimit60(bool on) async {
    if (state.phase != BlePhase.connected) {
      state = state.copyWith(
        speedLimitMode: on ? 1 : 0,
        eceMode: 0,
        fwSpeedLimitRaw: on ? 1 : 0,
      );
      if (on) {
        return '⚠️ Xe chưa kết nối. Đã lưu cấu hình giới hạn tốc độ 60 km/h trên ứng dụng.';
      } else {
        return '⚠️ Xe chưa kết nối. Đã lưu cấu hình tắt giới hạn (Full Power) trên ứng dụng.';
      }
    }

    try {
      // BƯỚC 1: Mở cổng ECE để firmware cho phép ghi cấu hình giới hạn tốc độ
      final msgOpenEce = await _writeSetting(Gatt.eceModeChar, [0x31], 'mở cổng ECE');
      await Future.delayed(const Duration(milliseconds: 150));

      // BƯỚC 2: Ghi giá trị giới hạn tốc độ ('1' = 60 km/h, '0' = Full Power mặc định)
      final msgSpeed = await _writeSetting(
        Gatt.speedLimitChar,
        [on ? 0x31 : 0x30],
        on ? 'bật giới hạn 60 km/h' : 'tắt giới hạn tốc độ (Full Power)',
      );
      await Future.delayed(const Duration(milliseconds: 150));

      // BƯỚC 3: Đóng cổng ECE lại về '0' để giải phóng đèn và chuyển mode lái hoạt động bình thường
      final msgCloseEce = await _writeSetting(Gatt.eceModeChar, [0x30], 'đóng cổng ECE');

      // Cập nhật trạng thái ứng dụng:
      // speedLimitMode = on (1 hoặc 0), eceMode = 0 (luôn đóng để xe hoạt động bình thường)
      state = state.copyWith(
        speedLimitMode: on ? 1 : 0,
        eceMode: 0,
        fwSpeedLimitRaw: on ? 1 : 0,
      );

      BleLogger.instance.event('speed_limit_sequence_completed', {
        'target_on': on,
        'speed_raw': on ? 1 : 0,
        'ece_restored': 0,
      });

      if (on) {
        return '⚡ Đã kích hoạt Giới hạn tốc độ 60 km/h thành công!\n'
            '🔒 Quy trình ngầm: Mở ECE → Ghi giới hạn 60 km/h → Đóng ECE.\n'
            '✅ Cổng ECE đã tự động đóng: Bạn vẫn có thể chuyển chế độ lái (D/S) và sử dụng đèn bình thường.\n$msgOpenEce\n$msgSpeed\n$msgCloseEce';
      } else {
        return '🔓 Đã tắt giới hạn tốc độ (trả về Full Power) thành công!\n'
            '🔒 Quy trình ngầm: Mở ECE → Ghi Limit 0 (mặc định) → Đóng ECE.\n'
            '💡 Nếu xe chưa nhả tốc độ ngay, bạn chỉ cần tắt máy xe rồi bật lại để bộ điều tốc giải phóng trần tốc độ khỏi RAM.\n$msgOpenEce\n$msgSpeed\n$msgCloseEce';
      }
    } catch (e) {
      BleLogger.instance.event('speed_limit_sequence_error', {'error': '$e'});
      return '❌ Lỗi thực hiện quy trình cài đặt tốc độ: $e';
    }
  }

  /// KHÓA AN TOÀN (ARM) — char eec8fd7f (LAB 23/10 đêm xác minh thực tế):
  /// protected '1' = khóa an toàn: xe khóa, BẮT BUỘC quẹt thẻ NFC mới kết nối
  /// lại được, còi hú khi đá chống; '0' = mở khóa. (Nhãn cũ "immobilizer qua
  /// 7f13fe5c" SAI — 7f13fe5c thực chất là char bật/tắt nguồn động, xem
  /// _sendPowerCommand; LAB ghi nhận "xe tắt bật đúng, không hành động khác".)
  Future<String> setImmobilizer(bool lock) async {
    final spd = state.lastTelemetry?.speed ?? 0.0;
    if (lock && spd > 0.5) {
      return '⚠️ CẢNH BÁO: Không thể khóa khi xe đang di chuyển (${spd.toStringAsFixed(1)} km/h)!';
    }
    if (state.phase != BlePhase.connected) {
      state = state.copyWith(isLocked: lock);
      return '⚠️ Xe chưa kết nối BLE. Đã đổi trạng thái trên giao diện.';
    }
    final msg = await _writeSetting(
      Gatt.powerProtectedChar,
      [lock ? 0x31 : 0x30],
      lock ? 'khóa an toàn (cần thẻ NFC để mở)' : 'mở khóa an toàn',
    );
    state = state.copyWith(isLocked: lock);
    if (lock) {
      return '$msg\n🔒 Xe đang KHÓA AN TOÀN: cần QUẸT THẺ NFC lên xe để mở/kết nối '
          'lại. Còi sẽ hú khi có người động vào xe (đá chống).';
    }
    return msg;
  }

  /// ⚠️ CẢNH BÁO AN TOÀN (RE2 verified — onWriteVescProgamming @0x4015565c):
  /// Char b0ca953d KHÔNG PHẢI công tắc đèn xe! Handler trong firmware thực hiện
  /// PURE TOGGLE (`cfg+0x62 = bVar1 ^ 1`, bỏ qua toàn bộ nội dung payload) để
  /// bật/tắt chế độ nạp VESC (Dev Mode), làm NGỪNG vescPollTask (@0x400db6b0)
  /// và canCheckConnectionTask (@0x400d5b02) (khiến IM=0 và đèn tắt như hệ quả phụ).
  /// Đã khóa hàm setBikeLights để tránh ngắt điều khiển VESC khi xe đang chạy.
  Future<String> setBikeLights(bool on) async {
    BleLogger.instance.event('bike_lights_blocked_safety', {
      'requested': on,
      'reason': 'b0ca953d is onWriteVescProgamming XOR toggle, not a light switch',
    });
    return '⚠️ Đã chặn an toàn: Cổng b0ca953d thực chất là công tắc đảo bit '
        'Chế độ nạp VESC (onWriteVescProgamming @0x4015565c), làm ngắt task poll VESC '
        '(IM = 0) chứ không phải công tắc đèn độc lập. Chỉ dùng trong Firmware Lab khi xe đứng yên.';
  }

  /// Đọc trạng thái khóa — KHÔNG dùng BLE nữa: 7f13fe5c trả echo bật/tắt
  /// NGUỒN (LAB 23/10 đêm), còn eec8fd7f trả "00 00" chưa rõ nghĩa. Trạng
  /// thái khóa theo dõi app-side (đặt khi bấm khóa/mở).
  Future<bool?> readLockStatus() async => null;

  /// Giới hạn tốc độ đơn lẻ — firmware 1.14.0 parse BOOLEAN (disasm onWriteSpeedLimit
  /// @0x40153d50: payload[0]-'1'==0 ? 1 : 0). '2'/'3' bị hiểu là TẮT.
  /// Read trả raw u8 (NVS 'speed-limit', default 1).
  Future<String> setFwSpeedLimit(bool on) =>
      _writeSetting(Gatt.speedLimitChar, [on ? 0x31 : 0x30], 'giới hạn tốc độ');

  /// Chế độ ECE — BOOLEAN '0'/'1' (disasm onWriteEceMode @0x40153bd0).
  Future<String> setFwEceMode(bool on) =>
      _writeSetting(Gatt.eceModeChar, [on ? 0x31 : 0x30], 'chế độ ECE');

  /// Chế độ Grab — BOOLEAN '0'/'1' (disasm onWriteGrabMode @0x40153e30).
  Future<String> setFwGrabMode(bool on) =>
      _writeSetting(Gatt.grabModeChar, [on ? 0x31 : 0x30], 'chế độ Grab');

  /// Tự tắt xe khi đỗ — '1' bật / '0' tắt.
  Future<String> setFwIdlingTurnOff(bool on) =>
      _writeSetting(Gatt.idlingTurnOffChar, [on ? 0x31 : 0x30], 'tự tắt khi đỗ');

  /// Tự bật/tắt theo khoảng cách BLE — XE TỰ xử lý. Handler onWriteDistance
  /// @0x401552cc cũng parse BOOLEAN '0'/'1'; char lưu u16 (NVS 'distance',
  /// default 8 — đơn vị chưa rõ, đang hiển thị giá trị thô).
  Future<String> setFwDistanceMode(bool on) =>
      _writeSetting(Gatt.distanceChar, [on ? 0x31 : 0x30], 'khoảng cách tự bật/tắt');

  /// Chọn profile sạc — 0=Standard, 1=Fast, 2=Boost.
  /// Ghidra-verified 23/10 (handler 0x40154240): parse RAW BYTE payload[0]
  /// (l8ui → s8i obj+2 → putUChar 'charging'/'defaultProfile'), có nhánh
  /// riêng cho giá trị 2 — KHÔNG phải ASCII '0'/'1'/'2' như setting khác!
  Future<String> setFwChargingProfile(int profile) =>
      _writeSetting(Gatt.chargingProfileChar, [profile.clamp(0, 2)], 'profile sạc');

  /// Bắt đầu đăng ký thẻ NFC mới — user quẹt thẻ vào xe trong ~10s
  /// (firmware RfidCardManager: "Adding new card...").
  Future<String> startAddNfcCard() async {
    final r = await _writeSetting(Gatt.addCardChar, [0x31], 'thêm thẻ NFC');
    return '$r\n👉 Quẹt thẻ MỚI vào đầu đọc trên xe trong ~10 giây…';
  }

  /// Tắt hẳn BMS — chỉ dùng khi đỗ lâu (nguy hiểm: phải mở ca-pô/bật lại xe).
  Future<String> turnOffBms() =>
      _writeSetting(Gatt.turnOffBmsChar, [0x31], 'tắt BMS');

  /// Factory reset cài đặt BLE của xe (firmware: "Factory reset BLE settings").
  Future<String> factoryResetBle() =>
      _writeSetting(Gatt.resetBleChar, [0x31], 'factory reset BLE');

  /// (setFwBikeName đã chuyển xuống dưới — ghi qua char 88c30d2c setName
  /// thật; char bikeNameChar 460a5bc5 chỉ là echo, KHÔNG lưu.)

  /// Đọc giá trị hiện tại của 1 char setting (protected-decrypt).
  /// Trả về bytes decrypt (rỗng nếu không đọc/decrypt được). Log đầy đủ
  /// dec_hex để bắt anomaly decrypt runtime (23/10: decrypt in-app của
  /// vài char không ra kết quả dù key đúng — cần so sánh với offline).
  Future<Uint8List> readFwSettingRaw(String uuid, String label) async {
    final empty = Uint8List(0);
    if (state.phase != BlePhase.connected) return empty;
    final c = _findCharacteristic(uuid);
    if (c == null) return empty;
    try {
      final raw = await _enqueueGatt(() => c.read().timeout(
          const Duration(milliseconds: 1200), onTimeout: () => Uint8List(0)));
      if (raw.length < 4) return empty;
      if (_sessionKey == null) return empty;
      final dec = BikeSessionCrypto.decryptProtectedRead(
        sessionKey: _sessionKey!,
        characteristicUuid: uuid,
        response: raw,
        expectedLength: expectedLengthForUuid(uuid),
      );
      BleLogger.instance.event('setting_read', {
        'char': uuid,
        'label': label,
        'hex': BleLogger.hex(raw, maxBytes: 48),
        'dec_hex': dec.isEmpty ? '' : BleLogger.hex(dec, maxBytes: 48),
      });
      return dec;
    } catch (_) {
      return empty;
    }
  }

  /// Đồng bộ toàn bộ settings thật từ xe về BleState (gọi khi mở màn hình
  /// settings / sau khi kết nối). Giá trị raw u8/u16 — map 0/1 sang bool.
  Future<void> refreshFwSettings() async {
    if (state.phase != BlePhase.connected || _sessionKey == null) return;
    final speed = await readFwSettingRaw(Gatt.speedLimitChar, 'giới hạn tốc độ');
    final ece = await readFwSettingRaw(Gatt.eceModeChar, 'chế độ ECE');
    final grab = await readFwSettingRaw(Gatt.grabModeChar, 'chế độ Grab');
    final idling =
        await readFwSettingRaw(Gatt.idlingTurnOffChar, 'tự tắt khi đỗ');
    final dist =
        await readFwSettingRaw(Gatt.distanceChar, 'khoảng cách tự bật/tắt');
    final chgDec = await readFwSettingRaw(Gatt.chargingProfileChar, 'profile sạc');
    final vescProgDec = await readFwSettingRaw(Gatt.vescProgrammingChar, 'vesc programming');
    final isLockedVal = await readLockStatus();

    // Giới hạn tốc độ được lưu tại speedLimitChar (1 = đang giới hạn 60 km/h, 0 = Full Power)
    // ECE là cổng cấu hình ngầm, bình thường luôn đóng (0) để đèn & chuyển mode D/S hoạt động
    final isLimited = speed.isNotEmpty && speed[0] == 1;
    final fwSpeedRaw = speed.isNotEmpty ? speed[0] : null;

    int? distU16;
    if (dist.length >= 2) {
      distU16 = ByteData.sublistView(Uint8List.fromList(dist)).getUint16(0, Endian.little);
    } else if (dist.isNotEmpty) {
      distU16 = dist[0];
    }

    final isVescProg = vescProgDec.isNotEmpty && vescProgDec[0] == 0x01;

    int? chgProfile;
    if (chgDec.isNotEmpty && chgDec[0] >= 0 && chgDec[0] <= 2) {
      chgProfile = chgDec[0];
    }
    state = state.copyWith(
      speedLimitMode: isLimited ? 1 : 0,
      fwSpeedLimitRaw: fwSpeedRaw ?? state.fwSpeedLimitRaw,
      eceMode: ece.isNotEmpty && ece[0] == 1 ? 1 : 0,
      grabMode: grab.isNotEmpty && grab[0] == 1 ? 1 : 0,
      idlingTurnOff: idling.isNotEmpty && idling[0] == 1,
      distanceMode: dist.isNotEmpty && dist[0] > 0 ? 1 : 0,
      distanceRawU16: distU16 ?? state.distanceRawU16,
      vescProgActive: isVescProg,
      chargingProfile: chgProfile ?? state.chargingProfile,
      isLocked: isLockedVal ?? state.isLocked,
    );
    BleLogger.instance.event('fw_settings_synced', {
      'speed': speed.isEmpty ? null : speed[0],
      'ece': ece.isEmpty ? null : ece[0],
      'is_speed_limited': isLimited,
      'grab': grab.isEmpty ? null : grab[0],
      'idling': idling.isEmpty ? null : idling[0],
      'distance': dist.isEmpty ? null : dist[0],
      'distance_u16': distU16,
      'vesc_prog_active': isVescProg,
      'charging_profile': chgProfile,
      'is_locked': isLockedVal,
    });
  }

  /// Khôi phục cờ VESC Programming (b0ca953d) về 0x00 nếu đang kẹt ở 0x01.
  Future<String> recoverFromVescProgrammingMode() async {
    final cur = await readFwSettingRaw(Gatt.vescProgrammingChar, 'check_vesc_prog');
    if (cur.isEmpty || cur[0] == 0) {
      state = state.copyWith(vescProgActive: false);
      return '✅ Cổng VESC đang ở chế độ Normal (0x00) — không cần khôi phục.';
    }
    final msg = await _writeSetting(
      Gatt.vescProgrammingChar,
      [0x30],
      'khôi phục VESC Programming về Normal (0x00)',
    );
    await refreshFwSettings();
    BleLogger.instance.event('vesc_programming_recovered', {'val': state.vescProgActive ? 1 : 0});
    return '🛠️ $msg';
  }

  // (ĐÃ GỞ v1.5.2) repairBeepUuid/readBeepUuid — dựa trên kết luận SAI rằng
  // 88c30d2c là char beepUUID. Ghidra 23/10 (task-memory id 54) chứng minh:
  // 88c30d2c = char TÊN XE (write = setName), 87efab0d = char beepUUID, và
  // firmware KHÔNG có code kích hoạt còi theo UUID → còi tìm xe là stub.

  /// Đọc tên xe hiện tại từ char 88c30d2c (getName — trả cipher khi session
  /// sống, decrypt rồi decode UTF-8).
  Future<String?> readFwBikeName() async {
    final dec = await readFwSettingRaw(Gatt.fwNameChar, 'tên xe');
    if (dec.isEmpty) return null;
    return BleLogger.tryUtf8(dec)?.trim();
  }

  /// Đặt tên xe — ghi THẬT xuống flash xe qua char 88c30d2c (firmware
  /// setName: NVS 'ble-info'/'name', log "Set new name: %s", maxLen 20).
  /// Ghidra-verified 23/10. (Char 460a5bc5 chỉ là echo — KHÔNG lưu.)
  Future<String> setFwBikeName(String name) async {
    final trimmed = name.trim();
    final bytes = utf8.encode(
        trimmed.length > 20 ? trimmed.substring(0, 20) : trimmed);
    final res = await _writeSetting(Gatt.fwNameChar, bytes, 'tên xe');
    final prefs = await _prefs;
    await prefs.setString(_kLastBikeName, trimmed);
    state = state.copyWith(bikeName: trimmed);
    return res;
  }

  /// Đặt tên xe cục bộ trên ứng dụng khi chưa kết nối Bluetooth
  Future<void> setLocalBikeName(String name) async {
    final trimmed = name.trim();
    final prefs = await _prefs;
    await prefs.setString(_kLastBikeName, trimmed);
    state = state.copyWith(bikeName: trimmed);
  }

  /// Đọc trọn bộ thông tin định danh & snapshot VESC (đã qua _enqueueGatt + cắt Stale-Tail)
  Future<void> fetchVehicleDiagnostics() async {
    if (state.phase != BlePhase.connected || _sessionKey == null) return;

    // 1. Model xe (4aae98e9)
    final modelDec = await readFwSettingRaw(Gatt.bikeModelChar, 'bike_model');
    final modelStr = modelDec.isEmpty ? null : BleLogger.tryUtf8(modelDec)?.trim();

    // 2. Manifest 3 boards (73d50009)
    final mfDec = await readFwSettingRaw(Gatt.boardManifestChar, 'board_manifest');
    final mfStr = mfDec.isEmpty ? null : BleLogger.tryUtf8(mfDec)?.trim();

    // 3. Serial khung xe (041d5a06)
    await readDeviceSerial();

    // 4. Tên xe lưu trong NVS (88c30d2c)
    final fwName = await readFwBikeName();

    // 5. VESC Snapshot 12B = 3 x float32 LE (35a9b4f6)
    double? vI, vV, vDuty;
    final vescDec = await readFwSettingRaw(Gatt.vescSnapshotChar, 'vesc_snapshot');
    if (vescDec.length >= 12) {
      final bd = ByteData.sublistView(vescDec, 0, 12);
      vI = bd.getFloat32(0, Endian.little);
      vV = bd.getFloat32(4, Endian.little);
      vDuty = bd.getFloat32(8, Endian.little);
    }

    state = state.copyWith(
      bikeName: (fwName != null && fwName.isNotEmpty) ? fwName : state.bikeName,
      bikeModelCode: modelStr ?? state.bikeModelCode,
      boardManifest: mfStr ?? state.boardManifest,
      vescCurrent: vI ?? state.vescCurrent,
      vescVoltage: vV ?? state.vescVoltage,
      vescDutyCycle: vDuty ?? state.vescDutyCycle,
    );
  }


  /// log hex + utf8 (và bản decrypt protected nếu có session key) để phân tích
  /// offline — tìm char còi, serial, các giá trị chưa biết. Chạy 1 lần/session,
  /// cách nhau 120ms để không nghẽn GATT.
  Future<void> sniffAllCharacteristics() async {
    if (state.phase != BlePhase.connected) return;
    final chars = state.characteristics
        .where((c) => c.properties.read)
        .toList(growable: false);
    BleLogger.instance.event('sniff_sweep_start', {'chars': chars.length});
    for (final c in chars) {
      try {
        final v = await c
            .read()
            .timeout(const Duration(milliseconds: 1500), onTimeout: () => Uint8List(0));
        if (v.isEmpty) {
          BleLogger.instance.event('sniff_read', {
            'uuid': c.uuid.str128,
            'len': 0,
          });
          continue;
        }
        final utf8s = BleLogger.tryUtf8(v);
        BleLogger.instance.event('sniff_read', {
          'uuid': c.uuid.str128,
          'len': v.length,
          'hex': BleLogger.hex(v, maxBytes: 64),
          'utf8': ?utf8s,
        });
        // Dữ liệu không in được + có session → thử decrypt protected read
        if (_sessionKey != null &&
            v.length >= 4 &&
            utf8s == null) {
          try {
            final dec = BikeSessionCrypto.decryptProtectedRead(
              sessionKey: _sessionKey!,
              characteristicUuid: c.uuid.str128,
              response: v,
            );
            final decStr = dec.isEmpty ? null : BleLogger.tryUtf8(dec);
            BleLogger.instance.event('sniff_read_decrypted', {
              'uuid': c.uuid.str128,
              'hex': BleLogger.hex(dec, maxBytes: 64),
              'utf8': ?decStr,
            });
          } catch (_) {}
        }
      } catch (e) {
        BleLogger.instance.event('sniff_read_err', {
          'uuid': c.uuid.str128,
          'error': '$e',
        });
      }
      await Future.delayed(const Duration(milliseconds: 120));
    }
    BleLogger.instance.event('sniff_sweep_done', {});
  }

  Future<String?> readDeviceSerial() async {
    final dev = _device;
    if (dev == null || state.phase != BlePhase.connected) return null;
    final c = _findCharacteristic(Gatt.deviceSerialChar);
    if (c == null) return null;
    try {
      final raw = await _enqueueGatt(() => c.read());
      // Log raw hex để nghiên cứu offline (serial có thể bị mã hóa session)
      BleLogger.instance.event('device_serial_read_raw', {
        'len': raw.length,
        'hex': BleLogger.hex(raw),
      });

      String? best;

      // (a) Giải mã protected read — char này trả cipher nếu session đang sống
      if (_sessionKey != null && raw.length >= 4) {
        try {
          final dec = BikeSessionCrypto.decryptProtectedRead(
            sessionKey: _sessionKey!,
            characteristicUuid: Gatt.deviceSerialChar,
            response: raw,
            expectedLength: expectedLengthForUuid(Gatt.deviceSerialChar),
          );
          if (dec.isNotEmpty) {
            BleLogger.instance.event('device_serial_read_decrypted', {
              'hex': BleLogger.hex(dec),
            });
            final s = BleLogger.tryUtf8(dec);
            if (s != null && s.trim().isNotEmpty) best = s.trim();
          }
        } catch (_) {}
      }

      // (b) Plain UTF-8 (strip control chars) — dùng khi char trả text thô
      final plain = utf8
          .decode(raw, allowMalformed: true)
          .replaceAll(RegExp(r'[\x00-\x1F\x7F-\x9F]'), '')
          .trim();
      // Ưu tiên kết quả decrypt nếu plain toàn rác mã hóa (tỷ lệ ký tự lạ cao)
      final printable =
          plain.isEmpty ? 0.0 : plain.runes.where((r) => r >= 32 && r <= 126).length / plain.runes.length;
      if (best == null || (plain.isNotEmpty && printable > 0.85 && plain.length >= 4)) {
        best = (printable > 0.85 && plain.isNotEmpty) ? plain : best;
      }

      BleLogger.instance.event('device_serial_read', {
        'serial': best ?? '',
        'source': (best == plain && best != null) ? 'plain' : (best != null ? 'decrypted' : 'none'),
      });
      if (best != null && best.isNotEmpty) {
        state = state.copyWith(frameSerial: best);
        return best;
      }
      return null;
    } catch (e) {
      BleLogger.instance.event('device_serial_read_err', {'error': '$e'});
      return null;
    }
  }

  // ------------------------------------------------------------------
  // FIRMWARE LAB — API kiểm nghiệm char riêng cho màn hình Lab
  // ------------------------------------------------------------------

  BluetoothCharacteristic? _labChar(String uuid) => _findCharacteristic(uuid);

  /// Bật/tắt chế độ LAB (màn Kiểm Nghiệm Firmware đang mở) — ngừng mọi
  /// lệnh tự động để không nhiễm dữ liệu test.
  bool _labModeActive = false;
  void setLabMode(bool active) {
    _labModeActive = active;
    BleLogger.instance.event('lab_mode', {'active': active});
  }

  /// Đọc 1 char bất kỳ: trả raw + bản decrypt protected (nếu có session key).
  Future<LabIoResult> labRead(String uuid, {String? testId}) async {
    final sw = Stopwatch()..start();
    final c = _labChar(uuid);
    if (state.phase != BlePhase.connected || c == null) {
      return _labLog(LabIoResult(
        op: 'read', uuid: uuid, ok: false,
        error: state.phase != BlePhase.connected
            ? 'Xe chưa kết nối'
            : 'Char không có trên GATT table của xe (sai UUID?)',
      ), testId);
    }
    try {
      final raw = await _enqueueGatt(() => c.read().timeout(
          const Duration(milliseconds: 1600), onTimeout: () => Uint8List(0)));
      List<int>? dec;
      String? text;
      String? parsed;

      final cleanUuid = uuid.replaceAll('-', '').toLowerCase();
      final isBeepScan = cleanUuid.startsWith('87efab0d');

      if (isBeepScan) {
        // Cổng 87efab0d (beepScanChar) là PLAIN Read (FUN_4015030c) — token ASCII xoay ngẫu nhiên
        text = utf8.decode(raw, allowMalformed: true);
      } else {
        if (_sessionKey != null && raw.length >= 4) {
          try {
            final expectedLen = expectedLengthForUuid(uuid);
            final d = BikeSessionCrypto.decryptProtectedRead(
              sessionKey: _sessionKey!,
              characteristicUuid: uuid,
              response: raw,
              expectedLength: expectedLen,
            );
            if (d.isNotEmpty) {
              dec = d;
              text = BleLogger.tryUtf8(d);

              // 35a9b4f6: Snapshot VESC 3 x float32 LE [motorCurrent, vescVoltage, dutyCycle]
              if (cleanUuid.startsWith('35a9b4f6') && d.length >= 12) {
                final bd = ByteData.sublistView(Uint8List.fromList(d), 0, 12);
                final motorCurrent = bd.getFloat32(0, Endian.little);
                final vescVoltage = bd.getFloat32(4, Endian.little);
                final dutyCycle = bd.getFloat32(8, Endian.little);
                parsed = 'VESC: I=${motorCurrent.toStringAsFixed(2)}A, '
                    'V=${vescVoltage.toStringAsFixed(2)}V, '
                    'duty=${dutyCycle.toStringAsFixed(3)}';
              }
              // 2c73e84e: Log Buffer Stats 4 x uint32 LE
              else if (cleanUuid.startsWith('2c73e84e') && d.length >= 16) {
                final bd = ByteData.sublistView(Uint8List.fromList(d), 0, 16);
                final s0 = bd.getUint32(0, Endian.little);
                final s1 = bd.getUint32(4, Endian.little);
                final s2 = bd.getUint32(8, Endian.little);
                final s3 = bd.getUint32(12, Endian.little);
                parsed = 'LogBuffer: s0=$s0, s1=$s1, s2=$s2, s3=$s3';
              }
            }
          } catch (_) {}
        }
        text ??= BleLogger.tryUtf8(raw);
      }
      return _labLog(LabIoResult(
        op: 'read', uuid: uuid, ok: true, payload: raw,
        decrypted: dec, text: text, parsed: parsed, elapsedMs: sw.elapsedMilliseconds,
      ), testId);
    } catch (e) {
      return _labLog(LabIoResult(
        op: 'read', uuid: uuid, ok: false, error: '$e',
        elapsedMs: sw.elapsedMilliseconds,
      ), testId);
    }
  }

  /// Ghi PLAIN (không mã hoá) — chọn withoutResponse theo properties char.
  Future<LabIoResult> labWritePlain(String uuid, List<int> data, {String? testId}) async {
    final sw = Stopwatch()..start();
    final c = _labChar(uuid);
    if (state.phase != BlePhase.connected || c == null) {
      return _labLog(LabIoResult(
        op: 'write_plain', uuid: uuid, ok: false,
        error: state.phase != BlePhase.connected
            ? 'Xe chưa kết nối'
            : 'Char không có trên GATT table của xe (sai UUID?)',
      ), testId);
    }
    final noResp = !c.properties.write && c.properties.writeWithoutResponse;
    try {
      await _enqueueGatt(() => c.write(Uint8List.fromList(data), withoutResponse: noResp));
      return _labLog(LabIoResult(
        op: 'write_plain', uuid: uuid, ok: true, payload: data,
        text: BleLogger.tryUtf8(data),
        elapsedMs: sw.elapsedMilliseconds,
      ), testId);
    } catch (e) {
      return _labLog(LabIoResult(
        op: 'write_plain', uuid: uuid, ok: false, error: '$e',
        elapsedMs: sw.elapsedMilliseconds,
      ), testId);
    }
  }

  /// Ghi PROTECTED (frame mã hoá + counter) — cần session key.
  Future<LabIoResult> labWriteProtected(String uuid, List<int> data, {String? testId}) async {
    final sw = Stopwatch()..start();
    final c = _labChar(uuid);
    if (state.phase != BlePhase.connected || c == null) {
      return _labLog(LabIoResult(
        op: 'write_protected', uuid: uuid, ok: false,
        error: state.phase != BlePhase.connected
            ? 'Xe chưa kết nối'
            : 'Char không có trên GATT table của xe (sai UUID?)',
      ), testId);
    }
    if (_sessionKey == null) {
      return _labLog(LabIoResult(
        op: 'write_protected', uuid: uuid, ok: false,
        error: 'Chưa có session key — kết nối và xác thực xe trước',
      ), testId);
    }
    try {
      final frame = BikeSessionCrypto.buildProtectedWrite(
        sessionKey: _sessionKey!,
        counter: _writeCounter++,
        characteristicUuid: uuid,
        data: data,
      );
      await _enqueueGatt(() => c.write(frame, withoutResponse: false));
      return _labLog(LabIoResult(
        op: 'write_protected', uuid: uuid, ok: true, payload: frame,
        elapsedMs: sw.elapsedMilliseconds,
      ), testId, {
        'data_hex': BleLogger.hex(data, maxBytes: 64),
        'data_utf8': BleLogger.tryUtf8(data) ?? '',
        'counter': _writeCounter - 1,
      });
    } catch (e) {
      return _labLog(LabIoResult(
        op: 'write_protected', uuid: uuid, ok: false, error: '$e',
        elapsedMs: sw.elapsedMilliseconds,
      ), testId);
    }
  }

  LabIoResult _labLog(LabIoResult r, String? testId, [Map<String, dynamic>? extra]) {
    BleLogger.instance.event('lab_${r.op}', {
      'test_id': testId,
      'uuid': r.uuid,
      'ok': r.ok,
      if (r.error != null) 'error': r.error,
      if (r.payload.isNotEmpty) 'hex': BleLogger.hex(r.payload, maxBytes: 64),
      if (r.decrypted != null) 'dec_hex': BleLogger.hex(r.decrypted!, maxBytes: 64),
      if (r.decrypted != null) 'dec_utf8': BleLogger.tryUtf8(r.decrypted!) ?? '',
      if (r.text != null) 'utf8': r.text,
      'ms': r.elapsedMs,
      ...?extra,
    });
    return r;
  }

  /// Chuỗi Auto-Secure / Chống trộm: [tắt xe (bất kể trạng thái nếu theft)]
  /// → đợi 2s cho BMS ổn định → BẬT KHÓA AN TOÀN (ARM eec8fd7f).
  /// Đây là NGOẠI LỆ duy nhất được tắt nguồn khi đang chạy (theo cấu hình chủ xe).
  Future<void> _runAutoSecureSequence({
    required bool theft,
    required double speed,
    required double rssi,
  }) async {
    _autoSecureBusy = true;
    try {
      BleLogger.instance.event(
          theft ? 'anti_theft_triggered' : 'auto_secure_triggered',
          {'rssi': rssi, 'speed': speed, 'bike_on': state.lastTelemetry?.isBikeOn});
      // 1. Tắt nguồn
      if (state.lastTelemetry?.isBikeOn == true) {
        try {
          if (theft && speed > 0.5) {
            // Chống trộm khi đang chạy: bypass guard tốc độ (lựa chọn chủ xe),
            // gửi thẳng chuỗi tắt nguồn.
            await _forceSendPowerOff();
          } else {
            await turnOffBike();
          }
        } catch (e) {
          BleLogger.instance.event('auto_secure_power_off_err', {'error': '$e'});
          return; // không ARM nếu không tắt được — tránh khóa khi xe đang cấp nguồn
        }
        await Future.delayed(const Duration(seconds: 2));
      }
      // 2. Bật khóa an toàn
      await setImmobilizer(true);
      state = state.copyWith(
        message: theft
            ? '🚨 CHỐNG TRỘM: thiết bị ở cách xa — xe đã TẮT và KHÓA AN TOÀN.'
            : '🔒 Xe đã TẮT và TỰ KHÓA AN TOÀN (bạn đã rời xa xe).',
      );
    } finally {
      _autoSecureBusy = false;
    }
  }

  /// Tìm cổng BẬT/TẮT NGUỒN THẬT (7f13fe5c — Protected Write: '1' = Bật sáng Taplo, '0' = Tắt nguồn).
  /// Ưu tiên tìm theo UUID 7f13fe5c (Gatt.powerOnOffChar / Gatt.lockBikeChar), fallback sang slot đứng ngay sau 44e2bde6 trong infoService.
  BluetoothCharacteristic? _findPowerCmdChar() {
    final direct = _findCharacteristic(Gatt.powerOnOffChar);
    if (direct != null) return direct;
    final chars = state.characteristics;
    for (var i = 0; i + 1 < chars.length; i++) {
      if (chars[i].uuid.str128.toLowerCase() == Gatt.bikeSerial.toLowerCase()) {
        final next = chars[i + 1];
        if (next.serviceUuid.str128.toLowerCase() ==
                Gatt.infoService.toLowerCase() &&
            (next.properties.write || next.properties.writeWithoutResponse)) {
          return next;
        }
      }
    }
    return null;
  }

  /// Tắt nguồn KHÔNG qua guard tốc độ — chỉ dùng cho luồng chống trộm.
  Future<void> _forceSendPowerOff() async {
    final pwrChar = _findPowerCmdChar();
    if (pwrChar != null && _sessionKey != null) {
      await _enqueueGatt(() async {
        final frame = BikeSessionCrypto.buildProtectedWrite(
          sessionKey: _sessionKey!,
          counter: _writeCounter++,
          characteristicUuid: pwrChar.uuid.str128,
          data: '0'.codeUnits,
        );
        await pwrChar.write(frame, withoutResponse: false);
      });
      BleLogger.instance.event('power_command', {
        'target': 'powerOnOffChar (7f13fe5c)',
        'val': '0',
        'note': 'anti-theft force',
      });
    }
  }

  /// Walk-up: tự MỞ khóa an toàn & tùy chọn BẬT XE SẴN khi user tới gần
  /// Kiểm tra chặt chẽ status thực tế của xe để không bao giờ gửi nhầm lệnh làm tắt xe đang mở.
  Future<void> _runWalkUpUnlockAndPower(double rssi) async {
    final isLocked = state.isLocked;
    final isBikeOn = state.lastTelemetry?.isBikeOn == true;

    BleLogger.instance.event('walk_up_triggered', {
      'rssi': rssi,
      'auto_power': state.walkUpAutoPowerOn,
      'is_locked': isLocked,
      'is_bike_on': isBikeOn,
    });
    try {
      // 1. Chỉ mở khóa bánh nếu xe ĐANG KHÓA AN TOÀN
      if (isLocked) {
        await unlockBike();
        await Future.delayed(const Duration(milliseconds: 350));
      }

      // 2. Chỉ gửi lệnh bật xe nếu user BẬT tính năng walkUpAutoPowerOn VÀ xe ĐANG TẮT
      if (state.walkUpAutoPowerOn) {
        final currentlyOn = state.lastTelemetry?.isBikeOn == true;
        if (!currentlyOn) {
          await turnOnBike();
          state = state.copyWith(
            message: '⚡ Đã tự MỞ KHÓA & BẬT ĐÈN TAPLO XE — Sẵn sàng khởi hành!',
          );
          return;
        }
      }

      if (isLocked) {
        state = state.copyWith(
          message: '🔓 Đã tự MỞ KHÓA BÁNH XE khi lại gần!',
        );
      } else if (isBikeOn) {
        state = state.copyWith(
          message: '✅ Xe đang mở sẵn — Sẵn sàng khởi hành!',
        );
      }
    } catch (e) {
      BleLogger.instance.event('walk_up_err', {'error': '$e'});
    }
  }

  Future<void> setAutoLockWalkAway(bool val) async {
    final prefs = await _prefs;
    await prefs.setBool(_kAutoLockWalkAway, val);
    state = state.copyWith(autoLockWalkAway: val);
  }

  Future<void> setWalkUpUnlock(bool val) async {
    final prefs = await _prefs;
    await prefs.setBool(_kWalkUpUnlock, val);
    state = state.copyWith(walkUpUnlock: val);
  }

  /// Bật/tắt tính năng phụ: Tự động khởi động nguồn xe sẵn khi bước lại gần
  Future<void> setWalkUpAutoPowerOn(bool val) async {
    final prefs = await _prefs;
    await prefs.setBool(_kWalkUpAutoPowerOn, val);
    state = state.copyWith(walkUpAutoPowerOn: val);
    BleLogger.instance.event('walk_up_auto_power_changed', {'enabled': val});
  }

  /// Tùy chỉnh mức sóng RSSI kích hoạt khi đến gần (-45.0 .. -72.0 dBm)
  Future<void> setWalkUpRssiThreshold(double val) async {
    final prefs = await _prefs;
    await prefs.setDouble(_kWalkUpRssiThreshold, val);
    state = state.copyWith(walkUpRssiThreshold: val);
    BleLogger.instance.event('walk_up_rssi_threshold_changed', {'threshold': val});
  }

  /// Tùy chỉnh mức sóng RSSI kích hoạt khi rời xa (-68.0 .. -95.0 dBm)
  /// Bật/tắt tính năng tự động quét & kết nối lại với xe
  Future<void> setAutoReconnect(bool val) async {
    final prefs = await _prefs;
    await prefs.setBool(_kAutoReconnect, val);
    state = state.copyWith(autoReconnect: val);
    if (!val) {
      _cancelReconnect();
    }
  }

  /// Bật/tắt chế độ quét liên tục không giới hạn số lần
  Future<void> setContinuousScan(bool val) async {
    final prefs = await _prefs;
    await prefs.setBool(_kContinuousScan, val);
    state = state.copyWith(continuousScan: val);
  }

  /// Tùy chỉnh số lần quét/kết nối lại tối đa (3, 5, 10, 15)
  Future<void> setReconnectMaxAttempts(int val) async {
    final prefs = await _prefs;
    await prefs.setInt(_kReconnectMaxAttempts, val);
    state = state.copyWith(reconnectMaxAttempts: val);
  }

  /// Tùy chỉnh chu kỳ quét / thời gian giữa các lần thử lại (3s, 5s, 10s, 20s)
  Future<void> setReconnectIntervalSeconds(int val) async {
    final prefs = await _prefs;
    await prefs.setInt(_kReconnectIntervalSeconds, val);
    state = state.copyWith(reconnectIntervalSeconds: val);
  }

  Future<void> setAutoLockRssiThreshold(double val) async {
    final prefs = await _prefs;
    await prefs.setDouble(_kAutoLockRssiThreshold, val);
    int distIndex = 1;
    if (val >= -78.0) {
      distIndex = 0;
    } else if (val <= -88.0) {
      distIndex = 2;
    }
    await prefs.setInt(_kAutoLockDistance, distIndex);
    state = state.copyWith(
      autoLockRssiThreshold: val,
      autoLockDistance: distIndex,
    );
    BleLogger.instance.event('auto_lock_rssi_threshold_changed', {'threshold': val});
  }

  Future<void> setAntiTheft5m(bool val) async {
    final prefs = await _prefs;
    await prefs.setBool(_kAntiTheft5m, val);
    state = state.copyWith(antiTheft5m: val);
  }

  Future<void> setAntiForgetAlert(bool val) async {
    final prefs = await _prefs;
    await prefs.setBool(_kAntiForgetAlert, val);
    state = state.copyWith(antiForgetAlert: val);
  }

  Future<void> setAutoLockDistance(int val) async {
    final prefs = await _prefs;
    await prefs.setInt(_kAutoLockDistance, val);
    const lockThresholds = [-75.0, -83.0, -90.0];
    final rssi = lockThresholds[val.clamp(0, 2)];
    await prefs.setDouble(_kAutoLockRssiThreshold, rssi);
    state = state.copyWith(
      autoLockDistance: val,
      autoLockRssiThreshold: rssi,
    );
  }

  Future<void> setAntiForgetDistance(int val) async {
    final prefs = await _prefs;
    await prefs.setInt(_kAntiForgetDistance, val);
    state = state.copyWith(antiForgetDistance: val);
  }

  Future<void> resetTrip() async {
    await _archiveCurrentTripIfMeaningful();
    TripGpsTracker.instance.clear();
    _tripStartOdo = state.lastTelemetry?.odo;
    _tripStartTime = DateTime.now();
    _tripStartPercent = state.lastTelemetry?.percent;
    _tripMaxSpeed = 0.0;
    _tripSpeedSum = 0.0;
    _tripSpeedSamples = 0;
    state = state.copyWith(
      trip: TripData(powerKw: state.trip.powerKw),
    );
  }

  Stream<BikeTelemetry> get telemetry => _telemetry.stream;

  BluetoothDevice? get _device => state.device;

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  // ------------------------------------------------------------------
  // Kết nối
  // ------------------------------------------------------------------

  Future<void> connect(BluetoothDevice device, {String? name}) async {
    if (state.phase == BlePhase.connected &&
        state.isAuthorized &&
        state.device?.remoteId == device.remoteId) {
      return;
    }
    _manualDisconnect = false;
    _writeCounter = 0;
    _cancelReconnect();
    state = BleState(phase: BlePhase.connecting, device: device, bikeName: name);
    unawaited(ForegroundService.start(
      title: 'Dat Bike',
      text: 'Đang kết nối với ${name ?? device.platformName}...',
    ));
    await BleLogger.instance.startSession();
    BleLogger.instance.event('connect_start', {
      'device_id': device.remoteId.str,
      'name': name ?? device.platformName,
    });
    // Health-check storage trước khi vào BLE: shared_preferences hỏng (vd
    // NoSuchMethodError getAll khi cài đè APK bẩn) sẽ nổ ngay trong handshake
    // khi đọc password đã lưu — phải báo đúng bệnh thay vì "kết nối xe thất bại".
    try {
      await _prefs;
    } catch (e, st) {
      BleLogger.instance.event('prefs_broken', {'error': '$e'});
      await BleLogger.logAppError('prefs_connect', e, st);
      state = state.copyWith(
        phase: BlePhase.disconnected,
        message: 'Lỗi bộ nhớ app (shared_preferences): $e\n'
            '→ Gỡ app rồi cài lại APK mới.',
      );
      unawaited(ForegroundService.stop());
      throw Exception(
          'Lỗi bộ nhớ app (shared_preferences) — gỡ app và cài lại APK mới. '
          'Chi tiết: $e');
    }
    // Auth bị từ chối sau kill-app: xe giữ session-lock một khoảng ngắn
    // (quan sát thực tế: còn khoá ở +10s, mở ở +35s). DÒ DẦY mỗi 3s (15 vòng
    // ≈ 45s) để vào ngay khoảnh khắc xe mở khoá — app gốc cũng chỉ nhanh vì
    // nối lại liên tục.
    var recovered = false;
    for (var cycle = 1; cycle <= 5 && !recovered; cycle++) {
      if (cycle > 1) {
        state = state.copyWith(
          phase: BlePhase.reconnecting,
          message: 'Xe giữ khoá phiên sau lần kết nối bị đứt — đang thử lại '
              '($cycle/5, mỗi 3s)...',
        );
        BleLogger.instance
            .event('auth_recovery_wait', {'cycle': cycle, 'delay_s': 3});
        _manualDisconnect = true; // chặn reconnect scheduler đua
        _recoveryDisconnect = true; // giữ logger sống
        try {
          await device.disconnect();
        } catch (_) {}
        await Future.delayed(const Duration(seconds: 3));
        _recoveryDisconnect = false;
        _manualDisconnect = false;
      }
      var ok = false;
      try {
        ok = await _establish(device);
      } catch (e) {
        BleLogger.instance.event('establish_err', {'cycle': cycle, 'error': '$e'});
        ok = false;
      }
      if (ok && state.isAuthorized) {
        await _saveLastBike(device, name);
        _watchConnection(device);
        state = state.copyWith(phase: BlePhase.connected, isAuthorized: true, message: null);
        unawaited(ForegroundService.start(
          title: 'Dat Bike: ${state.bikeName ?? device.platformName}',
          text: 'Đã kết nối Bluetooth — Sẵn sàng điều khiển',
        ));
        _failStreak = 0;
        recovered = true;
      }
    }
    if (recovered) return;
    try {
      final ok = await _establish(device);
      if (ok && state.isAuthorized) {
        await _saveLastBike(device, name);
        _watchConnection(device);
        state = state.copyWith(phase: BlePhase.connected, isAuthorized: true, message: null);
        unawaited(ForegroundService.start(
          title: 'Dat Bike: ${state.bikeName ?? device.platformName}',
          text: 'Đã kết nối Bluetooth — Sẵn sàng điều khiển',
        ));
        _failStreak = 0;
        return;
      } else {
        throw Exception(state.message ?? 'Không thể xác thực phiên xe sau 5 chu kỳ thử lại');
      }
    } catch (e) {
      BleLogger.instance.event('connect_failed', {'error': '$e'});
      state = state.copyWith(
          phase: BlePhase.disconnected, message: 'Kết nối thất bại: $e');
      unawaited(ForegroundService.stop());
      rethrow;
    }
  }

  Future<bool> _establish(BluetoothDevice device) async {
    // Auto-connect khi mở app (tryRestoreLastBike) và reconnect scheduler đi
    // THẲNG vào _establish, không qua connect() — nếu không tự mở session log
    // thì toàn bộ event của phiên tự động kết nối bị mất (sink null, event()
    // bỏ lặng lẽ). Chỉ mở khi chưa có session để không đẻ file mỗi lần retry.
    if (!BleLogger.instance.active) {
      await BleLogger.instance.startSession();
      BleLogger.instance.event('auto_session_start', {
        'device_id': device.remoteId.str,
        'name': device.platformName,
      });
    }
    // Mutex: nếu một handshake đang chạy (recovery loop đua với reconnect
    // scheduler…), không chạy chồng — log 19:02 cho thấy 2 flow song song
    // đăng ký 2 password khác nhau làm session key loạn hoàn toàn.
    if (_establishBusy) {
      BleLogger.instance.event('establish_skipped', {'reason': 'busy'});
      return state.isAuthorized;
    }
    _establishBusy = true;
    try {
      return await _establishInner(device);
    } finally {
      _establishBusy = false;
    }
  }

  Future<void> _connectWithCachePrime(
    BluetoothDevice device, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    // 1. Kiểm tra nếu thiết bị đã được kết nối ở cấp độ OS (Android/iOS)
    final alreadyConnected = FlutterBluePlus.connectedDevices
        .any((d) => d.remoteId == device.remoteId);
    if (alreadyConnected) {
      try {
        await device.connect(
          license: License.nonprofit,
          timeout: const Duration(seconds: 4),
          autoConnect: false,
        );
        return;
      } catch (_) {}
    }

    // 2. Chờ adapter Bluetooth bật nếu vừa mở app
    try {
      if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
        await FlutterBluePlus.adapterState
            .where((s) => s == BluetoothAdapterState.on)
            .first
            .timeout(const Duration(seconds: 4));
      }
    } catch (_) {}

    // 3. Scan nhanh có RemoteId để làm mới BLE cache và connection window của Android
    try {
      if (!FlutterBluePlus.isScanningNow) {
        StreamSubscription? scanSub;
        final completer = Completer<void>();
        scanSub = FlutterBluePlus.scanResults.listen((results) {
          if (results.any((r) => r.device.remoteId == device.remoteId)) {
            if (!completer.isCompleted) completer.complete();
          }
        });
        await FlutterBluePlus.startScan(
          withRemoteIds: [device.remoteId.str],
          timeout: const Duration(seconds: 3),
          androidScanMode: AndroidScanMode.lowLatency,
        );
        await completer.future.timeout(
          const Duration(seconds: 3),
          onTimeout: () {},
        );
        await scanSub.cancel();
      }
    } catch (_) {
    } finally {
      if (FlutterBluePlus.isScanningNow) {
        try {
          await FlutterBluePlus.stopScan();
        } catch (_) {}
      }
    }

    // 4. Kết nối trực tiếp sau khi cache đã được làm mới
    await device.connect(
      license: License.nonprofit,
      timeout: timeout,
      autoConnect: false,
    );
  }

  Future<bool> _establishInner(BluetoothDevice device) async {
    await _connectWithCachePrime(device);
    BleLogger.instance.event('connected', {'device_id': device.remoteId.str});
    _writeCounter = 0;
    int mtu = 23;
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        mtu = await device.requestMtu(Gatt.androidMtu);
      } catch (_) {}
    }
    BleLogger.instance.event('mtu', {'mtu': mtu});

    final services = await device.discoverServices();

    // BẢNG GATT ĐẦY ĐỦ — dữ liệu vàng để hoàn thiện bản đồ UUID.
    final gattTable = <Map<String, Object?>>[];
    for (final service in services) {
      gattTable.add({
        'service': service.uuid.str128.toLowerCase(),
        'characteristics': [
          for (final c in service.characteristics)
            {
              'uuid': c.uuid.str128.toLowerCase(),
              'properties': [
                if (c.properties.read) 'read',
                if (c.properties.write) 'write',
                if (c.properties.writeWithoutResponse) 'writeNoResp',
                if (c.properties.notify) 'notify',
                if (c.properties.indicate) 'indicate',
              ],
            },
        ],
      });
    }
    BleLogger.instance.event('gatt_table', {'services': gattTable});

    // expose cho AuthProbe / Phase 2
    final allChars = <BluetoothCharacteristic>[];
    for (final s in services) {
      allChars.addAll(s.characteristics);
    }
    state = state.copyWith(device: device, characteristics: allChars);

    // Đọc firmware version — char duy nhất app gốc đọc trước handshake.
    // Xe yêu cầu link đã bond/mã hoá: chưa bond sẽ bị err 0x05/137
    // (Insufficient Authentication) — thấy rõ trong btsnoop máy Samsung.
    for (final service in services) {
      for (final c in service.characteristics) {
        if (c.uuid.str128.toLowerCase() != Gatt.firmwareVersion.toLowerCase()) {
          continue;
        }
        try {
          final value = await c.read();
          BleLogger.instance.event('char_read', {
            'uuid': Gatt.firmwareVersion,
            'len': value.length,
            'hex': BleLogger.hex(value),
            'utf8': BleLogger.tryUtf8(value),
          });
        } catch (e) {
          BleLogger.instance.event('char_read_error', {
            'uuid': Gatt.firmwareVersion,
            'error': '$e',
          });
          if (_isAuthError(e)) {
            await _ensureBonded(device, reason: 'fw char bị err auth');
            try {
              final value = await c.read();
              BleLogger.instance.event('char_read', {
                'uuid': Gatt.firmwareVersion,
                'len': value.length,
                'hex': BleLogger.hex(value),
                'utf8': BleLogger.tryUtf8(value),
              });
            } catch (_) {}
          }
        }
      }
    }

    // Tự động kích hoạt bắt tay xác thực phiên xe (Phase 1 + 2) ngay khi kết nối
    await authenticateSession(targetDevice: device, chars: allChars);

    // Dashboard — ĐÃ XÁC MINH TRÊN XE THẬT: characteristic 6d2eb205 chỉ có
    // read/write, KHÔNG có notify. App gốc POLL đọc định kỳ
    // (DASHBOARD_REFRESH_INTERVAL), không subscribe.
    for (final service in services) {
      if (service.uuid.str128.toLowerCase() != Gatt.dashboardService) continue;
      for (final c in service.characteristics) {
        if (c.uuid.str128.toLowerCase() != Gatt.dashboardCharacteristic) continue;
        _dashChar = c;
        if (c.properties.notify) {
          // phòng xa: firmware tương lai thêm notify thì dùng notify
          await c.setNotifyValue(true);
          BleLogger.instance.event('notify_subscribed', {
            'uuid': c.uuid.str128.toLowerCase(),
          });
          _notifySub?.cancel();
          _notifySub = c.lastValueStream.listen((List<int> raw) {
            BleLogger.instance.event('notify', {
              'uuid': c.uuid.str128.toLowerCase(),
              'len': raw.length,
              'hex': BleLogger.hex(raw),
            });
            _handleDashboardPayload(raw);
          });
        }
      }
    }

    // Poll 1 giây/lần (giữ GATT sống + nhận telemetry). Blob mã hoá trước
    // handshake là hành vi xe gốc — cờ dashboardEncrypted báo lên UI.
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
        Duration(milliseconds: Gatt.dashboardPollMs), (_) => _pollDashboard());
    await _pollDashboard(); // đọc ngay 1 lần
    if (state.isAuthorized) {
      unawaited(refreshFwSettings());
      unawaited(fetchVehicleDiagnostics());
    }
    return state.isAuthorized;
  }

  Future<void> _pollDashboard() async {
    final c = _dashChar;
    if (c == null || state.phase != BlePhase.connected) return;
    // Watchdog: nếu đã xác thực mà keepalive chưa chạy (bất kỳ path nào làm
    // nó tắt/lỡ start) → tự khởi động lại. Đây là linh kiện giữ kết nối
    // không thẻ — phải luôn sống khi session sống.
    if (enableKeepalive &&
        state.isAuthorized &&
        _keepaliveTimer == null &&
        _activePassword.isNotEmpty &&
        _lastAuthNonce15 != null) {
      BleLogger.instance.event('keepalive_watchdog_restart', {});
      _startKeepalive();
    }
    try {
      final raw = await _enqueueGatt(() => c.read());
      _handleDashboardPayload(raw);
    } catch (e) {
      BleLogger.instance.event('poll_error', {'error': '$e'});
    }

    // Định kỳ đọc Battery Log (207 byte) mỗi 3 chu kỳ đo
    _batteryPollCounter++;
    if (_batteryPollCounter >= 3) {
      _batteryPollCounter = 0;
      unawaited(fetchBatteryDetails());
    }

    try {
      final dev = _device;
      if (dev != null) {
        final curRssi = await dev.readRssi();
        final filtered = _rssiKalman.filter(curRssi.toDouble());
        _smoothedRssi = filtered;
        state = state.copyWith(
          rssi: curRssi,
          filteredRssi: filtered.round(),
        );
        _checkAutoLockAndAlert();
      }
    } catch (_) {}
  }

  void _checkAutoLockAndAlert() {
    // LAB MODE: đang kiểm nghiệm char — TẤT TẢI mọi lệnh tự động (auto-lock,
    // anti-forget) phải ngừng để không chen lệnh '0' vào giữa chuỗi test
    // (log 17:45 23/10: auto-lock gửi power '0' xen giữa find-bike → dữ liệu
    // test bị nhiễm).
    if (_labModeActive) return;
    if (_smoothedRssi == null) return;
    final rssi = _smoothedRssi!;
    final isBikeOn = state.lastTelemetry?.isBikeOn == true;
    final isLocked = state.isLocked;
    final speed = state.lastTelemetry?.speed ?? 0.0;

    // Theo dõi xem user đã từng ở gần xe trong phiên kết nối này chưa
    final nearThreshold = state.walkUpRssiThreshold ?? -55.0;
    if (rssi >= nearThreshold) {
      _hasBeenNearBike = true;
    }

    // Bảo hộ 15 giây đầu sau khi vừa kết nối: tuyệt đối không kích hoạt auto-lock hay chống trộm,
    // vì lúc mới kết nối từ xa, RSSI ban đầu luôn yếu và user đang tiến lại gần xe!
    final justConnected = _connectedAt != null &&
        DateTime.now().difference(_connectedAt!) < const Duration(seconds: 15);

    // ===== TỰ ĐỘNG THEO CỰ LY =====
    final userRecent = _lastUserCommandAt != null &&
        DateTime.now().difference(_lastUserCommandAt!) < const Duration(seconds: 10);
    final autoAllowed = !_autoSecureBusy && !_isCommandBusy && !userRecent && !justConnected;

    // (c) CHỐNG TRỘM ≥5m: Chỉ kích hoạt khi user ĐÃ TỪNG Ở GẦN XE và sau đó rời xa
    if (state.antiTheft5m && autoAllowed && isBikeOn && _hasBeenNearBike) {
      if (rssi <= -78) {
        _theftCounter++;
        if (_theftCounter >= 5) {
          _theftCounter = 0;
          _hasBeenNearBike = false;
          unawaited(_runAutoSecureSequence(theft: true, speed: speed, rssi: rssi));
        }
      } else {
        _theftCounter = 0;
      }
    } else {
      _theftCounter = 0;
    }

    // (a) AUTO-SECURE rời xa: Chỉ kích hoạt khi user ĐÃ TỪNG Ở GẦN XE và sau đó đi ra xa
    if (state.autoLockWalkAway && autoAllowed && isBikeOn && speed <= 0.5 && _hasBeenNearBike) {
      const lockThresholds = [-75.0, -83.0, -90.0];
      final targetThreshold = state.autoLockRssiThreshold ??
          lockThresholds[state.autoLockDistance.clamp(0, 2)];
      if (rssi <= targetThreshold) {
        _autoLockCounter++;
        if (_autoLockCounter >= 3) {
          _autoLockCounter = 0;
          _hasBeenNearBike = false;
          unawaited(_runAutoSecureSequence(theft: false, speed: speed, rssi: rssi));
        }
      } else {
        _autoLockCounter = 0;
      }
    } else {
      _autoLockCounter = 0;
    }

    // (b) WALK-UP UNLOCK & BẬT XE SẴN KHI TỚI GẦN
    if (state.walkUpUnlock && autoAllowed) {
      // KIỂM TRA STATUS THỰC TẾ:
      // Chỉ thực hiện khi xe đang khóa hoặc (muốn tự bật điện và xe đang tắt).
      // Nếu xe ĐÃ MỞ SẴN (không khóa và đã bật) -> Tuyệt đối không gửi lệnh tắt hay bật lại!
      final needsUnlock = isLocked;
      final needsPower = state.walkUpAutoPowerOn && !isBikeOn;

      if (needsUnlock || needsPower) {
        if (rssi >= nearThreshold) {
          _unlockNearCounter++;
          if (_unlockNearCounter >= 2) {
            _unlockNearCounter = 0;
            unawaited(_runWalkUpUnlockAndPower(rssi));
          }
        } else {
          _unlockNearCounter = 0;
        }
      } else {
        _unlockNearCounter = 0;
      }
    } else {
      _unlockNearCounter = 0;
    }

    // 2. Walk-Up Proximity: Khi bước lại gần -> thông báo sẵn sàng
    final proximityNoticeThreshold = (state.walkUpRssiThreshold != null)
        ? (state.walkUpRssiThreshold! - 8.0)
        : -65.0;
    if (_smoothedRssi! > proximityNoticeThreshold) {
      if (!_walkUpTriggered) {
        _walkUpTriggered = true;
        BleLogger.instance.event('walk_up_ready', {'rssi': _smoothedRssi});
        state = state.copyWith(
          message: state.walkUpAutoPowerOn
              ? '👋 Đã lại gần xe! Đang tự động sẵn sàng khởi hành.'
              : '👋 Đã lại gần xe! Sẵn sàng vận hành.',
        );
      }
    } else if (_smoothedRssi! < ((state.autoLockRssiThreshold ?? -83.0) + 5.0)) {
      // Tái vũ trang cờ khi đã rời xa
      _walkUpTriggered = false;
    }

    // 3. Cảnh báo quên tắt xe khi rời xa (Anti-Forget Alert):
    if (state.antiForgetAlert && isBikeOn) {
      const alertThresholds = [-80, -88, -94];
      final threshold = alertThresholds[state.antiForgetDistance.clamp(0, 2)];
      if (_smoothedRssi! <= threshold) {
        _antiForgetCounter++;
        if (_antiForgetCounter == 3) {
          BleLogger.instance.event('anti_forget_alert_triggered', {
            'smoothed_rssi': _smoothedRssi,
            'threshold': threshold,
          });
          state = state.copyWith(
            message: '⚠️ CẢNH BÁO: Bạn đang rời xa nhưng xe vẫn đang BẬT nguồn!',
          );
        }
      } else {
        _antiForgetCounter = 0;
      }
    } else {
      _antiForgetCounter = 0;
    }
  }
  /// Kiểm tra dữ liệu telemetry có nằm trong giới hạn vật lý hợp lý của xe không.
  /// Nếu giải mã sai key (keystream rác), IEEE 754 float sẽ sinh ra số vô lý (NaN, âm, 10^30,...).
  bool _isTelemetrySane(BikeLogMsg msg) {
    if (msg.speed.isNaN || msg.speed < 0 || msg.speed > 250) return false;
    if (msg.odo.isNaN || msg.odo < 0 || msg.odo > 500000) return false;
    if (msg.voltage.isNaN || msg.voltage < 10 || msg.voltage > 130) return false;
    if (msg.percent < 0 || msg.percent > 100) return false;
    if (msg.kmLeft.isNaN || msg.kmLeft < 0 || msg.kmLeft > 500) return false;
    return true;
  }

  /// Kiểm tra xem gói tin thô sau khi giải mã với sessionKey có phải struct hợp lệ không.
  bool _isValidTelemetry(Uint8List sessionKey, List<int> raw) {
    if (raw.length < 4) return false;
    try {
      final decrypted = BikeSessionCrypto.decryptProtectedRead(
        sessionKey: sessionKey,
        characteristicUuid: Gatt.dashboardCharacteristic,
        response: raw,
      );
      if (decrypted.length >= 41) {
        final m = decodeDashboardStruct(decrypted);
        return _isTelemetrySane(m);
      }
    } catch (_) {}
    return false;
  }

  BluetoothCharacteristic? _findCharacteristic(String uuid) {
    final clean = uuid.toLowerCase().replaceAll('-', '');
    for (final c in state.characteristics) {
      if (c.uuid.str128.toLowerCase().replaceAll('-', '') == clean) return c;
    }
    return null;
  }

  void _handleBatteryPayload(List<int> raw) {
    if (raw.isEmpty) return;
    Uint8List payload = Uint8List.fromList(raw);

    // 1. Thử decode trực tiếp (Plain Protobuf hoặc JSON UTF-8) như app gốc Dat Bike (Br.d)
    try {
      final directMsg = decodeBatteryLogMsg(payload);
      if (directMsg.cellVols.isNotEmpty || directMsg.voltage > 0) {
        state = state.copyWith(lastBattery: directMsg);
        BleLogger.instance.event('battery_log_received_plain', {
          'voltage': directMsg.voltage,
          'current': directMsg.current,
          'cells': directMsg.cellVols.length,
          'balancing': directMsg.balancing,
          'protection': directMsg.protection,
        });
        return;
      }
    } catch (_) {}

    // 2. Nếu payload bị mã hoá session key (Protected Read) -> Thực hiện giải mã
    if (_sessionKey != null) {
      try {
        final decrypted = BikeSessionCrypto.decryptProtectedRead(
          sessionKey: _sessionKey!,
          characteristicUuid: Gatt.batteryLogCharacteristic,
          response: raw,
          expectedLength: 207,
        );
        if (decrypted.isNotEmpty) {
          final bMsg = decodeBatteryLogMsg(decrypted);
          state = state.copyWith(lastBattery: bMsg);
          BleLogger.instance.event('battery_log_received_decrypted', {
            'voltage': bMsg.voltage,
            'current': bMsg.current,
            'cells': bMsg.cellVols.length,
            'balancing': bMsg.balancing,
            'protection': bMsg.protection,
          });
          return;
        }
      } catch (e) {
        BleLogger.instance.event('battery_decode_err', {'error': '$e'});
      }
    }
  }

  /// Đọc dữ liệu chi tiết Battery Log (207 byte) từ xe
  Future<void> fetchBatteryDetails() async {
    final dev = _device;
    if (dev == null || state.phase != BlePhase.connected) return;
    _batteryChar ??= _findCharacteristic(Gatt.batteryLogCharacteristic);
    final bChar = _batteryChar;
    if (bChar == null) return;
    try {
      final raw = await _enqueueGatt(() => bChar.read());
      _handleBatteryPayload(raw);
    } catch (e) {
      BleLogger.instance.event('battery_read_err', {'error': '$e'});
    }
  }

  void _handleDashboardPayload(List<int> raw) {
    // Piggyback chẩn đoán vào chính event này (luôn chạy): plain = hex sau
    // giải mã, dk = tóm tắt decode dạng string — None nếu chưa có key.
    String? plainHex;
    Uint8List payloadToDecode = Uint8List.fromList(raw);
    if (_sessionKey != null) {
      try {
        final decrypted = BikeSessionCrypto.decryptProtectedRead(
          sessionKey: _sessionKey!,
          characteristicUuid: Gatt.dashboardCharacteristic,
          response: raw,
          expectedLength: 41,
        );
        if (decrypted.isNotEmpty) {
          payloadToDecode = decrypted;
          plainHex = BleLogger.hex(decrypted, maxBytes: 96);
        }
      } catch (_) {}
    }

    String? dk;
    try {
      // 6d2eb205 = struct thô 41B (không phải protobuf) — decode struct;
      // nếu sau này char đổi sang protobuf thật thì fallback tự động.
      final msg = (payloadToDecode.length >= 36)
          ? decodeDashboardStruct(payloadToDecode)
          : decodeBikeLogMsg(payloadToDecode);

      // Kiểm tra tính hợp lý của Telemetry trước khi cập nhật state
      if (!_isTelemetrySane(msg)) {
        _decodeFailStreak++;
        BleLogger.instance.event('dashboard_insane_telemetry', {
          'streak': _decodeFailStreak,
          'speed': msg.speed,
          'odo': msg.odo,
          'volts': msg.voltage,
          'percent': msg.percent,
        });
        if (_decodeFailStreak >= 3) {
          state = state.copyWith(dashboardEncrypted: true);
          // Session key bị lệch với xe -> tự động re-authenticate để đồng bộ lại trong nền
          if (state.phase == BlePhase.connected && !_establishBusy && _device != null) {
            BleLogger.instance.event('session_resync_triggered', {'reason': 'telemetry_corrupted'});
            unawaited(authenticateSession(targetDevice: _device, chars: state.characteristics));
          }
        }
        return;
      }

      _decodeFailStreak = 0;
      if (state.dashboardEncrypted) {
        state = state.copyWith(dashboardEncrypted: false);
      }

      if (payloadToDecode.length >= 41) {
        final b12 = payloadToDecode[12];
        final bd = ByteData.sublistView(payloadToDecode);
        final b13_14 = bd.getUint16(13, Endian.little);
        final b32 = payloadToDecode[32];
        final sig = '$b12:$b13_14:$b32';
        if (sig != _lastRawStatusSig) {
          _lastRawStatusSig = sig;
          BleLogger.instance.event('dashboard_raw_status_bytes', {
            'byte12': b12,
            'byte13_14': b13_14,
            'byte32': b32,
            'mode': msg.drivingModeLabel,
            'parking': msg.parking,
            'speed': msg.speed,
          });
        }
      }

      dk = 'st=${msg.state.name} sp=${msg.speed} odo=${msg.odo} '
          'km=${msg.kmLeft} ecu=${msg.ecu} mot=${msg.motor} '
          'fw=${msg.version} model=${msg.model}';

      // Cập nhật GPS tracker & chế độ lái xe (Chỉ ghi GPS khi ở D hoặc S và không gạt chân chống)
      final isDriveMode = (msg.state == BikeState.drive || msg.state == BikeState.super_) && !msg.parking;
      TripGpsTracker.instance.setDriveMode(isDriveMode);
      TripGpsTracker.instance.updateBikeSpeed(msg.speed);
      if (!TripGpsTracker.instance.isTracking && isDriveMode) {
        unawaited(TripGpsTracker.instance.startTracking());
      }

      // Cập nhật máy tính chuyến đi (Trip Computer) & Công suất tức thời
      _tripStartTime ??= DateTime.now();
      if (_tripStartOdo == null && msg.odo > 0) _tripStartOdo = msg.odo;
      if (_tripStartPercent == null && msg.percent > 0) _tripStartPercent = msg.percent;

      final dist = (msg.odo > 0 && _tripStartOdo != null)
          ? max(0.0, msg.odo - _tripStartOdo!)
          : state.trip.distanceKm;
      final dur = DateTime.now().difference(_tripStartTime!);
      if (msg.speed > _tripMaxSpeed) _tripMaxSpeed = msg.speed;
      if (msg.speed > 0.5) {
        _tripSpeedSum += msg.speed;
        _tripSpeedSamples++;
      }
      final avgSpd = _tripSpeedSamples > 0 ? (_tripSpeedSum / _tripSpeedSamples) : 0.0;
      final usedPct = (_tripStartPercent != null && msg.percent > 0)
          ? max(0, _tripStartPercent! - msg.percent)
          : 0;
      final pKw = (msg.voltage > 0) ? ((msg.voltage * msg.phase) / 1000.0) : 0.0;

      final currentTrip = TripData(
        distanceKm: dist,
        duration: dur,
        avgSpeedKmh: avgSpd,
        maxSpeedKmh: _tripMaxSpeed,
        usedPercent: usedPct,
        powerKw: pKw,
      );

      String? autoSerial = state.frameSerial;
      if (autoSerial == null && msg.frame.isNotEmpty) {
        final clean = msg.frame.replaceAll(RegExp(r'[\x00-\x1F\x7F-\x9F]'), '').trim();
        if (clean.isNotEmpty) autoSerial = clean;
      }

      state = state.copyWith(lastTelemetry: msg, trip: currentTrip, frameSerial: autoSerial);
      _telemetry.add(BikeTelemetry(msg, DateTime.now()));
    } catch (e) {
      _decodeFailStreak++;
      dk = 'parse_fail: $e';
      if (_decodeFailStreak >= 3) {
        state = state.copyWith(dashboardEncrypted: true);
      }
    }

    final n = _plainLogCount++;
    final detail = n < 3 || n % 20 == 0;
    BleLogger.instance.event('dashboard_payload', {
      'len': raw.length,
      'hex': detail ? BleLogger.hex(raw, maxBytes: 64) : null,
      'plain': detail ? plainHex : null,
      'dk': detail ? dk : null,
    });
  }

  /// Tự kết nối lại xe lần trước khi mở app.
  Future<bool> tryRestoreLastBike() async {
    if (_restoreBusy) return state.phase == BlePhase.connected;
    if (state.phase == BlePhase.connected || state.phase == BlePhase.connecting) return true;
    _restoreBusy = true;
    try {
      final SharedPreferences prefs;
      try {
        prefs = await _prefs;
      } catch (e, st) {
        await BleLogger.logAppError('prefs_restore', e, st);
        state = state.copyWith(
          phase: BlePhase.disconnected,
          message: 'Không đọc được bộ nhớ app (shared_preferences): $e\n'
              '→ Gỡ app rồi cài lại APK mới.',
        );
        return false;
      }
      final id = prefs.getString(_kLastBikeId);
      if (id == null || id.isEmpty) {
        return false;
      }
      if (state.phase == BlePhase.connected || state.phase == BlePhase.connecting) return true;

      // Đảm bảo đủ quyền BLE trên Android
      await BlePermissions.ensure();

      // Chờ Bluetooth bật nếu vừa mở app
      try {
        if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
          state = state.copyWith(
            phase: BlePhase.connecting,
            message: 'Đang đợi Bluetooth bật…',
          );
          await FlutterBluePlus.adapterState
              .where((s) => s == BluetoothAdapterState.on)
              .first
              .timeout(const Duration(seconds: 4));
        }
      } catch (_) {}

      final name = prefs.getString(_kLastBikeName) ?? 'Xe Dat Bike';
      BluetoothDevice device = BluetoothDevice.fromId(id);
      final connectedMatch = FlutterBluePlus.connectedDevices
          .where((d) => d.remoteId.str == id)
          .firstOrNull;
      if (connectedMatch != null) {
        device = connectedMatch;
      }

      _reconnectAttempts = 0;
      state = state.copyWith(
        phase: BlePhase.connecting,
        device: device,
        bikeName: name,
        message: 'Đang kết nối với xe $name…',
      );
      try {
        final ok = await _establish(device);
        if (ok && state.isAuthorized) {
          await _saveLastBike(device, name);
          _watchConnection(device);
          state = state.copyWith(phase: BlePhase.connected, reconnectAttempt: 0, message: null);
          unawaited(ForegroundService.start(
            title: 'Dat Bike: $name',
            text: 'Đã kết nối Bluetooth — Sẵn sàng điều khiển',
          ));
          return true;
        }
      } catch (e) {
        BleLogger.instance.event('restore_attempt_failed', {'error': '$e'});
      }

      // Xe chưa ở gần hoặc chưa bật nguồn: chuyển sang reconnect loop nếu autoReconnect bật
      if (state.autoReconnect) {
        _scheduleReconnect(device);
      } else {
        state = state.copyWith(
          phase: BlePhase.disconnected,
          message: 'Không tìm thấy xe $name. Bấm "Kết nối lại" khi ở gần xe.',
        );
      }
      return false;
    } finally {
      _restoreBusy = false;
    }
  }

  /// Chờ tối thiểu 300ms kể từ lần gửi lệnh trước để bảo đảm MCU và CAN bus
  /// truyền tin cậy tới BMS, không bị nghẽn mailbox hoặc rớt gói tin BMS.
  Future<void> _throttleCommand() async {
    if (_lastCommandCompletedAt != null) {
      final elapsed = DateTime.now().difference(_lastCommandCompletedAt!);
      const minInterval = Duration(milliseconds: 300);
      if (elapsed < minInterval) {
        final waitMs = minInterval.inMilliseconds - elapsed.inMilliseconds;
        BleLogger.instance.event('cmd_throttle_wait', {'wait_ms': waitMs});
        await Future.delayed(Duration(milliseconds: waitMs));
      }
    }
  }

  /// Chờ nếu đang có lệnh BLE trước đó chưa hoàn tất (tránh văng Exception làm đứt auto-lock).
  Future<void> _waitWhileCommandBusy({int maxWaitMs = 2500}) async {
    var waited = 0;
    while (_isCommandBusy && waited < maxWaitMs) {
      await Future.delayed(const Duration(milliseconds: 100));
      waited += 100;
    }
  }

  /// Lệnh BẬT XE — theo flow app gốc trong btsnoop 16:16:34:
  /// plain '1' (0x31) vào POWER_SWITCH_CHAR khi có session key.
  /// Chỉ gửi khi ĐÃ xác thực. CHẶN khi xe đang KHÓA AN TOÀN.
  Future<void> turnOnBike() async {
    _lastUserCommandAt = DateTime.now();
    if (state.isLocked) {
      state = state.copyWith(
          message: 'Xe đang KHÓA AN TOÀN — bấm MỞ KHÓA (hoặc quẹt thẻ NFC) trước khi bật xe');
      BleLogger.instance.event('power_blocked', {
        'reason': 'xe đang khóa an toàn (ARM) — phải mở khóa trước',
      });
      throw Exception('Xe đang khóa an toàn — mở khóa trước khi bật');
    }
    await _waitWhileCommandBusy();
    if (_isCommandBusy) {
      throw Exception('Xe đang xử lý lệnh trước đó, vui lòng đợi 1 giây...');
    }
    await _throttleCommand();
    _isCommandBusy = true;
    try {
      await _sendPowerCommand('1', 'MỞ XE');
    } finally {
      _isCommandBusy = false;
      _lastCommandCompletedAt = DateTime.now();
    }
  }

  /// Lệnh TẮT XE — plain '0' (0x30) + protected '0'.
  Future<void> turnOffBike() async {
    _lastUserCommandAt = DateTime.now();
    await _waitWhileCommandBusy();
    if (_isCommandBusy) {
      throw Exception('Xe đang xử lý lệnh trước đó, vui lòng đợi 1 giây...');
    }
    await _throttleCommand();
    _isCommandBusy = true;
    try {
      await _sendPowerCommand('0', 'TẮT XE');
      unawaited(_archiveCurrentTripIfMeaningful());
    } finally {
      _isCommandBusy = false;
      _lastCommandCompletedAt = DateTime.now();
    }
  }

  Future<void> _sendPowerCommand(String value, String label) async {
    if (!state.isAuthorized || _sessionKey == null) {
      state = state.copyWith(
          message: 'Chưa xác thực phiên — xe sẽ bỏ qua lệnh $label');
      BleLogger.instance.event('power_blocked', {
        'reason': 'chưa authenticate — KHÔNG gửi (tránh xe drop link)',
      });
      throw Exception('Chưa xác thực phiên xe (bật/tắt bị chặn)');
    }

    // KHÓA AN TOÀN KHI ĐANG CHẠY:
    // Tuyệt đối không cho tắt nguồn hoặc khóa xe nếu xe đang lăn bánh (> 0.5 km/h)
    final spd = state.lastTelemetry?.speed ?? 0.0;
    if (value == '0' && spd > 0.5) {
      final warn =
          'Không thể tắt/khóa xe khi xe đang di chuyển (${spd.toStringAsFixed(1)} km/h)!';
      state = state.copyWith(message: warn);
      BleLogger.instance.event('power_command_blocked_safety', {
        'speed': spd,
        'val': value,
        'label': label,
      });
      throw Exception(warn);
    }

    final pwrChar = _findPowerCmdChar();
    if (pwrChar == null) {
      throw Exception('Không tìm thấy cổng điều khiển nguồn xe (7f13fe5c)');
    }

    await _enqueueGatt(() async {
      final frame = BikeSessionCrypto.buildProtectedWrite(
        sessionKey: _sessionKey!,
        counter: _writeCounter++,
        characteristicUuid: pwrChar.uuid.str128,
        data: value.codeUnits,
      );
      await pwrChar.write(frame, withoutResponse: false);
      BleLogger.instance.event('power_command', {
        'target': 'powerOnOffChar (7f13fe5c)',
        'uuid': pwrChar.uuid.str128,
        'val': value,
        'counter': _writeCounter - 1,
      });
    });

    // Cập nhật Optimistic UI ngay lập tức để nút Bật/Tắt phản hồi tức thì (<150ms)
    final curTele = state.lastTelemetry;
    if (curTele != null) {
      curTele.state = (value == '1') ? BikeState.parking : BikeState.off;
    }
    state = state.copyWith(
      lastTelemetry: curTele,
      message: 'Đã gửi lệnh $label',
    );

    // Kích hoạt đọc lại Dashboard sau 150ms để đồng bộ trạng thái thật từ MCU
    Future.delayed(const Duration(milliseconds: 150), () {
      if (state.phase == BlePhase.connected) {
        unawaited(_pollDashboard());
      }
    });
  }

  Future<void> disconnect() async {
    _manualDisconnect = true;
    await _archiveCurrentTripIfMeaningful();
    TripGpsTracker.instance.stopTracking();
    _cancelReconnect();
    _stopKeepalive();
    _findBikeTimeoutTimer?.cancel();
    _findBikeTimeoutTimer = null;
    _findBikePeriodicTimer?.cancel();
    _findBikePeriodicTimer = null;
    _sessionKey = null;
    _lastRawStatusSig = null;
    await _connSub?.cancel();
    _connSub = null;
    await _notifySub?.cancel();
    _notifySub = null;
    for (final d in FlutterBluePlus.connectedDevices) {
      try {
        await d.disconnect();
      } catch (_) {}
    }
    // watcher đã bị huỷ ở trên nên close log tại đây (flush toàn bộ buffer)
    await BleLogger.instance.close();
    unawaited(ForegroundService.stop());
    state = state.copyWith(
      phase: BlePhase.disconnected,
      isAuthorized: false,
      isFindingBike: false,
    );
  }

  /// MỞ KHÓA XE AN TOÀN — disarm eec8fd7f '0' (qua BLE khi còn kết nối;
  /// nếu link đã đứt do khóa → quẹt thẻ NFC lên xe rồi kết nối lại).
  Future<String> unlockBike() async {
    _lastUserCommandAt = DateTime.now();
    final device = _device;
    if (device == null || state.phase != BlePhase.connected) {
      return 'Xe chưa được kết nối Bluetooth!\n→ Xe đang khóa? Quẹt THẺ NFC lên xe rồi thử lại.';
    }
    if (_isCommandBusy) {
      return 'Xe đang bận xử lý lệnh trước, vui lòng đợi giây lát...';
    }
    try {
      return await setImmobilizer(false);
    } catch (e) {
      return 'Lỗi gửi lệnh mở khóa xe: $e';
    }
  }

  /// KHÓA XE AN TOÀN — QUY TRÌNH CHUẨN (24/10): muốn khóa thì xe phải TẮT.
  /// 1. Guard: không khóa khi đang chạy.
  /// 2. Nếu xe đang BẬT → tự TẮT nguồn, chờ BMS ổn định ~2s.
  /// 3. ARM eec8fd7f '1'. Sau khóa: cần QUẸT THẺ NFC (hoặc app, khi còn
  ///    kết nối) để mở. Còi hú khi xe bị động vào (đá chống).
  Future<String> lockBike() async {
    _lastUserCommandAt = DateTime.now();
    final device = _device;
    if (device == null || state.phase != BlePhase.connected) {
      return 'Xe chưa được kết nối Bluetooth!';
    }
    if (_isCommandBusy) {
      return 'Xe đang bận xử lý lệnh trước, vui lòng đợi giây lát...';
    }
    final spd = state.lastTelemetry?.speed ?? 0.0;
    if (spd > 0.5) {
      return '⚠️ Không thể khóa khi xe đang di chuyển (${spd.toStringAsFixed(1)} km/h)!';
    }
    // Bước 1: xe đang bật → tắt nguồn trước (khóa chỉ thực hiện khi xe TẮT)
    if (state.lastTelemetry?.isBikeOn == true) {
      BleLogger.instance.event('lock_flow_auto_off', {'speed': spd});
      try {
        await turnOffBike();
      } catch (e) {
        return 'Không tắt được xe để khóa: $e\n→ Hãy tắt xe thủ công rồi bấm khóa lại.';
      }
      await Future.delayed(const Duration(seconds: 2));
    }
    // Bước 2: ARM khóa an toàn
    try {
      return await setImmobilizer(true);
    } catch (e) {
      return 'Lỗi gửi lệnh khóa xe: $e';
    }
  }

  /// Đồng bộ giờ hệ thống từ điện thoại gửi thẳng vào màn hình LCD Taplo xe.
  /// Characteristic: Gatt.currentTimeChar (44e2bde6-9cd5-4159-9d43-a3e3f4e9c737).
  /// Payload format: Chuỗi ASCII số GIÂY TRONG NGÀY theo GIỜ LOCAL (0..86399)
  /// = (hour*3600 + minute*60 + second). Chuẩn btsnoop: app gốc gửi "58607"
  /// = 16:16:47 giờ local. ✅ LAB 24/10: gửi epoch đầy đủ → taplo hiển thị
  /// UTC+0 (sai) — format giây-trong-ngày local là ĐÚNG.
  /// Ghi dạng protected write nếu đã có session key, hoặc plain write.
  Future<String> syncTimeWithBike([DateTime? customTime]) async {
    final device = _device;
    if (device == null || state.phase != BlePhase.connected) {
      return 'Xe chưa được kết nối Bluetooth!';
    }

    final localTime = customTime ?? DateTime.now();
    // Firmware hiển thị GIỜ ĐỊA PHƯƠNG: capture app gốc ghi '58607' = 16:16:47
    // local (btsnoop 16:16:34). KHÔNG convert UTC — bản cũ gửi UTC khiến đồng
    // hồ xe lệch -7h (UTC+7).
    final totalSecondsLocal =
        (localTime.hour * 3600) + (localTime.minute * 60) + localTime.second;
    final payload = utf8.encode(totalSecondsLocal.toString());

    final timeChar = _findCharacteristic(Gatt.currentTimeChar);
    if (timeChar == null) {
      BleLogger.instance.event('sync_time_err', {'error': 'Characteristic currentTimeChar not found'});
      return 'Không tìm thấy characteristic đồng bộ giờ trên xe!';
    }

    try {
      if (_sessionKey != null) {
        final frame = BikeSessionCrypto.buildProtectedWrite(
          sessionKey: _sessionKey!,
          counter: _writeCounter++,
          characteristicUuid: Gatt.currentTimeChar,
          data: payload,
        );
        await _enqueueGatt(() => timeChar.write(frame, withoutResponse: false));
        BleLogger.instance.event('sync_time_success', {
          'type': 'protected',
          'secondsLocal': totalSecondsLocal,
          'timeLocal': localTime.toIso8601String(),
          'counter': _writeCounter - 1,
        });
      } else {
        await _enqueueGatt(() => timeChar.write(payload, withoutResponse: false));
        BleLogger.instance.event('sync_time_success', {
          'type': 'plain',
          'secondsLocal': totalSecondsLocal,
          'timeLocal': localTime.toIso8601String(),
        });
      }

      state = state.copyWith(lastTimeSynced: localTime);
      final formattedTime = '${localTime.hour.toString().padLeft(2, '0')}:${localTime.minute.toString().padLeft(2, '0')}:${localTime.second.toString().padLeft(2, '0')}';
      return 'Đã đồng bộ giờ $formattedTime vào màn hình xe thành công!';
    } catch (e) {
      BleLogger.instance.event('sync_time_err', {'error': '$e'});
      return 'Lỗi đồng bộ giờ vào xe: $e';
    }
  }


  Timer? _findBikeTimeoutTimer;
  Timer? _findBikePeriodicTimer;

  /// Bắt đầu tìm xe — phát còi theo cơ chế ĐÚNG DUY NHẤT có bằng chứng:
  /// lặp lại chuỗi "bấm bật nguồn BẢN CŨ" (btsnoop app gốc: plain '1' →
  /// 350d9a82, protected '1' → char lệnh động, protected '1' → eec8fd7f)
  /// nhưng KHÔNG gửi gói confirmation thứ 2. Kinh nghiệm thực tế (user):
  /// bản chưa có confirmation, bấm bật lần 1 xe HÚ CÒI nhưng chưa mở
  /// nguồn, bấm lần 2 xe mới bật → gói đơn = còi kêu, rơ-le không khép.
  /// Chỉ cho phép khi xe ĐANG TẮT (tránh đụng nguồn khi xe đang chạy).
  Future<String> findBike({Duration timeout = const Duration(seconds: 10)}) async {
    _lastUserCommandAt = DateTime.now();
    final device = _device;
    if (device == null || state.phase != BlePhase.connected || !state.isAuthorized) {
      return 'Xe chưa được kết nối Bluetooth hoặc chưa xác thực!';
    }
    final spd = state.lastTelemetry?.speed ?? 0.0;
    if (spd > 0.5) {
      return 'Chức năng tìm xe không khả dụng khi xe đang di chuyển!';
    }
    if (state.lastTelemetry?.isBikeOn == true) {
      return 'Còi tìm xe chỉ hoạt động khi xe ĐANG TẮT (cơ chế hú của firmware). '
          'Hãy tắt xe trước rồi thử lại.';
    }

    _findBikeTimeoutTimer?.cancel();
    _findBikePeriodicTimer?.cancel();

    state = state.copyWith(isFindingBike: true, message: 'Đang phát còi tìm xe…');
    BleLogger.instance.event('find_bike_start', {
      'timeout_s': timeout.inSeconds,
      'pattern': state.findBikePattern,
      'mode': 'honk',
    });

    final pattern = state.findBikePattern;
    final intervalMs = switch (pattern) {
      1 => 1400, // Nhịp đôi
      2 => 1000, // Dồn dập
      _ => 1500, // Tiêu chuẩn — 1 gói/plain mỗi nhịp
    };

    // Tiếng còi đầu tiên ngay lập tức
    await _sendFindBikeHonk();

    // Lặp chuỗi hú — guard chống chồng lấn (chuỗi ~750ms có thể dài hơn interval)
    _findBikePeriodicTimer = Timer.periodic(Duration(milliseconds: intervalMs), (timer) async {
      if (!state.isFindingBike || _honkBusy) return;
      _honkBusy = true;
      try {
        await _sendFindBikeHonk();
      } catch (e) {
        BleLogger.instance.event('find_bike_tick_err', {'error': '$e'});
      } finally {
        _honkBusy = false;
      }
    });

    _findBikeTimeoutTimer = Timer(timeout, () {
      stopFindBike();
    });
    return 'Đang phát còi tìm xe trong ${timeout.inSeconds}s — mỗi tiếng hú là '
        '1 gói plain \'1\' lên 350d9a82 (LAB 23/10 verified: xe hú, không bật nguồn).';
  }

  /// Dừng phát tín hiệu tìm xe. KHÔNG gửi lệnh '0' nào — chuỗi '0' chính là
  /// lệnh TẮT nguồn, gửi khi dừng tìm xe có thể tắt xe ngoài ý muốn!
  Future<String> stopFindBike() async {
    _lastUserCommandAt = DateTime.now();
    _findBikeTimeoutTimer?.cancel();
    _findBikeTimeoutTimer = null;
    _findBikePeriodicTimer?.cancel();
    _findBikePeriodicTimer = null;
    if (state.isFindingBike) {
      state = state.copyWith(isFindingBike: false, message: 'Đã dừng tìm xe');
      BleLogger.instance.event('find_bike_stop', {});
    }
    return 'Đã dừng tìm xe.';
  }

  bool _honkBusy = false;

  /// 1 tiếng hú = 1 gói PLAIN '1' duy nhất lên 350d9a82 (LAB 23/10 đêm xác
  /// minh trực tiếp: ghi plain '1' → xe HÚ, ghi '0' → không thấy tác động).
  /// KHÔNG gửi gì lên eec8fd7f — đó là char KHÓA AN TOÀN ('1' = khóa xe,
  /// phải quẹt thẻ NFC mới mở lại!), và KHÔNG gửi '0' khi dừng.
  Future<void> _sendFindBikeHonk() async {
    final sw = _findCharacteristic(Gatt.powerSwitchChar);
    if (sw == null) {
      BleLogger.instance.event('find_bike_honk_err',
          {'target': 'powerSwitchChar', 'error': 'char not found'});
      return;
    }
    try {
      await _enqueueGatt(() => sw.write('1'.codeUnits, withoutResponse: false));
      BleLogger.instance.event('find_bike_honk', {
        'target': 'powerSwitchChar',
        'note': 'single plain 1 = honk (LAB verified)',
      });
    } catch (e) {
      BleLogger.instance.event('find_bike_honk_err',
          {'target': 'powerSwitchChar', 'error': '$e'});
    }
  }


  void _startKeepalive() {
    if (!enableKeepalive) return;
    _keepaliveTimer?.cancel();
    _keepaliveCount = 0;
    _keepaliveTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) {
      _runKeepaliveCycle();
    });
    BleLogger.instance.event('keepalive_start', {});
  }

  void _stopKeepalive() {
    _keepaliveTimer?.cancel();
    _keepaliveTimer = null;
  }

  /// Mot chu ky: ghi auth response cho nonce hien hanh -> ghi password ->
  /// doc nonce moi. Xe derive lai sessionKey tai auth write (reset counter)
  /// nen app re-derive bang CHINH nonce vua tra loi roi cap nhat nonce moi.
  Future<void> _runKeepaliveCycle() async {
    if (_keepaliveBusy || !state.isAuthorized) return;
    final nonce = _lastAuthNonce15;
    final dev = _device;
    if (nonce == null || dev == null || _activePassword.isEmpty) return;
    BluetoothCharacteristic? find(String uuid) {
      for (final c in state.characteristics) {
        if (c.uuid.str128.toLowerCase() == uuid.toLowerCase()) return c;
      }
      return null;
    }

    final authChar = find(Gatt.authorizationChar);
    if (authChar == null) return;
    _keepaliveBusy = true;
    try {
      final resp = BikeSessionCrypto.computeAuthResponse(
        pairingToken: Gatt.defaultPairingToken,
        nonce15: nonce,
      );
      await authChar.write(resp, withoutResponse: false);
      final post = await authChar.read();
      _sessionKey = BikeSessionCrypto.deriveSessionKey(
        pairingToken: Gatt.defaultPairingToken,
        password: _activePassword,
        challenge: nonce,
      );
      _writeCounter = 0;
      if (post.length == 16) {
        _lastAuthNonce15 = Uint8List.fromList(post.sublist(0, 15));
      }
      _keepaliveCount++;
      if (_keepaliveCount == 1 || _keepaliveCount % 20 == 0) {
        BleLogger.instance.event('keepalive', {
          'n': _keepaliveCount,
          'answered': BleLogger.hex(nonce),
        });
      }
    } catch (e) {
      BleLogger.instance.event('keepalive_error', {'error': '$e'});
      _stopKeepalive();
    } finally {
      _keepaliveBusy = false;
    }
  }


  Uint8List _sessionKeyOf(String token, String pw, Uint8List salt) =>
      BikeSessionCrypto.deriveSessionKey(
          pairingToken: token, password: pw, challenge: salt);

  /// Quy trình xác thực phiên theo TRÌNH TỰ THẬT của app gốc (btsnoop
  /// 2026-10-14 16:16, máy Samsung — xem docs/ble_session_protocol.md).
  ///
  /// Luồng đã verify:
  ///   1. (bond nếu link chưa mã hoá — err 0x05/137)
  ///   2. Đọc 16B từ AUTHORIZATION_CHAR (5e9a2c71): 15B nonce + 1B status
  ///   3. Ghi 16B auth response lên CHÍNH char đó
  ///   4. Đọc lại — status byte 0x01 = xe chấp nhận, 0x00 = từ chối
  ///   5. deriveSessionKey với nonce mới đọc được sau khi chấp nhận
  ///   6. Protected-write password ASCII lên bikeSerial (counter 0)
  ///   7. Ghi pairingToken UTF-8 lên sessionUuid (87efab0d)
  ///   8. Protected-write password lần 2 (counter 1)
  ///
  /// ⚠️ Bước 3-4 hiện sẽ THẤT BẠI trên xe thật: công thức auth response chưa
  /// crack được (computeAuthResponse là placeholder). Flow dừng an toàn ngay
  /// khi status != 0x01 — không spam ghi, không gửi lệnh khi chưa xác thực.
  Future<bool> authenticateSession({
    BluetoothDevice? targetDevice,
    List<BluetoothCharacteristic>? chars,
    String? pairingToken,
    String? password,
    bool forceRegister = false,
  }) async {
    final effectiveChars = (chars != null && chars.isNotEmpty)
        ? chars
        : state.characteristics;

    final dev = targetDevice ?? state.device;

    final token = (pairingToken?.isNotEmpty ?? false)
        ? pairingToken!
        : Gatt.defaultPairingToken;
    final prefs = await _prefs;
    final stored = prefs.getString(_kBikePassword);
    final hasStoredPassword = stored != null && stored.isNotEmpty;
    // PIN ưu tiên: password truyền vào (nếu có) -> password đã lưu trong prefs -> rỗng
    final pin = (password != null && password.isNotEmpty)
        ? password
        : (hasStoredPassword ? stored : '');

    BleLogger.instance.event('auto_handshake_start', {
      'token': token,
      'pin': pin,
      'chars_count': effectiveChars.length,
      'has_stored': hasStoredPassword,
      'force_register': forceRegister,
    });

    if (effectiveChars.isEmpty) {
      BleLogger.instance.event('auto_handshake_err', {'error': 'Danh sách characteristics rỗng'});
      return false;
    }

    BluetoothCharacteristic? find(String uuid) {
      final clean = uuid.toLowerCase().replaceAll('-', '');
      for (final c in effectiveChars) {
        if (c.uuid.str128.toLowerCase().replaceAll('-', '') == clean) return c;
      }
      return null;
    }

    try {
      final authChar = find(Gatt.authorizationChar);
      if (authChar == null) {
        BleLogger.instance.event('auto_handshake_err',
            {'error': 'Không tìm thấy AUTHORIZATION_CHAR (5e9a2c71)'});
        return false;
      }

      // ===== BƯỚC 1: Đọc 5e9a2c71 (authChar) trước tiên để kiểm tra trạng thái phiên trên xe =====
      List<int> nonce1 = Uint8List(0);
      try {
        nonce1 = await authChar
            .read()
            .timeout(const Duration(milliseconds: 800), onTimeout: () => Uint8List(0));
      } catch (e) {
        if (_isAuthError(e)) {
          if (dev != null) {
            await _ensureBonded(dev, reason: 'auth char cần link mã hoá');
            try {
              nonce1 = await authChar
                  .read()
                  .timeout(const Duration(milliseconds: 800), onTimeout: () => Uint8List(0));
            } catch (_) {}
          }
        } else {
          BleLogger.instance.event('auto_handshake_step1_warn', {'error': '$e'});
        }
      }

      BleLogger.instance.event('auto_handshake_challenge',
          {'hex': BleLogger.hex(nonce1), 'len': nonce1.length});
      if (nonce1.length != 16) {
        BleLogger.instance.event('auto_handshake_err',
            {'error': 'Nonce phải 16B, nhận ${nonce1.length}'});
        return false;
      }
      var nonce15 = Uint8List.fromList(nonce1.sublist(0, 15));
      final status1 = nonce1[15];
      BleLogger.instance.event('auto_handshake_status', {
        'status': status1,
        'note': status1 == Gatt.authStatusOk ? 'đã auth từ trước' : 'chưa auth'
      });

      final appAuthChar = find(Gatt.appAuthChar);
      Uint8List? acceptedNonce;

      if (status1 == Gatt.authStatusOk && !forceRegister) {
        // FAST-PATH: Xe đã chấp nhận xác thực từ trước -> giữ nguyên nonce1, KHÔNG ghi lại 5e9a2c71
        acceptedNonce = Uint8List.fromList(nonce1);
        _lastAuthNonce15 = nonce15;
        BleLogger.instance.event('auto_handshake_fast_path', {'hex': BleLogger.hex(nonce1)});
      } else {
        // SLOW-PATH (status1 == 0x00 hoặc forceRegister):
        // ===== BƯỚC 1.5: Giải Challenge-Response SHA-256 trên c8eaf27b (appAuthChar) =====
        if (pin.isNotEmpty && appAuthChar != null && !forceRegister) {
          try {
            final challengeRaw = await appAuthChar
                .read()
                .timeout(const Duration(milliseconds: 600), onTimeout: () => Uint8List(0));
            BleLogger.instance.event('auto_handshake_app_auth_read', {
              'hex': BleLogger.hex(challengeRaw),
              'len': challengeRaw.length,
            });
            if (challengeRaw.length >= 4) {
              final respHex = BikeSessionCrypto.computeAppAuthChallengeResponse(
                challengeRaw: challengeRaw,
                password: pin,
              );
              BleLogger.instance.event('auto_handshake_app_auth_solve', {
                'respHex': respHex,
                'candidate_pw': pin,
              });
              await appAuthChar
                  .write(ascii.encode(respHex), withoutResponse: false)
                  .timeout(const Duration(milliseconds: 800));
              // Delay ngắn như capture btsnoop (~40-50ms)
              await Future.delayed(const Duration(milliseconds: 50));
              try {
                final ack = await appAuthChar
                    .read()
                    .timeout(const Duration(milliseconds: 600), onTimeout: () => Uint8List(0));
                BleLogger.instance.event('auto_handshake_app_auth_ack', {
                  'hex': BleLogger.hex(ack),
                  'verified': ack.isNotEmpty && (ack[0] & 1) == 1,
                });
              } catch (_) {}
            }
          } catch (e) {
            BleLogger.instance.event('auto_handshake_app_auth_error', {'error': '$e'});
          }
        }

        // ===== BƯỚC 3+4: ghi auth response, đọc lại kiểm status =====
        const maxAttempts = 3;
        for (var attempt = 1; attempt <= maxAttempts; attempt++) {
          if (attempt > 1) {
            final fresh = await authChar
                .read()
                .timeout(const Duration(milliseconds: 800), onTimeout: () => Uint8List(0));
            BleLogger.instance.event('auto_handshake_challenge',
                {'attempt': attempt, 'hex': BleLogger.hex(fresh)});
            if (fresh.length == 16) {
              nonce15 = Uint8List.fromList(fresh.sublist(0, 15));
            }
          }
          final resp = BikeSessionCrypto.computeAuthResponse(
            pairingToken: token,
            nonce15: nonce15,
          );

          await authChar
              .write(resp, withoutResponse: false)
              .timeout(const Duration(milliseconds: 800));
          BleLogger.instance.event('auto_handshake_response_sent',
              {'attempt': attempt, 'hex': BleLogger.hex(resp)});

          await Future.delayed(const Duration(milliseconds: 120));

          final post = await authChar
              .read()
              .timeout(const Duration(milliseconds: 800), onTimeout: () => Uint8List(0));
          BleLogger.instance.event('auto_handshake_post_status',
              {'hex': BleLogger.hex(post)});
          if (post.length == 16 && post[15] == Gatt.authStatusOk) {
            acceptedNonce = Uint8List.fromList(post);
            _lastAuthNonce15 = Uint8List.fromList(post.sublist(0, 15));
            break;
          }
          if (attempt < maxAttempts) {
            await Future.delayed(
                Duration(milliseconds: attempt == 1 ? 300 : 1200));
          }
        }
      }

      if (acceptedNonce == null) {
        BleLogger.instance.event('auto_handshake_rejected', {
          'note': 'xe giữ status 0x00 — token hoặc challenge auth chưa được chấp nhận',
        });
        state = state.copyWith(
          isAuthorized: false,
          message: hasStoredPassword
              ? 'Xe từ chối xác thực (status 00) — vui lòng quẹt thẻ NFC vào xe nếu đổi điện thoại'
              : 'Xe từ chối xác thực (status 00) — vui lòng quẹt thẻ NFC vào xe để ghép nối lần đầu',
        );
        return false;
      }

      if (dev != null) {
        await _ensureBonded(dev, reason: 'xác thực thành công, thiết lập bond');
      }

      // ===== BƯỚC 5: chiến lược password — SELF-REGISTER fallback như app gốc =====
      final saltNonce = nonce15;
      final dash = find(Gatt.dashboardCharacteristic);
      final serialChar = find(Gatt.bikeSerial);
      int ctr(List<int> r) => r.length >= 4
          ? r[0] | (r[1] << 8) | (r[2] << 16) | (r[3] << 24)
          : -1;

      Future<bool> tryPassword(String label, String pw, Uint8List salt) async {
        final sk = BikeSessionCrypto.deriveSessionKey(
          pairingToken: token, password: pw, challenge: salt);
        BleLogger.instance.event('auto_handshake_try_password',
            {'candidate': label, 'key8': BleLogger.hex(sk.sublist(0, 8))});
        if (serialChar != null) {
          // Đính chính RE2: 44e2bde6 là CURRENT_TIME_CHAR (nhận số giây trong ngày 0..86399).
          // Trong btsnoop 16:16:47, app gốc gửi "58607" (= 16*3600 + 16*60 + 47) ở counter 0
          // để đồng bộ giờ ngay khi mở phiên, KHÔNG phải gửi chuỗi password thô (gửi pw chữ cái
          // sẽ làm atoi() trên xe đặt lại giờ Taplo về 00:00).
          final now = DateTime.now();
          final secondsOfDay =
              ((now.hour * 3600) + (now.minute * 60) + now.second).toString();
          final frame = BikeSessionCrypto.buildProtectedWrite(
            sessionKey: sk,
            counter: _writeCounter++,
            characteristicUuid: Gatt.timeSyncChar,
            data: secondsOfDay.codeUnits,
          );
          await serialChar
              .write(frame, withoutResponse: false)
              .timeout(const Duration(milliseconds: 800));
          BleLogger.instance.event('auto_handshake_time_sync_probe',
              {'candidate': label, 'seconds_of_day': secondsOfDay, 'hex': BleLogger.hex(frame)});
        }
        if (dash == null) return false;
        try {
          await Future.delayed(const Duration(milliseconds: 100));
          final r1 = await dash
              .read()
              .timeout(const Duration(milliseconds: 800), onTimeout: () => Uint8List(0));
          var live = _isValidTelemetry(sk, r1);
          final c1 = ctr(r1);
          var c2 = c1;
          if (!live) {
            await Future.delayed(const Duration(milliseconds: 700));
            final r2 = await dash
                .read()
                .timeout(const Duration(milliseconds: 800), onTimeout: () => Uint8List(0));
            c2 = ctr(r2);
            live = _isValidTelemetry(sk, r2) || (c1 >= 0 && c2 > c1);
          }
          BleLogger.instance.event('auto_handshake_session_check',
              {'candidate': label, 'password': pw, 'counter1': c1,
               'counter2': c2, 'session_live': live,
               'telemetry_valid': live,
               'salt': BleLogger.hex(salt), 'sk': BleLogger.hex(sk)});
          return live;
        } catch (_) {
          return false;
        }
      }

      var live = false;
      var livePw = '';
      Uint8List? liveKey;

      // (a) Thử candidate password (pin)
      if (pin.isNotEmpty) {
        _writeCounter = 0;
        live = await tryPassword('candidate "$pin"', pin, saltNonce);
        if (!live) {
          _writeCounter = 0;
          final postNonce15 = Uint8List.fromList(acceptedNonce.sublist(0, 15));
          live = await tryPassword('candidate "$pin" (postNonce)', pin, postNonce15);
          if (live) {
            livePw = pin;
            liveKey = _sessionKeyOf(token, pin, postNonce15);
            await prefs.setString(_kBikePassword, pin);
          }
        } else if (live) {
          livePw = pin;
          liveKey = _sessionKeyOf(token, pin, saltNonce);
          await prefs.setString(_kBikePassword, pin);
        }
      }
      // (b) password đã register lần trước (prefs) nếu khác pin
      if (!live && hasStoredPassword && stored != pin) {
        _writeCounter = 0;
        live = await tryPassword('registered "$stored"', stored, saltNonce);
        if (!live) {
          _writeCounter = 0;
          final postNonce15 = Uint8List.fromList(acceptedNonce.sublist(0, 15));
          live = await tryPassword('registered "$stored" (postNonce)', stored, postNonce15);
          if (live) {
            livePw = stored;
            liveKey = _sessionKeyOf(token, stored, postNonce15);
            await prefs.setString(_kBikePassword, stored);
          }
        } else if (live) {
          livePw = stored;
          liveKey = _sessionKeyOf(token, stored, saltNonce);
          await prefs.setString(_kBikePassword, stored);
        }
      }
      // (c) SELF-REGISTER: Chỉ cho phép tự động khi chưa từng có password lưu (!hasStoredPassword)
      // hoặc khi người dùng bấm nút Force Register (forceRegister == true)
      if (!live && appAuthChar != null && (!hasStoredPassword || forceRegister)) {
        final newPw = pin.isNotEmpty ? pin : () {
          const chars =
              'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
          final rng = Random.secure();
          return List.generate(12, (_) => chars[rng.nextInt(chars.length)]).join();
        }();
        BleLogger.instance.event('auto_handshake_register_password',
            {'new_password': newPw, 'is_fallback': hasStoredPassword});
        try {
          await appAuthChar
              .write(newPw.codeUnits, withoutResponse: false)
              .timeout(const Duration(milliseconds: 800));
          await Future.delayed(const Duration(milliseconds: 80));
          await appAuthChar
              .write(newPw.codeUnits, withoutResponse: false)
              .timeout(const Duration(milliseconds: 800));
          await Future.delayed(const Duration(milliseconds: 80));
          try {
            final ack = await appAuthChar
                .read()
                .timeout(const Duration(milliseconds: 600), onTimeout: () => Uint8List(0));
            BleLogger.instance.event('auto_handshake_register_ack',
                {'hex': BleLogger.hex(ack)});
          } catch (_) {}
        } catch (e) {
          BleLogger.instance.event('auto_handshake_register_error',
              {'error': '$e'});
        }

        // Re-auth với nonce mới → derive với password vừa đăng ký
        await Future.delayed(const Duration(milliseconds: 150));
        final nonce2 = await authChar
            .read()
            .timeout(const Duration(milliseconds: 800), onTimeout: () => Uint8List(0));
        if (nonce2.length == 16) {
          final n2 = Uint8List.fromList(nonce2.sublist(0, 15));
          final resp2 = BikeSessionCrypto.computeAuthResponse(
              pairingToken: token, nonce15: n2);
          await authChar
              .write(resp2, withoutResponse: false)
              .timeout(const Duration(milliseconds: 800));
          await Future.delayed(const Duration(milliseconds: 120));
          final post2 = await authChar
              .read()
              .timeout(const Duration(milliseconds: 800), onTimeout: () => Uint8List(0));
          final ok2 = post2.length == 16 && post2[15] == Gatt.authStatusOk;
          BleLogger.instance.event('auto_handshake_reauth',
              {'post_status': BleLogger.hex(post2), 'ok': ok2});
          if (ok2) {
            if (post2.length == 16) {
              _lastAuthNonce15 = Uint8List.fromList(post2.sublist(0, 15));
            }
            final sk2 = _sessionKeyOf(token, newPw, n2);
            BleLogger.instance.event('auto_handshake_session_key', {
              'salt_nonce2': BleLogger.hex(n2),
              'session_key': BleLogger.hex(sk2),
              'password': newPw,
            });
            _writeCounter = 0;
            live = await tryPassword('self-registered', newPw, n2);
            if (live) {
              livePw = newPw;
              liveKey = _sessionKeyOf(token, newPw, n2);
              await prefs.setString(_kBikePassword, newPw);
            }
          }
        }
      }

      // Token lên 87efab0d nếu session sống (đồng bộ giờ 44e2bde6 đã thực hiện trong tryPassword)
      if (live && liveKey != null) {
        final sessionUuidChar = find(Gatt.sessionUuid);
        if (sessionUuidChar != null) {
          await sessionUuidChar
              .write(token.codeUnits, withoutResponse: false)
              .timeout(const Duration(milliseconds: 800));
          BleLogger.instance.event('auto_handshake_uuid_sent', {'token': token});
        }
        _sessionKey = liveKey;
        _activePassword = livePw;
        _startKeepalive();
        state = state.copyWith(
          isAuthorized: true,
          sessionKey: liveKey,
          lastTimeSynced: DateTime.now(),
          message: 'SESSION HỢP LỆ — password '
              '"$livePw" sẵn sàng điều khiển',
        );

        BleLogger.instance.event('auto_handshake_success');
        unawaited(refreshFwSettings());
        unawaited(fetchVehicleDiagnostics());
        return true;
      } else {
        _sessionKey = null;
        _stopKeepalive();
        final msg = hasStoredPassword
            ? 'Auth Phase-1 OK nhưng session chưa hợp lệ với password đã lưu. '
              'Vui lòng quẹt thẻ NFC vào xe hoặc chọn "Quên xe" để ghép nối lại.'
            : 'Auth Phase-1 OK nhưng session chưa hợp lệ (đăng ký '
              'password mới chưa được xe chấp nhận) — gửi log để kiểm tra';
        state = state.copyWith(
          isAuthorized: false,
          sessionKey: null,
          message: msg,
        );
        BleLogger.instance.event('auto_handshake_failed_not_live');
        return false;
      }
    } catch (e) {
      BleLogger.instance.event('auto_handshake_failed', {'error': '$e'});
      return false;
    }
  }

  /// Lỗi "cần mã hoá link": Android code 137 (GATT_ERROR) hoặc ATT 0x05
  /// Insufficient Authentication — app gốc gặp y hệt trong btsnoop trước khi bond.
  bool _isAuthError(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('137') ||
        s.contains('insufficient') ||
        s.contains('gatt_auth') ||
        s.contains('auth_fail');
  }

  /// Bond (ghép nối+mã hoá) với xe — app gốc bond ngay sau discovery
  /// (btsnoop 16:16:15-17, bonding state 11→12). Trả về true nếu đã bond.
  Future<bool> _ensureBonded(BluetoothDevice device, {String reason = ''}) async {
    BleLogger.instance.event('bond_start', {'reason': reason});
    try {
      final currentBond = await device.bondState.first.timeout(
        const Duration(milliseconds: 1200),
        onTimeout: () => BluetoothBondState.none,
      );
      if (currentBond == BluetoothBondState.bonded) {
        BleLogger.instance.event('bond_already_bonded', {});
        return true;
      }
      await device.createBond();
      BleLogger.instance.event('bond_created', {});
      return true;
    } catch (e) {
      BleLogger.instance.event('bond_failed', {'error': '$e'});
      return false;
    }
  }


  /// Quên xe đã nhớ (unpair logic) — xoá cả bond hệ thống nếu có và xoá trạng thái.
  Future<void> forgetBike() async {
    _manualDisconnect = true;
    _cancelReconnect();
    _stopKeepalive();
    _findBikeTimeoutTimer?.cancel();
    _findBikeTimeoutTimer = null;
    _findBikePeriodicTimer?.cancel();
    _findBikePeriodicTimer = null;
    _sessionKey = null;

    final prefs = await _prefs;
    final savedId = prefs.getString(_kLastBikeId);
    final d = _device ?? (savedId != null ? BluetoothDevice.fromId(savedId) : null);
    if (d != null) {
      BleLogger.instance.event('forget_bike', {'device_id': d.remoteId.str});
      try {
        await d.removeBond();
      } catch (_) {}
      try {
        await d.disconnect();
      } catch (_) {}
    }
    for (final dev in FlutterBluePlus.connectedDevices) {
      try {
        await dev.disconnect();
      } catch (_) {}
    }

    await _connSub?.cancel();
    _connSub = null;
    await _notifySub?.cancel();
    _notifySub = null;

    await prefs.remove(_kLastBikeId);
    await prefs.remove(_kLastBikeName);
    await prefs.remove(_kBikePassword);

    await BleLogger.instance.close();
    unawaited(ForegroundService.stop());

    state = const BleState(
      phase: BlePhase.idle,
      message: 'Đã xóa thông tin xe',
      device: null,
      bikeName: null,
    );
  }

  // ------------------------------------------------------------------
  // Reconnect
  // ------------------------------------------------------------------

  void _watchConnection(BluetoothDevice device) {
    _connSub?.cancel();
    _connSub = FlutterBluePlus.events.onConnectionStateChanged.listen((e) async {
      if (e.device.remoteId != device.remoteId) return;
      if (e.connectionState == BluetoothConnectionState.disconnected) {
        BleLogger.instance.event('disconnected', {
          'device_id': device.remoteId.str,
          'manual': _manualDisconnect,
        });
        // HỦY NGAY subscription watcher để không bị trigger lặp lại khi các lệnh reconnect thất bại
        _connSub?.cancel();
        _connSub = null;

        _pollTimer?.cancel(); // hết poll spam 'device is not connected'
        _stopKeepalive();
        _notifySub?.cancel();
        _notifySub = null;
        _dashChar = null;
        _sessionKey = null;
        _writeCounter = 0;
        _decodeFailStreak = 0;
        _smoothedRssi = null;
        _rssiKalman.reset();
        _autoLockCounter = 0;
        _antiForgetCounter = 0;
        _walkUpTriggered = false;
        _batteryChar = null;
        _batteryPollCounter = 0;
        unawaited(_archiveCurrentTripIfMeaningful());

        if (_manualDisconnect) {
          // Recovery-disconnect không đóng logger (log giữa chừng phải còn
          // sống để chẩn đoán) — chỉ disconnect chủ động của user mới đóng.
          if (!_recoveryDisconnect) {
            await BleLogger.instance.close();
          }
          return;
        }

        final wasBikeOn = state.lastTelemetry?.isBikeOn == true;
        _reconnectAttempts = 0;
        state = state.copyWith(
          phase: BlePhase.reconnecting,
          reconnectAttempt: 0,
          isAuthorized: false,
          sessionKey: null,
          dashboardEncrypted: false,
          message: (wasBikeOn && state.antiForgetAlert)
              ? '⚠️ CẢNH BÁO AN TOÀN: Xe vẫn đang BẬT nguồn khi ngắt kết nối! Hãy kiểm tra xe ngay.'
              : null,
        );

        _scheduleReconnect(device);
      }
    });
  }

  void _scheduleReconnect(BluetoothDevice device) {
    if (_manualDisconnect) return;
    // Android/firewall có thể bắn NHIỀU disconnect event cho 1 lần đứt —
    // nếu timer reconnect đang chờ thì bỏ qua event trùng (tránh đếm khống).
    if (_reconnectPending) {
      BleLogger.instance.event('reconnect_debounced', {});
      return;
    }
    if (!state.autoReconnect) {
      BleLogger.instance.event('auto_reconnect_disabled', {});
      state = state.copyWith(
        phase: BlePhase.disconnected,
        message: 'Đã dừng kết nối. Bấm "Kết nối lại" để kết nối với xe.',
      );
      return;
    }
    _reconnectAttempts++;

    final maxAttempts = state.continuousScan ? 999999 : state.reconnectMaxAttempts;
    if (_reconnectAttempts > maxAttempts) {
      _reconnectPending = false;
      _cancelReconnect();
      unawaited(ForegroundService.stop());
      state = state.copyWith(
        phase: BlePhase.disconnected,
        reconnectAttempt: _reconnectAttempts,
        message: 'Đã dừng tìm xe sau $maxAttempts lần thử. Hãy đến gần xe và bấm "Kết nối lại".',
      );
      BleLogger.instance.event('reconnect_limit_reached', {'max': maxAttempts});
      return;
    }

    final delay = state.reconnectIntervalSeconds > 0
        ? state.reconnectIntervalSeconds
        : ((_reconnectAttempts <= _backoff.length) ? _backoff[_reconnectAttempts - 1] : 30);

    _reconnectPending = true;
    final maxLabel = state.continuousScan ? 'liên tục' : 'lần $_reconnectAttempts/$maxAttempts';
    state = state.copyWith(
      phase: BlePhase.reconnecting,
      reconnectAttempt: _reconnectAttempts,
      message: 'Mất kết nối — thử lại sau ${delay}s ($maxLabel)',
    );
    unawaited(ForegroundService.start(
      title: 'Dat Bike: ${state.bikeName ?? device.platformName}',
      text: 'Đang thử kết nối lại ($maxLabel)...',
    ));
    BleLogger.instance
        .event('reconnect_scheduled', {'attempt': _reconnectAttempts, 'delay_s': delay});
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: delay), () async {
      _reconnectPending = false;
      if (_manualDisconnect || (!state.continuousScan && _reconnectAttempts > maxAttempts)) return;
      try {
        final ok = await _establish(device);
        if (ok && state.isAuthorized) {
          BleLogger.instance.event('reconnected', {'attempt': _reconnectAttempts});
          _reconnectAttempts = 0;
          _connectedAt = DateTime.now();
          _hasBeenNearBike = false;
          state = state.copyWith(phase: BlePhase.connected, reconnectAttempt: 0, message: null);
          unawaited(ForegroundService.start(
            title: 'Dat Bike: ${state.bikeName ?? device.platformName}',
            text: 'Đã kết nối Bluetooth — Sẵn sàng điều khiển',
          ));
          _failStreak = 0;
          _watchConnection(device); // Chỉ gắn watcher khi ĐÃ KẾT NỐI THÀNH CÔNG!
        } else {
          throw Exception('Bắt tay phiên xe chưa hoàn tất');
        }
      } catch (e) {
        BleLogger.instance.event('reconnect_failed', {'attempt': _reconnectAttempts, 'error': '$e'});
        _failStreak++;
        if (_failStreak == 2) {
          state = state.copyWith(
            message: 'Đang đợi xe giải phóng phiên kết nối cũ (cooldown)… tiếp tục thử lại…',
          );
          BleLogger.instance.event('reconnect_waiting_cooldown', {'device': device.remoteId.str});
        }
        if (!_manualDisconnect) {
          _scheduleReconnect(device);
        }
      }
    });
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectPending = false;
    if (FlutterBluePlus.isScanningNow) {
      try {
        FlutterBluePlus.stopScan();
      } catch (_) {}
    }
  }

  void _teardown() {
    _cancelReconnect();
    _stopKeepalive();
    _findBikeTimeoutTimer?.cancel();
    _findBikePeriodicTimer?.cancel();
    _pollTimer?.cancel();
    _connSub?.cancel();
    _notifySub?.cancel();
    _telemetry.close();
  }

  Future<String?> lastBikeName() async {
    final prefs = await _prefs;
    return prefs.getString(_kLastBikeName);
  }

  Future<String?> lastBikeId() async {
    final prefs = await _prefs;
    return prefs.getString(_kLastBikeId);
  }

  Future<void> _saveLastBike(BluetoothDevice device, String? name) async {
    final prefs = await _prefs;
    await prefs.setString(_kLastBikeId, device.remoteId.str);
    await prefs.setString(_kLastBikeName, name ?? device.platformName);
    state = state.copyWith(bikeName: name ?? device.platformName);
  }
}

final bleProvider = NotifierProvider<BleController, BleState>(BleController.new);
