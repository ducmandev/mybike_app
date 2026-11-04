import 'dart:math' as math;

/// 4 thế hệ kiến trúc kỹ thuật của dòng xe Dat Bike
enum BikeGeneration {
  /// Thế hệ 1: Weaver / Weaver 200 / Weaver 200B / Weaver++ (MainPCB ESP32 Classic, không VCU)
  gen1Weaver,

  /// Thế hệ 2: Quantum First-Gen (4 bo mạch phân tán CAN 500kbps, không VCU)
  gen2Quantum,

  /// Thế hệ 3: Quantum S Series (All-in-One ESP32-S3 VCU kiêm Taplo DMA + BLE + NFC)
  gen3QuantumS,

  /// Thế hệ 4: Era Series (ESP32-S3 VCU + PCU điều khiển sạc thông minh ChargerOp)
  gen4Era,
}

/// Loại hóa học và cấu hình pack pin của xe
enum BatteryChemistry {
  /// Pin Lithium-ion Ternary NMC 20S (20S9P ~72V danh định: 60.0V cạn - 84.0V đầy)
  nmc20s,

  /// Pin Lithium Sắt Photphat LFP 23S (23S6P ~73.6V danh định: 64.0V cạn - 83.95V đầy)
  lfp23s6p,

  /// Pin LFP 23S4P (~4.3 kWh trên Quantum S3 & Era)
  lfp23s4p,
}

/// 11 biến thể model xe Dat Bike chuẩn xác từ Firmware và React Native Hermes DROM
enum BikeModel {
  w200('W200', 'Dat Bike Weaver 200', BikeGeneration.gen1Weaver, BatteryChemistry.nmc20s),
  w200b('W200B', 'Dat Bike Weaver 200B', BikeGeneration.gen1Weaver, BatteryChemistry.nmc20s),
  wPlus('W++', 'Dat Bike Weaver++', BikeGeneration.gen1Weaver, BatteryChemistry.nmc20s),
  qt('QT', 'Dat Bike Quantum', BikeGeneration.gen2Quantum, BatteryChemistry.lfp23s6p),
  qtS1('QT_S1', 'Dat Bike Quantum S1', BikeGeneration.gen3QuantumS, BatteryChemistry.lfp23s6p),
  qtS2('QT_S2', 'Dat Bike Quantum S2', BikeGeneration.gen3QuantumS, BatteryChemistry.lfp23s6p),
  qtS2_3kw('QT_S2_3kw', 'Dat Bike Quantum S2 (3kW)', BikeGeneration.gen3QuantumS, BatteryChemistry.lfp23s6p),
  qtS3('QT_S3', 'Dat Bike Quantum S3', BikeGeneration.gen3QuantumS, BatteryChemistry.lfp23s4p),
  qtS3_3kw('QT_S3_3kw', 'Dat Bike Quantum S3 (3kW)', BikeGeneration.gen3QuantumS, BatteryChemistry.lfp23s4p),
  eraE1('ERA_E1', 'Dat Bike Era E1', BikeGeneration.gen4Era, BatteryChemistry.lfp23s4p),
  eraE2('ERA_E2', 'Dat Bike Era E2', BikeGeneration.gen4Era, BatteryChemistry.lfp23s4p);

  const BikeModel(
    this.code,
    this.displayName,
    this.generation,
    this.batteryChemistry,
  );

  final String code;
  final String displayName;
  final BikeGeneration generation;
  final BatteryChemistry batteryChemistry;

  /// Xe có hỗ trợ khóa điện tử chống trộm (ARM/LOCK mode qua BLE) không?
  /// Dòng Weaver KHÔNG có contactor ngắt nguồn tự động, firmware Weaver báo lỗi:
  /// "Doesn't support lock the bike on this model".
  bool get supportsImmobilizerLock => generation != BikeGeneration.gen1Weaver;

  /// Xe có trang bị IMU hỗ trợ khởi hành ngang dốc (SlopeOp) không?
  bool get supportsSlopeOp =>
      generation == BikeGeneration.gen3QuantumS || generation == BikeGeneration.gen4Era;

  /// Xe có bộ điều khiển sạc thông minh đa cấp (ChargerOp Standard/Fast/Boost) qua bo PCU không?
  bool get supportsChargerOp => generation == BikeGeneration.gen4Era;

  /// Xe có đầu đọc thẻ NFC vật lý ở đầu xe / taplo không?
  bool get hasNfcTaplo => generation != BikeGeneration.gen1Weaver;

  /// Xe có bo MainPCB riêng biệt không (ngược lại là All-in-One VCU)?
  bool get hasDiscreteMainPcb =>
      generation == BikeGeneration.gen1Weaver || generation == BikeGeneration.gen2Quantum;

  /// Điện áp danh định của pack pin (Volt)
  double get nominalVoltage =>
      batteryChemistry == BatteryChemistry.nmc20s ? 72.0 : 73.6;

  /// Điện áp cắt khi cạn pin (Volt - 0% SoC)
  double get cutoffVoltage =>
      batteryChemistry == BatteryChemistry.nmc20s ? 60.0 : 64.0;

  /// Điện áp sạc đầy tối đa (Volt - 100% SoC)
  double get fullVoltage =>
      batteryChemistry == BatteryChemistry.nmc20s ? 84.0 : 83.95;

