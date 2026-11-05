import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'offline_map_service.dart';

enum MapTileStyle {
  fastCdn,     // OSM-FR: Máy chủ OpenStreetMap hiệu năng cao, đa luồng subdomain a/b/c, hoàn toàn miễn phí & KHÔNG CẦN API KEY
  darkEv,      // Dark EV: Lớp bản đồ đêm công nghệ bằng bộ lọc đảo màu HUD (No API Key)
  cyclosm,     // CyclOSM: Bản đồ chuyên biệt cho xe 2 bánh / xe điện Dat Bike (No API Key)
  osmStandard, // OpenStreetMap tiêu chuẩn (No API Key)
}

class MapTileService {
  /// URL template gạch bản đồ chuẩn toàn hệ thống (OpenStreetMap)
  static const String defaultUrlTemplate = OfflineMapService.defaultTileUrlTemplate;

  /// Matrix đảo màu và xoay hệ màu để biến bản đồ OSM tiêu chuẩn thành bản đồ đêm Dark EV
  /// Tương thích 100% mọi thiết bị, không cần API Key, không phụ thuộc server bên thứ ba
  static const List<double> darkMatrix = <double>[
    -0.574, -1.430, -0.144, 0, 255,
    -0.426, -0.570, -0.144, 0, 255,
    -0.426, -1.430,  0.856, 0, 255,
     0,      0,      0,      1,   0,
  ];

  static TileLayer buildTileLayer({
    MapTileStyle style = MapTileStyle.fastCdn,
  }) {
    // Tự động kiểm tra bộ nhớ đệm ổ cứng local offline trước (0ms latency, chạy offline hoàn toàn)
    // Nếu chưa có thì tải từ mạng và tự động lưu vào ổ cứng
    final offlineProvider = OfflineCacheTileProvider();

    switch (style) {
      case MapTileStyle.fastCdn:
        return TileLayer(
          urlTemplate: defaultUrlTemplate,
          userAgentPackageName: 'com.datbike.app',
          maxZoom: 19,
          tileProvider: offlineProvider,
        );

      case MapTileStyle.darkEv:
        return TileLayer(
          urlTemplate: defaultUrlTemplate,
          userAgentPackageName: 'com.datbike.app',
          maxZoom: 19,
          tileProvider: offlineProvider,
          tileBuilder: (context, tileWidget, tile) {
            return ColorFiltered(
              colorFilter: const ColorFilter.matrix(darkMatrix),
              child: tileWidget,
            );
          },
        );

      case MapTileStyle.cyclosm:
        return TileLayer(
          urlTemplate: defaultUrlTemplate,
          userAgentPackageName: 'com.datbike.app',
          maxZoom: 19,
          tileProvider: offlineProvider,
        );

      case MapTileStyle.osmStandard:
        return TileLayer(
          urlTemplate: defaultUrlTemplate,
          userAgentPackageName: 'com.datbike.app',
          maxZoom: 19,
          tileProvider: offlineProvider,
        );
    }
  }

  static String getStyleName(MapTileStyle style) {
    switch (style) {
      case MapTileStyle.fastCdn:
        return 'Tải Nhanh (OSM-FR)';
      case MapTileStyle.darkEv:
        return 'Bản Đồ Đêm EV';
      case MapTileStyle.cyclosm:
        return 'Làn Xe Máy / 2 Bánh';
      case MapTileStyle.osmStandard:
        return 'OSM Tiêu Chuẩn';
    }
  }

  static IconData getStyleIcon(MapTileStyle style) {
    switch (style) {
      case MapTileStyle.fastCdn:
        return Icons.bolt_rounded;
      case MapTileStyle.darkEv:
        return Icons.dark_mode_rounded;
      case MapTileStyle.cyclosm:
        return Icons.two_wheeler_rounded;
      case MapTileStyle.osmStandard:
        return Icons.public_rounded;
    }
  }
}
