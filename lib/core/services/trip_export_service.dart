import 'dart:io';
import 'dart:math' show max;

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../ble/ble_controller.dart' show TripRecord;
import '../models/merged_trip_session.dart';
import '../models/trip_gps_point.dart';

/// Các định dạng tệp hỗ trợ khi xuất dữ liệu hành trình.
enum TripExportFormat { gpx, csv, kml }

/// Tiện ích escape ký tự đặc biệt XML dùng chung cho GPX và KML.
abstract final class XmlEscape {
  static String escape(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }
}

/// Giao diện chiến lược (Strategy) chuyển đổi [MergedTripSession] sang từng định dạng tệp xuất.
abstract class TripFormatSerializer {
  const TripFormatSerializer();

  TripExportFormat get format;
  String get extension;
  String get mimeType;
  String serialize(MergedTripSession session);
}

/// Bộ tuần tự hóa GPX 1.1 cho [MergedTripSession].
class GpxTripSerializer extends TripFormatSerializer {
  const GpxTripSerializer();

  @override
  TripExportFormat get format => TripExportFormat.gpx;

  @override
  String get extension => 'gpx';

  @override
  String get mimeType => 'application/gpx+xml';

  @override
  String serialize(MergedTripSession session) {
    final buf = StringBuffer();
    final escapedTitle = XmlEscape.escape(session.title);
    final metadataTime = session.startTime.toUtc().toIso8601String();

    buf.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buf.writeln(
      '<gpx version="1.1" creator="Dat Bike Companion" '
      'xmlns="http://www.topografix.com/GPX/1/1" '
      'xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">',
    );
    buf.writeln('  <metadata>');
    buf.writeln('    <name>$escapedTitle</name>');
    buf.writeln('    <time>$metadataTime</time>');
    buf.writeln('  </metadata>');
    buf.writeln('  <trk>');
    buf.writeln('    <name>$escapedTitle</name>');

    for (final segment in session.segments) {
      if (segment.points.isEmpty) continue;
      buf.writeln('    <trkseg>');
      for (final pt in segment.points) {
        final lat = pt.lat.toStringAsFixed(6);
        final lon = pt.lng.toStringAsFixed(6);
        final timeIso = pt.timestamp.toUtc().toIso8601String();
        final speedMs = (max(0.0, pt.speedKmh) / 3.6).toStringAsFixed(3);

        buf.writeln('      <trkpt lat="$lat" lon="$lon">');
        if (pt.altitude != null) {
          buf.writeln('        <ele>${pt.altitude!.toStringAsFixed(1)}</ele>');
        }
        buf.writeln('        <time>$timeIso</time>');
        buf.writeln('        <extensions>');
        buf.writeln('          <gpxtpx:TrackPointExtension>');
        buf.writeln('            <gpxtpx:speed>$speedMs</gpxtpx:speed>');
        buf.writeln('          </gpxtpx:TrackPointExtension>');
        buf.writeln('        </extensions>');
        buf.writeln('      </trkpt>');
      }
      buf.writeln('    </trkseg>');
    }

    buf.writeln('  </trk>');
    buf.write('</gpx>');
    return buf.toString();
  }
}

/// Bộ tuần tự hóa CSV theo thứ tự thời gian cho [MergedTripSession].
class CsvTripSerializer extends TripFormatSerializer {
  const CsvTripSerializer();

  @override
  TripExportFormat get format => TripExportFormat.csv;

  @override
  String get extension => 'csv';

  @override
  String get mimeType => 'text/csv';

  @override
  String serialize(MergedTripSession session) {
    final lines = <String>[
      'timestamp_iso,elapsed_sec,segment,lat,lng,speed_kmh,heading,altitude,cumulative_km',
    ];
    final sessionStart = session.startTime;

    for (final segment in session.segments) {
      if (segment.points.isEmpty) continue;
      final pointCount = segment.points.length;

      for (var i = 0; i < pointCount; i++) {
        final pt = segment.points[i];
        final timestampIso = pt.timestamp.toUtc().toIso8601String();
        final elapsedSec = max(0, pt.timestamp.difference(sessionStart).inSeconds);
        final lat = pt.lat.toStringAsFixed(6);
        final lng = pt.lng.toStringAsFixed(6);
        final speedKmh = pt.speedKmh.toStringAsFixed(2);
        final heading = pt.heading != null ? pt.heading!.toStringAsFixed(1) : '';
        final altitude =
            pt.altitude != null ? pt.altitude!.toStringAsFixed(1) : '';

        final double cumulativeKm;
        if (segment.hasPoints) {
          cumulativeKm = session.cumulativeDistanceAtPointIndex(
            segment.startPointIndex + i,
          );
        } else if (pointCount <= 1) {
          cumulativeKm = segment.cumulativeEndKm;
        } else {
          final fraction = i / (pointCount - 1);
          cumulativeKm =
              segment.cumulativeStartKm +
              (segment.cumulativeEndKm - segment.cumulativeStartKm) * fraction;
        }

        lines.add(
          '$timestampIso,$elapsedSec,${segment.displayOrder},'
          '$lat,$lng,$speedKmh,$heading,$altitude,${cumulativeKm.toStringAsFixed(3)}',
        );
      }
    }

    return lines.join('\n');
  }
}

