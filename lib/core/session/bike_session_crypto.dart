// Lớp session crypto — thuật toán từ decompile app gốc 4.5.0 + btsnoop thật.
//
// ⚠️ Trạng thái verify (2026-10-19):
//   - buildProtectedWrite frame [counter][data][tag4] — ĐÚNG hình dáng wire
//     (khớp btsnoop); công thức HMAC body ('W'‖counter‖uuid16‖data) theo
//     decompile, chưa verify lại được tag trên frame thật.
//   - decryptProtectedRead header 4B counter — ĐÚNG theo btsnoop.
//   - deriveSessionKey (HKDF 'DBsess1') — theo decompile; salt = nonce15 của
//     lần exchange auth; password input là PIN xe (do chủ xe đặt — app nhận
//     từ input người dùng). Chưa verify lại được tag trên frame thật.
//   - computeAuthResponse — ĐÃ CRACK + VERIFY (xem docstring hàm).
//
// Nguồn: docs/ble_session_protocol.md (datbike-eproject) + work/btsnoop_hci.log:
//   sessionKey = HKDF-SHA256(ikm = concat(utf8(a0), utf8(a1)),
//                            salt = a2,
//                            info = 'DBsess1', L = 32)
//   protected write frame = u32le(counter) ‖ data ‖ HMAC-SHA256(sessionKey,
//                            'W' ‖ u32le(counter) ‖ uuid16 ‖ data)[0:4]
//   protected read  = [header 2B][cipher] → XOR keystream
//                            HMAC-SHA256(sessionKey, 'R' ‖ header ‖ uuid16 ‖ u32le(blockIdx))
//   (mỗi block keystream 32 byte — đúng chiều dài output SHA-256)

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class BikeSessionCrypto {
  BikeSessionCrypto(this.sessionKey);

  final Uint8List sessionKey;

  static const infoSalt = 'DBsess1';
  static const writePrefix = 0x57; // 'W'
  static const readPrefix = 0x52; // 'R'
  static const hmacTagLen = 4;
  static const keystreamBlock = 32;

  // ------------------------------------------------------------------
  // Derive
  // ------------------------------------------------------------------

  /// HKDF-Extract + Expand 1 block — tham số theo đúng đặc tả đã verify:
  ///
  /// - [pairingToken]: từ server /attest/pairing-token (String)
  /// - [password]: passcode xe = 6 số cuối motor number (String)
  /// - [challenge]: 15 bytes nhị phân đọc từ APP_AUTH_CHAR (Uint8List)
  ///
  /// Công thức:
  ///   IKM = utf8(pairingToken) + utf8(password)
  ///   PRK = HMAC-SHA256(key=challenge_15B, msg=IKM)
  ///   sessionKey = HMAC-SHA256(key=PRK, msg=utf8('DBsess1') + [0x01])
  static Uint8List deriveSessionKey({
    required String pairingToken,
    required String password,
    required Uint8List challenge,
  }) {
    final ikm = [...utf8.encode(pairingToken), ...utf8.encode(password)];
    final prk = _hmac(challenge, ikm); // Extract (key = binary challenge)
    final info = [...utf8.encode(infoSalt), 0x01];
    return _hmac(prk, info); // Expand T(1)
  }

  // ------------------------------------------------------------------
  // Protected write
  // ------------------------------------------------------------------

  /// Frame ghi: [u32le(counter)][data][hmac-tag 4B].
  /// HMAC tính trên ['W'][u32le(counter)][uuid16][data] — byte 'W' không truyền đi.
  static Uint8List buildProtectedWrite({
    required Uint8List sessionKey,
    required int counter,
    required String characteristicUuid,
    required List<int> data,
  }) {
    final counterLe = u32le(counter);
    final uuidBytes = uuidToBytes(characteristicUuid);
    final body = [writePrefix, ...counterLe, ...uuidBytes, ...data];
    final tag = _hmac(sessionKey, body).sublist(0, hmacTagLen);
    return Uint8List.fromList([...counterLe, ...data, ...tag]);
  }

  // ------------------------------------------------------------------
  // Protected read
  // ------------------------------------------------------------------

  /// Giải mã response: [header 4B = u32le counter][cipher]; keystream HMAC
  /// 32 byte/block. Header 4B xác nhận từ btsnoop (counter tăng theo từng
  /// read toàn cục — doc cũ ghi 2B là sai).
  /// Trả về buffer rỗng nếu frame < 4 byte (hành vi app gốc).
  static Uint8List decryptProtectedRead({
    required Uint8List sessionKey,
    required String characteristicUuid,
    required List<int> response,
    int? expectedLength,
  }) {
    if (response.length < 4) return Uint8List(0);
    // Header là counter u32le 4 byte (subarray(0, 4) trong JS app gốc)
    final header = response.sublist(0, 4);
    final cipher = response.sublist(4);
    final uuidBytes = uuidToBytes(characteristicUuid);
    final out = Uint8List(cipher.length);
    var block = 0;
    for (var off = 0; off < cipher.length; off += keystreamBlock, block++) {
      final ks = _hmac(sessionKey,
          [readPrefix, ...header, ...uuidBytes, ...u32le(block)]);
      final chunk = (cipher.length - off).clamp(0, keystreamBlock);
      for (var t = 0; t < chunk; t++) {
        out[off + t] = cipher[off + t] ^ ks[t];
      }
    }
    if (expectedLength != null && out.length > expectedLength) {
      return Uint8List.sublistView(out, 0, expectedLength);
    }
    return out;
  }

  // ------------------------------------------------------------------
  // Phase 1 — auth response (ĐÃ CRACK + VERIFY 2026-10-19)
  // ------------------------------------------------------------------

  /// Auth response 16B của Phase 1 — ĐÃ VERIFY trên capture thật.
  ///
  /// Nguồn: đối chiếu 2 phía —
  /// - App gốc (decompile Hermes): msg = Uint8Array(21) set('DBauth',0) +
  ///   set(nonce15,6); key = Buffer.from(pairingToken,'utf8');
  ///   response = hmacSha256(key, msg).slice(0,16) — ghi lên 5e9a2c71.
  /// - Firmware xe (disasm onWriteAuthentication @0x40151806, mbedtls
  ///   md_hmac SHA-256): tính đúng HMAC như trên rồi XOR-so 16B constant-time.
  ///
  /// pairingToken = chuỗi 36 ký tự nhúng trong firmware (blob obfuscate ở
  /// DROM 0x3f413174, XOR keystream SHA256(key64=0x779e77defb3e5a4b LE,
  /// blockIdx)) — token fw 1.14.0: `c97eb99d-c695-4b5f-8a99-7b24ff2a7980`
  /// (hằng số chung, server cấp lại đúng chuỗi này cho app).
  ///
  /// Vector verify (btsnoop 2026-10-14): nonce15 2b4371f9…34f4 →
  /// resp b950cdc5…7f33; nonce15 0beb6afd…d581 → resp 646720b8…e378.
  static Uint8List computeAuthResponse({
    required String pairingToken,
    required Uint8List nonce15,
  }) {
    final msg =
        Uint8List.fromList([...utf8.encode('DBauth'), ...nonce15]);
    return Uint8List.fromList(
        _hmac(utf8.encode(pairingToken), msg).sublist(0, 16));
  }

  /// Tính toán phản hồi xác thực Legacy Auth 16 byte cho các dòng xe đời cũ
  /// (Weaver 200, Weaver++, Quantum đời đầu) trên cổng LEGACY_APP_AUTH_CHAR (c75ebe03).
  ///
  /// Nguồn: đối chiếu từ _fun9980 (connect_full_readable.js:2528):
  /// - Xe gửi 16 byte challenge.
  /// - App lấy 15 byte đầu: nonce15 = challenge[0..15].
  /// - Tạo buffer 21 byte msg = ['DBauth', ...nonce15].
  /// - Tính HMAC-SHA256 với key = utf8(password), msg = msg(21 byte).
  /// - Lấy 16 byte đầu tiên ghi ngược lại lên c75ebe03.
  /// - Xe kiểm tra hợp lệ và trả về status byte 0x01 ở byte thứ 16.
  static Uint8List computeLegacyAuthResponse({
    required String password,
    required Uint8List challenge16,
  }) {
    if (challenge16.length < 15) {
      throw ArgumentError('challenge16 phải có ít nhất 15 bytes');
    }
    final nonce15 = challenge16.sublist(0, 15);
    final msg = Uint8List.fromList([...utf8.encode('DBauth'), ...nonce15]);
    return Uint8List.fromList(
        _hmac(utf8.encode(password), msg).sublist(0, 16));
  }

  /// Giải mã challenge từ APP_AUTH_CHAR (c8eaf27b) bằng SHA-256 (64 hex lowercase)
  /// để kết nối lại (Auto-Reconnect) mà không cần quẹt thẻ NFC.
  ///
  /// Nguồn: App gốc Dat Bike (_fun9954 trong connect_full_readable.js) & btsnoop conn2:
  ///   raw4 = read(c8eaf27b)
  ///   challenge = raw4.readUInt32LE() >>> 1
  ///   hashHex = sha256(challenge.toString() + password).hexdigest()
  ///   write(c8eaf27b, ascii(hashHex))
  static String computeAppAuthChallengeResponse({
    required List<int> challengeRaw,
    required String password,
  }) {
    if (challengeRaw.length < 4) {
      throw ArgumentError('challengeRaw phải có ít nhất 4 bytes');
    }
    final u32 = ByteData.sublistView(Uint8List.fromList(challengeRaw))
        .getUint32(0, Endian.little);
    final challenge = u32 >> 1;
    final hashInput = '$challenge$password';
    return sha256.convert(utf8.encode(hashInput)).toString().toLowerCase();
  }

  // ------------------------------------------------------------------
  // Helpers
  // ------------------------------------------------------------------

  static Uint8List u32le(int v) => Uint8List.fromList([
        v & 0xff,
        (v >> 8) & 0xff,
        (v >> 16) & 0xff,
        (v >> 24) & 0xff,
      ]);

  /// UUID 128-bit string → 16 byte (bỏ dash, hex-decode).
  static Uint8List uuidToBytes(String uuid) {
    final hex = uuid.replaceAll('-', '').replaceAll(' ', '');
    if (hex.length != 32) {
      throw FormatException('UUID không hợp lệ: $uuid');
    }
    return Uint8List.fromList([
      for (var i = 0; i < 32; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
    ]);
  }

  static Uint8List _hmac(List<int> key, List<int> msg) =>
      Uint8List.fromList(Hmac(sha256, key).convert(msg).bytes);

  /// Public HMAC-SHA256 — dùng cho auth handshake 'DBauth'.
  static Uint8List hmacPublic(List<int> key, List<int> msg) =>
      _hmac(key, msg);
}
