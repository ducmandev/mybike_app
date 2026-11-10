import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:mybike_app/core/models/bike_model_profile.dart';
import 'package:mybike_app/core/navigation/nav_models.dart';
import 'package:mybike_app/core/navigation/native_nav_bridge.dart';
import 'package:mybike_app/core/navigation/navigation_controller.dart';
import 'package:mybike_app/core/services/map_tile_service.dart';
import 'package:mybike_app/features/dashboard/widgets/cockpit_live_map.dart';

void main() {
  group('1. Nav Models & Enums Tests', () {
    test('NavManeuverType parses all string variants correctly', () {
      expect(NavManeuverType.fromString('turn_left'), NavManeuverType.turnLeft);
      expect(NavManeuverType.fromString('turn_right'), NavManeuverType.turnRight);
      expect(NavManeuverType.fromString('slight_left'), NavManeuverType.slightLeft);
      expect(NavManeuverType.fromString('slight_right'), NavManeuverType.slightRight);
      expect(NavManeuverType.fromString('u_turn'), NavManeuverType.uTurn);
      expect(NavManeuverType.fromString('straight'), NavManeuverType.straight);
      expect(NavManeuverType.fromString('arrive'), NavManeuverType.arrive);
      expect(NavManeuverType.fromString('UNKNOWN_CODE'), NavManeuverType.straight);
      expect(NavManeuverType.fromString(null), NavManeuverType.straight);

      expect(NavManeuverType.turnLeft.code, 'turn_left');
      expect(NavManeuverType.turnRight.code, 'turn_right');
      expect(NavManeuverType.slightLeft.code, 'slight_left');
      expect(NavManeuverType.slightRight.code, 'slight_right');
      expect(NavManeuverType.uTurn.code, 'u_turn');
      expect(NavManeuverType.arrive.code, 'arrive');
      expect(NavManeuverType.straight.code, 'straight');

      expect(NavManeuverType.turnLeft.vietnameseLabel, 'Ráº½ trÃ¡i');
      expect(NavManeuverType.turnRight.vietnameseLabel, 'Ráº½ pháº£i');
      expect(NavManeuverType.arrive.vietnameseLabel, 'Äáº¿n Ä‘Ã­ch');
    });

    test('NavSearchResult json roundtrip', () {
      const item = NavSearchResult(
        displayName: 'Chá»£ Báº¿n ThÃ nh, Quáº­n 1',
        shortName: 'Chá»£ Báº¿n ThÃ nh',
        lat: 10.7725,
        lng: 106.6980,
        category: 'landmark',
      );
      final json = item.toJson();
      final fromJson = NavSearchResult.fromJson(json);
      expect(fromJson.displayName, item.displayName);
      expect(fromJson.shortName, item.shortName);
      expect(fromJson.lat, item.lat);
      expect(fromJson.lng, item.lng);
      expect(fromJson.category, item.category);
      expect(fromJson.latLng.latitude, 10.7725);
    });

    test('NavRouteResult and TrackingState formatters', () {
      const route = NavRouteResult(
        distanceMeters: 4500,
        durationSeconds: 600,
        polyline: [LatLng(10.77, 106.70), LatLng(10.78, 106.71)],
        steps: [],
        evForecast: NavEvForecast(
          estimatedConsumptionWh: 120,
          estimatedSocUsedPercent: 2.2,
          arrivalSocPercent: 88,
          status: 'safe',
        ),
        isEcoMode: false,
      );
      expect(route.distanceKm, 4.5);
      expect(route.durationMinutes, 10);
      expect(route.formattedDistance, '4.5 km');
      expect(route.formattedDuration, '10 phÃºt');

      const tracking = NavTrackingState(
        snappedLocation: LatLng(10.77, 106.70),
        snappedBearing: 90,
        crossTrackErrorMeters: 3.5,
        isOffRoute: false,
        closestPolylineIndex: 0,
        currentStepIndex: 0,
        distanceToNextManeuverMeters: 180,
        remainingDistanceMeters: 3200,
        remainingDurationSeconds: 420,
        arrivalSocPercent: 87.5,
        energyStatus: 'safe',
        hasArrived: false,
      );
      expect(tracking.formattedDistanceToManeuver, '180 m');
      expect(tracking.formattedRemainingDistance, '3.2 km');
      expect(tracking.formattedRemainingTime, '7 phÃºt');
    });
  });

  group('2. NativeNavBridge Routing & EV Forecast Tests', () {
    final bridge = NativeNavBridge();
    const start = LatLng(10.7719, 106.7065); // Báº¿n Báº¡ch Äáº±ng
    const end = LatLng(10.7725, 106.6980); // Chá»£ Báº¿n ThÃ nh

    test('Native library is loaded on Windows via FFI', () {
      expect(bridge.isNativeLoaded, isTrue);
    });

    test('calculateRoute generates valid route in Normal mode', () {
      final route = bridge.calculateRoute(
        start: start,
        end: end,
        ecoMode: false,
        batterySoc: 90,
        bikeModel: BikeModel.qtS1,
      );

      expect(route, isNotNull);
      expect(route!.distanceMeters, greaterThan(500));
      expect(route.durationSeconds, greaterThan(30));
      expect(route.polyline.length, greaterThanOrEqualTo(2));
      expect(route.steps.isNotEmpty, isTrue);
      expect(route.isEcoMode, isFalse);
      expect(route.evForecast.isSafe, isTrue);
      expect(route.evForecast.arrivalSocPercent, lessThanOrEqualTo(90));
      expect(route.evForecast.warningMessage, isNull);
    });

    test('calculateRoute in Eco mode consumes less energy', () {
      final normalRoute = bridge.calculateRoute(
        start: start,
        end: end,
        ecoMode: false,
        batterySoc: 80,
        bikeModel: BikeModel.qtS1,
      );

      final ecoRoute = bridge.calculateRoute(
        start: start,
        end: end,
        ecoMode: true,
        batterySoc: 80,
        bikeModel: BikeModel.qtS1,
      );

      expect(normalRoute, isNotNull);
      expect(ecoRoute, isNotNull);
      expect(ecoRoute!.isEcoMode, isTrue);
      expect(ecoRoute.evForecast.estimatedConsumptionWh,
          lessThan(normalRoute!.evForecast.estimatedConsumptionWh));
      expect(ecoRoute.evForecast.arrivalSocPercent,
          greaterThan(normalRoute.evForecast.arrivalSocPercent));
    });

    test('EV forecast triggers warning when arrival battery is between 5% and 20%', () {
      final route = bridge.calculateRoute(
        start: start,
        end: end,
        ecoMode: false,
        batterySoc: 18,
        bikeModel: BikeModel.qtS1,
      );

      expect(route, isNotNull);
      expect(route!.evForecast.isWarning, isTrue);
      expect(route.evForecast.status, 'warning');
      expect(route.evForecast.warningMessage, isNotNull);
      expect(route.evForecast.warningMessage, contains('tráº¡m sáº¡c'));
    });

    test('EV forecast triggers critical when arrival battery drops below critical threshold', () {
      final route = bridge.calculateRoute(
        start: start,
        end: end,
        ecoMode: false,
        batterySoc: 3,
        bikeModel: BikeModel.qtS1,
      );

      expect(route, isNotNull);
      expect(route!.evForecast.isCritical, isTrue);
      expect(route.evForecast.status, 'critical');
      expect(route.evForecast.warningMessage, isNotNull);
      expect(route.evForecast.warningMessage, contains('Cáº§n sáº¡c'));
    });

    test('Zero or null batterySoc defaults to 100% without negative critical warning', () {
      final routeZero = bridge.calculateRoute(
        start: start,
        end: end,
        ecoMode: false,
        batterySoc: 0,
        bikeModel: BikeModel.qtS1,
      );

      expect(routeZero, isNotNull);
      expect(routeZero!.evForecast.arrivalSocPercent, greaterThan(95));
      expect(routeZero.evForecast.status, 'safe');
      expect(routeZero.evForecast.isCritical, isFalse);

      final routeNull = bridge.calculateRoute(
        start: start,
        end: end,
        ecoMode: false,
        batterySoc: null,
        bikeModel: BikeModel.qtS1,
      );

      expect(routeNull, isNotNull);
      expect(routeNull!.evForecast.arrivalSocPercent, greaterThan(95));
      expect(routeNull.evForecast.status, 'safe');
    });

    test('Fallback engine returns null for distances > 1500m without corridor', () {
      const farStart = LatLng(10.7719, 106.7065); // TP.HCM
      const farEnd = LatLng(21.0287, 105.8523); // HÃ  Ná»™i (1,100 km)
      final farRoute = bridge.calculateRoute(
        start: farStart,
        end: farEnd,
        ecoMode: false,
      );
      // Rust network has no link between HCM and Hanoi, and fallback refuses long straight line
      expect(farRoute, isNull);
    });

    test('Arterial route: Ben Thanh to Tan Son Nhat airport (7.5km)', () {
      const benThanh = LatLng(10.7725, 106.6980);
      const tsnAirport = LatLng(10.8184, 106.6588);
      final route = bridge.calculateRoute(
        start: benThanh,
        end: tsnAirport,
        ecoMode: false,
      );
      expect(route, isNotNull);
      expect(route!.distanceMeters, greaterThan(5000));
      expect(route.steps.isNotEmpty, isTrue);
    });

    test('Arterial route: Ben Thanh to Thu Duc (13km)', () {
      const benThanh = LatLng(10.7725, 106.6980);
      const thuDuc = LatLng(10.8500, 106.7680);
      final route = bridge.calculateRoute(
        start: benThanh,
        end: thuDuc,
        ecoMode: false,
      );
      expect(route, isNotNull);
      expect(route!.distanceMeters, greaterThan(10000));
      expect(route.steps.isNotEmpty, isTrue);
    });

    test('Arterial route: Hanoi Hoan Kiem to Cau Giay (6.5km)', () {
      const hoanKiem = LatLng(21.0287, 105.8523);
      const cauGiay = LatLng(21.0333, 105.7950);
      final route = bridge.calculateRoute(
        start: hoanKiem,
        end: cauGiay,
        ecoMode: false,
      );
      expect(route, isNotNull);
      expect(route!.distanceMeters, greaterThan(5000));
      expect(route.steps.isNotEmpty, isTrue);
    });
  });

  group('3. NativeNavBridge Turn-by-Turn Tracking Tests', () {
    final bridge = NativeNavBridge();
    const start = LatLng(10.7719, 106.7065);
    const end = LatLng(10.7725, 106.6980);

    final route = bridge.calculateRoute(
      start: start,
      end: end,
      ecoMode: false,
      batterySoc: 85,
    )!;

    test('trackStep snaps cleanly onto route when driving near path', () {
      final onRoutePoint = route.polyline[1];
      final tracking = bridge.trackStep(
        currentPos: onRoutePoint,
        speedKmh: 35.0,
        heading: 90.0,
        route: route,
        currentStepIndex: 0,
        batterySoc: 85,
      );

      expect(tracking.crossTrackErrorMeters, lessThan(10.0));
      expect(tracking.isOffRoute, isFalse);
      expect(tracking.hasArrived, isFalse);
      expect(tracking.remainingDistanceMeters, greaterThan(0));
    });

    test('trackStep detects isOffRoute == true when deviating > 35m', () {
      const offRoutePoint = LatLng(10.8500, 106.7500);
      final tracking = bridge.trackStep(
        currentPos: offRoutePoint,
        speedKmh: 30.0,
        heading: 45.0,
        route: route,
        currentStepIndex: 0,
        batterySoc: 85,
      );

      expect(tracking.crossTrackErrorMeters, greaterThan(35.0));
      expect(tracking.isOffRoute, isTrue);
    });

    test('trackStep detects hasArrived == true when within 25m of destination', () {
      final endPoint = route.polyline.last;
      final tracking = bridge.trackStep(
        currentPos: endPoint,
        speedKmh: 0.0,
        heading: 90.0,
        route: route,
        currentStepIndex: route.steps.length - 1,
        batterySoc: 83,
      );

      expect(tracking.hasArrived, isTrue);
    });
  });

  group('4. PlaceSearchService Offline & Online Tests', () {
    final searchService = PlaceSearchService();

    test('Normalizes Vietnamese diacritics accurately', () {
      expect(PlaceSearchService.normalizeVietnamese('Chá»£ Báº¿n ThÃ nh'), 'cho ben thanh');
      expect(PlaceSearchService.normalizeVietnamese('ÄÃ  Náºµng & HÃ  Ná»™i'), 'da nang & ha noi');
      expect(PlaceSearchService.normalizeVietnamese('Thá»§ ThiÃªm 100%'), 'thu thiem 100%');
    });

    test('Searches built-in landmarks with Vietnamese diacritics', () async {
      final results = await searchService.search('Chá»£ Báº¿n ThÃ nh');
      expect(results.isNotEmpty, isTrue);
      expect(results.first.shortName, 'Chá»£ Báº¿n ThÃ nh');
      expect(results.first.category, 'landmark');
    });

    test('Searches built-in landmarks without diacritics (unaccented)', () async {
      final results = await searchService.search('ben thanh');
      expect(results.any((r) => r.shortName.contains('Báº¿n ThÃ nh')), isTrue);
    });

    test('Searches with unaccented variants like thu thiem, ho guom', () async {
      final thuThiem = await searchService.search('thu thiem');
      expect(thuThiem.any((r) => r.shortName.contains('Thá»§ ThiÃªm')), isTrue);

      final hoGuom = await searchService.search('ho hoan kiem');
      expect(hoGuom.any((r) => r.shortName.contains('Há»“ HoÃ n Kiáº¿m')), isTrue);
    });

    test('Supports direct coordinates search (lat, lng)', () async {
      final coordResults = await searchService.search('10.7725, 106.6980');
      expect(coordResults.isNotEmpty, isTrue);
      expect(coordResults.first.category, 'custom');
      expect(coordResults.first.lat, 10.7725);
      expect(coordResults.first.lng, 106.6980);
    });

    test('Searches Dat Charge charging stations across provinces', () async {
      final results = await searchService.search('Dat Charge');
      expect(results.isNotEmpty, isTrue);
      expect(results.every((r) => r.category == 'charging_station'), isTrue);
      expect(results.length, greaterThanOrEqualTo(5));
    });

    test('Searches regional landmarks in Hanoi, Da Nang, Can Tho, Binh Duong', () async {
      final hanoi = await searchService.search('Há»“ HoÃ n Kiáº¿m');
      expect(hanoi.isNotEmpty, isTrue);

      final danang = await searchService.search('Cáº§u Rá»“ng');
      expect(danang.isNotEmpty, isTrue);

      final cantho = await searchService.search('Ninh Kiá»u');
      expect(cantho.isNotEmpty, isTrue);

      final binhduong = await searchService.search('BÃ¬nh DÆ°Æ¡ng');
      expect(binhduong.isNotEmpty, isTrue);
    });
  });

  group('5. NavigationController State Flow Tests', () {
    test('selectDestination, toggleEcoMode, start/stop and clearRoute flow', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final controller = container.read(navigationProvider.notifier);

      expect(container.read(navigationProvider).destination, isNull);
      expect(container.read(navigationProvider).activeRoute, isNull);
      expect(container.read(navigationProvider).isNavigating, isFalse);

      const dest = NavSearchResult(
        displayName: 'Chá»£ Báº¿n ThÃ nh',
        shortName: 'Chá»£ Báº¿n ThÃ nh',
        lat: 10.7725,
        lng: 106.6980,
        category: 'landmark',
      );
      await controller.selectDestination(
        dest,
        currentPos: const LatLng(10.7719, 106.7065),
        batterySoc: 90,
        bikeModel: BikeModel.qtS1,
      );

      final stateWithRoute = container.read(navigationProvider);
      expect(stateWithRoute.destination, dest);
      expect(stateWithRoute.activeRoute, isNotNull);
      expect(stateWithRoute.tracking, isNotNull);
      expect(stateWithRoute.isNavigating, isFalse);

      await controller.toggleEcoMode(
        currentPos: const LatLng(10.7719, 106.7065),
        batterySoc: 90,
        bikeModel: BikeModel.qtS1,
      );
      expect(container.read(navigationProvider).ecoMode, isTrue);
      expect(container.read(navigationProvider).activeRoute!.isEcoMode, isTrue);

      controller.startNavigation();
      expect(container.read(navigationProvider).isNavigating, isTrue);

      controller.stopNavigation();
      expect(container.read(navigationProvider).isNavigating, isFalse);

      controller.clearRoute();
      expect(container.read(navigationProvider).destination, isNull);
      expect(container.read(navigationProvider).activeRoute, isNull);
      expect(container.read(navigationProvider).tracking, isNull);
    });

    test('searchPlaces with debounce and searchPlacesImmediately', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final controller = container.read(navigationProvider.notifier);

      // searchPlaces lá»c ngay káº¿t quáº£ ná»™i bá»™ vÃ  Ä‘áº·t isSearching = true
      controller.searchPlaces('Ben Thanh');
      expect(container.read(navigationProvider).isSearching, isTrue);
      expect(container.read(navigationProvider).searchResults.isNotEmpty, isTrue);

      // searchPlacesImmediately tÃ¬m kiáº¿m ngay láº­p tá»©c
      await controller.searchPlacesImmediately('Dat Charge Q1');
      expect(container.read(navigationProvider).isSearching, isFalse);
      expect(container.read(navigationProvider).searchResults.any((r) => r.shortName.contains('Q1')), isTrue);
    });

    test('updateGpsPosition triggers reroute when off-route', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final controller = container.read(navigationProvider.notifier);
      const dest = NavSearchResult(
        displayName: 'Chá»£ Báº¿n ThÃ nh',
        shortName: 'Chá»£ Báº¿n ThÃ nh',
        lat: 10.7725,
        lng: 106.6980,
        category: 'landmark',
      );
      await controller.selectDestination(
        dest,
        currentPos: const LatLng(10.7719, 106.7065),
        batterySoc: 80,
      );

      final initialRoute = container.read(navigationProvider).activeRoute;
      expect(initialRoute, isNotNull);

      // Di chuyá»ƒn lá»‡ch háº³n sang tá»a Ä‘á»™ khÃ¡c
      const offRouteGps = LatLng(10.8200, 106.7800);
      controller.updateGpsPosition(offRouteGps, 30.0, 90.0, batterySoc: 80);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      final rerouted = container.read(navigationProvider).activeRoute;
      expect(rerouted, isNotNull);
    });
  });

  group('6. CockpitLiveMap Navigation HUD Widget Tests', () {
    testWidgets(
        'CockpitLiveMap renders in standard Dashboard mode with Bike Speed and GPS Speed without overflow',
        (tester) async {
      tester.view.physicalSize = const Size(600 * 2.0, 900 * 2.0);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: CockpitLiveMap(
                currentSpeedKmh: 42.0,
                isFullScreen: false,
                batteryPercent: 88,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(CockpitLiveMap), findsOneWidget);

      // Hiá»ƒn thá»‹ tá»‘c Ä‘á»™ xe (Tá»C Äá»˜ XE: 42 km/h hoáº·c chá»©a 42)
      final bikeSpeedFinder = find.byWidgetPredicate((w) =>
          w is Text &&
          (w.data?.contains('42') == true ||
           w.data?.contains('Tá»C Äá»˜ XE') == true ||
           w.data?.contains('XE:') == true));
      expect(bikeSpeedFinder, findsWidgets);

      // Hiá»ƒn thá»‹ tá»‘c Ä‘á»™ tÃ­nh tá»« GPS (Tá»C Äá»˜ GPS hoáº·c GPS:)
      final gpsSpeedFinder = find.byWidgetPredicate((w) =>
          w is Text &&
          (w.data?.contains('Tá»C Äá»˜ GPS') == true ||
           w.data?.contains('GPS:') == true ||
           w.data?.contains('GPS') == true));
      expect(gpsSpeedFinder, findsWidgets);

      // Kiá»ƒm tra thanh tÃ¬m kiáº¿m cÅ© khÃ´ng cÃ²n xuáº¥t hiá»‡n
      expect(find.text('TÃ¬m Ä‘iá»ƒm Ä‘áº¿n, tráº¡m sáº¡c Dat Charge...'), findsNothing);
    });

    testWidgets(
        'CockpitLiveMap renders Dual Speedometer HUD (Bike Speed & GPS Speed) in FullScreen mode',
        (tester) async {
      tester.view.physicalSize = const Size(600 * 2.0, 900 * 2.0);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: CockpitLiveMap(
                currentSpeedKmh: 55.5,
                isFullScreen: true,
                batteryPercent: 92,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(CockpitLiveMap), findsOneWidget);

      // Kiá»ƒm tra hiá»ƒn thá»‹ nhÃ£n 'Tá»C Äá»˜ XE' vÃ  'Tá»C Äá»˜ GPS', giÃ¡ trá»‹ '55.5', vÃ  nhÃ£n 'Äá»™ lá»‡ch:'
      expect(find.textContaining('Tá»C Äá»˜ XE'), findsWidgets);
      expect(find.textContaining('Tá»C Äá»˜ GPS'), findsWidgets);
      expect(find.textContaining('55.5'), findsWidgets);
      expect(find.textContaining('Äá»™ lá»‡ch:'), findsWidgets);

      // Kiá»ƒm tra thanh tÃ¬m kiáº¿m cÅ© khÃ´ng cÃ²n xuáº¥t hiá»‡n
      expect(find.text('TÃ¬m Ä‘iá»ƒm Ä‘áº¿n, tráº¡m sáº¡c Dat Charge...'), findsNothing);
    });

    testWidgets(
        'CockpitLiveMap in Fullscreen mode renders Back button, Compass button, and opens Style Menu',
        (tester) async {
      tester.view.physicalSize = const Size(600 * 2.0, 900 * 2.0);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      bool backPressed = false;

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: CockpitLiveMap(
                currentSpeedKmh: 20.0,
                isFullScreen: true,
                onExpandFullScreen: () {
                  backPressed = true;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Kiá»ƒm tra nÃºt Back (Icons.arrow_back_rounded)
      final backBtn = find.byIcon(Icons.arrow_back_rounded);
      expect(backBtn, findsWidgets);
      await tester.tap(backBtn.first);
      await tester.pumpAndSettle();
      expect(backPressed, isTrue);

      // Kiá»ƒm tra nÃºt La bÃ n (find.text('Báº®C') -> tap -> find.text('XE'))
      expect(find.text('Báº®C'), findsWidgets);
      await tester.tap(find.text('Báº®C').first);
      await tester.pumpAndSettle();
      expect(find.text('XE'), findsWidgets);

      // Má»Ÿ menu kiá»ƒu báº£n Ä‘á»“ (Icons.layers_clear_rounded -> 'Báº£n Äá»“ Tá»‘i Giáº£n' / 'Tá»‘i Giáº£n')
      final styleBtn = find.byIcon(Icons.layers_clear_rounded);
      expect(styleBtn, findsWidgets);
      await tester.tap(styleBtn.first);
      await tester.pumpAndSettle();

      expect(
        find.byWidgetPredicate((w) =>
            w is Text &&
            (w.data == 'Báº£n Äá»“ Tá»‘i Giáº£n (KhuyÃªn DÃ¹ng)' ||
             w.data?.contains('Báº£n Äá»“ Tá»‘i Giáº£n') == true ||
             w.data?.contains('Tá»‘i Giáº£n') == true)),
        findsWidgets,
      );
    });

    testWidgets(
        'FullScreenNavigationPage renders CockpitLiveMap with Dual Speedometer HUD in full-bleed mode',
        (tester) async {
      tester.view.physicalSize = const Size(600 * 2.0, 900 * 2.0);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: FullScreenNavigationPage(
              currentSpeedKmh: 40.0,
              batteryPercent: 75,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(CockpitLiveMap), findsOneWidget);
      expect(find.textContaining('Tá»C Äá»˜ XE'), findsWidgets);
      expect(find.textContaining('Tá»C Äá»˜ GPS'), findsWidgets);
      expect(find.byIcon(Icons.arrow_back_rounded), findsWidgets);
    });
  });

  group('7. MapTileService Minimal and Detailed Layout Tests', () {
    test('MapTileService correctly classifies minimal styles and detailed styles', () {
      expect(MapTileService.isMinimal(MapTileStyle.minimalLight), isTrue);
      expect(MapTileService.isMinimal(MapTileStyle.voyagerNav), isTrue);
      expect(MapTileService.isMinimal(MapTileStyle.darkEv), isTrue);
      expect(MapTileService.isMinimal(MapTileStyle.fastCdn), isFalse);
      expect(MapTileService.isMinimal(MapTileStyle.cyclosm), isFalse);
      expect(MapTileService.isMinimal(MapTileStyle.osmStandard), isFalse);

      expect(MapTileService.getStyleName(MapTileStyle.minimalLight), contains('Tá»‘i Giáº£n'));
      expect(MapTileService.getStyleName(MapTileStyle.fastCdn), contains('Chi Tiáº¿t'));
      expect(MapTileService.getStyleDescription(MapTileStyle.minimalLight), contains('Lá»c bá»›t Khu phá»‘/PhÆ°á»ng'));
    });

    test('PlaceSearchService.cleanOsmDisplayName strips clutter and postal codes', () {
      const raw1 = 'Chá»£ Báº¿n ThÃ nh, LÃª Lá»£i, PhÆ°á»ng Báº¿n ThÃ nh, Khu phá»‘ 1, Quáº­n 1, 700000, Viá»‡t Nam';
      final clean1 = PlaceSearchService.cleanOsmDisplayName(raw1, minimal: true);
      expect(clean1, 'Chá»£ Báº¿n ThÃ nh, LÃª Lá»£i, Quáº­n 1');

      final clean1Detailed = PlaceSearchService.cleanOsmDisplayName(raw1, minimal: false);
      expect(clean1Detailed, 'Chá»£ Báº¿n ThÃ nh, LÃª Lá»£i, PhÆ°á»ng Báº¿n ThÃ nh, Khu phá»‘ 1, Quáº­n 1');

      const raw2 = '101 BÃ¹i Thá»‹ XuÃ¢n, Tá»• dÃ¢n phá»‘ 12, áº¤p ÄÃ´ng, PhÆ°á»ng 2, TÃ¢n BÃ¬nh, 71000, Vietnam';
      final clean2 = PlaceSearchService.cleanOsmDisplayName(raw2, minimal: true);
      expect(clean2, '101 BÃ¹i Thá»‹ XuÃ¢n, TÃ¢n BÃ¬nh');

      const raw3 = 'KhÃ³m 3, ThÃ´n 5, XÃ£ HÃ²a PhÃº, Äáº¯k Láº¯k';
      final clean3 = PlaceSearchService.cleanOsmDisplayName(raw3, minimal: true);
      expect(clean3, 'Äáº¯k Láº¯k');

      final clean3Detailed = PlaceSearchService.cleanOsmDisplayName(raw3, minimal: false);
      expect(clean3Detailed, 'KhÃ³m 3, ThÃ´n 5, XÃ£ HÃ²a PhÃº, Äáº¯k Láº¯k');
    });
  });
}

