use crate::graph::{calculate_bearing, haversine_distance_m, RoadEdge, RoadGraph, RoadType};
use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::collections::{BinaryHeap, HashMap, HashSet};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RouteStep {
    pub instruction: String,
    pub street_name: String,
    pub maneuver: String,
    pub distance_m: f64,
    pub duration_s: f64,
    pub lat: f64,
    pub lng: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RouteResult {
    pub distance_m: f64,
    pub duration_s: f64,
    pub polyline: Vec<[f64; 2]>,
    pub steps: Vec<RouteStep>,
}

#[derive(Copy, Clone, PartialEq)]
struct AStarNode {
    node_id: u64,
    f_score: f64,
}

impl Eq for AStarNode {}

impl Ord for AStarNode {
    fn cmp(&self, other: &Self) -> Ordering {
        // Reverse for min-heap
        other
            .f_score
            .partial_cmp(&self.f_score)
            .unwrap_or(Ordering::Equal)
    }
}

impl PartialOrd for AStarNode {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

/// Computes the edge traversal cost based on mode.
/// Excludes RoadType::Motorway and !is_motorcycle_allowed by returning None.
fn edge_cost(edge: &RoadEdge, eco_mode: bool) -> Option<f64> {
    // VIETNAM MOTORCYCLE LAW: Exclude motorways & restricted roads
    if edge.road_type == RoadType::Motorway || !edge.is_motorcycle_allowed {
        return None;
    }

    let speed_m_s = (edge.speed_limit_kmh.max(10.0) / 3.6).max(1.0);
    let time_s = edge.distance_m / speed_m_s;

    if !eco_mode {
        // Fastest mode: minimize time
        Some(time_s)
    } else {
        // Eco mode: minimize energy consumption (optimal 35-45 km/h, penalize higher drag or stop-and-go)
        let factor = if edge.speed_limit_kmh >= 35.0 && edge.speed_limit_kmh <= 45.0 {
            1.0
        } else if edge.speed_limit_kmh > 45.0 {
            1.0 + (edge.speed_limit_kmh - 45.0) * 0.025
        } else {
            1.0 + (35.0 - edge.speed_limit_kmh) * 0.02
        };
        Some(edge.distance_m * factor)
    }
}

/// Admissible heuristic for A* between two nodes
fn heuristic(graph: &RoadGraph, from_id: u64, to_id: u64, eco_mode: bool) -> f64 {
    let n1 = match graph.nodes.get(&from_id) {
        Some(n) => n,
        None => return 0.0,
    };
    let n2 = match graph.nodes.get(&to_id) {
        Some(n) => n,
        None => return 0.0,
    };

    let dist = haversine_distance_m(n1.lat, n1.lng, n2.lat, n2.lng);

    if !eco_mode {
        // Max motorcycle urban legal speed ~ 60 km/h = 16.67 m/s
        let max_speed_ms = 60.0 / 3.6;
        dist / max_speed_ms
    } else {
        // In eco mode, cost factor >= 1.0, so straight distance is strictly admissible
        dist
    }
}

/// Admissible heuristic from a node to target destination coordinates
fn heuristic_coords(graph: &RoadGraph, from_id: u64, dest_lat: f64, dest_lng: f64, eco_mode: bool) -> f64 {
    let n1 = match graph.nodes.get(&from_id) {
        Some(n) => n,
        None => return 0.0,
    };
    let dist = haversine_distance_m(n1.lat, n1.lng, dest_lat, dest_lng);
    if !eco_mode {
        let max_speed_ms = 60.0 / 3.6;
        dist / max_speed_ms
    } else {
        dist
    }
}

/// A* Shortest Path implementation for single start/dest node.
pub fn astar_route(
    graph: &RoadGraph,
    start_id: u64,
    dest_id: u64,
    eco_mode: bool,
) -> Result<Vec<RoadEdge>, String> {
    if !graph.nodes.contains_key(&start_id) {
        return Err(format!("Điểm xuất phát ID {} không tồn tại", start_id));
    }
    if !graph.nodes.contains_key(&dest_id) {
        return Err(format!("Điểm đến ID {} không tồn tại", dest_id));
    }
    if start_id == dest_id {
        return Ok(Vec::new());
    }

    let mut open_set = BinaryHeap::new();
    let mut g_score: HashMap<u64, f64> = HashMap::new();
    let mut came_from: HashMap<u64, RoadEdge> = HashMap::new();

    g_score.insert(start_id, 0.0);
    open_set.push(AStarNode {
        node_id: start_id,
        f_score: heuristic(graph, start_id, dest_id, eco_mode),
    });

    while let Some(AStarNode { node_id, .. }) = open_set.pop() {
        if node_id == dest_id {
            // Reconstruct path
            let mut path = Vec::new();
            let mut curr = dest_id;
            while let Some(edge) = came_from.get(&curr) {
                path.push(edge.clone());
                curr = edge.from;
            }
            path.reverse();
            return Ok(path);
        }

        let current_g = match g_score.get(&node_id) {
            Some(&g) => g,
            None => continue,
        };

        if let Some(edges) = graph.adjacency.get(&node_id) {
            for edge in edges {
                let cost = match edge_cost(edge, eco_mode) {
                    Some(c) => c,
                    None => continue, // Forbidden (Motorway or motorcycle disallowed)
                };

                let neighbor = edge.to;
                let tentative_g = current_g + cost;

                if tentative_g < *g_score.get(&neighbor).unwrap_or(&f64::MAX) {
                    came_from.insert(neighbor, edge.clone());
                    g_score.insert(neighbor, tentative_g);
                    let f = tentative_g + heuristic(graph, neighbor, dest_id, eco_mode);
                    open_set.push(AStarNode {
                        node_id: neighbor,
                        f_score: f,
                    });
                }
            }
        }
    }

    Err("Không tìm thấy lộ trình hợp lệ cho xe máy".to_string())
}

/// Multi-Candidate A* routing: seeds multiple candidate nodes around start and accepts any candidate
/// node around destination. Overcomes isolated dead-ends or parking lot cul-de-sacs without jumping
/// off the real road geometry.
pub fn astar_route_multi(
    graph: &RoadGraph,
    start_candidates: &[(u64, f64)],
    dest_candidates: &[(u64, f64)],
    dest_lat: f64,
    dest_lng: f64,
    eco_mode: bool,
) -> Result<(Vec<RoadEdge>, u64), String> {
    if start_candidates.is_empty() {
        return Err("Không có điểm kết nối hợp lệ gần điểm xuất phát".to_string());
    }
    if dest_candidates.is_empty() {
        return Err("Không có điểm kết nối hợp lệ gần điểm đến".to_string());
    }

    let dest_set: HashSet<u64> = dest_candidates.iter().map(|&(id, _)| id).collect();

    // Fast-path: Check if start and dest are snapped to the same node in immediate proximity (< 30m)
    for &(s_id, s_dist) in start_candidates {
        if let Some(&(_, d_dist)) = dest_candidates.iter().find(|(id, _)| *id == s_id) {
            if s_dist + d_dist < 30.0 {
                return Ok((Vec::new(), s_id));
            }
        }
    }

    let mut open_set = BinaryHeap::new();
    let mut g_score: HashMap<u64, f64> = HashMap::new();
    let mut came_from: HashMap<u64, RoadEdge> = HashMap::new();

    for &(s_id, s_dist) in start_candidates {
        let init_g = if !eco_mode {
            s_dist / (20.0 / 3.6)
        } else {
            s_dist
        };
        g_score.insert(s_id, init_g);
        let h = heuristic_coords(graph, s_id, dest_lat, dest_lng, eco_mode);
        open_set.push(AStarNode {
            node_id: s_id,
            f_score: init_g + h,
        });
    }

    while let Some(AStarNode { node_id, .. }) = open_set.pop() {
        // Destination candidate reached via a real edge traversal
        if dest_set.contains(&node_id) && came_from.contains_key(&node_id) {
            let mut path = Vec::new();
            let mut curr = node_id;
            while let Some(edge) = came_from.get(&curr) {
                path.push(edge.clone());
                curr = edge.from;
            }
            path.reverse();
            return Ok((path, node_id));
        }

        let current_g = match g_score.get(&node_id) {
            Some(&g) => g,
            None => continue,
        };

        if let Some(edges) = graph.adjacency.get(&node_id) {
            for edge in edges {
                let cost = match edge_cost(edge, eco_mode) {
                    Some(c) => c,
                    None => continue,
                };

                let neighbor = edge.to;
                let tentative_g = current_g + cost;

                if tentative_g < *g_score.get(&neighbor).unwrap_or(&f64::MAX) {
                    came_from.insert(neighbor, edge.clone());
                    g_score.insert(neighbor, tentative_g);
                    let f = tentative_g + heuristic_coords(graph, neighbor, dest_lat, dest_lng, eco_mode);
                    open_set.push(AStarNode {
                        node_id: neighbor,
                        f_score: f,
                    });
                }
            }
        }
    }

    Err("Không tìm thấy lộ trình hợp lệ cho xe máy".to_string())
}

/// Generates turn-by-turn RouteStep list from traversed edges.
pub fn build_route_steps(graph: &RoadGraph, edges: &[RoadEdge], dest_node_id: u64) -> Vec<RouteStep> {
    if edges.is_empty() {
        if let Some(dest) = graph.nodes.get(&dest_node_id) {
            return vec![RouteStep {
                instruction: "Đã đến điểm đích".to_string(),
                street_name: "".to_string(),
                maneuver: "arrive".to_string(),
                distance_m: 0.0,
                duration_s: 0.0,
                lat: dest.lat,
                lng: dest.lng,
            }];
        }
        return Vec::new();
    }

    let mut raw_steps: Vec<RouteStep> = Vec::new();
    let mut prev_bearing = 0.0;
    let mut has_prev_bearing = false;

    for (i, edge) in edges.iter().enumerate() {
        let from_node = match graph.nodes.get(&edge.from) {
            Some(n) => n,
            None => continue,
        };
        let to_node = match graph.nodes.get(&edge.to) {
            Some(n) => n,
            None => continue,
        };

        let current_bearing = calculate_bearing(from_node.lat, from_node.lng, to_node.lat, to_node.lng);
        let speed_ms = (edge.speed_limit_kmh.max(10.0) / 3.6).max(1.0);
        let duration = edge.distance_m / speed_ms;

        if i == 0 {
            raw_steps.push(RouteStep {
                instruction: format!("Bắt đầu di chuyển trên {}", edge.street_name),
                street_name: edge.street_name.clone(),
                maneuver: "depart".to_string(),
                distance_m: edge.distance_m,
                duration_s: duration,
                lat: from_node.lat,
                lng: from_node.lng,
            });
            prev_bearing = current_bearing;
            has_prev_bearing = true;
            continue;
        }

        // Merge micro-segments (< 8.0m) to prevent phantom turn instructions on curved road geometry
        if edge.distance_m < 8.0 && !raw_steps.is_empty() {
            if let Some(last) = raw_steps.last_mut() {
                last.distance_m += edge.distance_m;
                last.duration_s += duration;
                continue;
            }
        }

        let delta = if has_prev_bearing {
            ((current_bearing - prev_bearing + 540.0) % 360.0) - 180.0
        } else {
            0.0
        };

        let is_same_street = raw_steps.last().map_or(false, |s| s.street_name == edge.street_name);

        let (maneuver, instruction) = if is_same_street {
            if delta.abs() >= 135.0 {
                ("u_turn".to_string(), format!("Quay đầu xe trên {}", edge.street_name))
            } else {
                ("straight".to_string(), format!("Đi thẳng theo {}", edge.street_name))
            }
        } else {
            if delta.abs() >= 135.0 {
                ("u_turn".to_string(), format!("Quay đầu xe vào {}", edge.street_name))
            } else if delta < -45.0 {
                ("turn_left".to_string(), format!("Rẽ trái vào {}", edge.street_name))
            } else if delta <= -15.0 {
                ("slight_left".to_string(), format!("Chếch sang trái vào {}", edge.street_name))
            } else if delta > 45.0 {
                ("turn_right".to_string(), format!("Rẽ phải vào {}", edge.street_name))
            } else if delta >= 15.0 {
                ("slight_right".to_string(), format!("Chếch sang phải vào {}", edge.street_name))
            } else {
                ("straight".to_string(), format!("Tiếp tục đi thẳng vào {}", edge.street_name))
            }
        };

        raw_steps.push(RouteStep {
            instruction,
            street_name: edge.street_name.clone(),
            maneuver,
            distance_m: edge.distance_m,
            duration_s: duration,
            lat: from_node.lat,
            lng: from_node.lng,
        });

        prev_bearing = current_bearing;
        has_prev_bearing = true;
    }

    // Consolidate consecutive "straight" steps on the same street
    let mut consolidated: Vec<RouteStep> = Vec::new();
    for step in raw_steps {
        if let Some(last) = consolidated.last_mut() {
            if last.street_name == step.street_name
                && (step.maneuver == "straight" || step.maneuver == "depart")
                && (last.maneuver == "straight" || last.maneuver == "depart")
            {
                last.distance_m += step.distance_m;
                last.duration_s += step.duration_s;
                continue;
            }
        }
        consolidated.push(step);
    }

    // Append final arrival step
    if let Some(dest_node) = graph.nodes.get(&dest_node_id) {
        consolidated.push(RouteStep {
            instruction: "Đã đến điểm đích".to_string(),
            street_name: "".to_string(),
            maneuver: "arrive".to_string(),
            distance_m: 0.0,
            duration_s: 0.0,
            lat: dest_node.lat,
            lng: dest_node.lng,
        });
    }

    consolidated
}

/// Main routing function taking GPS start & dest coords and producing polyline & steps.
pub fn calculate_route(
    graph: &RoadGraph,
    start_lat: f64,
    start_lng: f64,
    dest_lat: f64,
    dest_lng: f64,
    eco_mode: bool,
) -> Result<RouteResult, String> {
    let (edges, dest_node) = if let (Some(s_id), Some(e_id)) = (graph.corridor_start_id, graph.corridor_end_id) {
        let route_edges = astar_route(graph, s_id, e_id, eco_mode)?;
        (route_edges, e_id)
    } else {
        let (s_nearest_id, s_nearest_dist) = graph
            .find_nearest_node_with_distance(start_lat, start_lng)
            .ok_or_else(|| "Không tìm thấy điểm kết nối mạng lưới gần điểm xuất phát".to_string())?;

        let (d_nearest_id, d_nearest_dist) = graph
            .find_nearest_node_with_distance(dest_lat, dest_lng)
            .ok_or_else(|| "Không tìm thấy điểm kết nối mạng lưới gần điểm đến".to_string())?;

        let snap_threshold = 15000.0;
        if s_nearest_dist > snap_threshold || d_nearest_dist > snap_threshold {
            return Err("Khu vực này cần kết nối mạng để tải dữ liệu đường bộ chi tiết".to_string());
        }

        let dist_sd = haversine_distance_m(start_lat, start_lng, dest_lat, dest_lng);
        let max_cap = if dist_sd > 60.0 {
            (dist_sd * 0.45).min(snap_threshold)
        } else {
            snap_threshold
        };

        let s_radius = (s_nearest_dist + 150.0).min(max_cap).max(s_nearest_dist);
        let mut start_candidates = graph.find_nearest_nodes(start_lat, start_lng, s_radius, 20);
        if start_candidates.is_empty() {
            start_candidates.push((s_nearest_id, s_nearest_dist));
        }

        let d_radius = (d_nearest_dist + 150.0).min(max_cap).max(d_nearest_dist);
        let mut dest_candidates = graph.find_nearest_nodes(dest_lat, dest_lng, d_radius, 20);
        if dest_candidates.is_empty() {
            dest_candidates.push((d_nearest_id, d_nearest_dist));
        }

        astar_route_multi(
            graph,
            &start_candidates,
            &dest_candidates,
            dest_lat,
            dest_lng,
            eco_mode,
        )?
    };

    let mut polyline = Vec::new();
    let mut total_distance = 0.0;
    let mut total_duration = 0.0;

    if edges.is_empty() {
        if let Some(node) = graph.nodes.get(&dest_node) {
            polyline.push([node.lat, node.lng]);
        } else {
            polyline.push([start_lat, start_lng]);
        }
    } else {
        if let Some(first_node) = graph.nodes.get(&edges[0].from) {
            polyline.push([first_node.lat, first_node.lng]);
        }
        for edge in &edges {
            if let Some(to_node) = graph.nodes.get(&edge.to) {
                polyline.push([to_node.lat, to_node.lng]);
            }
            total_distance += edge.distance_m;
            let speed_ms = (edge.speed_limit_kmh.max(10.0) / 3.6).max(1.0);
            total_duration += edge.distance_m / speed_ms;
        }
    }

    let steps = build_route_steps(graph, &edges, dest_node);

    Ok(RouteResult {
        distance_m: total_distance,
        duration_s: total_duration,
        polyline,
        steps,
    })
}
