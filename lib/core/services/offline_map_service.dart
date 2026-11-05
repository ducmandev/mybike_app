import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Thông tin tiến độ tải bản đồ offline
class DownloadProgress {
  final int current;
  final int total;
  final int bytes;
  final bool isRunning;
  final bool isPaused;
  final bool isCompleted;
  final String? regionName;
  final String? error;

  const DownloadProgress({
    this.current = 0,
    this.total = 0,
    this.bytes = 0,
    this.isRunning = false,
    this.isPaused = false,
    this.isCompleted = false,
    this.regionName,
    this.error,
  });

  double get percent => total > 0 ? (current / total).clamp(0.0, 1.0) : 0.0;
  int get percentInt => (percent * 100).round();
  String get sizeMbText => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Khu vực định nghĩa sẵn để tải offline
class OfflineRegionPreset {
  final String id;
  final String name;
  final String description;
  final IconData icon;
  final LatLngBounds bounds;

  const OfflineRegionPreset({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
    required this.bounds,
  });
}

/// Dịch vụ quản lý tải và lưu trữ bản đồ offline cho Dat Bike App
class OfflineMapService {
  OfflineMapService._();
  static final OfflineMapService instance = OfflineMapService._();

  static const String _kSchemaKey = 'offline_tile_cache_schema';
  static const int _kCurrentSchema = 2;

  Directory? _cacheDir;
  static Directory? _globalCachedDir;
  static Completer<Directory>? _dirCompleter;
  bool _isDownloading = false;
  bool _cancelRequested = false;
  bool _pauseRequested = false;

  /// Bộ phát tiến độ tải bản đồ toàn cục cho toàn bộ ứng dụng lắng nghe
  final ValueNotifier<DownloadProgress> progressNotifier =
      ValueNotifier<DownloadProgress>(const DownloadProgress());

  bool get isDownloading => _isDownloading;

  /// Tạo khóa nhận diện nguồn gạch bản đồ ổn định từ URL template
  /// Giúp phân vùng độc lập các nguồn tile và phong cách bản đồ khác nhau
  static String generateSourceKey(String urlTemplate) {
    if (urlTemplate.trim().isEmpty) return 'default';
    var clean = urlTemplate.replaceFirst(RegExp(r'^https?://'), '');
    clean = clean.replaceAll(RegExp(r'\{s\}[\.-]?'), '');
    clean = clean.replaceAll(RegExp(r'/\{z\}/\{x\}/\{y\}.*$'), '');
    clean = clean
        .replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '')
        .toLowerCase();
    if (clean.isEmpty) clean = 'tile_source';

    var hash = 5381;
    for (final code in urlTemplate.codeUnits) {
      hash = ((hash << 5) + hash) + code;
      hash = hash & 0xFFFFFFFF;
    }
    final hexHash = hash.toRadixString(16).padLeft(8, '0').substring(0, 6);
    return '${clean}_$hexHash';
  }

  /// Kiểm tra tính hợp lệ của dữ liệu ảnh gạch bản đồ thông qua Magic Bytes
  /// Chấp nhận: PNG (89 50 4E 47), JPEG (FF D8 FF), WebP (RIFF .... WEBP)
  static bool isValidTileImageBytes(Uint8List? bytes) {
    if (bytes == null || bytes.length < 8) return false;

    // 1. PNG: 0x89, 0x50, 0x4E, 0x47
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return true;
    }

    // 2. JPEG: 0xFF, 0xD8, 0xFF
    if (bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return true;
    }

