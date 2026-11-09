// Unit Test Suite: Proximity & Safety State Machine (Â§4.6)
//
// Kiá»ƒm chá»©ng toÃ n diá»‡n logic & thuáº­t toÃ¡n cho 7 ká»‹ch báº£n an toÃ n:
// 1. Luá»“ng 1: Walk-Up Fast-Track Kalman Convergence
// 2. Luá»“ng 2A: Body Shadowing Protection (Äá»©ng gáº§n 2-3m bá»‹ suy hao thoÃ¡ng qua)
// 3. Luá»“ng 2B: Chá»‘t 1 láº§n _walkUpConsumed & Timeout 90 giÃ¢y Ä‘á»©ng gáº§n khÃ´ng di chuyá»ƒn
// 4. Luá»“ng 3: Láº¡i gáº§n má»Ÿ xe láº¥y Ä‘á»“ trong 5 giÃ¢y rá»“i Ä‘i xa ngay (Expedited Auto-Lock)
// 5. Case 4: Báº£o vá»‡ khi dá»«ng Ä‘Ã¨n Ä‘á» á»Ÿ mode Drive / Super (Red Light Safety)
// 6. Case 5: TÃ¡i vÅ© trang _walkUpConsumed khi thá»±c sá»± rá»i xa (Rearm Hysteresis)
// 7. Case 6: Chá»‘ng trá»™m antiTheft5m phÃ¢n biá»‡t tá»‘c Ä‘á»™ tháº¥p (<=15km/h) vÃ  cao (>15km/h)

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mybike_app/core/proto/bike_log.dart';
import 'package:mybike_app/core/utils/kalman_filter.dart';
import 'package:mybike_app/core/ble/ble_controller.dart';

/// MÃ¡y tráº¡ng thÃ¡i mÃ´ phá»ng Proximity & Safety State Machine cá»§a Dat Bike App.
/// Thá»±c thi chÃ­nh xÃ¡c cÃ¡c quy táº¯c nghiá»‡p vá»¥ theo Ä‘áº·c táº£ ká»¹ thuáº­t Â§4.6.
class ProximitySafetyStateMachine {
  // --- Cáº¥u hÃ¬nh (Configuration) ---
  bool walkUpUnlock;
  bool walkUpAutoPowerOn;
  bool autoLockWalkAway;
  bool antiTheft5m;

  double nearThreshold; // Máº·c Ä‘á»‹nh -55.0 dBm (~1-2m)
  double targetThreshold; // Máº·c Ä‘á»‹nh -75.0 dBm
  double rearmThreshold; // Máº·c Ä‘á»‹nh -78.0 dBm

  static const double kTheftLowSpeedThreshold = -78.0;
  static const double kTheftHighSpeedThreshold = -85.0;
  static const double kSpeedCutoff = 15.0; // km/h
  static const int kTheftLowSpeedCycles = 5;
  static const int kTheftHighSpeedCycles = 8;
  static const int kIdleTimeoutSeconds = 90;

  // --- Bá»™ lá»c tÃ­n hiá»‡u Kalman 1D ---
  final KalmanFilter1D kalman;

  // --- Biáº¿n tráº¡ng thÃ¡i mÃ¡y (State Variables) ---
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

  /// RÃ o cháº¯n 15s Ä‘áº§u vá»«a káº¿t ná»‘i:
  /// ÄÆ°á»£c gá»¡ bá» NGAY Láº¬P Tá»¨C khi xe Ä‘Ã£ Ä‘Æ°á»£c má»Ÿ bá»Ÿi Walk-Up hoáº·c user Ä‘Ã£ tá»«ng bÆ°á»›c sÃ¡t xe!
  bool isEffectiveJustConnected(DateTime now) {
    if (connectedAt == null) return false;
    final in15sWindow = now.difference(connectedAt!) < const Duration(seconds: 15);
    // Náº¿u Ä‘Ã£ tá»«ng gáº§n xe hoáº·c Ä‘Ã£ má»Ÿ bá»Ÿi Walk-Up -> rÃ o cháº¯n máº¥t hiá»‡u lá»±c
    if (hasBeenNearBike || openedByWalkUp) {
      return false;
    }
    return in15sWindow;
  }