/// Bộ tuần tự hóa KML 2.2 cho [MergedTripSession].
class KmlTripSerializer extends TripFormatSerializer {
  const KmlTripSerializer();

  @override
  TripExportFormat get format => TripExportFormat.kml;

  @override
  String get extension => 'kml';

  @override
  String get mimeType => 'application/vnd.google-earth.kml+xml';

  @override
  String serialize(MergedTripSession session) {
    final buf = StringBuffer();
    final escapedTitle = XmlEscape.escape(session.title);
    final summaryDesc = XmlEscape.escape(
      '${session.segmentCount} chặng · '
      '${session.totalDistanceKm.toStringAsFixed(2)} km · '
      'CO2 tiết kiệm ${session.totalCo2SavedKg.toStringAsFixed(2)} kg',
    );

    buf.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buf.writeln('<kml xmlns="http://www.opengis.net/kml/2.2">');
    buf.writeln('  <Document>');
    buf.writeln('    <name>$escapedTitle</name>');
    buf.writeln('    <description>$summaryDesc</description>');

    buf.writeln('    <Style id="routeLineStyle">');
    buf.writeln('      <LineStyle>');
    buf.writeln('        <color>ffeb6325</color>');
    buf.writeln('        <width>4</width>');
    buf.writeln('      </LineStyle>');
    buf.writeln('    </Style>');

    buf.writeln('    <Style id="startPinStyle">');
    buf.writeln('      <IconStyle>');
    buf.writeln('        <color>ff81b910</color>');
    buf.writeln('        <scale>1.1</scale>');
    buf.writeln('      </IconStyle>');
    buf.writeln('    </Style>');

    buf.writeln('    <Style id="endPinStyle">');
    buf.writeln('      <IconStyle>');
    buf.writeln('        <color>ff481de1</color>');
    buf.writeln('        <scale>1.1</scale>');
    buf.writeln('      </IconStyle>');
    buf.writeln('    </Style>');

    buf.writeln('    <Style id="stopoverPinStyle">');
    buf.writeln('      <IconStyle>');
    buf.writeln('        <color>ff0b9ef5</color>');
    buf.writeln('        <scale>1.0</scale>');
    buf.writeln('      </IconStyle>');
    buf.writeln('    </Style>');

    for (final segment in session.segments) {
      if (segment.points.isEmpty) continue;
      final segName = XmlEscape.escape('Chặng ${segment.displayOrder}');
      final segDesc = XmlEscape.escape(
        '${segment.trip.distanceKm.toStringAsFixed(2)} km · '
        'Tốc độ tối đa ${segment.trip.maxSpeedKmh.toStringAsFixed(1)} km/h',
      );
      final coords = segment.points.map(_kmlCoord).join(' ');

      buf.writeln('    <Placemark>');
      buf.writeln('      <name>$segName</name>');
      buf.writeln('      <description>$segDesc</description>');
      buf.writeln('      <styleUrl>#routeLineStyle</styleUrl>');
      buf.writeln('      <LineString>');
      buf.writeln('        <tessellate>1</tessellate>');
      buf.writeln('        <coordinates>$coords</coordinates>');
      buf.writeln('      </LineString>');
      buf.writeln('    </Placemark>');
    }

    if (session.allPoints.isNotEmpty) {
      final first = session.allPoints.first;
      final last = session.allPoints.last;

      buf.writeln('    <Placemark>');
      buf.writeln('      <name>Điểm xuất phát</name>');
      buf.writeln(
        '      <description>${XmlEscape.escape(first.timestamp.toUtc().toIso8601String())}</description>',
      );
      buf.writeln('      <styleUrl>#startPinStyle</styleUrl>');
      buf.writeln('      <Point>');
      buf.writeln('        <coordinates>${_kmlCoord(first)}</coordinates>');
      buf.writeln('      </Point>');
      buf.writeln('    </Placemark>');

      buf.writeln('    <Placemark>');
      buf.writeln('      <name>Điểm kết thúc</name>');
      buf.writeln(
        '      <description>${XmlEscape.escape(last.timestamp.toUtc().toIso8601String())}</description>',
      );
      buf.writeln('      <styleUrl>#endPinStyle</styleUrl>');
      buf.writeln('      <Point>');
      buf.writeln('        <coordinates>${_kmlCoord(last)}</coordinates>');
      buf.writeln('      </Point>');
      buf.writeln('    </Placemark>');
    }

    for (final stop in session.stopovers) {
      final stopName = XmlEscape.escape(stop.label);
      final stopDesc = XmlEscape.escape(
        'Điểm dừng ${stop.label} · ${stop.formattedDuration}',
      );
      buf.writeln('    <Placemark>');
      buf.writeln('      <name>$stopName</name>');
      buf.writeln('      <description>$stopDesc</description>');
      buf.writeln('      <styleUrl>#stopoverPinStyle</styleUrl>');
      buf.writeln('      <Point>');
      buf.writeln('        <coordinates>${_kmlCoord(stop.location)}</coordinates>');
      buf.writeln('      </Point>');
      buf.writeln('    </Placemark>');
    }

    buf.writeln('  </Document>');
    buf.write('</kml>');
    return buf.toString();
  }

