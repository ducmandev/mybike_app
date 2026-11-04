// Dat Bike GATT profile — UUID & Handler đã xác minh chéo qua Ghidra RE2 (mainPcb-1.14.0.bin)
// và HCI btsnoop capture (2026-10-26).
//
// Nguồn chuẩn:
// - docs/TAI_LIEU_KIEN_TRUC_VA_PHAT_TRIEN_TOAN_DIEN.md
// - datbike-eproject/work/firmware_re2/00_SCOPE.md + decomp_reg.log / decomp_vescprog.log

class Gatt {
  Gatt._();

  // ==================== SERVICES ====================

  /// Service dashboard — telemetry 41B float/u8 (Protected Read poll, không notify).
  static const dashboardService = 'cf6900a7-4520-4a4c-977c-82979e8baccf';

  /// Service xác thực — challenge/nonce auth + appAuth token + legacy auth.
  static const authService = '10cb0217-ff02-4474-a1ef-6fd88b5bdaea';

  /// Service thông tin & điều khiển xe (18 chars trong BLEInfo.cpp).
  static const infoService = 'd4905f67-8931-4faa-8c61-86ec7490f3c5';

  /// Service OTA — truyền firmware (5 chars writeNoResp + 1 control char).
  /// KHÔNG phải BEEP_SCAN hay Alert Service như các bản chú thích cũ ghi sai.
  static const otaService = '5b6d1069-a0bc-4875-ba5b-fdc94647d918';

  /// Service cấu hình vận hành (BLEBikeMasterConfig.cpp — ECE, SpeedLimit, Grab).
  static const programmingService = 'f7e2c8a1-3d5b-4906-9e1f-8c0a2b4d6e8f';

  /// Service cấu hình sạc (Charging Profile — dòng Era).
  static const chargingService = '8a2b0d00-9c52-4f5a-9d3e-1f7a0c4b6e21';

  // ==================== CHARACTERISTICS (Auth Service) ====================

  /// APP_AUTH_CHAR (c8eaf27b) — nhận app-token 12 ký tự ASCII khi đăng ký
  /// hoặc 64B SHA256 hex challenge-response; đọc trả 4 byte challenge/ack.
  /// Firmware handler: onWriteAppAuth.
  static const appAuthChar = 'c8eaf27b-9fb7-4bc3-b11a-bf68c97b1b1f';

  /// AUTHORIZATION_CHAR (5e9a2c71) — char NONCE/STATUS chính của handshake:
  /// đọc 16 byte = 15B nonce + 1B status (0x00 = chưa auth, 0x01 = chấp nhận),
  /// ghi 16 byte HMAC-SHA256(pairingToken, 'DBauth' || nonce15)[0:16].
  /// Firmware handler: onWriteAuthentication (@0x40151806).
  static const authorizationChar = '5e9a2c71-0b3d-4f86-a1c2-7d4e8f0b9a63';

  /// LEGACY_APP_AUTH (4cb05df8) — Protected Read trả 12 byte dữ liệu auth theo phiên.
  /// App gốc KHÔNG ghi char này; tên cũ "onOffBikeChar" là sai.
  static const onOffBikeChar = '4cb05df8-9c3a-4d7e-9b2f-8e1a3c6d5b41';
  static const legacyAppAuthChar = 'c75ebe03-ea2f-4c0e-a720-1e7112a72d81';

  /// AUTH_FEATURE_FLAG (91e84eb0) — Protected Read trả 1 byte tĩnh 0x01.
  static const authFeatureFlagChar = '91e84eb0-dea0-436f-a157-f21d89443b32';

  // ==================== CHARACTERISTICS (Dashboard Service) ====================

  /// DASHBOARD_CHAR (6d2eb205) — Poll đọc telemetry ~700ms/lần (không notify).
  /// Protected Read trả 45 byte = 4B Counter LE + 41B Ciphertext (buildBikeLogPacket @0x400e0cb8).
  static const dashboardCharacteristic = '6d2eb205-6f9b-4ecf-bb1b-a5fad127c66c';

  /// BIKE_LOG_CHAR (018e6a6f) — Protected Read 112B (4B counter + 108B protobuf định danh xe).
  static const bikeLogCharacteristic = '018e6a6f-4bda-7b07-8586-1298248a8d5c';