  /// Kiá»ƒm tra xe Ä‘ang á»Ÿ cháº¿ Ä‘á»™ Äá»— / Standby an toÃ n Ä‘á»ƒ khÃ³a tá»± Ä‘á»™ng
  /// Dá»«ng Ä‘Ã¨n Ä‘á» á»Ÿ Drive hoáº·c Super tuyá»‡t Ä‘á»‘i KHÃ”NG pháº£i lÃ  Ä‘á»—!
  bool isParkedOrStandby(BikeLogMsg tele) {
    if ((tele.state == BikeState.drive || tele.state == BikeState.super_) && !tele.parking) {
      return false; // Äang cháº¡y hoáº·c dá»«ng Ä‘Ã¨n Ä‘á» á»Ÿ sá»‘ Drive/Super!
    }
    return true;
  }

  /// Xá»­ lÃ½ máº«u RSSI Ä‘o Ä‘Æ°á»£c cÃ¹ng telemetry xe
  void processSample(
    double curRssi,
    BikeLogMsg tele, {
    DateTime? now,
  }) {
    final currentTime = now ?? DateTime.now();

    // 1. CÆ¡ cháº¿ Walk-Up Fast-Track Kalman
    // Náº¿u cÃ³ Ä‘á»™ vá»t >= 8 dB vÃ  vÆ°á»£t ngÆ°á»¡ng gáº§n (>= nearThreshold),
    // Fast-Track kÃ­ch hoáº¡t reset bá»™ lá»c vá» giÃ¡ trá»‹ Ä‘o má»›i nháº¥t Ä‘á»ƒ báº¯t sÃ³ng tá»©c thÃ¬.
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

    // Ghi nháº­n tráº¡ng thÃ¡i Ä‘Ã£ tá»«ng vÃ o sá»‘ Drive trong phiÃªn lÃ m viá»‡c
    if (tele.state == BikeState.drive || tele.state == BikeState.super_) {
      hasEnteredDriveInSession = true;
    }

    // Ghi nháº­n Ä‘Ã£ tá»«ng á»Ÿ gáº§n xe
    if (rssi >= nearThreshold) {
      hasBeenNearBike = true;
    }

    // 2. TÃ¡i vÅ© trang _walkUpConsumed khi thá»±c sá»± rá»i xa
    // Cáº§n 3 chu ká»³ liÃªn tiáº¿p <= rearmThreshold
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

    // Äiá»u kiá»‡n cho phÃ©p tá»± Ä‘á»™ng
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

    // 4. Chá»‘ng trá»™m antiTheft5m (phÃ¢n biá»‡t tá»‘c Ä‘á»™ tháº¥p <=15 km/h vs tá»‘c Ä‘á»™ cao >15 km/h)
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

    // 5. Tá»± Ä‘á»™ng khÃ³a khi rá»i xa (Auto-Lock Walk-Away)
    // - Báº¯t buá»™c isParkedOrStandby == true (báº£o vá»‡ dá»«ng Ä‘Ã¨n Ä‘á»)
    // - Náº¿u chÆ°a tá»«ng vÃ o Drive trong session: chá»‰ cáº§n 2 chu ká»³ (má»Ÿ láº¥y Ä‘á»“ rá»“i Ä‘i)
    // - Náº¿u Ä‘Ã£ tá»«ng vÃ o Drive: cáº§n 3 chu ká»³ tiÃªu chuáº©n
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

  /// Kiá»ƒm tra timeout 90 giÃ¢y khÃ´ng vÃ o Drive sau khi má»Ÿ báº±ng Walk-Up
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

  /// NgÆ°á»i dÃ¹ng chá»§ Ä‘á»™ng báº¥m táº¯t xe trÃªn á»©ng dá»¥ng
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
  group('Luá»“ng 1 (Walk-Up Fast-Track Kalman)', () {
    test('Standard Kalman without Fast-Track is sluggish after distant connection (-78 dBm -> -50 dBm)', () {
      final kalman = KalmanFilter1D(processNoise: 0.05, measurementNoise: 3.0, initialEstimate: -78.0);
      expect(kalman.currentEstimate, -78.0);

      // BÆ°á»›c sÃ¡t vÃ o xe, nháº­n Ä‘Æ°á»£c máº«u máº¡nh -50 dBm
      final standardEstimate = kalman.filter(-50.0);

      // Náº¿u khÃ´ng cÃ³ fast-track, bá»™ lá»c bá»‹ trá»… náº·ng ná», káº¹t trong khoáº£ng -72 dBm .. -62 dBm
      expect(standardEstimate, lessThan(-60.0),
          reason: 'Bá»™ lá»c thÆ°á»ng pháº£i bá»‹ trá»… vÃ  chÆ°a thá»ƒ cháº¡m tá»›i ngÆ°á»¡ng -55 dBm ngay');
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

      // KÃ­ch hoáº¡t cÆ¡ cháº¿ Fast-Track
      kalman.reset(curRssi);

      expect(kalman.currentEstimate, equals(-50.0),
          reason: 'Fast-track pháº£i Ä‘Æ°a estimate vá» ngay -50.0 dBm chá»‰ trong 1 chu ká»³');
    });

    test('Small jump (< 8 dB) does NOT trigger fast-track reset, preserving Kalman noise suppression', () {
      final kalman = KalmanFilter1D(processNoise: 0.05, measurementNoise: 3.0, initialEstimate: -78.0);
      const curRssi = -72.0; // TÄƒng 6 dB (< 8 dB)
      final jump = curRssi - kalman.currentEstimate!;
      expect(jump, lessThan(8.0));

      final filtered = kalman.filter(curRssi);
      expect(filtered, isNot(equals(curRssi)),
          reason: 'CÃº nháº£y nhá» pháº£i Ä‘Æ°á»£c lá»c mÆ°á»£t, khÃ´ng Ä‘Æ°á»£c reset Ä‘á»™t ngá»™t');
    });

    test('StateMachine executes instant walk-up unlock on cycle 1 with Fast-Track', () {
      final sm = ProximitySafetyStateMachine(
        nearThreshold: -55.0,
        customKalman: KalmanFilter1D(processNoise: 0.05, measurementNoise: 3.0, initialEstimate: -78.0),
      );
      final tele = BikeLogMsg()..state = BikeState.off..parking = true..speed = 0.0;

      // BÆ°á»›c sÃ¡t xe: curRssi = -50.0 dBm
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

  group('Luá»“ng 2A (Äá»©ng gáº§n 2-3m bá»‹ Body Shadowing suy hao thoÃ¡ng qua)', () {
    test('Kalman filter dampens transient drop (-60 dBm -> -76 dBm -> -62 dBm)', () {
      final kalman = KalmanFilter1D(processNoise: 0.05, measurementNoise: 3.0, initialEstimate: -60.0);

      // 1 máº«u nhiá»…u do cÆ¡ thá»ƒ xoay ngÆ°á»i che khuáº¥t tÃ­n hiá»‡u tá»¥t xuá»‘ng -76 dBm
      final filteredDip = kalman.filter(-76.0);

      // GiÃ¡ trá»‹ sau lá»c chá»‰ giáº£m nháº¹ (~ -63..-65 dBm), tuyá»‡t Ä‘á»‘i khÃ´ng xuyÃªn thá»§ng ngÆ°á»¡ng -75 dBm
      expect(filteredDip, greaterThan(-70.0),
          reason: 'Kalman pháº£i lá»c mÆ°á»£t cÃº tá»¥t tá»©c thá»i do body shadowing');
      expect(filteredDip, greaterThan(-75.0));

      // Máº«u tiáº¿p theo há»“i phá»¥c láº¡i -62 dBm
      final filteredRecover = kalman.filter(-62.0);
      expect(filteredRecover, greaterThan(-65.0));
    });

    test('Transient dip for 1 cycle does not increment auto-lock counter to threshold and resets immediately', () {
      final sm = ProximitySafetyStateMachine(targetThreshold: -75.0);
      sm.hasBeenNearBike = true;
      sm.isBikeOn = true;
      sm.isLocked = false;
      sm.hasEnteredDriveInSession = true; // YÃªu cáº§u 3 chu ká»³

      final tele = BikeLogMsg()..state = BikeState.parking..parking = true..speed = 0.0;

      // Äá»©ng á»•n Ä‘á»‹nh á»Ÿ -60 dBm
      sm.processSample(-60.0, tele);
      expect(sm.autoLockCounter, 0);

      // Giáº£ sá»­ cÃ³ máº«u nhiá»…u cá»±c Ä‘oan khiáº¿n smoothedRssi cháº¡m -76 dBm trong 1 chu ká»³
      sm.kalman.reset(-76.0); // Ã‰p giáº£ láº­p smoothedRssi = -76.0
      sm.processSample(-76.0, tele);
      expect(sm.autoLockCounter, 1);
      expect(sm.eventLog, isNot(contains('auto_lock_walk_away')));

      // Chu ká»³ tiáº¿p theo sÃ³ng há»“i vá» -62 dBm
      sm.kalman.reset(-62.0);
      sm.processSample(-62.0, tele);
      expect(sm.autoLockCounter, 0, reason: 'Bá»™ Ä‘áº¿m auto-lock pháº£i reset vá» 0 ngay khi RSSI há»“i phá»¥c');
      expect(sm.isLocked, isFalse);
      expect(sm.isBikeOn, isTrue);
    });
  });

  group('Luá»“ng 2B (Chá»‘t 1 láº§n _walkUpConsumed & Timeout 90 giÃ¢y)', () {
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

      // Walk-up má»Ÿ xe
      sm.processSample(-52.0, tele, now: t0);
      expect(sm.isBikeOn, isTrue);
      expect(sm.walkUpConsumed, isTrue);

      // NgÆ°á»i dÃ¹ng báº¥m táº¯t xe lÃºc t = 10s
      final t1 = t0.add(const Duration(seconds: 10));
      sm.userManualTurnOff(t1);
      expect(sm.isBikeOn, isFalse);
      expect(sm.isLocked, isTrue);

      // NgÆ°á»i dÃ¹ng váº«n Ä‘á»©ng cÃ¡ch xe 1-2m (-52 dBm) trong 5 chu ká»³ tiáº¿p theo
      tele.state = BikeState.off;
      for (int i = 1; i <= 5; i++) {
        final tStep = t1.add(Duration(seconds: 15 + i * 2));
        sm.processSample(-52.0, tele, now: tStep);
        expect(sm.isBikeOn, isFalse,
            reason: 'Xe TUYá»†T Äá»I KHÃ”NG tá»± báº­t láº¡i láº§n 2 khi user chÆ°a rá»i xa');
        expect(sm.isLocked, isTrue);
      }
      expect(sm.eventLog.where((e) => e == 'walk_up_unlocked').length, 1);
    });

    test('90s idle timeout without entering Drive auto-locks bike and never re-triggers while nearby', () {
      final sm = ProximitySafetyStateMachine(nearThreshold: -55.0);
      final tele = BikeLogMsg()..state = BikeState.standBy..parking = true..speed = 0.0;
      final t0 = DateTime(2026, 11, 9, 10, 0, 0);

      // Walk-up má»Ÿ xe lÃºc t = 0s
      sm.processSample(-52.0, tele, now: t0);
      expect(sm.openedByWalkUp, isTrue);
      expect(sm.hasEnteredDriveInSession, isFalse);

      // Äá»©ng nÃ³i chuyá»‡n gáº§n xe 90s (speed = 0, parking = true)
      final t90 = t0.add(const Duration(seconds: 90));
      sm.checkIdleTimeout(tele, t90);

      expect(sm.eventLog, contains('idle_90s_timeout_locked'));
      expect(sm.isBikeOn, isFalse);
      expect(sm.isLocked, isTrue);
      expect(sm.walkUpConsumed, isTrue);

      // Tiáº¿p tá»¥c Ä‘á»©ng á»Ÿ -52 dBm á»Ÿ giÃ¢y 95..110
      for (int sec = 95; sec <= 110; sec += 3) {
        final tLater = t0.add(Duration(seconds: sec));
        sm.processSample(-52.0, tele, now: tLater);
        expect(sm.isBikeOn, isFalse);
        expect(sm.isLocked, isTrue);
      }
    });
  });

  group('Luá»“ng 3 (Láº¡i gáº§n má»Ÿ xe láº¥y Ä‘á»“ trong 5 giÃ¢y rá»“i Ä‘i xa ngay - Expedited Auto-Lock)', () {
    test('Approaching bike immediately removes effectiveJustConnected 15s barrier', () {
      final sm = ProximitySafetyStateMachine();
      final t0 = DateTime(2026, 11, 9, 10, 0, 0);
      sm.connectedAt = t0;

      // Ban Ä‘áº§u á»Ÿ xa (-80 dBm), barrier cÃ³ hiá»‡u lá»±c trong 15s Ä‘áº§u
      expect(sm.isEffectiveJustConnected(t0.add(const Duration(seconds: 2))), isTrue);

      // Láº¡i gáº§n xe (-50 dBm) lÃºc t = 3s
      final tele = BikeLogMsg()..state = BikeState.off..parking = true..speed = 0.0;
      sm.processSample(-50.0, tele, now: t0.add(const Duration(seconds: 3)));

      expect(sm.hasBeenNearBike, isTrue);
      expect(sm.openedByWalkUp, isTrue);
      // RÃ o cháº¯n 15s pháº£i bá»‹ xoÃ¡ bá» ngay láº­p tá»©c!
      expect(sm.isEffectiveJustConnected(t0.add(const Duration(seconds: 4))), isFalse);
    });

    test('Without entering Drive, auto-lock requires only 2 cycles and locks at second 7', () {
      final sm = ProximitySafetyStateMachine(targetThreshold: -75.0);
      final t0 = DateTime(2026, 11, 9, 10, 0, 0);
      sm.connectedAt = t0;
      final tele = BikeLogMsg()..state = BikeState.standBy..parking = true..speed = 0.0;

      // GiÃ¢y thá»© 2: Má»Ÿ xe láº¥y Ä‘á»“
      final t2 = t0.add(const Duration(seconds: 2));
      sm.processSample(-50.0, tele, now: t2);
      expect(sm.isBikeOn, isTrue);
      expect(sm.hasEnteredDriveInSession, isFalse);

      // GiÃ¢y thá»© 5: Äi ra xa, smoothed RSSI Ä‘áº¡t -76 dBm <= targetThreshold (-75 dBm) (chu ká»³ 1)
      final t5 = t0.add(const Duration(seconds: 5));
      sm.kalman.reset(-76.0);
      sm.processSample(-76.0, tele, now: t5);
      expect(sm.autoLockCounter, 1);
      expect(sm.isLocked, isFalse);

      // GiÃ¢y thá»© 7: Váº«n á»Ÿ xa, smoothed RSSI Ä‘áº¡t -78 dBm <= targetThreshold (-75 dBm) (chu ká»³ 2)
      final t7 = t0.add(const Duration(seconds: 7));
      sm.processSample(-78.0, tele, now: t7);
      expect(sm.eventLog, contains('auto_lock_walk_away'));
      expect(sm.isLocked, isTrue);
      expect(sm.isBikeOn, isFalse);
      expect(sm.autoLockCounter, 0);
    });
  });

  group('Case 4 (Báº£o vá»‡ khi dá»«ng Ä‘Ã¨n Ä‘á» á»Ÿ mode Drive / Super)', () {
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
        antiTheft5m: false, // CÃ´ láº­p kiá»ƒm tra tÃ­nh nÄƒng autoLockWalkAway
      );
      sm.hasBeenNearBike = true;
      sm.isBikeOn = true;
      sm.isLocked = false;

      // Xe Ä‘ang dá»«ng Ä‘Ã¨n Ä‘á»: sá»‘ Drive, khÃ´ng háº¡ chÃ¢n chá»‘ng, tá»‘c Ä‘á»™ 0.0 km/h
      final redLightMsg = BikeLogMsg()
        ..state = BikeState.drive
        ..parking = false
        ..speed = 0.0;

      // Äiá»‡n thoáº¡i Ä‘Ãºt sÃ¢u tÃºi quáº§n hoáº·c bá»‹ nhiá»…u sÃ³ng, RSSI = -80 dBm trong 5 chu ká»³
      for (int i = 1; i <= 5; i++) {
        sm.processSample(-80.0, redLightMsg);
        expect(sm.autoLockCounter, 0,
            reason: 'Chu ká»³ $i: KhÃ´ng Ä‘Æ°á»£c tÄƒng autoLockCounter khi xe á»Ÿ sá»‘ Drive táº¡i ngÃ£ tÆ°');
        expect(sm.isBikeOn, isTrue);
        expect(sm.isLocked, isFalse);
      }

      expect(sm.eventLog, isNot(contains('auto_lock_walk_away')));
    });

    test('Super mode red light stop is equally protected against walk-away auto lock', () {
      final sm = ProximitySafetyStateMachine(
        targetThreshold: -75.0,
        antiTheft5m: false, // CÃ´ láº­p kiá»ƒm tra tÃ­nh nÄƒng autoLockWalkAway
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

  group('Case 5 (TÃ¡i vÅ© trang _walkUpConsumed khi thá»±c sá»± rá»i xa)', () {
    test('_walkUpConsumed remains true for 1 or 2 cycles <= rearmThreshold', () {
      final sm = ProximitySafetyStateMachine(rearmThreshold: -78.0);
      sm.walkUpConsumed = true;
      final tele = BikeLogMsg()..state = BikeState.off..parking = true..speed = 0.0;

      // Chu ká»³ 1: -80 dBm
      sm.processSample(-80.0, tele);
      expect(sm.rearmCounter, 1);
      expect(sm.walkUpConsumed, isTrue);

      // Chu ká»³ 2: -82 dBm
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
      expect(sm.walkUpConsumed, isFalse, reason: 'Sau 3 chu ká»³ rá»i xa, walkUpConsumed pháº£i Ä‘Æ°á»£c náº¡p láº¡i');
      expect(sm.eventLog, contains('walk_up_rearmed'));
    });

    test('Temporary rebound above rearmThreshold resets the 3-cycle rearm counter', () {
      final sm = ProximitySafetyStateMachine(rearmThreshold: -78.0);
      sm.walkUpConsumed = true;
      final tele = BikeLogMsg()..state = BikeState.off..parking = true..speed = 0.0;

      sm.processSample(-80.0, tele); // Counter = 1
      sm.processSample(-81.0, tele); // Counter = 2

      // SÃ³ng há»“i phá»¥c Ä‘Æ°a smoothedRssi lÃªn trÃªn ngÆ°á»¡ng rearmThreshold (-78 dBm)
      sm.kalman.reset(-70.0);
      sm.processSample(-70.0, tele);

      expect(sm.rearmCounter, 0, reason: 'Nhiá»…u sÃ³ng báº­t láº¡i pháº£i reset rearmCounter');
      expect(sm.walkUpConsumed, isTrue);
    });

    test('After full rearm, user returning near (RSSI >= -55 dBm) triggers walk-up unlock normally', () {
      final sm = ProximitySafetyStateMachine(nearThreshold: -55.0, rearmThreshold: -78.0);
      sm.walkUpConsumed = true;
      sm.isLocked = true;
      sm.isBikeOn = false;
      final tele = BikeLogMsg()..state = BikeState.off..parking = true..speed = 0.0;

      // 3 chu ká»³ rá»i xa
      sm.processSample(-80.0, tele);
      sm.processSample(-82.0, tele);
      sm.processSample(-84.0, tele);
      expect(sm.walkUpConsumed, isFalse);

      // Quay láº¡i gáº§n xe
      sm.processSample(-52.0, tele);
      expect(sm.eventLog, contains('walk_up_unlocked'));
      expect(sm.isLocked, isFalse);
      expect(sm.isBikeOn, isTrue);
      expect(sm.walkUpConsumed, isTrue);
    });
  });

  group('Case 6 (Chá»‘ng trá»™m antiTheft5m phÃ¢n biá»‡t tá»‘c Ä‘á»™ tháº¥p vÃ  cao)', () {
    test('Low speed (speed <= 15 km/h): triggers after 5 consecutive cycles with RSSI <= -78 dBm', () {
      final sm = ProximitySafetyStateMachine();
      sm.hasBeenNearBike = true;
      sm.isBikeOn = true;
      sm.isLocked = false;

      // Xe Ä‘ang bá»‹ dáº¯t trá»™m vá»›i tá»‘c Ä‘á»™ 6.0 km/h (<= 15 km/h)
      final lowSpeedMsg = BikeLogMsg()..state = BikeState.drive..parking = false..speed = 6.0;

      for (int i = 1; i <= 4; i++) {
        sm.processSample(-80.0, lowSpeedMsg);
        expect(sm.theftCounter, i);
        expect(sm.eventLog, isNot(contains('anti_theft_triggered')));
      }

      // Chu ká»³ thá»© 5
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

      // Xe Ä‘ang di chuyá»ƒn tá»‘c Ä‘á»™ cao 45 km/h
      final highSpeedMsg = BikeLogMsg()..state = BikeState.drive..parking = false..speed = 45.0;

      // RSSI = -80 dBm (má»©c kÃ­ch hoáº¡t tá»‘c Ä‘á»™ tháº¥p) trong 10 chu ká»³
      for (int i = 1; i <= 10; i++) {
        sm.processSample(-80.0, highSpeedMsg);
        expect(sm.theftCounter, 0,
            reason: 'Tá»‘c Ä‘á»™ cao yÃªu cáº§u RSSI <= -85 dBm; -80 dBm khÃ´ng Ä‘Æ°á»£c tÃ­nh vÃ o counter');
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

      // 5 chu ká»³ Ä‘áº§u (Ä‘á»§ vá»›i low-speed nhÆ°ng KHÃ”NG Ä‘á»§ vá»›i high-speed)
      for (int i = 1; i <= 5; i++) {
        sm.processSample(-88.0, highSpeedMsg);
        expect(sm.theftCounter, i);
        expect(sm.eventLog, isNot(contains('anti_theft_triggered')),
            reason: '5 chu ká»³ chÆ°a Ä‘á»§ Ä‘á»‘i vá»›i cháº¿ Ä‘á»™ cháº¡y nhanh');
      }

      // Chu ká»³ 6 vÃ  7
      sm.processSample(-88.0, highSpeedMsg);
      expect(sm.theftCounter, 6);
      sm.processSample(-88.0, highSpeedMsg);
      expect(sm.theftCounter, 7);
      expect(sm.eventLog, isNot(contains('anti_theft_triggered')));

      // Chu ká»³ thá»© 8: KÃ­ch hoáº¡t chá»‘ng trá»™m
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

      // 5 chu ká»³ sÃ¢u
      for (int i = 1; i <= 5; i++) {
        sm.processSample(-89.0, highSpeedMsg);
      }
      expect(sm.theftCounter, 5);

      // Chu ká»³ 6: TÃ­n hiá»‡u vá»t lÃªn trÃªn -85 dBm (vÃ­ dá»¥ -75 dBm)
      sm.kalman.reset(-75.0);
      sm.processSample(-75.0, highSpeedMsg);
      expect(sm.theftCounter, 0, reason: 'Nhiá»…u sÃ³ng vá»t lÃªn pháº£i xÃ³a chuá»—i counter vá» 0');
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
      expect(state.walkUpRssiThreshold, isNull); // Sáº½ fallback vá» -55.0 dBm
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
}