  static String _kmlCoord(TripGpsPoint pt) {
    final lng = pt.lng.toStringAsFixed(6);
    final lat = pt.lat.toStringAsFixed(6);
    if (pt.altitude != null) {
      return '$lng,$lat,${pt.altitude!.toStringAsFixed(1)}';
    }
    return '$lng,$lat';
  }
}

/// Dịch vụ xuất và chia sẻ hành trình (đơn lẻ hoặc đã ghép đa chặng) sang GPX, CSV, KML.
class TripExportService {
  TripExportService._();

  static final TripExportService instance = TripExportService._();

  static final Map<TripExportFormat, TripFormatSerializer> _serializers = {
    TripExportFormat.gpx: const GpxTripSerializer(),
    TripExportFormat.csv: const CsvTripSerializer(),
    TripExportFormat.kml: const KmlTripSerializer(),
  };

  TripFormatSerializer _serializerFor(TripExportFormat format) =>
      _serializers[format]!;

  /// Tạo [MergedTripSession] từ một chuyến đi đơn lẻ để dùng chung luồng xuất/chia sẻ.
  MergedTripSession sessionFromSingleTrip(
    TripRecord trip,
    List<TripGpsPoint> route, {
    int? tripNumber,
  }) {
    final effectiveRoute = route.isNotEmpty ? route : trip.route;
    return MergedTripSession.fromTrips(
      trips: [trip],
      routesByTripId: {trip.id: effectiveRoute},
      mode: TripMergeMode.single,
      customTitle: tripNumber != null ? 'Hành trình #$tripNumber' : null,
    );
  }

  /// Tạo nội dung GPX 1.1 hợp lệ, tách riêng từng `<trkseg>` cho mỗi chặng có điểm GPS.
  String buildGpx(MergedTripSession session) =>
      _serializerFor(TripExportFormat.gpx).serialize(session);

  /// Tạo nội dung CSV theo thứ tự thời gian của toàn bộ điểm GPS qua các chặng.
  String buildCsv(MergedTripSession session) =>
      _serializerFor(TripExportFormat.csv).serialize(session);

  /// Tạo nội dung KML 2.2 gồm từng chặng `<LineString>`, điểm đầu/cuối và điểm dừng `P1..Pn`.
  String buildKml(MergedTripSession session) =>
      _serializerFor(TripExportFormat.kml).serialize(session);

  /// Tạo chuỗi nội dung tương ứng với [format].
  String buildContent(MergedTripSession session, TripExportFormat format) =>
      _serializerFor(format).serialize(session);

  /// Phần mở rộng tệp chuẩn cho từng [TripExportFormat].
  String fileExtension(TripExportFormat format) =>
      _serializerFor(format).extension;

  /// Ghi nội dung xuất hành trình ra tệp tạm trong thư mục cache của hệ thống.
  Future<File> writeTempExportFile(
    MergedTripSession session,
    TripExportFormat format,
  ) async {
    final tempDir = await getTemporaryDirectory();
    final safeBase = _sanitizeFileName(session.title);
    final ext = fileExtension(format);
    final stamp = session.startTime.millisecondsSinceEpoch;
    final fileName = '${safeBase}_$stamp.$ext';
    final file = File('${tempDir.path}${Platform.pathSeparator}$fileName');
    final content = buildContent(session, format);
    return file.writeAsString(content, flush: true);
  }