  /// BATTERY_LOG_CHAR (84c7be0b) — Protected Read 211B (4B counter + 207B protobuf BMS/Cell).
  static const batteryLogCharacteristic = '84c7be0b-7619-45c1-a503-95f4ff8736ed';

  // ==================== CHARACTERISTICS (Info Service — BLEInfo.cpp) ====================

  /// Firmware version (d1da175e) — Plain Read trả chuỗi "1.14.0" (Read-Only, cần link đã bond).
  static const firmwareVersion = 'd1da175e-b1b5-4248-8f36-98c9482b8d24';

  /// CURRENT_TIME / TIME_SYNC (44e2bde6) — Đặt giờ đồng hồ RTC trên Taplo.
  /// - Firmware đăng ký Write-Only (Protected Write, handler FUN_40154f24):
  ///   nhận chuỗi ASCII số giây trong ngày theo giờ địa phương (0..86399).
  /// - Đính chính RE2: Trong btsnoop Samsung (16:16:22 và 16:16:47), chuỗi "58582"
  ///   và "58607" chính là số giây trong ngày (16*3600+16*60+47 = 58607) mà app gốc
  ///   đồng bộ giờ ngay sau handshake (counter = 0), KHÔNG PHẢI mã PIN xe hay giây UTC Epoch.
  /// - Khi đọc trước khi có session: trả về chuỗi tĩnh "28825".
  static const bikeSerial = '44e2bde6-9cd5-4159-9d43-a3e3f4e9c737';
  static const currentTimeChar = '44e2bde6-9cd5-4159-9d43-a3e3f4e9c737';
  static const timeSyncChar = '44e2bde6-9cd5-4159-9d43-a3e3f4e9c737';

  /// Serial xe thật (041d5a06) — Protected Read trả 17 ký tự ASCII (vd "RL9C4NGSSSCC00187").
  static const deviceSerialChar = '041d5a06-e35f-42d3-92c8-0d421186d2f3';

  /// SESSION_UUID / BEEP_UUID (87efab0d) — Đăng ký PLAIN Read & PLAIN Write
  /// (FUN_4015030c trong BLEInfo, KHÔNG mã hóa Protected Read/Write):
  /// - Read (FUN_40155a30): tạo và trả về chuỗi UUID 36B xoay ngẫu nhiên mỗi lần đọc.
  /// - Write (setBeepUUID @0x40156d08): lưu chuỗi vào NVS 'ble-info'/'beep' (tối đa 36B).
  ///   Trong fw 1.14.0 không có hàm nào tiêu thụ giá trị này để hú còi (stub).
  static const sessionUuid = '87efab0d-9e32-4ab8-8916-ed7cb72d819a';

  /// POWER_SWITCH_CHAR / WAKE_HONK (350d9a82) — Đăng ký Write-Only PLAIN Write:
  /// - Khi xe đang tắt máy: ghi plain '1' phát 1 tiếng còi + chớp Hazard (dùng làm Tìm xe).
  /// - Tuyệt đối KHÔNG dùng đơn lẻ để Bật/Tắt nguồn (lệnh Bật/Tắt nguồn thật phải gửi Protected Write lên 7f13fe5c).
  static const powerSwitchChar = '350d9a82-b3f3-4213-bdda-6403be495f53';

  /// Còi tìm xe thực tế khi xe đang tắt máy (ghi plain '1' vào 350d9a82).
  static const findBikeChar = '350d9a82-b3f3-4213-bdda-6403be495f53';

  /// BEEP_UUID (87efab0d) — App gốc 4.5.0 ghi '1'/'0' lên char này nhưng trên
  /// fw 1.14.0 handler chỉ lưu NVS 'beep' (stub, không phát tiếng còi).
  static const beepScanChar = '87efab0d-9e32-4ab8-8916-ed7cb72d819a';

  /// KHÓA AN TOÀN / ARM (eec8fd7f) — Protected Read / Protected Write:
  /// - Ghi Protected '1': khóa an toàn (còi hú chống trộm khi dắt/đá chống, bắt buộc quẹt NFC để mở).
  /// - Ghi Protected '0': mở khóa an toàn.
  static const powerProtectedChar = 'eec8fd7f-4709-441a-a838-b9eb3066ede4';

