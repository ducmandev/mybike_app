// Unit Test Suite: Proximity & Safety State Machine (§4.6)
//
// Kiểm chứng toàn diện logic & thuật toán cho 7 kịch bản an toàn:
// 1. Luồng 1: Walk-Up Fast-Track Kalman Convergence
// 2. Luồng 2A: Body Shadowing Protection (Đứng gần 2-3m bị suy hao thoáng qua)
// 3. Luồng 2B: Chốt 1 lần _walkUpConsumed & Timeout 90 giây đứng gần không di chuyển
// 4. Luồng 3: Lại gần mở xe lấy đồ trong 5 giây rồi đi xa ngay (Expedited Auto-Lock)
// 5. Case 4: Bảo vệ khi dừng đèn đỏ ở mode Drive / Super (Red Light Safety)
// 6. Case 5: Tái vũ trang _walkUpConsumed khi thực sự rời xa (Rearm Hysteresis)
// 7. Case 6: Chống trộm antiTheft5m phân biệt tốc độ thấp (<=15km/h) và cao (>15km/h)

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mybike_app/core/proto/bike_log.dart';
import 'package:mybike_app/core/utils/kalman_filter.dart';
import 'package:mybike_app/core/ble/ble_controller.dart';
import 'package:mybike_app/core/ble/gatt.dart';

/// Máy trạng thái mô phỏng Proximity & Safety State Machine của Dat Bike App.
/// Thực thi chính xác các quy tắc nghiệp vụ theo đặc tả kỹ thuật §4.6.
class ProximitySafetyStateMachine {
  // --- Cấu hình (Configuration) ---
  bool walkUpUnlock;
  bool walkUpAutoPowerOn;
  bool autoLockWalkAway;
  bool antiTheft5m;

  double nearThreshold; // Mặc định -55.0 dBm (~1-2m)
  double targetThreshold; // Mặc định -75.0 dBm
  double rearmThreshold; // Mặc định -78.0 dBm

  static const double kTheftLowSpeedThreshold = -78.0;
  static const double kTheftHighSpeedThreshold = -85.0;
  static const double kSpeedCutoff = 15.0; // km/h
  static const int kTheftLowSpeedCycles = 5;
  static const int kTheftHighSpeedCycles = 8;
  static const int kIdleTimeoutSeconds = 90;

  // --- Bộ lọc tín hiệu Kalman 1D ---
  final KalmanFilter1D kalman;

  // --- Biến trạng thái máy (State Variables) ---
  double? smoothedRssi;
  bool walkUpConsumed = false;
  bool openedByWalkUp = false;
  bool hasBeenNearBike = false;
  bool hasEnteredDriveInSession = false;

  DateTime? connectedAt;
  DateTime? lastUserCommandAt;
  DateTime? sessionStartAt;

  bool autoSecureBusy = false;
  bool isCommandBusy = false;

  bool isLocked = true;
  bool isBikeOn = false;

  int autoLockCounter = 0;
  int theftCounter = 0;
  int rearmCounter = 0;
  int unlockNearCounter = 0;

  final List<String> eventLog = [];

  ProximitySafetyStateMachine({
    this.walkUpUnlock = true,
    this.walkUpAutoPowerOn = true,
    this.autoLockWalkAway = true,
    this.antiTheft5m = true,
    this.nearThreshold = -55.0,
    this.targetThreshold = -75.0,
    this.rearmThreshold = -78.0,
    KalmanFilter1D? customKalman,
  }) : kalman = customKalman ?? KalmanFilter1D(processNoise: 0.05, measurementNoise: 3.0);

  /// Rào chắn 15s đầu vừa kết nối:
  /// Được gỡ bỏ NGAY LẬP TỨC khi xe đã được mở bởi Walk-Up hoặc user đã từng bước sát xe!
  bool isEffectiveJustConnected(DateTime now) {
    if (connectedAt == null) return false;
    final in15sWindow = now.difference(connectedAt!) < const Duration(seconds: 15);
    // Nếu đã từng gần xe hoặc đã mở bởi Walk-Up -> rào chắn mất hiệu lực
    if (hasBeenNearBike || openedByWalkUp) {
      return false;
    }
    return in15sWindow;
  }

  /// Kiểm tra xe đang ở chế độ Đỗ / Standby an toàn để khóa tự động
  /// Dừng đèn đỏ ở Drive hoặc Super tuyệt đối KHÔNG phải là đỗ!
  bool isParkedOrStandby(BikeLogMsg tele) {
    if ((tele.state == BikeState.drive || tele.state == BikeState.super_) && !tele.parking) {
      return false; // Đang chạy hoặc dừng đèn đỏ ở số Drive/Super!
    }
    return true;
  }