  /// Xuất ra tệp tạm và mở hộp thoại chia sẻ hệ thống qua `share_plus`.
  Future<void> shareSessionExport(
    MergedTripSession session,
    TripExportFormat format,
  ) async {
    final file = await writeTempExportFile(session, format);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: _serializerFor(format).mimeType)],
        subject: session.title,
        text:
            'Hành trình Dat Bike: ${session.title} '
            '(${session.totalDistanceKm.toStringAsFixed(1)} km)',
      ),
    );
  }

  static String _sanitizeFileName(String raw) {
    final normalized = _foldVietnameseAccents(raw.trim());
    final cleaned = normalized
        .replaceAll(RegExp(r'[^a-zA-Z0-9_-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (cleaned.isEmpty) {
      return 'datbike_trip';
    }
    return cleaned.length > 64 ? cleaned.substring(0, 64) : cleaned;
  }

  static String _foldVietnameseAccents(String input) {
    const replacements = <String, String>{
      'à': 'a', 'á': 'a', 'ả': 'a', 'ã': 'a', 'ạ': 'a',
      'ă': 'a', 'ằ': 'a', 'ắ': 'a', 'ẳ': 'a', 'ẵ': 'a', 'ặ': 'a',
      'â': 'a', 'ầ': 'a', 'ấ': 'a', 'ẩ': 'a', 'ẫ': 'a', 'ậ': 'a',
      'À': 'A', 'Á': 'A', 'Ả': 'A', 'Ã': 'A', 'Ạ': 'A',
      'Ă': 'A', 'Ằ': 'A', 'Ắ': 'A', 'Ẳ': 'A', 'Ẵ': 'A', 'Ặ': 'A',
      'Â': 'A', 'Ầ': 'A', 'Ấ': 'A', 'Ẩ': 'A', 'Ẫ': 'A', 'Ậ': 'A',
      'đ': 'd', 'Đ': 'D',
      'è': 'e', 'é': 'e', 'ẻ': 'e', 'ẽ': 'e', 'ẹ': 'e',
      'ê': 'e', 'ề': 'e', 'ế': 'e', 'ể': 'e', 'ễ': 'e', 'ệ': 'e',
      'È': 'E', 'É': 'E', 'Ẻ': 'E', 'Ẽ': 'E', 'Ẹ': 'E',
      'Ê': 'E', 'Ề': 'E', 'Ế': 'E', 'Ể': 'E', 'Ễ': 'E', 'Ệ': 'E',
      'ì': 'i', 'í': 'i', 'ỉ': 'i', 'ĩ': 'i', 'ị': 'i',
      'Ì': 'I', 'Í': 'I', 'Ỉ': 'I', 'Ĩ': 'I', 'Ị': 'I',
      'ò': 'o', 'ó': 'o', 'ỏ': 'o', 'õ': 'o', 'ọ': 'o',
      'ô': 'o', 'ồ': 'o', 'ố': 'o', 'ổ': 'o', 'ỗ': 'o', 'ộ': 'o',
      'ơ': 'o', 'ờ': 'o', 'ớ': 'o', 'ở': 'o', 'ỡ': 'o', 'ợ': 'o',
      'Ò': 'O', 'Ó': 'O', 'Ỏ': 'O', 'Õ': 'O', 'Ọ': 'O',
      'Ô': 'O', 'Ồ': 'O', 'Ố': 'O', 'Ổ': 'O', 'Ỗ': 'O', 'Ộ': 'O',
      'Ơ': 'O', 'Ờ': 'O', 'Ớ': 'O', 'Ở': 'O', 'Ỡ': 'O', 'Ợ': 'O',
      'ù': 'u', 'ú': 'u', 'ủ': 'u', 'ũ': 'u', 'ụ': 'u',
      'ư': 'u', 'ừ': 'u', 'ứ': 'u', 'ử': 'u', 'ữ': 'u', 'ự': 'u',
      'Ù': 'U', 'Ú': 'U', 'Ủ': 'U', 'Ũ': 'U', 'Ụ': 'U',
      'Ư': 'U', 'Ừ': 'U', 'Ứ': 'U', 'Ử': 'U', 'Ữ': 'U', 'Ự': 'U',
      'ỳ': 'y', 'ý': 'y', 'ỷ': 'y', 'ỹ': 'y', 'ỵ': 'y',
      'Ỳ': 'Y', 'Ý': 'Y', 'Ỷ': 'Y', 'Ỹ': 'Y', 'Ỵ': 'Y',
    };
    final buf = StringBuffer();
    for (final rune in input.runes) {
      final ch = String.fromCharCode(rune);
      buf.write(replacements[ch] ?? ch);
    }
    return buf.toString();
  }
}
