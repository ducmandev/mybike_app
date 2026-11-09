import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mybike_app/core/models/bike_model_profile.dart';
import 'package:mybike_app/core/navigation/native_nav_bridge.dart';
import 'package:mybike_app/core/navigation/navigation_controller.dart';
import 'package:mybike_app/core/services/map_tile_service.dart';
import 'package:mybike_app/core/services/offline_map_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('offline_sim_test_');
    OfflineMapService.resetCacheDirForTesting(tempDir);
  });

  tearDown(() async {
    OfflineMapService.resetCacheDirForTesting(null);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Offline Simulation Tests (Full On-Device Without Internet)', () {
    // Tọa độ Chợ Bến Thành (Start) & Dinh Độc Lập (Dest) tại TP.HCM
    const startPos = LatLng(10.7725, 106.6980);
    const destPos = LatLng(10.7770, 106.6954);

    test('1. Offline Region Download & Road Graph Storage saves and loads correctly', () async {
      final bounds = LatLngBounds(
        const LatLng(10.7600, 106.6800),
        const LatLng(10.7900, 106.7100),
      );

      // Tạo mẫu dữ liệu OSM Road Graph Overpass JSON
      final mockOsmJson = '''
      {
        "elements": [
          {"type": "node", "id": 1001, "lat": 10.7725, "lon": 106.6980, "tags": {"name": "Chợ Bến Thành"}},
          {"type": "node", "id": 1002, "lat": 10.7745, "lon": 106.6968, "tags": {"name": "Ngã tư Pasteur"}},
          {"type": "node", "id": 1003, "lat": 10.7770, "lon": 106.6954, "tags": {"name": "Dinh Độc Lập"}},
          {
            "type": "way",
            "id": 5001,
            "nodes": [1001, 1002, 1003],
            "tags": {"highway": "primary", "name": "Đường Nam Kỳ Khởi Nghĩa", "maxspeed": "50"}
          }
        ]
      }
      ''';

      // Lưu Road Graph offline
      await OfflineMapService.instance.saveOfflineRoadGraph(
        'hcm_center',
        mockOsmJson,
        bounds: bounds,
      );

      // Nạp Road Graph offline cho tọa độ start và dest
      final loadedJson = await OfflineMapService.instance.loadOfflineRoadGraph(startPos, destPos);
      expect(loadedJson, isNotNull);
      expect(loadedJson, contains('"elements"'));
      expect(loadedJson, contains('Đường Nam Kỳ Khởi Nghĩa'));
    });

    test('2. Offline Tile Loading & Smart Fallback across partitioned sources', () async {
      final sourceKeyOrg = OfflineMapService.generateSourceKey(MapTileService.defaultUrlTemplate);
      const otherUrl = 'https://{s}.tile.openstreetmap.fr/osmfr/{z}/{x}/{y}.png';
      final sourceKeyFr = OfflineMapService.generateSourceKey(otherUrl);

      // Giả lập người dùng đã tải tile ở nguồn cũ (sourceKeyFr)
      final legacyTileFile = await OfflineMapService.instance.getTileFile(
        14, 13009, 7212,
        sourceKey: sourceKeyFr,
      );
      await legacyTileFile.parent.create(recursive: true);
      final validPngBytes = Uint8List.fromList([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
      ]);
      await legacyTileFile.writeAsBytes(validPngBytes);

      // Thư mục chính (sourceKeyOrg) ban đầu chưa có file
      final primaryTileFile = await OfflineMapService.instance.getTileFile(
        14, 13009, 7212,
        sourceKey: sourceKeyOrg,
      );
      expect(await primaryTileFile.exists(), isFalse);

      // Tìm kiếm thông minh qua findAnyCachedTile
      final fallback = await OfflineMapService.instance.findAnyCachedTile(
        14, 13009, 7212,
        excludeSourceKey: sourceKeyOrg,
      );
      expect(fallback, isNotNull);
      expect(await fallback!.exists(), isTrue);

      // Sao chép sang đúng phân vùng
      await primaryTileFile.parent.create(recursive: true);
      await fallback.copy(primaryTileFile.path);

      expect(await primaryTileFile.exists(), isTrue);
      expect(await OfflineMapService.instance.hasTile(14, 13009, 7212, sourceKey: sourceKeyOrg), isTrue);
    });

    test('3. Completely Offline A* Route Calculation & EV Battery Forecast (100% On-Device)', () async {
      final searchService = PlaceSearchService();
      final navBridge = NativeNavBridge();

      // Khi không có internet và chưa có file tải trước:
      // fetchRawOpenStreetMapData tự động tổng hợp hành lang đường đô thị từ CSDL địa danh
      final rawOsmJson = await searchService.fetchRawOpenStreetMapData(startPos, destPos);
      expect(rawOsmJson, isNotNull);
      expect(rawOsmJson, contains('"elements"'));
      expect(rawOsmJson, contains('Đại lộ hành lang giao thông'));

      // Tính toán tuyến đường bằng Rust Engine (hoặc Fallback Engine cục bộ)
      final route = navBridge.calculateRoute(
        start: startPos,
        end: destPos,
        ecoMode: true,
        batterySoc: 85,
        bikeModel: BikeModel.qtS1,
        osmRawJson: rawOsmJson,
        minimalFilter: true,
      );

      expect(route, isNotNull);
      expect(route!.distanceMeters, greaterThan(300.0));
      expect(route.durationSeconds, greaterThan(20.0));
      expect(route.polyline.length, greaterThanOrEqualTo(2));
      expect(route.steps, isNotEmpty);

      // Kiểm tra dự báo tiêu thụ pin EV
      expect(route.evForecast.estimatedSocUsedPercent, greaterThanOrEqualTo(0));
      expect(route.evForecast.arrivalSocPercent, inInclusiveRange(70, 85));
      expect(route.evForecast.isSafe, isTrue);
    });

    test('4. Real-time Turn-by-Turn GPS Tracking Simulation Along Route', () async {
      final searchService = PlaceSearchService();
      final navBridge = NativeNavBridge();

      final rawOsmJson = await searchService.fetchRawOpenStreetMapData(startPos, destPos);
      final route = navBridge.calculateRoute(
        start: startPos,
        end: destPos,
        ecoMode: false,
        batterySoc: 90,
        bikeModel: BikeModel.qtS1,
        osmRawJson: rawOsmJson,
      )!;

      expect(route.polyline.isNotEmpty, isTrue);

      // 4.1 GPS tại vị trí bắt đầu
      final trackStart = navBridge.trackStep(
        currentPos: route.polyline.first,
        speedKmh: 25.0,
        heading: 45.0,
        route: route,
        currentStepIndex: 0,
        batterySoc: 90,
      );
      expect(trackStart.isOffRoute, isFalse);
      expect(trackStart.remainingDistanceMeters, greaterThan(100.0));
      expect(trackStart.distanceToNextManeuverMeters, greaterThanOrEqualTo(0.0));

      // 4.2 GPS tại điểm giữa hành trình
      final midPointIndex = (route.polyline.length / 2).floor();
      final midPoint = route.polyline[midPointIndex];
      final trackMid = navBridge.trackStep(
        currentPos: midPoint,
        speedKmh: 35.0,
        heading: 90.0,
        route: route,
        currentStepIndex: 0,
        batterySoc: 89,
      );
      expect(trackMid.isOffRoute, isFalse);
      expect(trackMid.remainingDistanceMeters, lessThan(trackStart.remainingDistanceMeters));

      // 4.3 GPS tại đích đến
      final trackEnd = navBridge.trackStep(
        currentPos: route.polyline.last,
        speedKmh: 0.0,
        heading: 90.0,
        route: route,
        currentStepIndex: route.steps.length - 1,
        batterySoc: 88,
      );
      expect(trackEnd.remainingDistanceMeters, lessThanOrEqualTo(25.0));
      expect(trackEnd.hasArrived, isTrue);
    });

    test('5. Pure OSM Raw Vector Road Graph (Nodes & Ways) ingested directly into Rust Navigation Engine', () async {
      // Dữ liệu OSM thô với các Node và Way thực tế tại Quận 1
      const rawOsmJson = '''
      {
        "elements": [
          {"type": "node", "id": 2001, "lat": 10.7725, "lon": 106.6980, "tags": {"name": "Ngã tư Lê Lợi - Bến Thành"}},
          {"type": "node", "id": 2002, "lat": 10.7738, "lon": 106.6972, "tags": {"name": "Lê Lợi - Pasteur"}},
          {"type": "node", "id": 2003, "lat": 10.7755, "lon": 106.6963, "tags": {"name": "Lê Thánh Tôn"}},
          {"type": "node", "id": 2004, "lat": 10.7770, "lon": 106.6954, "tags": {"name": "Cổng Dinh Độc Lập"}},
          {
            "type": "way",
            "id": 8001,
            "nodes": [2001, 2002, 2003, 2004],
            "tags": {
              "highway": "primary",
              "name": "Đường Nam Kỳ Khởi Nghĩa",
              "motorcycle": "yes",
              "maxspeed": "50"
            }
          }
        ]
      }
      ''';

      final navBridge = NativeNavBridge();
      final route = navBridge.calculateRoute(
        start: const LatLng(10.7725, 106.6980),
        end: const LatLng(10.7770, 106.6954),
        ecoMode: false,
        batterySoc: 95,
        bikeModel: BikeModel.qtS1,
        osmRawJson: rawOsmJson,
      );

      expect(route, isNotNull);
      expect(route!.polyline.length, greaterThanOrEqualTo(4));
      expect(route.polyline.first.latitude, closeTo(10.7725, 0.0001));
      expect(route.polyline.last.latitude, closeTo(10.7770, 0.0001));
      expect(route.distanceMeters, greaterThan(300.0));
    });
  });
}