  /// Xử lý mẫu RSSI đo được cùng telemetry xe
  void processSample(
    double curRssi,
    BikeLogMsg tele, {
    DateTime? now,
  }) {
    final currentTime = now ?? DateTime.now();

    // 1. Cơ chế Walk-Up Fast-Track Kalman
    // Nếu có độ vọt >= 8 dB và vượt ngưỡng gần (>= nearThreshold),
    // Fast-Track kích hoạt reset bộ lọc về giá trị đo mới nhất để bắt sóng tức thì.
    final prevEstimate = kalman.currentEstimate;
    if (prevEstimate != null &&
        (curRssi - prevEstimate) >= 8.0 &&
        curRssi >= nearThreshold) {
      kalman.reset(curRssi);
      smoothedRssi = curRssi;
      eventLog.add('fast_track_kalman_reset');
    } else {
      smoothedRssi = kalman.filter(curRssi);
    }

    final rssi = smoothedRssi!;
    final speed = tele.speed;

    // Ghi nhận trạng thái đã từng vào số Drive trong phiên làm việc
    if (tele.state == BikeState.drive || tele.state == BikeState.super_) {
      hasEnteredDriveInSession = true;
    }

    // Ghi nhận đã từng ở gần xe
    if (rssi >= nearThreshold) {
      hasBeenNearBike = true;
    }

    // 2. Tái vũ trang _walkUpConsumed khi thực sự rời xa
    // Cần 3 chu kỳ liên tiếp <= rearmThreshold
    if (walkUpConsumed) {
      if (rssi <= rearmThreshold) {
        rearmCounter++;
        if (rearmCounter >= 3) {
          walkUpConsumed = false;
          rearmCounter = 0;
          eventLog.add('walk_up_rearmed');
        }
      } else {
        rearmCounter = 0;
      }
    } else {
      rearmCounter = 0;
    }

    // Điều kiện cho phép tự động
    final effectiveJustConnected = isEffectiveJustConnected(currentTime);
    final userRecent = lastUserCommandAt != null &&
        currentTime.difference(lastUserCommandAt!) < const Duration(seconds: 10);

    final autoAllowed = !autoSecureBusy && !isCommandBusy && !userRecent && !effectiveJustConnected;
    final walkUpAllowed = !autoSecureBusy && !isCommandBusy && !userRecent;

    // 3. Walk-Up Unlock & Auto Power On
    if (walkUpUnlock && walkUpAllowed && !walkUpConsumed) {
      final needsUnlock = isLocked;
      final needsPower = walkUpAutoPowerOn && !isBikeOn;

      if (needsUnlock || needsPower) {
        if (rssi >= nearThreshold) {
          unlockNearCounter++;
          if (unlockNearCounter >= 1) {
            unlockNearCounter = 0;
            walkUpConsumed = true;
            openedByWalkUp = true;
            isLocked = false;
            if (walkUpAutoPowerOn) {
              isBikeOn = true;
            }
            sessionStartAt = currentTime;
            eventLog.add('walk_up_unlocked');
          }
        } else {
          unlockNearCounter = 0;
        }
      } else {
        unlockNearCounter = 0;
      }
    } else {
      unlockNearCounter = 0;
    }

    // 4. Chống trộm antiTheft5m (phân biệt tốc độ thấp <=15 km/h vs tốc độ cao >15 km/h)
    if (antiTheft5m && autoAllowed && isBikeOn && hasBeenNearBike) {
      final isHighSpeed = speed > kSpeedCutoff;
      final theftThresh = isHighSpeed ? kTheftHighSpeedThreshold : kTheftLowSpeedThreshold;
      final requiredCycles = isHighSpeed ? kTheftHighSpeedCycles : kTheftLowSpeedCycles;

      if (rssi <= theftThresh) {
        theftCounter++;
        if (theftCounter >= requiredCycles) {
          theftCounter = 0;
          hasBeenNearBike = false;
          isLocked = true;
          isBikeOn = false;
          eventLog.add('anti_theft_triggered');
        }
      } else {
        theftCounter = 0;
      }
    } else {
      theftCounter = 0;
    }

    // 5. Tự động khóa khi rời xa (Auto-Lock Walk-Away)
    // - Bắt buộc isParkedOrStandby == true (bảo vệ dừng đèn đỏ)
    // - Nếu chưa từng vào Drive trong session: chỉ cần 2 chu kỳ (mở lấy đồ rồi đi)
    // - Nếu đã từng vào Drive: cần 3 chu kỳ tiêu chuẩn
    final safeToAutoLock = isParkedOrStandby(tele) && speed <= 0.5;
    if (autoLockWalkAway && autoAllowed && isBikeOn && safeToAutoLock && hasBeenNearBike) {
      final requiredCycles = hasEnteredDriveInSession ? 3 : 2;
      if (rssi <= targetThreshold) {
        autoLockCounter++;
        if (autoLockCounter >= requiredCycles) {
          autoLockCounter = 0;
          hasBeenNearBike = false;
          isLocked = true;
          isBikeOn = false;
          eventLog.add('auto_lock_walk_away');
        }
      } else {
        autoLockCounter = 0;
      }
    } else {
      autoLockCounter = 0;
    }
  }

  /// Kiểm tra timeout 90 giây không vào Drive sau khi mở bằng Walk-Up
  void checkIdleTimeout(BikeLogMsg tele, DateTime now) {
    if (openedByWalkUp && !hasEnteredDriveInSession && isBikeOn) {
      final parked = tele.parking || tele.state == BikeState.parking || tele.state == BikeState.standBy;
      if (parked && tele.speed == 0.0) {
        if (sessionStartAt != null &&
            now.difference(sessionStartAt!).inSeconds >= kIdleTimeoutSeconds) {
          isBikeOn = false;
          isLocked = true;
          eventLog.add('idle_90s_timeout_locked');
        }
      }
    }
  }

  /// Người dùng chủ động bấm tắt xe trên ứng dụng
  void userManualTurnOff(DateTime now) {
    isBikeOn = false;
    isLocked = true;
    lastUserCommandAt = now;
    eventLog.add('user_manual_turned_off');
  }
}

class TestBleControllerHarness extends BleController {
  final BleState initialState;
  TestBleControllerHarness(this.initialState);

  @override
  BleState build() => initialState;

  @override
  Future<void> refreshFwSettings() async {}
}