    // 3. WebP: 'RIFF' + 4 bytes + 'WEBP'
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 && // R
        bytes[1] == 0x49 && // I
        bytes[2] == 0x46 && // F
        bytes[3] == 0x46 && // F
        bytes[8] == 0x57 && // W
        bytes[9] == 0x45 && // E
        bytes[10] == 0x42 && // B
        bytes[11] == 0x50) { // P
      return true;
    }

    return false;
  }

  @visibleForTesting
  static void resetCacheDirForTesting([Directory? dir]) {
    _globalCachedDir = dir;
    _dirCompleter = null;
    instance._cacheDir = dir;
  }

  /// Lấy thư mục lưu trữ tile offline trên bộ nhớ thiết bị
  Future<Directory> getCacheDirectory() async {
    if (_cacheDir != null) return _cacheDir!;
    if (_globalCachedDir != null) {
      _cacheDir = _globalCachedDir;
      return _globalCachedDir!;
    }
    if (_dirCompleter != null) return _dirCompleter!.future;

    _dirCompleter = Completer<Directory>();
    try {
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}/offline_map_tiles');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      _globalCachedDir = dir;
      _cacheDir = dir;

      // Kích hoạt migration schema nền an toàn để xóa sạch file cache legacy dính Carto ở root
      unawaited(migrateCacheSchemaIfNeeded(targetDir: dir));

      _dirCompleter!.complete(dir);
      return dir;
    } catch (e) {
      _dirCompleter!.completeError(e);
      _dirCompleter = null;
      rethrow;
    }
  }

  /// Tự động di chuyển schema và xóa sạch các file cache legacy ở thư mục gốc
  Future<void> migrateCacheSchemaIfNeeded({
    Directory? targetDir,
    SharedPreferences? prefs,
  }) async {
    try {
      final sp = prefs ?? await SharedPreferences.getInstance();
      final current = sp.getInt(_kSchemaKey) ?? 0;
      if (current >= _kCurrentSchema) return;

      final dir = targetDir ?? await getCacheDirectory();
      if (await dir.exists()) {
        final entities = dir.listSync(followLinks: false);
        for (final entity in entities) {
          final baseName = entity.path.split(Platform.pathSeparator).last;
          if (baseName == 'v2') continue;
          try {
            if (entity is File) {
              entity.deleteSync();
            } else if (entity is Directory) {
              entity.deleteSync(recursive: true);
            }
          } catch (_) {}
        }
      }
      await sp.setInt(_kSchemaKey, _kCurrentSchema);
    } catch (_) {}
  }

  /// Đường dẫn file tile local phân vùng theo nguồn: v2/{sourceKey}/{z}_{x}_{y}.png
  Future<File> getTileFile(int z, int x, int y, {required String sourceKey}) async {
    final dir = await getCacheDirectory();
    final safeKey = sourceKey.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    return File('${dir.path}/v2/$safeKey/${z}_${x}_$y.png');
  }

  /// Kiểm tra xem 1 tile đã được tải về máy chưa theo nguồn tương ứng
  Future<bool> hasTile(int z, int x, int y, {required String sourceKey}) async {
    final file = await getTileFile(z, x, y, sourceKey: sourceKey);
    return file.exists();
  }

  /// Lấy thống kê dung lượng cache offline hiện tại (quét đệ quy toàn bộ thư mục v2)
  Future<({int tileCount, int totalBytes, String sizeText})> getCacheStats() async {
    try {
      final dir = await getCacheDirectory();
      int count = 0;
      int bytes = 0;
      if (await dir.exists()) {
        final entities = dir.listSync(recursive: true, followLinks: false);
        for (final entity in entities) {
          if (entity is File) {
            final p = entity.path.toLowerCase();
            if (p.endsWith('.png') || p.endsWith('.jpg') || p.endsWith('.jpeg') || p.endsWith('.webp')) {
              count++;
              bytes += entity.lengthSync();
            }
          }
        }
      }
      final mb = (bytes / (1024 * 1024)).toStringAsFixed(1);
      return (tileCount: count, totalBytes: bytes, sizeText: '$mb MB');
    } catch (_) {
      return (tileCount: 0, totalBytes: 0, sizeText: '0.0 MB');
    }
  }

  /// Xóa toàn bộ dữ liệu bản đồ offline đã tải (xóa đệ quy toàn bộ thư mục con)
  Future<void> clearCache() async {
    try {
      final dir = await getCacheDirectory();
      if (await dir.exists()) {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
      await dir.create(recursive: true);
    } catch (_) {}
  }

  /// Chuyển đổi Kinh/Vĩ độ sang Tọa độ Tile x, y
  static int lon2tileX(double lon, int z) {
    return ((lon + 180.0) / 360.0 * (1 << z)).floor();
  }

  static int lat2tileY(double lat, int z) {
    final rad = lat * math.pi / 180.0;
    return ((1.0 - math.log(math.tan(rad) + 1.0 / math.cos(rad)) / math.pi) / 2.0 * (1 << z)).floor();
  }

  /// Danh sách các khu vực thành phố lớn định nghĩa sẵn
  static List<OfflineRegionPreset> getPresets() {
    return [
      OfflineRegionPreset(
        id: 'hcm',
        name: 'TP. Hồ Chí Minh & Bình Dương',
        description: 'Trung tâm Quận 1-12, Thủ Đức, Thuận An',
        icon: Icons.location_city_rounded,
        bounds: LatLngBounds(
          const LatLng(10.68, 106.58),
          const LatLng(10.92, 106.85),
        ),
      ),
      OfflineRegionPreset(
        id: 'hanoi',
        name: 'Hà Nội & Vùng Thủ Đô',
        description: 'Hoàn Kiếm, Cầu Giấy, Tây Hồ, Thanh Xuân',
        icon: Icons.account_balance_rounded,
        bounds: LatLngBounds(
          const LatLng(20.95, 105.73),
          const LatLng(21.10, 105.93),
        ),
      ),
      OfflineRegionPreset(
        id: 'danang',
        name: 'Đà Nẵng & Hội An',
        description: 'Sơn Trà, Hải Châu, Ngũ Hành Sơn, Phố cổ',
        icon: Icons.beach_access_rounded,
        bounds: LatLngBounds(
          const LatLng(15.92, 108.15),
          const LatLng(16.12, 108.32),
        ),
      ),
    ];
  }

  /// Tạo Bounding Box quanh tọa độ bất kỳ với bán kính km
  static LatLngBounds createRadiusBounds(LatLng center, double radiusKm) {
    const latKm = 111.0;
    final deltaLat = radiusKm / latKm;
    final deltaLng = radiusKm / (latKm * math.cos(center.latitude * math.pi / 180.0));
    return LatLngBounds(
      LatLng(center.latitude - deltaLat, center.longitude - deltaLng),
      LatLng(center.latitude + deltaLat, center.longitude + deltaLng),
    );
  }

  /// Tính toán danh sách các tile cần tải cho một vùng bounds và khoảng zoom
  List<({int z, int x, int y})> calculateTileList({
    required LatLngBounds bounds,
    required int minZoom,
    required int maxZoom,
  }) {
    final list = <({int z, int x, int y})>[];
    for (int z = minZoom; z <= maxZoom; z++) {
      final minX = lon2tileX(bounds.west, z);
      final maxX = lon2tileX(bounds.east, z);
      final minY = lat2tileY(bounds.north, z);
      final maxY = lat2tileY(bounds.south, z);

      final startX = math.min(minX, maxX);
      final endX = math.max(minX, maxX);
      final startY = math.min(minY, maxY);
      final endY = math.max(minY, maxY);

      for (int x = startX; x <= endX; x++) {
        for (int y = startY; y <= endY; y++) {
          list.add((z: z, x: x, y: y));
        }
      }
    }
    return list;
  }

  /// Hủy quá trình tải đang chạy
  Future<void> cancelDownload() async {
    _cancelRequested = true;
    _pauseRequested = false;
    await clearPendingTask();
    progressNotifier.value = const DownloadProgress(
      isRunning: false,
      isPaused: false,
      isCompleted: false,
    );
  }

  /// Tạm dừng quá trình tải (lưu lại trạng thái để Resume bất cứ lúc nào)
  void pauseDownload() {
    _pauseRequested = true;
  }

  Future<File> _getTaskFile() async {
    final dir = await getCacheDirectory();
    final v2Dir = Directory('${dir.path}/v2');
    if (!await v2Dir.exists()) {
      await v2Dir.create(recursive: true);
    }
    return File('${v2Dir.path}/download_task.json');
  }

  Future<void> _saveTaskState({
    required LatLngBounds bounds,
    required int minZoom,
    required int maxZoom,
    required String regionName,
    required int totalTiles,
  }) async {
    try {
      final file = await _getTaskFile();
      final map = {
        'regionName': regionName,
        'minZoom': minZoom,
        'maxZoom': maxZoom,
        'north': bounds.north,
        'south': bounds.south,
        'east': bounds.east,
        'west': bounds.west,
        'totalTiles': totalTiles,
        'updatedAt': DateTime.now().toIso8601String(),
      };
      await file.writeAsString(jsonEncode(map));
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> getPendingTask() async {
    try {
      final file = await _getTaskFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        return jsonDecode(content) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  Future<void> clearPendingTask() async {
    try {
      final file = await _getTaskFile();
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  /// Tiếp tục tải tác vụ còn dở dang
  Future<void> resumeDownload({
    void Function(DownloadProgress progress)? onProgress,
  }) async {
    final task = await getPendingTask();
    if (task == null) return;

    final bounds = LatLngBounds(
      LatLng((task['south'] as num).toDouble(), (task['west'] as num).toDouble()),
      LatLng((task['north'] as num).toDouble(), (task['east'] as num).toDouble()),
    );
    final minZoom = (task['minZoom'] as num).toInt();
    final maxZoom = (task['maxZoom'] as num).toInt();
    final regionName = (task['regionName'] as String?) ?? 'Bản đồ';

    await downloadRegion(
      bounds: bounds,
      minZoom: minZoom,
      maxZoom: maxZoom,
      regionName: regionName,
      onProgress: onProgress,
    );
  }

  /// Bắt đầu tải hàng loạt (Bulk Download) các gạch bản đồ về máy
  Future<void> downloadRegion({
    required LatLngBounds bounds,
    required int minZoom,
    required int maxZoom,
    String regionName = 'Bản đồ offline',
    String urlTemplate = 'https://{s}.tile.openstreetmap.fr/osmfr/{z}/{x}/{y}.png',
    List<String> subdomains = const ['a', 'b', 'c'],
    void Function(DownloadProgress progress)? onProgress,
  }) async {
    if (_isDownloading) return;
    _isDownloading = true;
    _cancelRequested = false;
    _pauseRequested = false;

    final tiles = calculateTileList(bounds: bounds, minZoom: minZoom, maxZoom: maxZoom);
    final total = tiles.length;
    int current = 0;
    int totalBytes = 0;

    await _saveTaskState(
      bounds: bounds,
      minZoom: minZoom,
      maxZoom: maxZoom,
      regionName: regionName,
      totalTiles: total,
    );

    void notify(DownloadProgress p) {
      progressNotifier.value = p;
      onProgress?.call(p);
    }

    notify(DownloadProgress(
      current: 0,
      total: total,
      bytes: 0,
      isRunning: true,
      regionName: regionName,
    ));

    final subLen = subdomains.length;
    int subIndex = 0;
    final sourceKey = generateSourceKey(urlTemplate);

    // Chạy đồng thời 4 kết nối song song để tải nhanh
    const concurrency = 4;
    int index = 0;

    Future<void> worker() async {
      while (index < tiles.length && !_cancelRequested && !_pauseRequested) {
        final curIndex = index++;
        final tile = tiles[curIndex];

        final file = await getTileFile(tile.z, tile.x, tile.y, sourceKey: sourceKey);
        if (await file.exists()) {
          final len = await file.length();
          if (len > 0) {
            current++;
            totalBytes += len;
            notify(DownloadProgress(
              current: current,
              total: total,
              bytes: totalBytes,
              isRunning: true,
              regionName: regionName,
            ));
            continue;
          }
        }

        final sub = subdomains[subIndex++ % subLen];
        final url = urlTemplate
            .replaceAll('{s}', sub)
            .replaceAll('{z}', '${tile.z}')
            .replaceAll('{x}', '${tile.x}')
            .replaceAll('{y}', '${tile.y}');

        try {
          final res = await http.get(
            Uri.parse(url),
            headers: {'User-Agent': 'DatBikeApp/2.6.29 (offline-cache)'},
          ).timeout(const Duration(seconds: 8));

          final contentType = res.headers['content-type']?.toLowerCase() ?? '';
          final isImageHeader = contentType.startsWith('image/') || contentType.isEmpty;

          if (res.statusCode == 200 &&
              isImageHeader &&
              isValidTileImageBytes(res.bodyBytes)) {
            await file.parent.create(recursive: true);
            await file.writeAsBytes(res.bodyBytes);
            totalBytes += res.bodyBytes.length;
          }
        } catch (_) {}

        current++;
        notify(DownloadProgress(
          current: current,
          total: total,
          bytes: totalBytes,
          isRunning: true,
          regionName: regionName,
        ));
      }
    }

    final workers = List.generate(concurrency, (_) => worker());
    await Future.wait(workers);

    _isDownloading = false;

    if (_cancelRequested) {
      await clearPendingTask();
      notify(DownloadProgress(
        current: current,
        total: total,
        bytes: totalBytes,
        isRunning: false,
        isPaused: false,
        isCompleted: false,
        regionName: regionName,
      ));
    } else if (_pauseRequested) {
      notify(DownloadProgress(
        current: current,
        total: total,
        bytes: totalBytes,
        isRunning: false,
        isPaused: true,
        isCompleted: false,
        regionName: regionName,
      ));
    } else {
      await clearPendingTask();
      notify(DownloadProgress(
        current: current,
        total: total,
        bytes: totalBytes,
        isRunning: false,
        isPaused: false,
        isCompleted: true,
        regionName: regionName,
      ));
    }
  }
}

/// TileProvider kết hợp Bộ nhớ đệm Offline Disk Cache
/// Ưu tiên nạp từ ổ cứng local trước (0ms latency, 100% offline).
/// Nếu chưa có trong máy thì tải từ mạng và tự động lưu vào ổ cứng cho lần xem tiếp theo.
class OfflineCacheTileProvider extends TileProvider {
  OfflineCacheTileProvider({super.headers});

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    final url = getTileUrl(coordinates, options);
    final sourceKey = OfflineMapService.generateSourceKey(options.urlTemplate ?? '');
    return OfflineTileImageProvider(
      coordinates: coordinates,
      options: options,
      url: url,
      sourceKey: sourceKey,
      headers: headers,
    );
  }
}

class OfflineTileImageProvider extends ImageProvider<OfflineTileImageProvider> {
  final TileCoordinates coordinates;
  final TileLayer options;
  final String url;
  final String sourceKey;
  final Map<String, String>? headers;

  const OfflineTileImageProvider({
    required this.coordinates,
    required this.options,
    required this.url,
    required this.sourceKey,
    this.headers,
  });

  @override
  Future<OfflineTileImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<OfflineTileImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(OfflineTileImageProvider key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: 1.0,
      informationCollector: () => [
        DiagnosticsProperty<String>('URL', url),
        DiagnosticsProperty<TileCoordinates>('Coordinates', coordinates),
        DiagnosticsProperty<String>('SourceKey', sourceKey),
      ],
    );
  }

  Future<ui.Codec> _loadAsync(OfflineTileImageProvider key, ImageDecoderCallback decode) async {
    // 1. Kiểm tra trong ổ cứng local trước theo phân vùng sourceKey
    final file = await OfflineMapService.instance.getTileFile(
      coordinates.z,
      coordinates.x,
      coordinates.y,
      sourceKey: sourceKey,
    );

    if (await file.exists()) {
      try {
        final bytes = await file.readAsBytes();
        if (OfflineMapService.isValidTileImageBytes(bytes)) {
          final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
          return await decode(buffer);
        } else {
          // Xóa file rác hoặc file lỗi không phải ảnh hợp lệ
          unawaited(file.delete().catchError((_) => file));
        }
      } catch (_) {}
    }

    // 2. Nếu chưa có trên máy, tải từ mạng và chỉ cache khi ảnh hợp lệ
    try {
      final uri = Uri.parse(url);
      final response = await http.get(uri, headers: headers).timeout(const Duration(seconds: 4));
      final contentType = response.headers['content-type']?.toLowerCase() ?? '';
      final isImageHeader = contentType.startsWith('image/') || contentType.isEmpty;

      if (response.statusCode == 200 &&
          isImageHeader &&
          OfflineMapService.isValidTileImageBytes(response.bodyBytes)) {
        // Ghi nền bất đồng bộ an toàn vào ổ cứng để không làm giật UI
        unawaited(
          file.parent.exists().then((exists) async {
            if (!exists) {
              await file.parent.create(recursive: true);
            }
            await file.writeAsBytes(response.bodyBytes);
          }).catchError((_) {}),
        );

        final buffer = await ui.ImmutableBuffer.fromUint8List(response.bodyBytes);
        return await decode(buffer);
      }
    } catch (_) {}

    // 3. Fallback pixel trong suốt khi offline hoàn toàn và tile chưa tải
    final transparentPng = Uint8List.fromList([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
      0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
      0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
      0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
      0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
      0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ]);
    final buffer = await ui.ImmutableBuffer.fromUint8List(transparentPng);
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    return other is OfflineTileImageProvider &&
        other.coordinates == coordinates &&
        other.url == url &&
        other.sourceKey == sourceKey;
  }

  @override
  int get hashCode => Object.hash(coordinates, url, sourceKey);
}
