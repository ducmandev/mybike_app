import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mybike_app/core/ble/ble_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SavedBike Model Tests', () {
    test('toJson and fromJson preserve all fields accurately', () {
      final now = DateTime.now();
      final bike = SavedBike(
        id: 'CC:BA:F9:88:24:01',
        name: 'Quantum S1 Của Tôi',
        originalAdvName: 'Dat Bike Quantum S1',
        model: 'Quantum S1',
        licensePlate: '29-A1 999.99',
        frameSerial: 'RL9C4NGSSSCC00187',
        color: 'Trắng Ngọc',
        note: 'Đã gắn baga và sạc nhanh 3.3kW',
        password: 'secure_password_123',
        lastConnectedAt: now,
        lastOdo: 12500.5,
        lastBatteryPercent: 88,
        isDefault: true,
      );

      final json = bike.toJson();
      final fromJson = SavedBike.fromJson(json);

      expect(fromJson.id, bike.id);
      expect(fromJson.name, bike.name);
      expect(fromJson.originalAdvName, bike.originalAdvName);
      expect(fromJson.model, bike.model);
      expect(fromJson.licensePlate, bike.licensePlate);
      expect(fromJson.frameSerial, bike.frameSerial);
      expect(fromJson.color, bike.color);
      expect(fromJson.note, bike.note);
      expect(fromJson.password, bike.password);
      expect(fromJson.lastOdo, bike.lastOdo);
      expect(fromJson.lastBatteryPercent, bike.lastBatteryPercent);
      expect(fromJson.isDefault, isTrue);
    });

    test('fromJson handles minimal or missing fields gracefully', () {
      final minimalJson = {
        'id': 'AA:BB:CC:11:22:33',
        'name': 'Xe Dat Bike',
      };
      final bike = SavedBike.fromJson(minimalJson);

      expect(bike.id, 'AA:BB:CC:11:22:33');
      expect(bike.name, 'Xe Dat Bike');
      expect(bike.model, isNull);
      expect(bike.licensePlate, isNull);
      expect(bike.isDefault, isFalse);
    });

    test('copyWith updates specified fields only', () {
      const bike = SavedBike(
        id: 'ID1',
        name: 'Bike 1',
        model: 'Quantum',
        isDefault: false,
      );

      final updated = bike.copyWith(
        name: 'Bike 1 Renamed',
        isDefault: true,
      );

      expect(updated.id, 'ID1');
      expect(updated.name, 'Bike 1 Renamed');
      expect(updated.model, 'Quantum');
      expect(updated.isDefault, isTrue);
    });
  });

  group('VehicleStorageService Garage & Multi-Bike Storage Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('Auto-migrates legacy single-bike storage into garage', () async {
      SharedPreferences.setMockInitialValues({
        'last_bike_id': 'LEGACY_MAC_123',
        'last_bike_name': 'Xe Đang Đi',
        'bike_password': 'old_password',
      });

      final bikes = await VehicleStorageService.instance.loadSavedBikes();
      expect(bikes.length, 1);
      expect(bikes[0].id, 'LEGACY_MAC_123');
      expect(bikes[0].name, 'Xe Đang Đi');
      expect(bikes[0].isDefault, isTrue);

      final pwd = await VehicleStorageService.instance.getBikePassword('LEGACY_MAC_123');
      expect(pwd, 'old_password');
    });

    test('Adds multiple bikes and maintains default status', () async {
      final bike1 = SavedBike(
        id: 'BIKE_A',
        name: 'Quantum Alpha',
        model: 'Quantum',
        isDefault: true,
      );
      final bike2 = SavedBike(
        id: 'BIKE_B',
        name: 'Weaver Beta',
        model: 'Weaver++',
        isDefault: false,
      );

      var list = await VehicleStorageService.instance.addOrUpdateBike(bike1);
      expect(list.length, 1);
      expect(list[0].id, 'BIKE_A');
      expect(list[0].isDefault, isTrue);

      list = await VehicleStorageService.instance.addOrUpdateBike(bike2);
      expect(list.length, 2);
      expect(list.firstWhere((b) => b.id == 'BIKE_A').isDefault, isTrue);
      expect(list.firstWhere((b) => b.id == 'BIKE_B').isDefault, isFalse);
    });

    test('Changing default bike updates all entries accurately', () async {
      final bike1 = SavedBike(id: 'BIKE_A', name: 'Quantum A', isDefault: true);
      final bike2 = SavedBike(id: 'BIKE_B', name: 'Weaver B', isDefault: false);

      await VehicleStorageService.instance.addOrUpdateBike(bike1);
      await VehicleStorageService.instance.addOrUpdateBike(bike2);

      final list = await VehicleStorageService.instance.setDefaultBike('BIKE_B');
      expect(list.firstWhere((b) => b.id == 'BIKE_A').isDefault, isFalse);
      expect(list.firstWhere((b) => b.id == 'BIKE_B').isDefault, isTrue);
    });

    test('Deleting a bike removes it and promotes remaining bike if default was deleted', () async {
      final bike1 = SavedBike(id: 'BIKE_A', name: 'Quantum A', isDefault: true);
      final bike2 = SavedBike(id: 'BIKE_B', name: 'Weaver B', isDefault: false);

      await VehicleStorageService.instance.addOrUpdateBike(bike1);
      await VehicleStorageService.instance.addOrUpdateBike(bike2);

      final list = await VehicleStorageService.instance.removeBike('BIKE_A');
      expect(list.length, 1);
      expect(list[0].id, 'BIKE_B');
      expect(list[0].isDefault, isTrue); // Automatically promoted to default
    });

    test('Stores and isolates passwords per bike ID', () async {
      await VehicleStorageService.instance.setBikePassword('BIKE_1', 'pass_bike_1');
      await VehicleStorageService.instance.setBikePassword('BIKE_2', 'pass_bike_2');

      final pwd1 = await VehicleStorageService.instance.getBikePassword('BIKE_1');
      final pwd2 = await VehicleStorageService.instance.getBikePassword('BIKE_2');

      expect(pwd1, 'pass_bike_1');
      expect(pwd2, 'pass_bike_2');

      await VehicleStorageService.instance.removeBikePassword('BIKE_1');
      expect(await VehicleStorageService.instance.getBikePassword('BIKE_1'), 'pass_bike_2'); // fallback to legacy
    });

    test('Deleting all bikes clears legacy keys and prevents resurrection', () async {
      final bike1 = SavedBike(id: 'BIKE_A', name: 'Quantum A', isDefault: true);
      await VehicleStorageService.instance.addOrUpdateBike(bike1);

      // Verify bike is saved
      var list = await VehicleStorageService.instance.loadSavedBikes();
      expect(list.length, 1);

      // Now remove the only bike
      list = await VehicleStorageService.instance.removeBike('BIKE_A');
      expect(list.isEmpty, isTrue);

      // Subsequent load should be completely empty and NOT resurrect legacy bike
      final reloaded = await VehicleStorageService.instance.loadSavedBikes();
      expect(reloaded.isEmpty, isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('last_bike_id'), isNull);
      expect(prefs.getString('last_bike_name'), isNull);
    });

    test('clearAllBikes cleans all garage keys, legacy keys, and per-bike passwords', () async {
      final bike1 = SavedBike(id: 'BIKE_A', name: 'Quantum A', isDefault: true);
      final bike2 = SavedBike(id: 'BIKE_B', name: 'Weaver B', isDefault: false);
      await VehicleStorageService.instance.addOrUpdateBike(bike1);
      await VehicleStorageService.instance.addOrUpdateBike(bike2);
      await VehicleStorageService.instance.setBikePassword('BIKE_A', 'pwdA');
      await VehicleStorageService.instance.setBikePassword('BIKE_B', 'pwdB');

      await VehicleStorageService.instance.clearAllBikes();

      final reloaded = await VehicleStorageService.instance.loadSavedBikes();
      expect(reloaded.isEmpty, isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('last_bike_id'), isNull);
      expect(prefs.getString('last_bike_name'), isNull);
      expect(prefs.getString('bike_pwd_BIKE_A'), isNull);
      expect(prefs.getString('bike_pwd_BIKE_B'), isNull);
    });
  });

  group('BleState Multi-Bike State Tests', () {
    test('BleState supports savedBikes and activeBikeId', () {
      final bikes = [
        const SavedBike(id: 'BIKE_1', name: 'Quantum S1', isDefault: true),
        const SavedBike(id: 'BIKE_2', name: 'Weaver++', isDefault: false),
      ];

      final state = BleState(
        phase: BlePhase.idle,
        savedBikes: bikes,
        activeBikeId: 'BIKE_1',
        bikeName: 'Quantum S1',
      );

      expect(state.savedBikes.length, 2);
      expect(state.activeBikeId, 'BIKE_1');
      expect(state.bikeName, 'Quantum S1');

      final switched = state.copyWith(
        activeBikeId: 'BIKE_2',
        bikeName: 'Weaver++',
      );

      expect(switched.activeBikeId, 'BIKE_2');
      expect(switched.bikeName, 'Weaver++');
      expect(switched.savedBikes.length, 2);
    });
  });
}
