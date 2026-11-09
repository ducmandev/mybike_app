import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

/// Kết quả tìm kiếm địa điểm / điểm đến
class NavSearchResult {
  final String displayName;
  final String shortName;
  final double lat;
  final double lng;
  final String category; // 'landmark', 'charging_station', 'place', 'custom'

  const NavSearchResult({
    required this.displayName,
    required this.shortName,
    required this.lat,
    required this.lng,
    required this.category,
  });

  LatLng get latLng => LatLng(lat, lng);

  Map<String, dynamic> toJson() => {
        'display_name': displayName,
        'short_name': shortName,
        'lat': lat,
        'lng': lng,
        'category': category,
      };

  factory NavSearchResult.fromJson(Map<String, dynamic> json) {
    return NavSearchResult(
      displayName: (json['display_name'] ?? json['displayName'] ?? '') as String,
      shortName: (json['short_name'] ?? json['shortName'] ?? '') as String,
      lat: ((json['lat'] ?? 0.0) as num).toDouble(),
      lng: ((json['lng'] ?? json['lon'] ?? 0.0) as num).toDouble(),
      category: (json['category'] ?? 'place') as String,
    );
  }

  NavSearchResult copyWith({
    String? displayName,
    String? shortName,
    double? lat,
    double? lng,
    String? category,
  }) {
    return NavSearchResult(
      displayName: displayName ?? this.displayName,
      shortName: shortName ?? this.shortName,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      category: category ?? this.category,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NavSearchResult &&
          runtimeType == other.runtimeType &&
          lat == other.lat &&
          lng == other.lng &&
          shortName == other.shortName;

  @override
  int get hashCode => Object.hash(lat, lng, shortName);
}

/// Loại thao tác di chuyển / ngã rẽ Turn-by-Turn
enum NavManeuverType {
  straight,
  turnLeft,
  turnRight,
  slightLeft,
  slightRight,
  uTurn,
  arrive;

  /// Helper parse từ chuỗi C-ABI / JSON
  static NavManeuverType fromString(String? val) {
    if (val == null) return NavManeuverType.straight;
    final clean = val.trim().toLowerCase();
    switch (clean) {
      case 'turn_left':
      case 'turnleft':
      case 'left':
        return NavManeuverType.turnLeft;
      case 'turn_right':
      case 'turnright':
      case 'right':
        return NavManeuverType.turnRight;
      case 'slight_left':
      case 'slightleft':
        return NavManeuverType.slightLeft;
      case 'slight_right':
      case 'slightright':
        return NavManeuverType.slightRight;
      case 'u_turn':
      case 'uturn':
        return NavManeuverType.uTurn;
      case 'arrive':
      case 'destination':
        return NavManeuverType.arrive;
      case 'straight':
      default:
        return NavManeuverType.straight;
    }
  }

  String get code {
    switch (this) {
      case NavManeuverType.turnLeft:
        return 'turn_left';
      case NavManeuverType.turnRight:
        return 'turn_right';
      case NavManeuverType.slightLeft:
        return 'slight_left';
      case NavManeuverType.slightRight:
        return 'slight_right';
      case NavManeuverType.uTurn:
        return 'u_turn';
      case NavManeuverType.arrive:
        return 'arrive';
      case NavManeuverType.straight:
        return 'straight';
    }
  }

  IconData get icon {
    switch (this) {
      case NavManeuverType.turnLeft:
        return Icons.turn_left_rounded;
      case NavManeuverType.turnRight:
        return Icons.turn_right_rounded;
      case NavManeuverType.slightLeft:
        return Icons.turn_slight_left_rounded;
      case NavManeuverType.slightRight:
        return Icons.turn_slight_right_rounded;
      case NavManeuverType.uTurn:
        return Icons.u_turn_left_rounded;
      case NavManeuverType.arrive:
        return Icons.place_rounded;
      case NavManeuverType.straight:
        return Icons.arrow_upward_rounded;
    }
  }

  String get vietnameseLabel {
    switch (this) {
      case NavManeuverType.turnLeft:
        return 'Rẽ trái';
      case NavManeuverType.turnRight:
        return 'Rẽ phải';
      case NavManeuverType.slightLeft:
        return 'Chếch sang trái';
      case NavManeuverType.slightRight:
        return 'Chếch sang phải';
      case NavManeuverType.uTurn:
        return 'Quay đầu xe';
      case NavManeuverType.arrive:
        return 'Đến đích';
      case NavManeuverType.straight:
        return 'Đi thẳng';
    }
  }
}

/// Một bước chỉ dẫn ngã rẽ trên lộ trình
class NavRouteStep {
  final String instruction;
  final String streetName;
  final NavManeuverType maneuver;
  final double distanceMeters;
  final double durationSeconds;
  final double lat;
  final double lng;

  const NavRouteStep({
    required this.instruction,
    required this.streetName,
    required this.maneuver,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.lat,
    required this.lng,
  });

  LatLng get latLng => LatLng(lat, lng);

  Map<String, dynamic> toJson() => {
        'instruction': instruction,
        'street_name': streetName,
        'maneuver': maneuver.code,
        'distance_meters': distanceMeters,
        'duration_seconds': durationSeconds,
        'lat': lat,
        'lng': lng,
      };

  factory NavRouteStep.fromJson(Map<String, dynamic> json) {
    return NavRouteStep(
      instruction: (json['instruction'] ?? '') as String,
      streetName: (json['street_name'] ?? json['streetName'] ?? '') as String,
      maneuver: NavManeuverType.fromString(json['maneuver'] as String?),
      distanceMeters: ((json['distance_m'] ?? json['distance_meters'] ?? json['distanceMeters'] ?? 0.0) as num).toDouble(),
      durationSeconds: ((json['duration_s'] ?? json['duration_seconds'] ?? json['durationSeconds'] ?? 0.0) as num).toDouble(),
      lat: ((json['lat'] ?? 0.0) as num).toDouble(),
      lng: ((json['lng'] ?? 0.0) as num).toDouble(),
    );
  }
}

/// Dự báo năng lượng và mức tiêu hao pin EV Dat Bike
class NavEvForecast {
  final double estimatedConsumptionWh;
  final double estimatedSocUsedPercent;
  final double arrivalSocPercent;
  final String status; // 'safe', 'warning', 'critical'
  final String? warningMessage;

  const NavEvForecast({
    required this.estimatedConsumptionWh,
    required this.estimatedSocUsedPercent,
    required this.arrivalSocPercent,
    required this.status,
    this.warningMessage,
  });

  bool get isSafe => status == 'safe';
  bool get isWarning => status == 'warning';
  bool get isCritical => status == 'critical';

  Map<String, dynamic> toJson() => {
        'estimated_consumption_wh': estimatedConsumptionWh,
        'estimated_soc_used_percent': estimatedSocUsedPercent,
        'arrival_soc_percent': arrivalSocPercent,
        'status': status,
        'warning_message': warningMessage,
      };

  factory NavEvForecast.fromJson(Map<String, dynamic> json) {
    return NavEvForecast(
      estimatedConsumptionWh:
          ((json['estimated_consumption_wh'] ?? json['estimatedConsumptionWh'] ?? 0.0) as num).toDouble(),
      estimatedSocUsedPercent:
          ((json['estimated_soc_used_percent'] ?? json['estimatedSocUsedPercent'] ?? 0.0) as num).toDouble(),
      arrivalSocPercent:
          ((json['arrival_soc_percent'] ?? json['arrivalSocPercent'] ?? 100.0) as num).toDouble(),
      status: (json['status'] ?? 'safe') as String,
      warningMessage: json['warning_message'] ?? json['warningMessage'],
    );
  }
}

/// Tuyến đường hoàn chỉnh được giải từ Engine Rust On-Device
class NavRouteResult {
  final double distanceMeters;
  final double durationSeconds;
  final List<LatLng> polyline;
  final List<NavRouteStep> steps;
  final NavEvForecast evForecast;
  final bool isEcoMode;

  const NavRouteResult({
    required this.distanceMeters,
    required this.durationSeconds,
    required this.polyline,
    required this.steps,
    required this.evForecast,
    required this.isEcoMode,
  });

  double get distanceKm => distanceMeters / 1000.0;
  int get durationMinutes => (durationSeconds / 60.0).round();

  String get formattedDistance {
    if (distanceMeters >= 1000) {
      return '${(distanceMeters / 1000.0).toStringAsFixed(1)} km';
    }
    return '${distanceMeters.toStringAsFixed(0)} m';
  }

  String get formattedDuration {
    final mins = durationMinutes;
    if (mins >= 60) {
      final h = mins ~/ 60;
      final m = mins % 60;
      return '${h}h ${m}p';
    }
    return '$mins phút';
  }

  NavRouteResult copyWith({
    double? distanceMeters,
    double? durationSeconds,
    List<LatLng>? polyline,
    List<NavRouteStep>? steps,
    NavEvForecast? evForecast,
    bool? isEcoMode,
  }) {
    return NavRouteResult(
      distanceMeters: distanceMeters ?? this.distanceMeters,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      polyline: polyline ?? this.polyline,
      steps: steps ?? this.steps,
      evForecast: evForecast ?? this.evForecast,
      isEcoMode: isEcoMode ?? this.isEcoMode,
    );
  }

  Map<String, dynamic> toJson() => {
        'distance_meters': distanceMeters,
        'duration_seconds': durationSeconds,
        'polyline': polyline.map((p) => [p.latitude, p.longitude]).toList(),
        'steps': steps.map((s) => s.toJson()).toList(),
        'ev_forecast': evForecast.toJson(),
        'is_eco_mode': isEcoMode,
      };

  factory NavRouteResult.fromJson(Map<String, dynamic> json) {
    final polyRaw = json['polyline'] as List<dynamic>? ?? [];
    final parsedPolyline = <LatLng>[];
    for (final item in polyRaw) {
      if (item is List && item.length >= 2) {
        parsedPolyline.add(LatLng((item[0] as num).toDouble(), (item[1] as num).toDouble()));
      }
    }

    final stepsRaw = json['steps'] as List<dynamic>? ?? [];
    final parsedSteps = stepsRaw
        .map((s) => NavRouteStep.fromJson(s as Map<String, dynamic>))
        .toList();

    return NavRouteResult(
      distanceMeters: ((json['distance_m'] ?? json['distance_meters'] ?? json['distanceMeters'] ?? 0.0) as num).toDouble(),
      durationSeconds: ((json['duration_s'] ?? json['duration_seconds'] ?? json['durationSeconds'] ?? 0.0) as num).toDouble(),
      polyline: parsedPolyline,
      steps: parsedSteps,
      evForecast: NavEvForecast.fromJson(
        (json['ev_forecast'] ?? json['evForecast'] ?? {}) as Map<String, dynamic>,
      ),
      isEcoMode: (json['is_eco_mode'] ?? json['isEcoMode'] ?? false) as bool,
    );
  }
}

/// Trạng thái bám đường & điều hướng Turn-by-Turn thời gian thực
class NavTrackingState {
  final LatLng snappedLocation;
  final double snappedBearing;
  final double crossTrackErrorMeters;
  final bool isOffRoute;
  final int closestPolylineIndex;
  final int currentStepIndex;
  final double distanceToNextManeuverMeters;
  final double remainingDistanceMeters;
  final double remainingDurationSeconds;
  final double arrivalSocPercent;
  final String energyStatus; // 'safe', 'warning', 'critical'
  final bool hasArrived;

  const NavTrackingState({
    required this.snappedLocation,
    required this.snappedBearing,
    required this.crossTrackErrorMeters,
    required this.isOffRoute,
    required this.closestPolylineIndex,
    required this.currentStepIndex,
    required this.distanceToNextManeuverMeters,
    required this.remainingDistanceMeters,
    required this.remainingDurationSeconds,
    required this.arrivalSocPercent,
    required this.energyStatus,
    required this.hasArrived,
  });

  String get formattedDistanceToManeuver {
    if (distanceToNextManeuverMeters >= 1000) {
      return '${(distanceToNextManeuverMeters / 1000.0).toStringAsFixed(1)} km';
    }
    return '${distanceToNextManeuverMeters.toStringAsFixed(0)} m';
  }

  String get formattedRemainingDistance {
    if (remainingDistanceMeters >= 1000) {
      return '${(remainingDistanceMeters / 1000.0).toStringAsFixed(1)} km';
    }
    return '${remainingDistanceMeters.toStringAsFixed(0)} m';
  }

  String get formattedRemainingTime {
    final mins = (remainingDurationSeconds / 60.0).round();
    if (mins >= 60) {
      final h = mins ~/ 60;
      final m = mins % 60;
      return '${h}h ${m}p';
    }
    return '$mins phút';
  }

  Map<String, dynamic> toJson() => {
        'snapped_lat': snappedLocation.latitude,
        'snapped_lng': snappedLocation.longitude,
        'snapped_bearing': snappedBearing,
        'cross_track_error_meters': crossTrackErrorMeters,
        'is_off_route': isOffRoute,
        'closest_polyline_index': closestPolylineIndex,
        'current_step_index': currentStepIndex,
        'distance_to_next_maneuver_meters': distanceToNextManeuverMeters,
        'remaining_distance_meters': remainingDistanceMeters,
        'remaining_duration_seconds': remainingDurationSeconds,
        'arrival_soc_percent': arrivalSocPercent,
        'energy_status': energyStatus,
        'has_arrived': hasArrived,
      };

  factory NavTrackingState.fromJson(Map<String, dynamic> json) {
    return NavTrackingState(
      snappedLocation: LatLng(
        ((json['snapped_lat'] ?? json['snappedLat'] ?? 0.0) as num).toDouble(),
        ((json['snapped_lng'] ?? json['snappedLng'] ?? 0.0) as num).toDouble(),
      ),
      snappedBearing: ((json['snapped_bearing'] ?? json['snappedBearing'] ?? 0.0) as num).toDouble(),
      crossTrackErrorMeters: ((json['cross_track_error_m'] ??
              json['cross_track_error_meters'] ??
              json['crossTrackErrorMeters'] ??
              0.0) as num)
          .toDouble(),
      isOffRoute: (json['is_off_route'] ?? json['isOffRoute'] ?? false) as bool,
      closestPolylineIndex:
          ((json['closest_polyline_index'] ?? json['closestPolylineIndex'] ?? 0) as num).toInt(),
      currentStepIndex:
          ((json['current_step_index'] ?? json['currentStepIndex'] ?? 0) as num).toInt(),
      distanceToNextManeuverMeters: ((json['distance_to_next_maneuver_m'] ??
              json['distance_to_next_maneuver_meters'] ??
              json['distanceToNextManeuverMeters'] ??
              0.0) as num)
          .toDouble(),
      remainingDistanceMeters: ((json['remaining_distance_m'] ??
              json['remaining_distance_meters'] ??
              json['remainingDistanceMeters'] ??
              0.0) as num)
          .toDouble(),
      remainingDurationSeconds: ((json['remaining_duration_s'] ??
              json['remaining_duration_seconds'] ??
              json['remainingDurationSeconds'] ??
              0.0) as num)
          .toDouble(),
      arrivalSocPercent:
          ((json['arrival_soc_percent'] ?? json['arrivalSocPercent'] ?? 100.0) as num).toDouble(),
      energyStatus: (json['energy_status'] ?? json['energyStatus'] ?? 'safe') as String,
      hasArrived: (json['has_arrived'] ?? json['hasArrived'] ?? false) as bool,
    );
  }
}