  /// Ước tính phần trăm SoC dựa trên hóa học cell pin và điện áp pack
  double calculateSocFromVoltage(double packVoltage) {
    if (packVoltage <= cutoffVoltage) return 0.0;
    if (packVoltage >= fullVoltage) return 100.0;

    if (batteryChemistry == BatteryChemistry.nmc20s) {
      // Pin NMC có đường cong OCV xả dốc tuyến tính
      // Dải 60V (3.0V/cell) -> 84V (4.2V/cell)
      final soc = ((packVoltage - cutoffVoltage) / (fullVoltage - cutoffVoltage)) * 100.0;
      return math.max(0.0, math.min(100.0, soc));
    } else {
      // Pin LFP có vùng bình nguyên điện áp đặc trưng (~3.2V - 3.25V/cell tức ~73.6V - 74.8V)
      // Sử dụng bảng nội suy OCV chuẩn của Dat Bike LFP 23S
      const ocvPoints = <List<double>>[
        [64.0, 0.0],
        [69.0, 5.0],
        [71.3, 10.0],
        [73.1, 20.0],
        [73.6, 40.0],
        [74.5, 70.0],
        [75.9, 85.0],
        [78.2, 95.0],
        [83.95, 100.0],
      ];

      for (var i = 0; i < ocvPoints.length - 1; i++) {
        final vLow = ocvPoints[i][0];
        final vHigh = ocvPoints[i + 1][0];
        if (packVoltage >= vLow && packVoltage <= vHigh) {
          final socLow = ocvPoints[i][1];
          final socHigh = ocvPoints[i + 1][1];
          final ratio = (packVoltage - vLow) / (vHigh - vLow);
          return socLow + ratio * (socHigh - socLow);
        }
      }
      return 100.0;
    }
  }

  /// Nhận diện model từ chuỗi định danh (Tên BLE, Serial WMI, VIN hoặc mã NVS)
  static BikeModel resolve({
    String? deviceName,
    String? vinOrSerial,
    String? modelString,
  }) {
    // 1. Kiểm tra trực tiếp từ modelString (nếu có từ DROM hoặc NVS)
    if (modelString != null && modelString.isNotEmpty) {
      final norm = modelString.trim().toUpperCase();
      for (final m in BikeModel.values) {
        if (m.code.toUpperCase() == norm) return m;
      }
    }

    // 2. Nhận diện từ tiền tố số khung (VIN Mask) theo chuẩn Dat Bike
    if (vinOrSerial != null && vinOrSerial.isNotEmpty) {
      final vin = vinOrSerial.trim().toUpperCase();
      if (vin.startsWith('RL9C1FNLS') || vin.contains('W200')) {
        return BikeModel.w200;
      }
      if (vin.contains('W++') || vin.contains('WPLUS')) {
        return BikeModel.wPlus;
      }
      if (vin.startsWith('RX5C5FMKM') || vin.contains('FMKM') || vin.contains('ERA_E1')) {
        return BikeModel.eraE1;
      }
      if (vin.startsWith('RX5C5FMLM') || vin.contains('FMLM') || vin.contains('ERA_E2')) {
        return BikeModel.eraE2;
      }
      if (vin.contains('FNSS')) {
        return BikeModel.qt;
      }
      if (vin.contains('MJ') || vin.contains('QT_S3') || vin.contains('QTS3')) {
        return BikeModel.qtS3;
      }
      if (vin.contains('MH') || vin.contains('QT_S2') || vin.contains('QTS2')) {
        return BikeModel.qtS2;
      }
      if (vin.contains('NG') || vin.contains('QT_S1') || vin.contains('QTS1') || vin.startsWith('RL9C') || vin.startsWith('RX5C')) {
        return BikeModel.qtS1;
      }
    }

    // 3. Nhận diện từ tên thiết bị BLE quảng bá (Advertised Name)
    if (deviceName != null && deviceName.isNotEmpty) {
      final name = deviceName.trim().toUpperCase();
      if (name.startsWith('W200B')) return BikeModel.w200b;
      if (name.startsWith('W200')) return BikeModel.w200;
      if (name.startsWith('W++') || name.startsWith('WEAVER++')) return BikeModel.wPlus;
      if (name.startsWith('WEAVER')) return BikeModel.w200;
      if (name.startsWith('ERA-E1') || name.startsWith('ERAE1')) return BikeModel.eraE1;
      if (name.startsWith('ERA-E2') || name.startsWith('ERAE2')) return BikeModel.eraE2;
      if (name.startsWith('ERA')) return BikeModel.eraE1;
      if (name.startsWith('QTS3') || name.startsWith('QT-S3')) return BikeModel.qtS3;
      if (name.startsWith('QTS2') || name.startsWith('QT-S2')) return BikeModel.qtS2;
      if (name.startsWith('QTS1') || name.startsWith('QT-S1') || name.startsWith('QTS')) return BikeModel.qtS1;
      if (name.startsWith('QT') || name.startsWith('QUANTUM')) return BikeModel.qt;
    }

    // Mặc định an toàn cho các dòng xe phổ biến hiện tại là Quantum S1
    return BikeModel.qtS1;
  }
}
