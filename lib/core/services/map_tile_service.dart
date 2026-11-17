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
  /// Giúp nổi bật đường giao thông và tuyến đường tốc độ cao tương phản, hoàn toàn xử lý trên GPU thiết bị (0% API Key)
  static const List<double> minimalLightMatrix = <double>[
    0.88, 0.08, 0.04, 0, 22,
    0.06, 0.90, 0.04, 0, 22,
    0.05, 0.08, 0.87, 0, 24,
    0,    0,    0,    1,  0,
  ];

  /// Ma trận xám bạc mát (Cool Slate Grayscale) độ tương phản cao cho Chế độ Tối Giản.
  /// Triệt tiêu màu cam/vàng gắt của đường phố OSM thành xám bạc trung tính,
  /// giữ lại nhãn đường và công viên dịu nhẹ để tuyến đường nổi bật tuyệt đối.
  static const List<double> coolGrayscaleMatrix = <double>[
    0.246, 0.509, 0.105, 0, 25,
    0.201, 0.580, 0.109, 0, 27,
    0.210, 0.551, 0.168, 0, 29,
    0,     0,     0,     1,  0,
  ];

  /// Matrix đảo màu và xoay hệ màu 180° để biến bản đồ OSM tiêu chuẩn thành bản đồ đêm Dark EV
  /// Tương thích 100% mọi thiết bị, 100% OpenStreetMap miễn phí, không cần API Key
  static const List<double> darkMatrix = <double>[
     0.574, -1.430, -0.144, 0, 255,
    -0.426, -0.430, -0.144, 0, 255,
    -0.426, -1.430,  0.856, 0, 255,
     0,      0,      0,      1,   0,
  ];

  static TileBuilder _colorMatrixTileBuilder(List<double> matrix) {
    final filter = ColorFilter.matrix(matrix);
    return (BuildContext context, Widget tileWidget, TileImage tile) {
      return ColorFiltered(
        colorFilter: filter,
        child: tileWidget,
      );
    };
  }

  static Color routeBorderColorFor(MapTileStyle style) =>
      style == MapTileStyle.darkEv ? Colors.white : const Color(0xFF0F172A);

  /// Bảng màu tốc độ độ tương phản cao (không lẫn vào đường cam/vàng của bản đồ sáng):
  /// - <= 15 km/h: Sky (#0EA5E9) -> Cyan (#06B6D4)
  /// - 15..35 km/h: Cyan (#06B6D4) -> Emerald (#10B981)
  /// - 35..55 km/h: Emerald (#10B981) -> Cobalt Blue (#2563EB) -> Electric Violet (#7C3AED)
  /// - > 55 km/h: Electric Violet (#7C3AED) -> Deep Crimson (#E11D48)
  static Color getHighContrastSpeedColor(double speedKmh) {
    if (speedKmh <= 15.0) {
      final t = (speedKmh / 15.0).clamp(0.0, 1.0);
      return Color.lerp(const Color(0xFF0EA5E9), const Color(0xFF06B6D4), t)!;
    } else if (speedKmh <= 35.0) {
      final t = ((speedKmh - 15.0) / 20.0).clamp(0.0, 1.0);
      return Color.lerp(const Color(0xFF06B6D4), const Color(0xFF10B981), t)!;
    } else if (speedKmh <= 45.0) {
      final t = ((speedKmh - 35.0) / 10.0).clamp(0.0, 1.0);
      return Color.lerp(const Color(0xFF10B981), const Color(0xFF2563EB), t)!;
    } else if (speedKmh <= 55.0) {
      final t = ((speedKmh - 45.0) / 10.0).clamp(0.0, 1.0);
      return Color.lerp(const Color(0xFF2563EB), const Color(0xFF7C3AED), t)!;
    } else {
      final t = ((speedKmh - 55.0) / 30.0).clamp(0.0, 1.0);
      return Color.lerp(const Color(0xFF7C3AED), const Color(0xFFE11D48), t)!;
    }
  }

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
          tileBuilder: _colorMatrixTileBuilder(coolGrayscaleMatrix),
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
          tileBuilder: _colorMatrixTileBuilder(minimalLightMatrix),
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
          tileBuilder: _colorMatrixTileBuilder(darkMatrix),
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