void main() {
  group('Luồng 1 (Walk-Up Fast-Track Kalman)', () {
    test('Standard Kalman without Fast-Track is sluggish after distant connection (-78 dBm -> -50 dBm)', () {
      final kalman = KalmanFilter1D(processNoise: 0.05, measurementNoise: 3.0, initialEstimate: -78.0);
      expect(kalman.currentEstimate, -78.0);

      // Bước sát vào xe, nhận được mẫu mạnh -50 dBm
      final standardEstimate = kalman.filter(-50.0);

      // Nếu không có fast-track, bộ lọc bị trễ nặng nề, kẹt trong khoảng -72 dBm .. -62 dBm
      expect(standardEstimate, lessThan(-60.0),
          reason: 'Bộ lọc thường phải bị trễ và chưa thể chạm tới ngưỡng -55 dBm ngay');
      expect(standardEstimate, greaterThan(-75.0));
    });

    test('Fast-Track reset converges immediately to -50.0 dBm in 1 cycle when jump >= 8 dB and >= nearThreshold', () {
      final kalman = KalmanFilter1D(processNoise: 0.05, measurementNoise: 3.0, initialEstimate: -78.0);
      const curRssi = -50.0;
      const nearThreshold = -55.0;

      final prevEstimate = kalman.currentEstimate!;
      final jump = curRssi - prevEstimate; // 28.0 dB >= 8.0 dB
      expect(jump, greaterThanOrEqualTo(8.0));
      expect(curRssi, greaterThanOrEqualTo(nearThreshold));

      // Kích hoạt cơ chế Fast-Track
      kalman.reset(curRssi);

      expect(kalman.currentEstimate, equals(-50.0),
          reason: 'Fast-track phải đưa estimate về ngay -50.0 dBm chỉ trong 1 chu kỳ');
    });

    test('Small jump (< 8 dB) does NOT trigger fast-track reset, preserving Kalman noise suppression', () {
      final kalman = KalmanFilter1D(processNoise: 0.05, measurementNoise: 3.0, initialEstimate: -78.0);
      const curRssi = -72.0; // Tăng 6 dB (< 8 dB)
      final jump = curRssi - kalman.currentEstimate!;
      expect(jump, lessThan(8.0));

      final filtered = kalman.filter(curRssi);
      expect(filtered, isNot(equals(curRssi)),
          reason: 'Cú nhảy nhỏ phải được lọc mượt, không được reset đột ngột');
    });

    test('StateMachine executes instant walk-up unlock on cycle 1 with Fast-Track', () {
      final sm = ProximitySafetyStateMachine(
        nearThreshold: -55.0,
        customKalman: KalmanFilter1D(processNoise: 0.05, measurementNoise: 3.0, initialEstimate: -78.0),
      );
      final tele = BikeLogMsg()..state = BikeState.off..parking = true..speed = 0.0;

      // Bước sát xe: curRssi = -50.0 dBm
      sm.processSample(-50.0, tele);

      expect(sm.eventLog, contains('fast_track_kalman_reset'));
      expect(sm.eventLog, contains('walk_up_unlocked'));
      expect(sm.smoothedRssi, -50.0);
      expect(sm.isLocked, isFalse);
      expect(sm.isBikeOn, isTrue);
      expect(sm.walkUpConsumed, isTrue);
      expect(sm.openedByWalkUp, isTrue);
    });
  });

  group('Luồng 2A (Đứng gần 2-3m bị Body Shadowing suy hao thoáng qua)', () {
    test('Kalman filter dampens transient drop (-60 dBm -> -76 dBm -> -62 dBm)', () {
      final kalman = KalmanFilter1D(processNoise: 0.05, measurementNoise: 3.0, initialEstimate: -60.0);

      // 1 mẫu nhiễu do cơ thể xoay người che khuất tín hiệu tụt xuống -76 dBm
      final filteredDip = kalman.filter(-76.0);

      // Giá trị sau lọc chỉ giảm nhẹ (~ -63..-65 dBm), tuyệt đối không xuyên thủng ngưỡng -75 dBm
      expect(filteredDip, greaterThan(-70.0),
          reason: 'Kalman phải lọc mượt cú tụt tức thời do body shadowing');
      expect(filteredDip, greaterThan(-75.0));

      // Mẫu tiếp theo hồi phục lại -62 dBm
      final filteredRecover = kalman.filter(-62.0);
      expect(filteredRecover, greaterThan(-65.0));
    });

    test('Transient dip for 1 cycle does not increment auto-lock counter to threshold and resets immediately', () {
      final sm = ProximitySafetyStateMachine(targetThreshold: -75.0);
      sm.hasBeenNearBike = true;
      sm.isBikeOn = true;
      sm.isLocked = false;
      sm.hasEnteredDriveInSession = true; // Yêu cầu 3 chu kỳ

      final tele = BikeLogMsg()..state = BikeState.parking..parking = true..speed = 0.0;

      // Đứng ổn định ở -60 dBm
      sm.processSample(-60.0, tele);
      expect(sm.autoLockCounter, 0);

      // Giả sử có mẫu nhiễu cực đoan khiến smoothedRssi chạm -76 dBm trong 1 chu kỳ
      sm.kalman.reset(-76.0); // Ép giả lập smoothedRssi = -76.0
      sm.processSample(-76.0, tele);
      expect(sm.autoLockCounter, 1);
      expect(sm.eventLog, isNot(contains('auto_lock_walk_away')));

      // Chu kỳ tiếp theo sóng hồi về -62 dBm
      sm.kalman.reset(-62.0);
      sm.processSample(-62.0, tele);
      expect(sm.autoLockCounter, 0, reason: 'Bộ đếm auto-lock phải reset về 0 ngay khi RSSI hồi phục');
      expect(sm.isLocked, isFalse);
      expect(sm.isBikeOn, isTrue);
    });
  });

  group('Luồng 2B (Chốt 1 lần _walkUpConsumed & Timeout 90 giây)', () {
    test('Walk-Up locks once: _walkUpConsumed = true and _openedByWalkUp = true', () {
      final sm = ProximitySafetyStateMachine(nearThreshold: -55.0);
      final tele = BikeLogMsg()..state = BikeState.off..parking = true..speed = 0.0;

      sm.processSample(-52.0, tele);
      expect(sm.walkUpConsumed, isTrue);
      expect(sm.openedByWalkUp, isTrue);
      expect(sm.isLocked, isFalse);
      expect(sm.isBikeOn, isTrue);
    });

    test('User manually turns off bike while standing at -52 dBm -> Bike NEVER auto-powers on again', () {
      final sm = ProximitySafetyStateMachine(nearThreshold: -55.0);
      final tele = BikeLogMsg()..state = BikeState.off..parking = true..speed = 0.0;
      final t0 = DateTime(2026, 11, 9, 10, 0, 0);

      // Walk-up mở xe
      sm.processSample(-52.0, tele, now: t0);
      expect(sm.isBikeOn, isTrue);
      expect(sm.walkUpConsumed, isTrue);

      // Người dùng bấm tắt xe lúc t = 10s
      final t1 = t0.add(const Duration(seconds: 10));
      sm.userManualTurnOff(t1);
      expect(sm.isBikeOn, isFalse);
      expect(sm.isLocked, isTrue);

      // Người dùng vẫn đứng cách xe 1-2m (-52 dBm) trong 5 chu kỳ tiếp theo
      tele.state = BikeState.off;
      for (int i = 1; i <= 5; i++) {
        final tStep = t1.add(Duration(seconds: 15 + i * 2));
        sm.processSample(-52.0, tele, now: tStep);
        expect(sm.isBikeOn, isFalse,
            reason: 'Xe TUYỆT ĐỐI KHÔNG tự bật lại lần 2 khi user chưa rời xa');
        expect(sm.isLocked, isTrue);
      }
      expect(sm.eventLog.where((e) => e == 'walk_up_unlocked').length, 1);
    });

    test('90s idle timeout without entering Drive auto-locks bike and never re-triggers while nearby', () {
      final sm = ProximitySafetyStateMachine(nearThreshold: -55.0);
      final tele = BikeLogMsg()..state = BikeState.standBy..parking = true..speed = 0.0;
      final t0 = DateTime(2026, 11, 9, 10, 0, 0);

      // Walk-up mở xe lúc t = 0s
      sm.processSample(-52.0, tele, now: t0);
      expect(sm.openedByWalkUp, isTrue);
      expect(sm.hasEnteredDriveInSession, isFalse);

      // Đứng nói chuyện gần xe 90s (speed = 0, parking = true)
      final t90 = t0.add(const Duration(seconds: 90));
      sm.checkIdleTimeout(tele, t90);

      expect(sm.eventLog, contains('idle_90s_timeout_locked'));
      expect(sm.isBikeOn, isFalse);
      expect(sm.isLocked, isTrue);
      expect(sm.walkUpConsumed, isTrue);

      // Tiếp tục đứng ở -52 dBm ở giây 95..110
      for (int sec = 95; sec <= 110; sec += 3) {
        final tLater = t0.add(Duration(seconds: sec));
        sm.processSample(-52.0, tele, now: tLater);
        expect(sm.isBikeOn, isFalse);
        expect(sm.isLocked, isTrue);
      }
    });
  });

  group('Luồng 3 (Lại gần mở xe lấy đồ trong 5 giây rồi đi xa ngay - Expedited Auto-Lock)', () {
    test('Approaching bike immediately removes effectiveJustConnected 15s barrier', () {
      final sm = ProximitySafetyStateMachine();
      final t0 = DateTime(2026, 11, 9, 10, 0, 0);
      sm.connectedAt = t0;

      // Ban đầu ở xa (-80 dBm), barrier có hiệu lực trong 15s đầu
      expect(sm.isEffectiveJustConnected(t0.add(const Duration(seconds: 2))), isTrue);

      // Lại gần xe (-50 dBm) lúc t = 3s
      final tele = BikeLogMsg()..state = BikeState.off..parking = true..speed = 0.0;
      sm.processSample(-50.0, tele, now: t0.add(const Duration(seconds: 3)));

      expect(sm.hasBeenNearBike, isTrue);
      expect(sm.openedByWalkUp, isTrue);
      // Rào chắn 15s phải bị xoá bỏ ngay lập tức!
      expect(sm.isEffectiveJustConnected(t0.add(const Duration(seconds: 4))), isFalse);
    });

    test('Without entering Drive, auto-lock requires only 2 cycles and locks at second 7', () {
      final sm = ProximitySafetyStateMachine(targetThreshold: -75.0);
      final t0 = DateTime(2026, 11, 9, 10, 0, 0);
      sm.connectedAt = t0;
      final tele = BikeLogMsg()..state = BikeState.standBy..parking = true..speed = 0.0;

      // Giây thứ 2: Mở xe lấy đồ
      final t2 = t0.add(const Duration(seconds: 2));
      sm.processSample(-50.0, tele, now: t2);
      expect(sm.isBikeOn, isTrue);
      expect(sm.hasEnteredDriveInSession, isFalse);

      // Giây thứ 5: Đi ra xa, smoothed RSSI đạt -76 dBm <= targetThreshold (-75 dBm) (chu kỳ 1)
      final t5 = t0.add(const Duration(seconds: 5));
      sm.kalman.reset(-76.0);
      sm.processSample(-76.0, tele, now: t5);
      expect(sm.autoLockCounter, 1);
      expect(sm.isLocked, isFalse);

      // Giây thứ 7: Vẫn ở xa, smoothed RSSI đạt -78 dBm <= targetThreshold (-75 dBm) (chu kỳ 2)
      final t7 = t0.add(const Duration(seconds: 7));
      sm.processSample(-78.0, tele, now: t7);
      expect(sm.eventLog, contains('auto_lock_walk_away'));
      expect(sm.isLocked, isTrue);
      expect(sm.isBikeOn, isFalse);
      expect(sm.autoLockCounter, 0);
    });
  });

  group('Case 4 (Bảo vệ khi dừng đèn đỏ ở mode Drive / Super)', () {
    test('isParkedOrStandby is false when in Drive or Super mode without parking stand', () {
      final sm = ProximitySafetyStateMachine();

      final driveMsg = BikeLogMsg()..state = BikeState.drive..parking = false..speed = 0.0;
      expect(sm.isParkedOrStandby(driveMsg), isFalse);

      final superMsg = BikeLogMsg()..state = BikeState.super_..parking = false..speed = 0.0;
      expect(sm.isParkedOrStandby(superMsg), isFalse);

      final parkedDriveMsg = BikeLogMsg()..state = BikeState.drive..parking = true..speed = 0.0;
      expect(sm.isParkedOrStandby(parkedDriveMsg), isTrue);

      final standByMsg = BikeLogMsg()..state = BikeState.standBy..parking = false..speed = 0.0;
      expect(sm.isParkedOrStandby(standByMsg), isTrue);
    });

    test('Auto-lock is NEVER triggered at red light even if RSSI drops to -80 dBm for 5 cycles', () {
      final sm = ProximitySafetyStateMachine(
        targetThreshold: -75.0,
        antiTheft5m: false, // Cô lập kiểm tra tính năng autoLockWalkAway
      );
      sm.hasBeenNearBike = true;
      sm.isBikeOn = true;
      sm.isLocked = false;

      // Xe đang dừng đèn đỏ: số Drive, không hạ chân chống, tốc độ 0.0 km/h
      final redLightMsg = BikeLogMsg()
        ..state = BikeState.drive
        ..parking = false
        ..speed = 0.0;

      // Điện thoại đút sâu túi quần hoặc bị nhiễu sóng, RSSI = -80 dBm trong 5 chu kỳ
      for (int i = 1; i <= 5; i++) {
        sm.processSample(-80.0, redLightMsg);
        expect(sm.autoLockCounter, 0,
            reason: 'Chu kỳ $i: Không được tăng autoLockCounter khi xe ở số Drive tại ngã tư');
        expect(sm.isBikeOn, isTrue);
        expect(sm.isLocked, isFalse);
      }

      expect(sm.eventLog, isNot(contains('auto_lock_walk_away')));
    });

    test('Super mode red light stop is equally protected against walk-away auto lock', () {
      final sm = ProximitySafetyStateMachine(
        targetThreshold: -75.0,
        antiTheft5m: false, // Cô lập kiểm tra tính năng autoLockWalkAway
      );
      sm.hasBeenNearBike = true;
      sm.isBikeOn = true;
      sm.isLocked = false;

      final superMsg = BikeLogMsg()
        ..state = BikeState.super_
        ..parking = false
        ..speed = 0.0;

      for (int i = 1; i <= 5; i++) {
        sm.processSample(-82.0, superMsg);
        expect(sm.autoLockCounter, 0);
      }
      expect(sm.eventLog, isNot(contains('auto_lock_walk_away')));
      expect(sm.isBikeOn, isTrue);
    });
  });

  group('Case 5 (Tái vũ trang _walkUpConsumed khi thực sự rời xa)', () {
    test('_walkUpConsumed remains true for 1 or 2 cycles <= rearmThreshold', () {
      final sm = ProximitySafetyStateMachine(rearmThreshold: -78.0);
      sm.walkUpConsumed = true;
      final tele = BikeLogMsg()..state = BikeState.off..parking = true..speed = 0.0;

      // Chu kỳ 1: -80 dBm
      sm.processSample(-80.0, tele);
      expect(sm.rearmCounter, 1);
      expect(sm.walkUpConsumed, isTrue);

      // Chu kỳ 2: -82 dBm
      sm.processSample(-82.0, tele);
      expect(sm.rearmCounter, 2);
      expect(sm.walkUpConsumed, isTrue);
    });

    test('3 consecutive cycles <= rearmThreshold successfully rearms _walkUpConsumed to false', () {
      final sm = ProximitySafetyStateMachine(rearmThreshold: -78.0);
      sm.walkUpConsumed = true;
      final tele = BikeLogMsg()..state = BikeState.off..parking = true..speed = 0.0;

      sm.processSample(-80.0, tele);
      sm.processSample(-82.0, tele);
      sm.processSample(-85.0, tele);

      expect(sm.rearmCounter, 0);
      expect(sm.walkUpConsumed, isFalse, reason: 'Sau 3 chu kỳ rời xa, walkUpConsumed phải được nạp lại');
      expect(sm.eventLog, contains('walk_up_rearmed'));
    });

    test('Temporary rebound above rearmThreshold resets the 3-cycle rearm counter', () {
      final sm = ProximitySafetyStateMachine(rearmThreshold: -78.0);
      sm.walkUpConsumed = true;
      final tele = BikeLogMsg()..state = BikeState.off..parking = true..speed = 0.0;

      sm.processSample(-80.0, tele); // Counter = 1
      sm.processSample(-81.0, tele); // Counter = 2

      // Sóng hồi phục đưa smoothedRssi lên trên ngưỡng rearmThreshold (-78 dBm)
      sm.kalman.reset(-70.0);
      sm.processSample(-70.0, tele);

      expect(sm.rearmCounter, 0, reason: 'Nhiễu sóng bật lại phải reset rearmCounter');
      expect(sm.walkUpConsumed, isTrue);
    });

    test('After full rearm, user returning near (RSSI >= -55 dBm) triggers walk-up unlock normally', () {
      final sm = ProximitySafetyStateMachine(nearThreshold: -55.0, rearmThreshold: -78.0);
      sm.walkUpConsumed = true;
      sm.isLocked = true;
      sm.isBikeOn = false;
      final tele = BikeLogMsg()..state = BikeState.off..parking = true..speed = 0.0;

      // 3 chu kỳ rời xa
      sm.processSample(-80.0, tele);
      sm.processSample(-82.0, tele);
      sm.processSample(-84.0, tele);
      expect(sm.walkUpConsumed, isFalse);

      // Quay lại gần xe
      sm.processSample(-52.0, tele);
      expect(sm.eventLog, contains('walk_up_unlocked'));
      expect(sm.isLocked, isFalse);
      expect(sm.isBikeOn, isTrue);
      expect(sm.walkUpConsumed, isTrue);
    });
  });

  group('Case 6 (Chống trộm antiTheft5m phân biệt tốc độ thấp và cao)', () {
    test('Low speed (speed <= 15 km/h): triggers after 5 consecutive cycles with RSSI <= -78 dBm', () {
      final sm = ProximitySafetyStateMachine();
      sm.hasBeenNearBike = true;
      sm.isBikeOn = true;
      sm.isLocked = false;

      // Xe đang bị dắt trộm với tốc độ 6.0 km/h (<= 15 km/h)
      final lowSpeedMsg = BikeLogMsg()..state = BikeState.drive..parking = false..speed = 6.0;

      for (int i = 1; i <= 4; i++) {
        sm.processSample(-80.0, lowSpeedMsg);
        expect(sm.theftCounter, i);
        expect(sm.eventLog, isNot(contains('anti_theft_triggered')));
      }

      // Chu kỳ thứ 5
      sm.processSample(-80.0, lowSpeedMsg);
      expect(sm.eventLog, contains('anti_theft_triggered'));
      expect(sm.isLocked, isTrue);
      expect(sm.isBikeOn, isFalse);
      expect(sm.theftCounter, 0);
    });

    test('High speed (speed > 15 km/h): RSSI -80 dBm for 10 cycles does NOT trigger (requires <= -85 dBm)', () {
      final sm = ProximitySafetyStateMachine();
      sm.hasBeenNearBike = true;
      sm.isBikeOn = true;
      sm.isLocked = false;

      // Xe đang di chuyển tốc độ cao 45 km/h
      final highSpeedMsg = BikeLogMsg()..state = BikeState.drive..parking = false..speed = 45.0;

      // RSSI = -80 dBm (mức kích hoạt tốc độ thấp) trong 10 chu kỳ
      for (int i = 1; i <= 10; i++) {
        sm.processSample(-80.0, highSpeedMsg);
        expect(sm.theftCounter, 0,
            reason: 'Tốc độ cao yêu cầu RSSI <= -85 dBm; -80 dBm không được tính vào counter');
      }
      expect(sm.eventLog, isNot(contains('anti_theft_triggered')));
      expect(sm.isBikeOn, isTrue);
    });

    test('High speed: RSSI <= -85 dBm requires 8 consecutive cycles (5 cycles is insufficient)', () {
      final sm = ProximitySafetyStateMachine();
      sm.hasBeenNearBike = true;
      sm.isBikeOn = true;
      sm.isLocked = false;

      final highSpeedMsg = BikeLogMsg()..state = BikeState.drive..parking = false..speed = 35.0;

      // 5 chu kỳ đầu (đủ với low-speed nhưng KHÔNG đủ với high-speed)
      for (int i = 1; i <= 5; i++) {
        sm.processSample(-88.0, highSpeedMsg);
        expect(sm.theftCounter, i);
        expect(sm.eventLog, isNot(contains('anti_theft_triggered')),
            reason: '5 chu kỳ chưa đủ đối với chế độ chạy nhanh');
      }

      // Chu kỳ 6 và 7
      sm.processSample(-88.0, highSpeedMsg);
      expect(sm.theftCounter, 6);
      sm.processSample(-88.0, highSpeedMsg);
      expect(sm.theftCounter, 7);
      expect(sm.eventLog, isNot(contains('anti_theft_triggered')));

      // Chu kỳ thứ 8: Kích hoạt chống trộm
      sm.processSample(-88.0, highSpeedMsg);
      expect(sm.eventLog, contains('anti_theft_triggered'));
      expect(sm.isLocked, isTrue);
      expect(sm.isBikeOn, isFalse);
    });

    test('High speed: temporary glitch above -85 dBm at cycle 6 resets cycle counter to 0', () {
      final sm = ProximitySafetyStateMachine();
      sm.hasBeenNearBike = true;
      sm.isBikeOn = true;
      sm.isLocked = false;

      final highSpeedMsg = BikeLogMsg()..state = BikeState.drive..parking = false..speed = 40.0;

      // 5 chu kỳ sâu
      for (int i = 1; i <= 5; i++) {
        sm.processSample(-89.0, highSpeedMsg);
      }
      expect(sm.theftCounter, 5);

      // Chu kỳ 6: Tín hiệu vọt lên trên -85 dBm (ví dụ -75 dBm)
      sm.kalman.reset(-75.0);
      sm.processSample(-75.0, highSpeedMsg);
      expect(sm.theftCounter, 0, reason: 'Nhiễu sóng vọt lên phải xóa chuỗi counter về 0');
      expect(sm.eventLog, isNot(contains('anti_theft_triggered')));
    });
  });

  group('BleState & BleController Proximity Configuration Integration', () {
    test('Default BleState values align with Safety State Machine defaults', () {
      const state = BleState(phase: BlePhase.idle);
      expect(state.walkUpUnlock, isFalse);
      expect(state.antiTheft5m, isFalse);
      expect(state.walkUpAutoPowerOn, isFalse);
      expect(state.autoLockWalkAway, isFalse);
      expect(state.walkUpRssiThreshold, isNull); // Sẽ fallback về -55.0 dBm
      expect(state.autoLockRssiThreshold, isNull);
    });

    test('TestBleControllerHarness updates safety toggles and parameters', () async {
      SharedPreferences.setMockInitialValues({});
      final controller = TestBleControllerHarness(const BleState(phase: BlePhase.idle));
      final container = ProviderContainer(
        overrides: [bleProvider.overrideWith(() => controller)],
      );
      addTearDown(container.dispose);

      final notifier = container.read(bleProvider.notifier);
      await notifier.setWalkUpUnlock(true);
      await notifier.setWalkUpAutoPowerOn(true);
      await notifier.setAntiTheft5m(true);
      await notifier.setWalkUpRssiThreshold(-52.0);

      final s = container.read(bleProvider);
      expect(s.walkUpUnlock, isTrue);
      expect(s.walkUpAutoPowerOn, isTrue);
      expect(s.antiTheft5m, isTrue);
      expect(s.walkUpRssiThreshold, -52.0);
    });
  });

  group('Real BleController Proximity & iOS Bugfixes', () {
    Future<void> waitUntil(
      bool Function() condition, {
      Duration timeout = const Duration(seconds: 5),
    }) async {
      final deadline = DateTime.now().add(timeout);
      while (!condition()) {
        if (DateTime.now().isAfter(deadline)) break;
        await Future.delayed(const Duration(milliseconds: 20));
      }
    }

    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    test('BleState.forNewConnection preserves user proximity settings while resetting session state', () {
      final dev = BluetoothDevice.fromId('AA:BB:CC:DD:EE:01');
      final prev = BleState(
        phase: BlePhase.connected,
        isAuthorized: true,
        isLocked: true,
        rssi: -70,
        filteredRssi: -71,
        autoLockWalkAway: true,
        walkUpUnlock: true,
        walkUpAutoPowerOn: true,
        walkUpRssiThreshold: -62.0,
        autoLockRssiThreshold: -80.0,
        antiTheft5m: true,
        antiForgetAlert: true,
        autoLockDistance: 2,
      );

      final next = prev.forNewConnection(
        device: dev,
        bikeName: 'My Quantum',
        bikeModel: BikeModel.qtS1,
      );

      expect(next.phase, BlePhase.connecting);
      expect(next.isAuthorized, isFalse);
      expect(next.isLocked, isFalse);
      expect(next.rssi, isNull);
      expect(next.filteredRssi, isNull);
      expect(next.autoLockWalkAway, isTrue);
      expect(next.walkUpUnlock, isTrue);
      expect(next.walkUpAutoPowerOn, isTrue);
      expect(next.walkUpRssiThreshold, -62.0);
      expect(next.autoLockRssiThreshold, -80.0);
      expect(next.antiTheft5m, isTrue);
      expect(next.antiForgetAlert, isTrue);
      expect(next.autoLockDistance, 2);
    });

    test('iOS uses calibrated RSSI defaults (-62 walk-up, [-72, -80, -88] auto-lock)', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final iosController = TestBleControllerHarness(const BleState(phase: BlePhase.idle));
      final container = ProviderContainer(
        overrides: [bleProvider.overrideWith(() => iosController)],
      );
      addTearDown(container.dispose);

      container.read(bleProvider);
      expect(iosController.effectiveWalkUpRssiThreshold, -62.0);
      expect(iosController.effectiveAutoLockRssiThreshold, -80.0);

      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(iosController.effectiveWalkUpRssiThreshold, -55.0);
      expect(iosController.effectiveAutoLockRssiThreshold, -83.0);
    });

    test('Invalid RSSI sentinels (127, 0, +5, -120) are ignored', () {
      final tele = BikeLogMsg()
        ..state = BikeState.lock
        ..speed = 0.0;
      final controller = TestBleControllerHarness(BleState(
        phase: BlePhase.connected,
        isAuthorized: true,
        isLocked: true,
        walkUpUnlock: true,
        lastTelemetry: tele,
      ));
      final container = ProviderContainer(
        overrides: [bleProvider.overrideWith(() => controller)],
      );
      addTearDown(container.dispose);
      container.read(bleProvider);

      var writeCalled = false;
      controller.writeSettingTestOverride = (uuid, data, label) async {
        writeCalled = true;
        return 'Đã ghi $label xuống xe (0)';
      };

      controller.ingestRssiForTest(127);
      controller.ingestRssiForTest(0);
      controller.ingestRssiForTest(5);
      controller.ingestRssiForTest(-120);

      expect(controller.smoothedRssiForTest, isNull);
      expect(container.read(bleProvider).rssi, isNull);
      expect(writeCalled, isFalse);
    });

    test('Walk-up unlocks BikeState.lock and immediately powers on without lock guard error, then expedited walk-away locks', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final tele = BikeLogMsg()
        ..state = BikeState.lock
        ..parking = true
        ..speed = 0.0;
      final controller = TestBleControllerHarness(BleState(
        phase: BlePhase.connected,
        isAuthorized: true,
        isLocked: true,
        walkUpUnlock: true,
        walkUpAutoPowerOn: true,
        autoLockWalkAway: true,
        sessionKey: Uint8List(16),
        lastTelemetry: tele,
      ));
      final container = ProviderContainer(
        overrides: [bleProvider.overrideWith(() => controller)],
      );
      addTearDown(container.dispose);
      container.read(bleProvider);

      final ops = <String>[];
      controller.writeSettingTestOverride = (uuid, data, label) async {
        if (uuid == Gatt.powerProtectedChar) {
          ops.add(data.first == 0x30 ? 'unlock' : 'lock');
        }
        return 'Đã ghi $label xuống xe (${String.fromCharCodes(data)})';
      };
      controller.sendPowerTestOverride = (val, label) async {
        ops.add(val == '1' ? 'power_on' : 'power_off');
      };

      final t0 = DateTime(2026, 1, 1, 10, 0, 0);
      controller.setProximityTestTimestamps(connectedAt: t0.subtract(const Duration(seconds: 1)));

      // Bắt đầu ở -66 dBm -> bước gần tới -60 dBm (trên iOS threshold -62 dBm với jump >= 5 dB)
      controller.ingestRssiForTest(-66, now: t0);
      controller.ingestRssiForTest(-60, now: t0.add(const Duration(seconds: 1)));

      await waitUntil(() =>
          ops.length == 2 &&
          !container.read(bleProvider).isLocked &&
          container.read(bleProvider).lastTelemetry?.isBikeOn == true);

      expect(ops, ['unlock', 'power_on']);
      final afterWalkUp = container.read(bleProvider);
      expect(afterWalkUp.isLocked, isFalse);
      expect(afterWalkUp.lastTelemetry?.isBikeOn, isTrue);

      // Rời xa ngay sau 3 giây: không bị block bởi 10s manual cooldown!
      final tLeave = t0.add(const Duration(seconds: 4));
      controller.ingestRssiForTest(-82, now: tLeave);
      controller.ingestRssiForTest(-83, now: tLeave.add(const Duration(seconds: 1)));
      controller.ingestRssiForTest(-84, now: tLeave.add(const Duration(seconds: 2)));
      controller.ingestRssiForTest(-85, now: tLeave.add(const Duration(seconds: 3)));
      await waitUntil(() =>
          ops.length == 4 &&
          container.read(bleProvider).isLocked &&
          !controller.walkUpConsumedForTest);

      expect(ops, ['unlock', 'power_on', 'power_off', 'lock']);
      expect(container.read(bleProvider).isLocked, isTrue);
      // Walk-up phải tự tái vũ trang nếu user quay lại trước khi BLE ngắt
      expect(controller.walkUpConsumedForTest, isFalse);
    });

    test('Failed unlock keeps isLocked=true and retries after 3s cooldown', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final tele = BikeLogMsg()
        ..state = BikeState.lock
        ..parking = true
        ..speed = 0.0;
      final controller = TestBleControllerHarness(BleState(
        phase: BlePhase.connected,
        isAuthorized: true,
        isLocked: true,
        walkUpUnlock: true,
        walkUpAutoPowerOn: false,
        sessionKey: Uint8List(16),
        lastTelemetry: tele,
      ));
      final container = ProviderContainer(
        overrides: [bleProvider.overrideWith(() => controller)],
      );
      addTearDown(container.dispose);
      container.read(bleProvider);

      int attempt = 0;
      controller.writeSettingTestOverride = (uuid, data, label) async {
        attempt++;
        if (attempt == 1) {
          return 'Lỗi ghi $label: BLE timeout';
        }
        return 'Đã ghi $label xuống xe (${String.fromCharCodes(data)})';
      };

      final t0 = DateTime(2026, 1, 1, 10, 0, 0);
      controller.ingestRssiForTest(-58, now: t0);
      await waitUntil(() => attempt == 1);

      expect(attempt, 1);
      expect(container.read(bleProvider).isLocked, isTrue);
      expect(controller.walkUpConsumedForTest, isFalse);

      // Trong thời gian cooldown 3s không spam gửi lại
      controller.ingestRssiForTest(-58, now: t0.add(const Duration(seconds: 1)));
      await Future.delayed(const Duration(milliseconds: 40));
      expect(attempt, 1);

      // Sau 3s cooldown: tự thử lại và mở khóa thành công
      controller.ingestRssiForTest(-58, now: t0.add(const Duration(seconds: 4)));
      await waitUntil(() => attempt == 2 && !container.read(bleProvider).isLocked);
      expect(attempt, 2);
      expect(container.read(bleProvider).isLocked, isFalse);
    });

    test('Walk-away locks unlocked bike even when walkUpAutoPowerOn is false, while single spike does not lock', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final tele = BikeLogMsg()
        ..state = BikeState.off
        ..parking = true
        ..speed = 0.0;
      final controller = TestBleControllerHarness(BleState(
        phase: BlePhase.connected,
        isAuthorized: true,
        isLocked: false,
        walkUpUnlock: true,
        walkUpAutoPowerOn: false,
        autoLockWalkAway: true,
        sessionKey: Uint8List(16),
        lastTelemetry: tele,
      ));
      final container = ProviderContainer(
        overrides: [bleProvider.overrideWith(() => controller)],
      );
      addTearDown(container.dispose);
      container.read(bleProvider);

      int lockCount = 0;
      controller.writeSettingTestOverride = (uuid, data, label) async {
        if (uuid == Gatt.powerProtectedChar && data.first == 0x31) {
          lockCount++;
        }
        return 'Đã ghi $label xuống xe (${String.fromCharCodes(data)})';
      };

      final t0 = DateTime(2026, 1, 1, 10, 0, 0);
      // Đã đứng gần xe
      controller.ingestRssiForTest(-60, now: t0);
      expect(controller.hasBeenNearBikeForTest, isTrue);

      // 1-2 nhịp che thân thoáng qua KHÔNG được khóa
      controller.ingestRssiForTest(-85, now: t0.add(const Duration(seconds: 1)));
      controller.ingestRssiForTest(-60, now: t0.add(const Duration(seconds: 2)));
      await Future.delayed(const Duration(milliseconds: 30));
      expect(lockCount, 0);

      // Rời xa thực sự 5 nhịp -> tự khóa dù xe đang tắt máy (walkUpAutoPowerOn == false)
      for (int i = 1; i <= 5; i++) {
        controller.ingestRssiForTest(-84, now: t0.add(Duration(seconds: 2 + i)));
      }
      await waitUntil(() => lockCount == 1 && container.read(bleProvider).isLocked);
      expect(lockCount, 1);
      expect(container.read(bleProvider).isLocked, isTrue);
    });

    test('onAppResumed clears stale RSSI when last sample is > 4 seconds old', () async {
      final tele = BikeLogMsg()..state = BikeState.off;
      final controller = TestBleControllerHarness(BleState(
        phase: BlePhase.connected,
        isAuthorized: true,
        lastTelemetry: tele,
      ));
      final container = ProviderContainer(
        overrides: [bleProvider.overrideWith(() => controller)],
      );
      addTearDown(container.dispose);
      container.read(bleProvider);

      controller.ingestRssiForTest(
        -58,
        now: DateTime.now().subtract(const Duration(seconds: 10)),
      );
      expect(container.read(bleProvider).rssi, -58);
      expect(container.read(bleProvider).filteredRssi, -58);

      await controller.onAppResumed();
      expect(container.read(bleProvider).rssi, isNull);
      expect(container.read(bleProvider).filteredRssi, isNull);
    });

    test('Time-gap > 4s in _ingestRssiSample resets stale far RSSI immediately and unlocks walk-up', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final tele = BikeLogMsg()
        ..state = BikeState.lock
        ..parking = true
        ..speed = 0.0;
      final controller = TestBleControllerHarness(BleState(
        phase: BlePhase.connected,
        isAuthorized: true,
        isLocked: true,
        walkUpUnlock: true,
        walkUpAutoPowerOn: false,
        sessionKey: Uint8List(16),
        lastTelemetry: tele,
      ));
      final container = ProviderContainer(
        overrides: [bleProvider.overrideWith(() => controller)],
      );
      addTearDown(container.dispose);
      container.read(bleProvider);

      int unlockCount = 0;
      controller.writeSettingTestOverride = (uuid, data, label) async {
        if (uuid == Gatt.powerProtectedChar && data.first == 0x30) {
          unlockCount++;
        }
        return 'Đã ghi $label xuống xe (${String.fromCharCodes(data)})';
      };

      final t0 = DateTime(2026, 1, 1, 10, 0, 0);
      controller.ingestRssiForTest(-92, now: t0);
      expect(controller.smoothedRssiForTest, -92.0);

      // Giả lập OS throttle / mất sóng 6 giây (> 4s), user đã đứng sát xe (-60 dBm)
      controller.ingestRssiForTest(-60, now: t0.add(const Duration(seconds: 6)));
      expect(controller.smoothedRssiForTest, -60.0);
      expect(container.read(bleProvider).filteredRssi, -60);

      await waitUntil(() => unlockCount == 1 && !container.read(bleProvider).isLocked);
      expect(unlockCount, 1);
      expect(container.read(bleProvider).isLocked, isFalse);
    });

    test('Approach fast-track converges -92 -> -82 -> -74 -> -66 -> -60 quickly while rejecting single spike', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final tele = BikeLogMsg()
        ..state = BikeState.lock
        ..parking = true
        ..speed = 0.0;
      final controller = TestBleControllerHarness(BleState(
        phase: BlePhase.connected,
        isAuthorized: true,
        isLocked: true,
        walkUpUnlock: true,
        walkUpAutoPowerOn: false,
        sessionKey: Uint8List(16),
        lastTelemetry: tele,
      ));
      final container = ProviderContainer(
        overrides: [bleProvider.overrideWith(() => controller)],
      );
      addTearDown(container.dispose);
      container.read(bleProvider);

      int unlockCount = 0;
      controller.writeSettingTestOverride = (uuid, data, label) async {
        if (uuid == Gatt.powerProtectedChar && data.first == 0x30) {
          unlockCount++;
        }
        return 'Đã ghi $label xuống xe (${String.fromCharCodes(data)})';
      };

      final t0 = DateTime(2026, 1, 1, 10, 0, 0);
      controller.ingestRssiForTest(-92, now: t0);
      controller.ingestRssiForTest(-82, now: t0.add(const Duration(seconds: 1)));
      controller.ingestRssiForTest(-74, now: t0.add(const Duration(seconds: 2)));
      // Sau 2 mẫu đi bộ tăng mạnh liên tiếp, bộ lọc không bị kéo tụt dưới -75 dBm
      expect(controller.smoothedRssiForTest!, greaterThanOrEqualTo(-75.0));

      controller.ingestRssiForTest(-66, now: t0.add(const Duration(seconds: 3)));
      expect(controller.smoothedRssiForTest!, greaterThan(-70.0));

      controller.ingestRssiForTest(-60, now: t0.add(const Duration(seconds: 4)));
      expect(controller.smoothedRssiForTest, -60.0);
      await waitUntil(() => unlockCount == 1 && !container.read(bleProvider).isLocked);
      expect(unlockCount, 1);

      // Kiểm chứng nhiễu 1 nhịp đơn lẻ (-90 -> -72 -> -90) không snap vĩnh viễn lên trên
      final spikeController = TestBleControllerHarness(BleState(
        phase: BlePhase.connected,
        isAuthorized: true,
        isLocked: true,
        walkUpUnlock: true,
        lastTelemetry: tele,
      ));
      final spikeContainer = ProviderContainer(
        overrides: [bleProvider.overrideWith(() => spikeController)],
      );
      addTearDown(spikeContainer.dispose);
      spikeContainer.read(bleProvider);

      spikeController.ingestRssiForTest(-90, now: t0);
      spikeController.ingestRssiForTest(-72, now: t0.add(const Duration(seconds: 1)));
      expect(spikeController.smoothedRssiForTest!, lessThan(-80.0));
      spikeController.ingestRssiForTest(-90, now: t0.add(const Duration(seconds: 2)));
      expect(spikeController.smoothedRssiForTest!, lessThan(-83.0));
    });

    test('BleController.estimateDistanceMetersFromRssi calibrates iOS vs Android', () {
      final iosClose = BleController.estimateDistanceMetersFromRssi(-62, isIos: true);
      final androidClose = BleController.estimateDistanceMetersFromRssi(-62, isIos: false);
      expect(iosClose, lessThanOrEqualTo(1.5));
      expect(iosClose, lessThan(androidClose));

      // Kiểm tra clamp [0.5, 25.0]
      expect(BleController.estimateDistanceMetersFromRssi(-35, isIos: true), 0.5);
      expect(BleController.estimateDistanceMetersFromRssi(-110, isIos: false), 25.0);
    });

    test('setAutoLockDistance uses platform-specific thresholds ([-72, -80, -88] on iOS)', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final iosController = TestBleControllerHarness(const BleState(phase: BlePhase.idle));
      final iosContainer = ProviderContainer(
        overrides: [bleProvider.overrideWith(() => iosController)],
      );
      addTearDown(iosContainer.dispose);
      iosContainer.read(bleProvider);

      await iosController.setAutoLockDistance(0);
      expect(iosContainer.read(bleProvider).autoLockRssiThreshold, -72.0);
      await iosController.setAutoLockDistance(1);
      expect(iosContainer.read(bleProvider).autoLockRssiThreshold, -80.0);
      await iosController.setAutoLockDistance(2);
      expect(iosContainer.read(bleProvider).autoLockRssiThreshold, -88.0);

      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await iosController.setAutoLockDistance(0);
      expect(iosContainer.read(bleProvider).autoLockRssiThreshold, -75.0);
      await iosController.setAutoLockDistance(1);
      expect(iosContainer.read(bleProvider).autoLockRssiThreshold, -83.0);
      await iosController.setAutoLockDistance(2);
      expect(iosContainer.read(bleProvider).autoLockRssiThreshold, -90.0);
    });

    test('Telemetry arriving after an early close RSSI triggers walk-up, and setRadarScreenActive toggles safely', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      // Chưa có telemetry lúc mới kết nối
      final controller = TestBleControllerHarness(BleState(
        phase: BlePhase.connected,
        isAuthorized: true,
        isLocked: true,
        walkUpUnlock: true,
        walkUpAutoPowerOn: false,
        sessionKey: Uint8List(16),
      ));
      final container = ProviderContainer(
        overrides: [bleProvider.overrideWith(() => controller)],
      );
      addTearDown(container.dispose);
      container.read(bleProvider);

      int unlockCount = 0;
      controller.writeSettingTestOverride = (uuid, data, label) async {
        if (uuid == Gatt.powerProtectedChar && data.first == 0x30) {
          unlockCount++;
        }
        return 'Đã ghi $label xuống xe (${String.fromCharCodes(data)})';
      };

      // setRadarScreenActive toggle an toàn khi chưa có _dashChar
      expect(controller.radarScreenActiveForTest, isFalse);
      controller.setRadarScreenActive(true);
      expect(controller.radarScreenActiveForTest, isTrue);
      controller.setRadarScreenActive(false);
      expect(controller.radarScreenActiveForTest, isFalse);

      // RSSI gần tới trước khi telemetry hợp lệ tới
      controller.ingestRssiForTest(-58, now: DateTime.now());
      await Future.delayed(const Duration(milliseconds: 30));
      expect(unlockCount, 0);

      // Telemetry BikeState.lock hợp lệ tới sau -> tự kích hoạt walk-up ngay lập tức
      final raw = Uint8List(41);
      final bd = ByteData.sublistView(raw);
      bd.setFloat32(0, 120.5, Endian.little); // odo
      bd.setFloat32(4, 0.0, Endian.little); // speed
      raw[14] = 1; // parking
      bd.setFloat32(15, 72.0, Endian.little); // voltage
      raw[19] = 85; // percent
      raw[32] = BikeState.lock.index; // lock state

      controller.handleDashboardPayloadForTest(raw);
      await waitUntil(() => unlockCount == 1 && !container.read(bleProvider).isLocked);
      expect(unlockCount, 1);
      expect(container.read(bleProvider).isLocked, isFalse);
    });
  });
}