  // ==================== CHARACTERISTICS (OTA Service 5b6d1069) ====================

  /// Control char trong OTA Service (e0b2b4b4) — KHÔNG phải còi xe.
  @Deprecated('Thuộc OTA Service, không phải char còi.')
  static const beepMainChar = 'e0b2b4b4-4b1e-4f3e-8f1e-6b3e4b4b4b4b';

  static const otaChar1 = '68311857-4f93-4060-a42d-16da35a5843c';
  static const otaChar2 = '07765f94-d850-4e87-a2cf-6bae5d9a0b67';
  static const otaChar3 = '4244dedb-7b6b-4774-9525-d37fde1c67da';

  // ==================== MASTER_CONFIG & BLE_INFO SETTINGS ====================

  /// Giới hạn tốc độ (0a19a49a — MasterConfig): Protected Read (1B u8) / Protected Write ('1'/'0').
  /// Chỉ có hiệu lực trần tốc độ khi ECE (3b56ac38) cũng đang bật = 1.
  static const speedLimitChar = '0a19a49a-23bc-45ab-b2e9-4bf31665c76b';

  /// Chế độ ECE (3b56ac38 — MasterConfig, onWriteEceMode @0x40153bd0):
  /// Protected Read (1B u8) / Protected Write ('1'/'0'). Lưu NVS 'ble-info' + cfg+0xa3.
  static const eceModeChar = '3b56ac38-60fb-40f8-a42c-fa09e0714e44';

  /// Chế độ Grab (a1d8e7c4 — MasterConfig, onWriteGrabMode @0x40153e30):
  /// Protected Read (1B u8) / Protected Write ('1'/'0').
  static const grabModeChar = 'a1d8e7c4-5b3f-4902-8a6e-9c0d2f1e3b4a';

  /// Tự tắt xe khi đỗ (69c79762 — BLEInfo): Protected Read (1B u8) / Protected Write ('1'/'0').
  static const idlingTurnOffChar = '69c79762-9dd3-413e-9aaf-bdd147563c93';

  /// Khoảng cách BLE tự động (5d681587 — BLEInfo, onWriteDistance @0x401552cc):
  /// Protected Read (2B u16 LE, default 8) / Protected Write ('1'/'0').
  static const distanceChar = '5d681587-c268-4bd3-9560-66ec79dbfdc8';

  /// BẬT/TẮT NGUỒN ĐỘNG THẬT (7f13fe5c — BLEInfo):
  /// Firmware đăng ký Write-Only Protected Write ('1' = bật nguồn sáng Taplo sẵn sàng chạy, '0' = tắt nguồn);
  /// không có read handler nên đọc lại chỉ trả plain echo byte cuối trong buffer NimBLE.
  static const powerOnOffChar = '7f13fe5c-1971-4fec-97fd-f90e16cf8c28';
  static const lockBikeChar = '7f13fe5c-1971-4fec-97fd-f90e16cf8c28';

  /// CHẾ ĐỘ NẠP VESC / DEV MODE (b0ca953d — BLEInfo) — ⚠️ CẢNH BÁO AN TOÀN (RE2 verified):
  /// - Read handler (@0x401555c9): gọi getVescProgrammingActive (@0x40142dc0) trả 1B (00/01).
  /// - Write handler (onWriteVescProgamming @0x4015565c): thực hiện PURE TOGGLE
  ///   (XOR đảo bit `cfg+0x62 = bVar1 ^ 1`) và BỎ QUA TOÀN BỘ nội dung payload!
  /// - Khi cờ `cfg+0x62` = 1: Firmware NGỪNG vescPollTask (@0x400db6b0) và
  ///   canCheckConnectionTask (@0x400d5b02), làm chỉ số IM trên Taplo = 0 và tắt đèn
  ///   như hệ quả phụ. TUYỆT ĐỐI KHÔNG dùng làm công tắc đèn xe khi đang vận hành!
  static const vescProgrammingChar = 'b0ca953d-46db-4451-b457-b81696d4e3ae';

