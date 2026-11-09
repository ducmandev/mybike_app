import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mybike_app/core/services/offline_map_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OfflineMapService Coordinate and Region Tests', () {
    test('lon2tileX and lat2tileY convert geographic coordinates correctly', () {
      // Tọa độ Hồ Gươm (Hà Nội): 21.0285, 105.8542 tại Zoom 14
      final xHanoi = OfflineMapService.lon2tileX(105.8542, 14);
      final yHanoi = OfflineMapService.lat2tileY(21.0285, 14);

      expect(xHanoi, greaterThan(0));
      expect(yHanoi, greaterThan(0));
      expect(xHanoi, equals(13009));
      expect(yHanoi, equals(7212));
    });

    test('createRadiusBounds produces valid bounding box', () {
      const center = LatLng(10.7719, 106.7195);
      final bounds = OfflineMapService.createRadiusBounds(center, 5.0);

      expect(bounds.north, greaterThan(center.latitude));
      expect(bounds.south, lessThan(center.latitude));
      expect(bounds.east, greaterThan(center.longitude));
      expect(bounds.west, lessThan(center.longitude));
    });

    test('calculateTileList computes accurate non-empty tile list for presets', () {
      final presets = OfflineMapService.getPresets();
      expect(presets, isNotEmpty);

      final hcm = presets.first;
      final tiles = OfflineMapService.instance.calculateTileList(
        bounds: hcm.bounds,
        minZoom: 13,
        maxZoom: 14,
      );

      expect(tiles, isNotEmpty);
      for (final t in tiles) {
        expect(t.z, isIn([13, 14]));
        expect(t.x, greaterThan(0));
        expect(t.y, greaterThan(0));
      }
    });

    test('DownloadProgress calculates progress percentage and formatted size', () {
      const progress = DownloadProgress(
        current: 50,
        total: 100,
        bytes: 5 * 1024 * 1024,
        isRunning: true,
      );

      expect(progress.percent, equals(0.5));
      expect(progress.sizeMbText, equals('5.0 MB'));
    });
  });

  group('OfflineMapService Source Partitioning & Magic Bytes Tests', () {
    test('generateSourceKey is stable and distinguishes different urlTemplates', () {
      const templateOsmOrg = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
      const templateOsmFr = 'https://{s}.tile.openstreetmap.fr/osmfr/{z}/{x}/{y}.png';
      const templateCyclOsm = 'https://{s}.tile-cyclosm.openstreetmap.fr/cyclosm/{z}/{x}/{y}.png';

      final key1a = OfflineMapService.generateSourceKey(templateOsmOrg);
      final key1b = OfflineMapService.generateSourceKey(templateOsmOrg);
      final key2 = OfflineMapService.generateSourceKey(templateOsmFr);
      final key3 = OfflineMapService.generateSourceKey(templateCyclOsm);

      // (a) Ổn định cho cùng template
      expect(key1a, equals(key1b));
      expect(key1a, isNotEmpty);

      // (a) Khác nhau cho các urlTemplate khác nhau
      expect(key1a, isNot(equals(key2)));
      expect(key2, isNot(equals(key3)));
      expect(key1a, isNot(equals(key3)));

      // Ký tự hợp lệ cho tên thư mục
      expect(RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(key1a), isTrue);
      expect(RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(key2), isTrue);
      expect(RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(key3), isTrue);
    });

    test('isValidTileImageBytes correctly accepts PNG, JPEG, WebP and rejects invalid data', () {
      // (c) PNG hợp lệ (89 50 4E 47 ...) >= 512 bytes
      final validPng = Uint8List(512);
      validPng.setRange(0, 8, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      expect(OfflineMapService.isValidTileImageBytes(validPng), isTrue);

      // (c) JPEG hợp lệ (FF D8 FF ...) >= 512 bytes
      final validJpeg = Uint8List(512);
      validJpeg.setRange(0, 3, [0xFF, 0xD8, 0xFF]);
      expect(OfflineMapService.isValidTileImageBytes(validJpeg), isTrue);

      // (c) WebP hợp lệ ('RIFF' .... 'WEBP') >= 512 bytes
      final validWebp = Uint8List(512);
      validWebp.setRange(0, 4, [0x52, 0x49, 0x46, 0x46]);
      validWebp.setRange(8, 12, [0x57, 0x45, 0x42, 0x50]);
      expect(OfflineMapService.isValidTileImageBytes(validWebp), isTrue);

      // (c) Từ chối stub rỗng 103 bytes hoặc ảnh quá nhỏ (< 512 bytes)
      final stub103Bytes = Uint8List(103);
      stub103Bytes.setRange(0, 8, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      expect(OfflineMapService.isValidTileImageBytes(stub103Bytes), isFalse);

      // (c) Từ chối HTML error page
      final htmlError = Uint8List.fromList('<!DOCTYPE html><html><body>Error</body></html>'.codeUnits);
      expect(OfflineMapService.isValidTileImageBytes(htmlError), isFalse);

      // (c) Từ chối JSON error response (vd API Key Required / Carto error)
      final jsonError = Uint8List.fromList('{"error": "API key required", "code": 401}'.codeUnits);
      expect(OfflineMapService.isValidTileImageBytes(jsonError), isFalse);

      // (c) Từ chối buffer rỗng hoặc quá ngắn
      expect(OfflineMapService.isValidTileImageBytes(Uint8List(0)), isFalse);
      expect(OfflineMapService.isValidTileImageBytes(Uint8List.fromList([0x89, 0x50, 0x4E])), isFalse);
      expect(OfflineMapService.isValidTileImageBytes(null), isFalse);
    });
  });

  group('OfflineMapService Cache Directory Partitioning, Migration & Clear Tests', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('offline_tiles_test_');
      OfflineMapService.resetCacheDirForTesting(tempDir);
    });

    tearDown(() async {
      OfflineMapService.resetCacheDirForTesting(null);
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('getTileFile partitions tiles under v2/<sourceKey>/ folder', () async {
      final fileOsmOrg = await OfflineMapService.instance.getTileFile(
        14, 13009, 7212,
        sourceKey: 'osm_org_123',
      );
      final fileOsmFr = await OfflineMapService.instance.getTileFile(
        14, 13009, 7212,
        sourceKey: 'osm_fr_456',
      );

      final normalizedOsmOrg = fileOsmOrg.path.replaceAll(r'\', '/');
      final normalizedOsmFr = fileOsmFr.path.replaceAll(r'\', '/');
      expect(normalizedOsmOrg, contains('v2/osm_org_123'));
      expect(normalizedOsmFr, contains('v2/osm_fr_456'));
      expect(normalizedOsmOrg, endsWith('14_13009_7212.png'));
      expect(fileOsmOrg.path, isNot(equals(fileOsmFr.path)));
    });

    test('migration schema v2 deletes Carto legacy files at root and bumps schema to 2', () async {
      SharedPreferences.setMockInitialValues({'offline_tile_cache_schema': 1});
      final prefs = await SharedPreferences.getInstance();

      // Giả lập file phẳng legacy ở thư mục gốc (vd Carto "API key required" tile từ v2.6.28)
      final legacyFile1 = File('${tempDir.path}/14_13009_7212.png');
      await legacyFile1.writeAsString('legacy_carto_corrupted_tile');
      final legacyFile2 = File('${tempDir.path}/14_13009_7213.png');
      await legacyFile2.writeAsString('legacy_carto_corrupted_tile_2');
      final legacyDir = Directory('${tempDir.path}/old_cache_folder');
      await legacyDir.create();

      // Giả lập thư mục v2 đã có tile mới hợp lệ
      final v2Tile = File('${tempDir.path}/v2/osm_source/14_13009_7212.png');
      await v2Tile.parent.create(recursive: true);
      await v2Tile.writeAsBytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

      expect(await legacyFile1.exists(), isTrue);
      expect(await legacyFile2.exists(), isTrue);
      expect(await legacyDir.exists(), isTrue);
      expect(await v2Tile.exists(), isTrue);

      // (b) Chạy migration
      await OfflineMapService.instance.migrateCacheSchemaIfNeeded(
        targetDir: tempDir,
        prefs: prefs,
      );

      // File legacy ở root và thư mục cũ phải bị xóa sạch 100%
      expect(await legacyFile1.exists(), isFalse);
      expect(await legacyFile2.exists(), isFalse);
      expect(await legacyDir.exists(), isFalse);

      // Thư mục v2 được bảo toàn nguyên vẹn
      expect(await v2Tile.exists(), isTrue);

      // Schema được cập nhật lên 2
      expect(prefs.getInt('offline_tile_cache_schema'), equals(2));
    });

    test('clearCache deletes all files and subdirectories recursively', () async {
      // Tạo tile trong các thư mục con khác nhau của v2
      final tile1 = File('${tempDir.path}/v2/source_a/14_1_2.png');
      final tile2 = File('${tempDir.path}/v2/source_b/15_3_4.png');
      await tile1.parent.create(recursive: true);
      await tile2.parent.create(recursive: true);
      final dummyPng = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
      await tile1.writeAsBytes(dummyPng);
      await tile2.writeAsBytes(dummyPng);

      var stats = await OfflineMapService.instance.getCacheStats();
      expect(stats.tileCount, equals(2));
      expect(stats.totalBytes, equals(dummyPng.length * 2));

      // Thực hiện xóa toàn bộ cache đệ quy
      await OfflineMapService.instance.clearCache();

      // Kiểm tra thư mục vẫn tồn tại nhưng sạch bóng
      expect(await tempDir.exists(), isTrue);
      expect(await tile1.exists(), isFalse);
      expect(await tile2.exists(), isFalse);

      stats = await OfflineMapService.instance.getCacheStats();
      expect(stats.tileCount, equals(0));
      expect(stats.totalBytes, equals(0));
      expect(stats.sizeText, equals('0.0 MB'));
    });
  });
}
