use crate::graph::{calculate_bearing, haversine_distance_m};
use crate::router::RouteStep;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TrackingResult {
    pub snapped_lat: f64,
    pub snapped_lng: f64,
    pub snapped_bearing: f64,
    pub cross_track_error_m: f64,
    pub is_off_route: bool,
    pub closest_polyline_index: usize,
    pub current_step_index: usize,
    pub distance_to_next_maneuver_m: f64,
    pub remaining_distance_m: f64,
    pub remaining_duration_s: f64,
    pub has_arrived: bool,
}

/// Tracks the rider's GPS position against the active route polyline and steps.
pub fn track_position(
    current_lat: f64,
    current_lng: f64,
    current_speed_kmh: f64,
    _current_heading: f64,
    polyline: &[[f64; 2]],
    steps: &[RouteStep],
) -> TrackingResult {
    if polyline.is_empty() {
        return TrackingResult {
            snapped_lat: current_lat,
            snapped_lng: current_lng,
            snapped_bearing: 0.0,
            cross_track_error_m: 0.0,
            is_off_route: true,
            closest_polyline_index: 0,
            current_step_index: 0,
            distance_to_next_maneuver_m: 0.0,
            remaining_distance_m: 0.0,
            remaining_duration_s: 0.0,
            has_arrived: false,
        };
    }

    if polyline.len() == 1 {
        let p = polyline[0];
        let cte = haversine_distance_m(current_lat, current_lng, p[0], p[1]);
        return TrackingResult {
            snapped_lat: p[0],
            snapped_lng: p[1],
            snapped_bearing: 0.0,
            cross_track_error_m: cte,
            is_off_route: cte > 35.0,
            closest_polyline_index: 0,
            current_step_index: 0,
            distance_to_next_maneuver_m: 0.0,
            remaining_distance_m: cte,
            remaining_duration_s: 0.0,
            has_arrived: cte < 20.0,
        };
    }

    // Find closest segment via orthogonal projection
    let mut best_segment_idx = 0;
    let mut min_cte = f64::MAX;
    let mut best_snapped_lat = polyline[0][0];
    let mut best_snapped_lng = polyline[0][1];
    let mut best_bearing = 0.0;

    for i in 0..(polyline.len() - 1) {
        let lat1 = polyline[i][0];
        let lng1 = polyline[i][1];
        let lat2 = polyline[i + 1][0];
        let lng2 = polyline[i + 1][1];

        let mid_lat = ((lat1 + current_lat) / 2.0).to_radians();
        let scale_x = 111_319.5 * mid_lat.cos();
        let scale_y = 111_132.9;

        let vx = (lng2 - lng1) * scale_x;
        let vy = (lat2 - lat1) * scale_y;
        let ux = (current_lng - lng1) * scale_x;
        let uy = (current_lat - lat1) * scale_y;

        let len_sq = vx * vx + vy * vy;
        let (s_lat, s_lng) = if len_sq < 1e-6 {
            (lat1, lng1)
        } else {
            let t = ((ux * vx + uy * vy) / len_sq).clamp(0.0, 1.0);
            (lat1 + t * (lat2 - lat1), lng1 + t * (lng2 - lng1))
        };

        let cte = haversine_distance_m(current_lat, current_lng, s_lat, s_lng);
        if cte < min_cte {
            min_cte = cte;
            best_segment_idx = i;
            best_snapped_lat = s_lat;
            best_snapped_lng = s_lng;
            best_bearing = calculate_bearing(lat1, lng1, lat2, lng2);
        }
    }

    // Calculate remaining distance along the polyline from snapped point to destination
    let dist_to_segment_end = haversine_distance_m(
        best_snapped_lat,
        best_snapped_lng,
        polyline[best_segment_idx + 1][0],
        polyline[best_segment_idx + 1][1],
    );

    let mut remaining_dist = dist_to_segment_end;
    for j in (best_segment_idx + 1)..(polyline.len() - 1) {
        remaining_dist += haversine_distance_m(
            polyline[j][0],
            polyline[j][1],
            polyline[j + 1][0],
            polyline[j + 1][1],
        );
    }

    let has_arrived = remaining_dist < 20.0;
    let is_off_route = min_cte > 35.0;

    // Calculate traveled distance along polyline to determine step and distance to next maneuver
    let mut traveled_dist = 0.0;
    for k in 0..best_segment_idx {
        traveled_dist += haversine_distance_m(
            polyline[k][0],
            polyline[k][1],
            polyline[k + 1][0],
            polyline[k + 1][1],
        );
    }
    traveled_dist += haversine_distance_m(
        polyline[best_segment_idx][0],
        polyline[best_segment_idx][1],
        best_snapped_lat,
        best_snapped_lng,
    );

    // Compute cumulative start distance for each step
    let mut step_start_distances = Vec::with_capacity(steps.len());
    let mut cumulative = 0.0;
    for s in steps {
        step_start_distances.push(cumulative);
        cumulative += s.distance_m;
    }

    // Determine current_step_index
    let mut current_step_idx = 0;
    if !steps.is_empty() {
        for (idx, &start_d) in step_start_distances.iter().enumerate() {
            if start_d <= traveled_dist + 15.0 {
                current_step_idx = idx;
            } else {
                break;
            }
        }
        if current_step_idx >= steps.len() {
            current_step_idx = steps.len() - 1;
        }
    }

    let distance_to_next_maneuver = if current_step_idx + 1 < steps.len() {
        let next_start = step_start_distances[current_step_idx + 1];
        (next_start - traveled_dist).max(0.0)
    } else {
        remaining_dist
    };

    // Calculate remaining duration
    let effective_speed_kmh = if current_speed_kmh >= 10.0 {
        (current_speed_kmh.clamp(15.0, 50.0) + 35.0) / 2.0
    } else {
        30.0 // Urban motorcycle nominal speed
    };
    let speed_ms = (effective_speed_kmh / 3.6).max(1.0);
    let remaining_duration_s = remaining_dist / speed_ms;

    TrackingResult {
        snapped_lat: best_snapped_lat,
        snapped_lng: best_snapped_lng,
        snapped_bearing: best_bearing,
        cross_track_error_m: min_cte,
        is_off_route,
        closest_polyline_index: best_segment_idx,
        current_step_index: current_step_idx,
        distance_to_next_maneuver_m: distance_to_next_maneuver,
        remaining_distance_m: remaining_dist,
        remaining_duration_s,
        has_arrived,
    }
}