  /// Tắt hẳn BMS (1f4108ad — BLEInfo, onWriteTurnOffBms): Write-Only Protected Write ('1').
  /// Chỉ thực thi khi xe đang bật và đứng yên; ngắt hoàn toàn điện BMS sau 1000ms.
  static const turnOffBmsChar = '1f4108ad-8a70-4165-87d0-88e16f433758';

  /// Factory reset cài đặt BLE (a23df519 — BLEInfo): Write-Only Protected Write (mọi payload != rỗng).
  static const resetBleChar = 'a23df519-5279-4fdc-87ef-9b9e65b4a31f';

  /// Đăng ký thẻ NFC mới (c75ebe03 — RfidCardManager): Protected Read (2B) / Protected Write ('1'/'0').
  static const addCardChar = 'c75ebe03-ea2f-4c0e-a720-1e7112a72d81';

  /// Cache/Echo char (460a5bc5 — BLEInfo): Firmware chỉ đăng ký Protected Read (FUN_40154e70),
  /// Write callback rỗng (FUN_4014f644) — không lưu NVS.
  static const bikeNameChar = '460a5bc5-a5f5-4968-b548-dc218935245e';

  /// Model xe (4aae98e9 — BLEInfo): Read-Only Protected Read trả chuỗi model ("QT_S1").
  static const bikeModelChar = '4aae98e9-90b5-492f-8180-9538fa2c843d';

  /// TÊN XE THẬT (88c30d2c — BLEInfo): Protected Read (getName) / Protected Write (setName -> NVS 'name').
  static const fwNameChar = '88c30d2c-f80f-43f8-b0cb-fc1e4ae49be9';

  /// Snapshot VESC 3×float32 (35a9b4f6 — BLEInfo, FUN_40156db0):
  /// Read-Only Protected Read trả 12 byte = [motorCurrent, vescVoltage, dutyCycle].
  static const vescSnapshotChar = '35a9b4f6-e5f5-405b-9b08-ada85d78cc12';

  /// Manifest phiên bản các board (73d50009 — BLEInfo):
  /// Read-Only Protected Read trả chuỗi hash ("1adadba-#-8c02b07-896e9a7").
  static const boardManifestChar = '73d50009-ed01-4bb1-bdc2-e89b725a91db';

  /// Thống kê bộ nhớ đệm Log nội bộ (2c73e84e — BLEInfo):
  /// Read-Only Protected Read trả 16 byte = 4 × uint32 LE (FUN_400edc10/c3c/c64/cf8).
  /// Write callback trong firmware là hàm rỗng (FUN_4014f644).
  static const logBufferStatsChar = '2c73e84e-0150-4be2-928c-dee3e8e21b52';

  /// Chọn profile sạc (8a2b0d10 — Charging Service, handler @0x40154240):
  /// Protected Read / Protected Write 1 byte RAW (0x00=Standard, 0x01=Fast, 0x02=Boost; dòng Era).
  static const chargingProfileChar = '8a2b0d10-9c52-4f5a-9d3e-1f7a0c4b6e21';

  // ==================== OPERATING CONSTANTS ====================

  /// Tên BLE xe quảng bá (kể cả biến thể: 'Dat Bike Quantum S1').
  static const bikeName = 'dat.bik3';

  /// MTU tối đa Android.
  static const androidMtu = 517;

  /// Chu kỳ poll dashboard (ms) — app gốc poll ~650-700ms/lần (từ btsnoop).
  static const dashboardPollMs = 700;

  /// HMAC tag length (bytes) — 4 bytes = 32 bits.
  static const hmacTagLen = 4;

  /// Status byte của nonce 16B trên AUTHORIZATION_CHAR: 0x00 = chưa xác thực,
  /// 0x01 = xe đã chấp nhận response.
  static const authStatusOk = 0x01;

  /// Pairing token THẬT — giải mã từ firmware mainPcb-1.14.0 (@DROM 0x3f413174).
  static const defaultPairingToken =
      'c97eb99d-c695-4b5f-8a99-7b24ff2a7980';

  /// Giá trị fallback thử nghiệm trong khoá phiên nếu chưa có app-token 12 ký tự.
  static const defaultPassword = '58607';
}
