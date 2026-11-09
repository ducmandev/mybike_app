import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'offline_map_service.dart';

enum MapTileStyle {
  minimalLight, // Chế độ Tối Giản: 100% bản đồ OpenStreetMap gốc qua bộ lọc ma trận GPU làm dịu chi tiết thừa
  voyagerNav,   // Chế độ Điều Hướng: bản đồ OpenStreetMap gốc tập trung vào mạng lưới đường
  darkEv,       // Chế độ Ban Đêm (HUD): bản đồ OpenStreetMap gốc qua ma trận đảo màu công nghệ HUD
  fastCdn,      // Chế độ Chi Tiết: bản đồ OpenStreetMap gốc đầy đủ khu phố, phường, địa danh
  cyclosm,      // Chế độ Xe Máy & Xe 2 Bánh
  osmStandard,  // Chế độ Tiêu Chuẩn
}

class MapTileService {
  /// URL template gạch bản đồ chuẩn toàn hệ thống (OpenStreetMap)
  static const String defaultUrlTemplate = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  /// Matrix làm dịu độ tương phản của nền/chi tiết phụ trên tile OpenStreetMap
  /// Giúp nổi bật đường giao thông và tuyến đường Cyan neon, hoàn toàn xử lý trên GPU thiết bị (0% API Key)
  static const List<double> minimalLightMatrix = <double>[
    0.88, 0.08, 0.04, 0, 22,
    0.06, 0.90, 0.04, 0, 22,
    0.05, 0.08, 0.87, 0, 24,
    0,    0,    0,    1,  0,
  ];

  /// Matrix đảo màu và xoay hệ màu để biến bản đồ OSM tiêu chuẩn thành bản đồ đêm Dark EV
  /// Tương thích 100% mọi thiết bị, 100% OpenStreetMap miễn phí, không cần API Key
  static const List<double> darkMatrix = <double>[
    -0.574, -1.430, -0.144, 0, 255,
    -0.426, -0.570, -0.144, 0, 255,
    -0.426, -1.430,  0.856, 0, 255,
     0,      0,      0,      1,   0,
  ];

  static TileLayer buildTileLayer({
    MapTileStyle style = MapTileStyle.minimalLight,
  }) {
    final offlineProvider = OfflineCacheTileProvider();
    const subdomains = ['a', 'b', 'c'];

    switch (style) {
      case MapTileStyle.minimalLight:
        return TileLayer(
          urlTemplate: 'https://{s}.tile.openstreetmap.fr/osmfr/{z}/{x}/{y}.png',
          subdomains: subdomains,
          userAgentPackageName: 'com.datbike.app',
          maxZoom: 19,
          panBuffer: 1,
          keepBuffer: 3,
          tileProvider: offlineProvider,
        );

      case MapTileStyle.voyagerNav:
        return TileLayer(
          urlTemplate: 'https://{s}.tile.openstreetmap.fr/osmfr/{z}/{x}/{y}.png',
          subdomains: subdomains,
          userAgentPackageName: 'com.datbike.app',
          maxZoom: 19,
          panBuffer: 1,
          keepBuffer: 3,
          tileProvider: offlineProvider,
        );

      case MapTileStyle.darkEv:
        return TileLayer(
          urlTemplate: 'https://{s}.tile.openstreetmap.fr/osmfr/{z}/{x}/{y}.png',
          subdomains: subdomains,
          userAgentPackageName: 'com.datbike.app',
          maxZoom: 19,
          panBuffer: 1,
          keepBuffer: 3,
          tileProvider: offlineProvider,
        );

      case MapTileStyle.fastCdn:
        return TileLayer(
          urlTemplate: 'https://{s}.tile.openstreetmap.fr/osmfr/{z}/{x}/{y}.png',
          subdomains: subdomains,
          userAgentPackageName: 'com.datbike.app',
          maxZoom: 19,
          panBuffer: 1,
          keepBuffer: 3,
          tileProvider: offlineProvider,
        );

      case MapTileStyle.cyclosm:
        return TileLayer(
          urlTemplate: 'https://{s}.tile.openstreetmap.fr/osmfr/{z}/{x}/{y}.png',
          subdomains: subdomains,
          userAgentPackageName: 'com.datbike.app',
          maxZoom: 19,
          panBuffer: 1,
          keepBuffer: 3,
          tileProvider: offlineProvider,
        );

      case MapTileStyle.osmStandard:
        return TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          subdomains: subdomains,
          userAgentPackageName: 'com.datbike.app',
          maxZoom: 19,
          panBuffer: 1,
          keepBuffer: 3,
          tileProvider: offlineProvider,
        );
    }
  }

  static String getStyleName(MapTileStyle style) {
    switch (style) {
      case MapTileStyle.minimalLight:
        return 'Chế độ Tối Giản';
      case MapTileStyle.voyagerNav:
        return 'Chế độ Điều Hướng';
      case MapTileStyle.darkEv:
        return 'Chế độ Ban Đêm (HUD)';
      case MapTileStyle.fastCdn:
        return 'Chế độ Chi Tiết';
      case MapTileStyle.cyclosm:
        return 'Chế độ Xe Máy & Xe 2 Bánh';
      case MapTileStyle.osmStandard:
        return 'Chế độ Tiêu Chuẩn';
    }
  }

  static String getStyleDescription(MapTileStyle style) {
    switch (style) {
      case MapTileStyle.minimalLight:
        return 'Bản đồ OpenStreetMap gốc — Lọc bớt Khu phố/Phường & làm dịu chi tiết thừa';
      case MapTileStyle.voyagerNav:
        return 'Bản đồ OpenStreetMap gốc — Tập trung vào hạ tầng giao thông';
      case MapTileStyle.darkEv:
        return 'Bản đồ OpenStreetMap gốc — Xử lý ma trận đêm trên thiết bị';
      case MapTileStyle.fastCdn:
        return 'Bản đồ OpenStreetMap gốc — Hiển thị đầy đủ Phường, Khu phố & địa danh';
      case MapTileStyle.cyclosm:
        return 'Bản đồ OpenStreetMap gốc — Tối ưu cho xe máy và xe 2 bánh điện';
      case MapTileStyle.osmStandard:
        return 'Bản đồ OpenStreetMap gốc tiêu chuẩn';
    }
  }

  static bool isMinimal(MapTileStyle style) {
    return style == MapTileStyle.minimalLight ||
        style == MapTileStyle.voyagerNav ||
        style == MapTileStyle.darkEv;
  }

  static IconData getStyleIcon(MapTileStyle style) {
    switch (style) {
      case MapTileStyle.minimalLight:
        return Icons.layers_clear_rounded;
      case MapTileStyle.voyagerNav:
        return Icons.explore_rounded;
      case MapTileStyle.darkEv:
        return Icons.dark_mode_rounded;
      case MapTileStyle.fastCdn:
        return Icons.map_rounded;
      case MapTileStyle.cyclosm:
        return Icons.two_wheeler_rounded;
      case MapTileStyle.osmStandard:
        return Icons.public_rounded;
    }
  }
}
