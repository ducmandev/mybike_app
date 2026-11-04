import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:mybike_app/core/models/bike_model_profile.dart';
import 'package:mybike_app/core/session/bike_session_crypto.dart';
import 'package:mybike_app/core/ble/gatt.dart';

void main() {
  group('1. BikeModel Resolution & 11 Model Matrix Tests', () {
    test('Nhận diện chính xác 11 model từ modelString', () {
      expect(BikeModel.resolve(modelString: 'W200'), BikeModel.w200);
      expect(BikeModel.resolve(modelString: 'W200B'), BikeModel.w200b);
      expect(BikeModel.resolve(modelString: 'W++'), BikeModel.wPlus);
      expect(BikeModel.resolve(modelString: 'QT'), BikeModel.qt);
      expect(BikeModel.resolve(modelString: 'QT_S1'), BikeModel.qtS1);
      expect(BikeModel.resolve(modelString: 'QT_S2'), BikeModel.qtS2);
      expect(BikeModel.resolve(modelString: 'QT_S2_3kw'), BikeModel.qtS2_3kw);
      expect(BikeModel.resolve(modelString: 'QT_S3'), BikeModel.qtS3);
      expect(BikeModel.resolve(modelString: 'QT_S3_3kw'), BikeModel.qtS3_3kw);
      expect(BikeModel.resolve(modelString: 'ERA_E1'), BikeModel.eraE1);
      expect(BikeModel.resolve(modelString: 'ERA_E2'), BikeModel.eraE2);
    });

    test('Nhận diện từ số khung VIN Mask', () {
      expect(BikeModel.resolve(vinOrSerial: 'RL9C1FNLS12345678'), BikeModel.w200);
      expect(BikeModel.resolve(vinOrSerial: 'RL9C1FNSS12345678'), BikeModel.qt);
      expect(BikeModel.resolve(vinOrSerial: 'RL9C4NGSS12345678'), BikeModel.qtS1);
      expect(BikeModel.resolve(vinOrSerial: 'RX5C4MHSS12345678'), BikeModel.qtS2);
      expect(BikeModel.resolve(vinOrSerial: 'RX5C4MJSS12345678'), BikeModel.qtS3);
      expect(BikeModel.resolve(vinOrSerial: 'RX5C5FMKM12345678'), BikeModel.eraE1);
      expect(BikeModel.resolve(vinOrSerial: 'RX5C5FMLM12345678'), BikeModel.eraE2);
    });

    test('Nhận diện từ BLE Advertised Name', () {
      expect(BikeModel.resolve(deviceName: 'W200-8825'), BikeModel.w200);
      expect(BikeModel.resolve(deviceName: 'W200B-1123'), BikeModel.w200b);
      expect(BikeModel.resolve(deviceName: 'W++-9912'), BikeModel.wPlus);
      expect(BikeModel.resolve(deviceName: 'QT-0012'), BikeModel.qt);
      expect(BikeModel.resolve(deviceName: 'QTS1-4567'), BikeModel.qtS1);
      expect(BikeModel.resolve(deviceName: 'QTS2-1111'), BikeModel.qtS2);
      expect(BikeModel.resolve(deviceName: 'QTS3-2222'), BikeModel.qtS3);
      expect(BikeModel.resolve(deviceName: 'ERA-E1-3333'), BikeModel.eraE1);
      expect(BikeModel.resolve(deviceName: 'ERA-E2-4444'), BikeModel.eraE2);
      expect(BikeModel.resolve(deviceName: 'UnknownDevice'), BikeModel.qtS1); // Fallback an toàn
    });
  });

  group('2. Hardware Generation & Capabilities Interlock Tests', () {
    test('Dòng Weaver (Gen 1): Không hỗ trợ LOCK, không IMU SlopeOp, không NFC taplo', () {
      for (final m in [BikeModel.w200, BikeModel.w200b, BikeModel.wPlus]) {
        expect(m.generation, BikeGeneration.gen1Weaver);
        expect(m.supportsImmobilizerLock, isFalse, reason: '${m.code} không có rơ-le khóa');
        expect(m.supportsSlopeOp, isFalse);
        expect(m.hasNfcTaplo, isFalse);
        expect(m.hasDiscreteMainPcb, isTrue);
        expect(m.batteryChemistry, BatteryChemistry.nmc20s);
      }
    });

    test('Dòng Quantum S (Gen 3): Đầy đủ tính năng All-in-One VCU', () {
      for (final m in [BikeModel.qtS1, BikeModel.qtS2, BikeModel.qtS3]) {
        expect(m.generation, BikeGeneration.gen3QuantumS);
        expect(m.supportsImmobilizerLock, isTrue);
        expect(m.supportsSlopeOp, isTrue);
        expect(m.hasNfcTaplo, isTrue);
        expect(m.hasDiscreteMainPcb, isFalse); // All-in-One VCU
      }
    });

    test('Dòng Era (Gen 4): Hỗ trợ sạc đa cấp ChargerOp', () {
      expect(BikeModel.eraE1.supportsChargerOp, isTrue);
      expect(BikeModel.eraE2.supportsChargerOp, isTrue);
      expect(BikeModel.qtS1.supportsChargerOp, isFalse);
      expect(BikeModel.w200.supportsChargerOp, isFalse);
    });
  });

  group('3. Battery Chemistry & Voltage SoC Estimation Tests', () {
    test('Pin NMC 20S của dòng Weaver: tuyến tính 60V (0%) -> 84V (100%)', () {
      final model = BikeModel.w200;
      expect(model.calculateSocFromVoltage(59.0), 0.0);
      expect(model.calculateSocFromVoltage(60.0), 0.0);
      expect(model.calculateSocFromVoltage(72.0), closeTo(50.0, 0.1));
      expect(model.calculateSocFromVoltage(84.0), 100.0);
      expect(model.calculateSocFromVoltage(85.0), 100.0);
    });

    test('Pin LFP 23S của dòng Quantum/Era: đường cong LFP chuẩn', () {
      final model = BikeModel.qtS1;
      expect(model.calculateSocFromVoltage(63.0), 0.0);
      expect(model.calculateSocFromVoltage(64.0), 0.0);
      expect(model.calculateSocFromVoltage(83.95), 100.0);
      // Vùng bình nguyên LFP ~73.6V nằm trong khoảng 35-50%
      final plateauSoc = model.calculateSocFromVoltage(73.6);
      expect(plateauSoc, greaterThan(30.0));
      expect(plateauSoc, lessThan(60.0));
    });
  });

  group('4. Legacy Auth Algorithm & GATT UUID Tests', () {
    test('GATT UUID mapping khớp đúng đặc tả dịch ngược', () {
      expect(Gatt.legacyAppAuthChar, 'c75ebe03-ea2f-4c0e-a720-1e7112a72d81');
      expect(Gatt.onOffBikeChar, '4cb05df8-9c3a-4d7e-9b2f-8e1a3c6d5b41');
      expect(Gatt.appAuthChar, 'c8eaf27b-9fb7-4bc3-b11a-bf68c97b1b1f');
      expect(Gatt.authorizationChar, '5e9a2c71-0b3d-4f86-a1c2-7d4e8f0b9a63');
    });

    test('Tính toán Legacy Auth Response 16 byte thành công', () {
      final challenge16 = Uint8List.fromList([
        0x10, 0x22, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde,
        0xf0, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0x00,
      ]);
      const password = 'mySecretPassword';

      final resp1 = BikeSessionCrypto.computeLegacyAuthResponse(
        password: password,
        challenge16: challenge16,
      );

      expect(resp1.length, 16);
      // Kiểm tra tính đơn định (deterministic)
      final resp2 = BikeSessionCrypto.computeLegacyAuthResponse(
        password: password,
        challenge16: challenge16,
      );
      expect(resp1, equals(resp2));

      // Đổi password phải ra response khác
      final resp3 = BikeSessionCrypto.computeLegacyAuthResponse(
        password: 'otherPassword',
        challenge16: challenge16,
      );
      expect(resp1, isNot(equals(resp3)));
    });

    test('Throw error nếu challenge < 15 bytes', () {
      expect(
        () => BikeSessionCrypto.computeLegacyAuthResponse(
          password: '123',
          challenge16: Uint8List.fromList([1, 2, 3]),
        ),
        throwsArgumentError,
      );
    });
  });
}
