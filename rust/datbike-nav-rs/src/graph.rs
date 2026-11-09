use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs::File;
use std::io::Write;
use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum RoadType {
    Motorway,
    Trunk,
    Primary,
    Secondary,
    Tertiary,
    Residential,
    Service,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RoadNode {
    pub id: u64,
    pub lat: f64,
    pub lng: f64,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RoadEdge {
    pub from: u64,
    pub to: u64,
    pub distance_m: f64,
    pub speed_limit_kmh: f64,
    pub road_type: RoadType,
    pub street_name: String,
    pub is_motorcycle_allowed: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct RoadGraph {
    pub nodes: HashMap<u64, RoadNode>,
    pub adjacency: HashMap<u64, Vec<RoadEdge>>,
    #[serde(default)]
    pub corridor_start_id: Option<u64>,
    #[serde(default)]
    pub corridor_end_id: Option<u64>,
    #[serde(default)]
    pub spatial_grid: HashMap<(i32, i32), Vec<u64>>,
}

#[inline]
pub fn spatial_cell(lat: f64, lng: f64) -> (i32, i32) {
    ((lat * 100.0).floor() as i32, (lng * 100.0).floor() as i32)
}

pub fn haversine_distance_m(lat1: f64, lng1: f64, lat2: f64, lng2: f64) -> f64 {
    let r = 6_371_000.0;
    let phi1 = lat1.to_radians();
    let phi2 = lat2.to_radians();
    let dphi = (lat2 - lat1).to_radians();
    let dlambda = (lng2 - lng1).to_radians();

    let a = (dphi / 2.0).sin().powi(2)
        + phi1.cos() * phi2.cos() * (dlambda / 2.0).sin().powi(2);
    let c = 2.0 * a.sqrt().atan2((1.0 - a).sqrt().max(0.0));
    r * c
}

pub fn calculate_bearing(lat1: f64, lng1: f64, lat2: f64, lng2: f64) -> f64 {
    let phi1 = lat1.to_radians();
    let phi2 = lat2.to_radians();
    let dlambda = (lng2 - lng1).to_radians();

    let y = dlambda.sin() * phi2.cos();
    let x = phi1.cos() * phi2.sin() - phi1.sin() * phi2.cos() * dlambda.cos();
    let bearing_rad = y.atan2(x);
    let bearing_deg = bearing_rad.to_degrees();
    (bearing_deg + 360.0) % 360.0
}

/// Cleans raw OpenStreetMap address labels by removing country name, postal codes,
/// and administrative prefixes (Khu phố, Phường, Xã, etc.) if `minimal == true`.
pub fn clean_map_label(raw: &str, minimal: bool) -> String {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return String::new();
    }

    let parts: Vec<&str> = trimmed
        .split(',')
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .collect();

    if parts.is_empty() {
        return String::new();
    }

    let mut cleaned_parts = Vec::new();

    for &part in &parts {
        let lower = part.to_lowercase();

        // 1. Filter country tokens
        if lower == "việt nam" || lower == "vietnam" || lower == "vn" {
            continue;
        }

        // 2. Filter 5-6 digit postal codes (e.g., 700000, 100000)
        let is_digits_only = part.chars().all(|c| c.is_ascii_digit());
        if is_digits_only && (part.len() == 5 || part.len() == 6) {
            continue;
        }

        // 3. Filter administrative subdivisions when minimal == true
        if minimal {
            let is_admin = lower.starts_with("khu phố")
                || lower.starts_with("khu pho")
                || lower.starts_with("kp.")
                || lower.starts_with("kp ")
                || lower.starts_with("tổ dân phố")
                || lower.starts_with("to dan pho")
                || lower.starts_with("tdp.")
                || lower.starts_with("tdp ")
                || lower.starts_with("tổ ")
                || lower.starts_with("to ")
                || lower.starts_with("phường")
                || lower.starts_with("phuong")
                || lower.starts_with("p.")
                || lower.starts_with("p ")
                || lower.starts_with("xã ")
                || lower.starts_with("xa ")
                || lower.starts_with("ấp ")
                || lower.starts_with("ap ")
                || lower.starts_with("khóm ")
                || lower.starts_with("khom ")
                || lower.starts_with("thôn ")
                || lower.starts_with("thon ");

            if is_admin {
                continue;
            }
        }

        cleaned_parts.push(part);
    }

    if cleaned_parts.is_empty() {
        // Fallback to first non-empty component if everything was filtered
        parts[0].to_string()
    } else {
        cleaned_parts.join(", ")
    }
}

#[derive(Debug, Deserialize)]
struct OsmOverpassResponse {
    #[serde(default)]
    elements: Vec<OsmElement>,
}

#[derive(Debug, Deserialize)]
struct OsmElement {
    #[serde(rename = "type")]
    element_type: String,
    id: u64,
    #[serde(default)]
    lat: Option<f64>,
    #[serde(default)]
    lon: Option<f64>,
    #[serde(default)]
    nodes: Option<Vec<u64>>,
    #[serde(default)]
    tags: Option<HashMap<String, serde_json::Value>>,
}

fn get_tag_str<'a>(tags: &'a HashMap<String, serde_json::Value>, key: &str) -> Option<&'a str> {
    tags.get(key).and_then(|v| v.as_str())
}

impl RoadGraph {
    pub fn new() -> Self {
        Self {
            nodes: HashMap::new(),
            adjacency: HashMap::new(),
            corridor_start_id: None,
            corridor_end_id: None,
            spatial_grid: HashMap::new(),
        }
    }

    pub fn build_spatial_index(&mut self) {
        self.spatial_grid.clear();
        for (&id, node) in &self.nodes {
            let cell = spatial_cell(node.lat, node.lng);
            self.spatial_grid.entry(cell).or_default().push(id);
        }
    }

    pub fn add_node(&mut self, node: RoadNode) {
        self.nodes.insert(node.id, node);
    }

    pub fn add_edge(&mut self, edge: RoadEdge) {
        self.adjacency.entry(edge.from).or_default().push(edge);
    }

    pub fn add_bidirectional_edge(&mut self, edge: RoadEdge) {
        self.add_edge(edge.clone());
        let rev_edge = RoadEdge {
            from: edge.to,
            to: edge.from,
            distance_m: edge.distance_m,
            speed_limit_kmh: edge.speed_limit_kmh,
            road_type: edge.road_type,
            street_name: edge.street_name,
            is_motorcycle_allowed: edge.is_motorcycle_allowed,
        };
        self.add_edge(rev_edge);
    }

    pub fn find_nearest_node_with_distance(&self, lat: f64, lng: f64) -> Option<(u64, f64)> {
        if !self.spatial_grid.is_empty() {
            let center_cell = spatial_cell(lat, lng);
            let mut best_node = None;
            let mut min_dist = f64::MAX;

            for r in 0..=4i32 {
                for dy in -r..=r {
                    for dx in -r..=r {
                        if r > 0 && dx.abs() != r && dy.abs() != r {
                            continue;
                        }
                        let cell = (center_cell.0 + dy, center_cell.1 + dx);
                        if let Some(node_ids) = self.spatial_grid.get(&cell) {
                            for &nid in node_ids {
                                if let Some(node) = self.nodes.get(&nid) {
                                    let dist = haversine_distance_m(lat, lng, node.lat, node.lng);
                                    if dist < min_dist {
                                        min_dist = dist;
                                        best_node = Some((nid, dist));
                                    }
                                }
                            }
                        }
                    }
                }
                if best_node.is_some() && min_dist < (r as f64 * 1050.0) {
                    return best_node;
                }
            }
            if best_node.is_some() {
                return best_node;
            }
        }

        let mut best_node = None;
        let mut min_dist = f64::MAX;

        for node in self.nodes.values() {
            let dist = haversine_distance_m(lat, lng, node.lat, node.lng);
            if dist < min_dist {
                min_dist = dist;
                best_node = Some((node.id, dist));
            }
        }

        best_node
    }

    pub fn find_nearest_node(&self, lat: f64, lng: f64) -> Option<u64> {
        self.find_nearest_node_with_distance(lat, lng).map(|(id, _)| id)
    }

    /// Finds up to limit nearest nodes within max_dist_m that have at least one valid outgoing
    /// motorcycle edge, sorted ascending by distance.
    pub fn find_nearest_nodes(
        &self,
        lat: f64,
        lng: f64,
        max_dist_m: f64,
        limit: usize,
    ) -> Vec<(u64, f64)> {
        let mut candidates = Vec::new();

        if !self.spatial_grid.is_empty() {
            let center_cell = spatial_cell(lat, lng);
            let cell_radius = ((max_dist_m / 1050.0).ceil() as i32).max(1);

            for dy in -cell_radius..=cell_radius {
                for dx in -cell_radius..=cell_radius {
                    let cell = (center_cell.0 + dy, center_cell.1 + dx);
                    if let Some(node_ids) = self.spatial_grid.get(&cell) {
                        for &nid in node_ids {
                            let has_valid_outgoing = self.adjacency.get(&nid).map_or(false, |edges| {
                                edges
                                    .iter()
                                    .any(|e| e.road_type != RoadType::Motorway && e.is_motorcycle_allowed)
                            });

                            if !has_valid_outgoing {
                                continue;
                            }

                            if let Some(node) = self.nodes.get(&nid) {
                                let dist = haversine_distance_m(lat, lng, node.lat, node.lng);
                                if dist <= max_dist_m {
                                    candidates.push((nid, dist));
                                }
                            }
                        }
                    }
                }
            }

            candidates.sort_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal));
            if candidates.len() > limit {
                candidates.truncate(limit);
            }
            return candidates;
        }

        for node in self.nodes.values() {
            let has_valid_outgoing = self.adjacency.get(&node.id).map_or(false, |edges| {
                edges
                    .iter()
                    .any(|e| e.road_type != RoadType::Motorway && e.is_motorcycle_allowed)
            });

            if !has_valid_outgoing {
                continue;
            }

            let dist = haversine_distance_m(lat, lng, node.lat, node.lng);
            if dist <= max_dist_m {
                candidates.push((node.id, dist));
            }
        }

        candidates.sort_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal));
        if candidates.len() > limit {
            candidates.truncate(limit);
        }
        candidates
    }

    /// Dynamically ingests waypoints from a corridor into the graph.
    /// Creates connected nodes along the waypoints as an independent road chain without shortcutting to default nodes.
    pub fn ingest_corridor(
        &mut self,
        waypoints: &[[f64; 2]],
        street_name: Option<&str>,
        speed_limit: Option<f64>,
    ) -> Vec<u64> {
        if waypoints.is_empty() {
            return Vec::new();
        }

        let base_id: u64 = 1_000_000;
        let mut node_ids = Vec::with_capacity(waypoints.len());
        let street = street_name.unwrap_or("Tuyến hành lang tạm").to_string();
        let speed = speed_limit.unwrap_or(40.0);

        for (idx, &[lat, lng]) in waypoints.iter().enumerate() {
            let nid = base_id + idx as u64;
            let node = RoadNode {
                id: nid,
                lat,
                lng,
                name: format!("{}_{}", street, idx + 1),
            };
            self.add_node(node);
            node_ids.push(nid);
        }

        // Connect consecutive corridor nodes
        for i in 0..(node_ids.len() - 1) {
            let from_id = node_ids[i];
            let to_id = node_ids[i + 1];
            let n1 = &self.nodes[&from_id];
            let n2 = &self.nodes[&to_id];
            let dist = haversine_distance_m(n1.lat, n1.lng, n2.lat, n2.lng);

            self.add_bidirectional_edge(RoadEdge {
                from: from_id,
                to: to_id,
                distance_m: dist.max(1.0),
                speed_limit_kmh: speed,
                road_type: RoadType::Primary,
                street_name: street.clone(),
                is_motorcycle_allowed: true,
            });
        }

        if waypoints.len() >= 2 {
            self.corridor_start_id = Some(base_id);
            self.corridor_end_id = Some(base_id + (waypoints.len() as u64) - 1);
        }

        node_ids
    }

    /// Ingests raw OpenStreetMap Overpass JSON data into the graph.
    /// Filters motorcycle-forbidden ways, parses one-way restrictions, applies maxspeed,
    /// cleans street names, and creates road edges.
    pub fn ingest_osm_overpass_json(
        &mut self,
        raw_json: &str,
        minimal_filter: bool,
    ) -> Result<usize, String> {
        let elements: Vec<OsmElement> = match serde_json::from_str::<OsmOverpassResponse>(raw_json) {
            Ok(resp) => resp.elements,
            Err(_) => match serde_json::from_str::<Vec<OsmElement>>(raw_json) {
                Ok(elems) => elems,
                Err(e) => return Err(format!("Lỗi phân tích JSON OpenStreetMap: {}", e)),
            },
        };

        let mut added_edges = 0;

        // First pass: ingest nodes
        for elem in &elements {
            if elem.element_type == "node" {
                if let (Some(lat), Some(lon)) = (elem.lat, elem.lon) {
                    let raw_name = elem.tags.as_ref().and_then(|tags| {
                        get_tag_str(tags, "name:vi").or_else(|| get_tag_str(tags, "name"))
                    });

                    let name = match raw_name {
                        Some(rn) => {
                            let cl = clean_map_label(rn, minimal_filter);
                            if cl.is_empty() {
                                format!("Node {}", elem.id)
                            } else {
                                cl
                            }
                        }
                        None => format!("Node {}", elem.id),
                    };

                    self.add_node(RoadNode {
                        id: elem.id,
                        lat,
                        lng: lon,
                        name,
                    });
                }
            }
        }

        // Second pass: ingest ways
        for elem in &elements {
            if elem.element_type == "way" {
                let way_nodes = match &elem.nodes {
                    Some(nds) if nds.len() >= 2 => nds,
                    _ => continue,
                };

                let tags = match &elem.tags {
                    Some(t) => t,
                    None => continue,
                };

                // Filter out buildings, non-road areas, and indoor structures
                if tags.contains_key("building") {
                    continue;
                }
                if get_tag_str(tags, "area") == Some("yes") {
                    continue;
                }
                if get_tag_str(tags, "indoor") == Some("yes") {
                    continue;
                }

                let highway = match get_tag_str(tags, "highway") {
                    Some(h) => h,
                    None => continue,
                };

                let (road_type, default_speed, is_mc_default) = match highway {
                    "motorway" | "motorway_link" => (RoadType::Motorway, 80.0, false),
                    "trunk" | "trunk_link" => (RoadType::Trunk, 50.0, true),
                    "primary" | "primary_link" => (RoadType::Primary, 45.0, true),
                    "secondary" | "secondary_link" => (RoadType::Secondary, 40.0, true),
                    "tertiary" | "tertiary_link" | "unclassified" => (RoadType::Tertiary, 35.0, true),
                    "residential" | "living_street" | "service" => (RoadType::Residential, 25.0, true),
                    _ => continue, // Ignore footway, pedestrian, steps, path, cycleway, construction, etc.
                };

                // Check motorcycle access restrictions
                let mut is_motorcycle_allowed = is_mc_default;
                if road_type == RoadType::Motorway {
                    is_motorcycle_allowed = false;
                }
                if let Some(val) = get_tag_str(tags, "motorcycle") {
                    if val == "no" {
                        is_motorcycle_allowed = false;
                    } else if val == "yes" && road_type != RoadType::Motorway {
                        is_motorcycle_allowed = true;
                    }
                }
                if let Some(val) = get_tag_str(tags, "motor_vehicle") {
                    if val == "no" {
                        is_motorcycle_allowed = false;
                    }
                }
                if let Some(val) = get_tag_str(tags, "vehicle") {
                    if val == "no" {
                        is_motorcycle_allowed = false;
                    }
                }
                if let Some(val) = get_tag_str(tags, "access") {
                    if val == "private" || val == "no" {
                        is_motorcycle_allowed = false;
                    }
                }

                // Speed limit
                let mut speed = default_speed;
                if let Some(maxspeed_tag) = tags.get("maxspeed") {
                    if let Some(val) = maxspeed_tag.as_f64() {
                        if val > 0.0 && val <= 120.0 {
                            speed = val;
                        }
                    } else if let Some(maxspeed_str) = maxspeed_tag.as_str() {
                        if maxspeed_str == "VN:urban" {
                            speed = 50.0;
                        } else if maxspeed_str == "VN:rural" {
                            speed = 60.0;
                        } else {
                            let num_str: String = maxspeed_str
                                .chars()
                                .take_while(|c| c.is_ascii_digit() || *c == '.')
                                .collect();
                            if let Ok(val) = num_str.parse::<f64>() {
                                if val > 0.0 && val <= 120.0 {
                                    speed = val;
                                }
                            }
                        }
                    }
                }

                // Street name
                let raw_name = get_tag_str(tags, "name:vi")
                    .or_else(|| get_tag_str(tags, "name"))
                    .or_else(|| get_tag_str(tags, "ref"))
                    .unwrap_or("Đường nội bộ");

                let cleaned_name = clean_map_label(raw_name, minimal_filter);
                let street_name = if cleaned_name.trim().is_empty() {
                    "Đường nội bộ".to_string()
                } else {
                    cleaned_name
                };

                // One-way detection & Vietnamese motorcycle exemptions
                let is_roundabout = get_tag_str(tags, "junction")
                    .map_or(false, |j| j == "roundabout" || j == "circular");
                let oneway_val = get_tag_str(tags, "oneway");
                let oneway_mc = get_tag_str(tags, "oneway:motorcycle")
                    .or_else(|| get_tag_str(tags, "motorcycle:oneway"));

                let (is_forward_only, is_reverse_only) = if oneway_mc == Some("no")
                    || oneway_mc == Some("false")
                    || oneway_mc == Some("0")
                {
                    // Vietnamese traffic rule: street one-way for cars but two-way for motorcycles
                    (false, false)
                } else if oneway_mc == Some("yes")
                    || oneway_mc == Some("1")
                    || oneway_mc == Some("true")
                {
                    (true, false)
                } else if oneway_val == Some("-1") {
                    (false, true)
                } else if oneway_val == Some("yes")
                    || oneway_val == Some("1")
                    || oneway_val == Some("true")
                    || is_roundabout
                {
                    (true, false)
                } else {
                    (false, false)
                };

                for i in 0..(way_nodes.len() - 1) {
                    let from_id = way_nodes[i];
                    let to_id = way_nodes[i + 1];

                    let (n1_lat, n1_lng) = match self.nodes.get(&from_id) {
                        Some(n) => (n.lat, n.lng),
                        None => continue,
                    };
                    let (n2_lat, n2_lng) = match self.nodes.get(&to_id) {
                        Some(n) => (n.lat, n.lng),
                        None => continue,
                    };

                    let dist = haversine_distance_m(n1_lat, n1_lng, n2_lat, n2_lng).max(1.0);

                    if is_forward_only {
                        self.add_edge(RoadEdge {
                            from: from_id,
                            to: to_id,
                            distance_m: dist,
                            speed_limit_kmh: speed,
                            road_type,
                            street_name: street_name.clone(),
                            is_motorcycle_allowed,
                        });
                        added_edges += 1;
                    } else if is_reverse_only {
                        self.add_edge(RoadEdge {
                            from: to_id,
                            to: from_id,
                            distance_m: dist,
                            speed_limit_kmh: speed,
                            road_type,
                            street_name: street_name.clone(),
                            is_motorcycle_allowed,
                        });
                        added_edges += 1;
                    } else {
                        self.add_bidirectional_edge(RoadEdge {
                            from: from_id,
                            to: to_id,
                            distance_m: dist,
                            speed_limit_kmh: speed,
                            road_type,
                            street_name: street_name.clone(),
                            is_motorcycle_allowed,
                        });
                        added_edges += 2;
                    }
                }
            }
        }

        Ok(added_edges)
    }

    /// Serializes graph into `.dbnav` binary format using `bincode`.
    pub fn save_to_file<P: AsRef<Path>>(&self, path: P) -> Result<(), Box<dyn std::error::Error>> {
        let bytes = bincode::serialize(self)?;
        let mut file = File::create(path)?;
        file.write_all(&bytes)?;
        Ok(())
    }

    /// Deserializes `.dbnav` binary format using zero-copy memory mapping (`memmap2`) and `bincode`.
    pub fn load_from_file<P: AsRef<Path>>(path: P) -> Result<Self, Box<dyn std::error::Error>> {
        let file = File::open(path)?;
        let mmap = unsafe { memmap2::Mmap::map(&file)? };
        let graph: RoadGraph = bincode::deserialize(&mmap[..])?;
        Ok(graph)
    }

    /// Built-in urban road networks for Ho Chi Minh City and Hanoi arterial corridors.
    pub fn default_urban_network() -> Self {
        let mut graph = Self::new();

        let add_bi = |g: &mut RoadGraph, from: u64, to: u64, road_type: RoadType, speed: f64, street: &str, mc_allowed: bool| {
            let n1 = match g.nodes.get(&from) {
                Some(n) => n,
                None => panic!("Node {} không tồn tại trong đồ thị", from),
            };
            let n2 = match g.nodes.get(&to) {
                Some(n) => n,
                None => panic!("Node {} không tồn tại trong đồ thị", to),
            };
            let dist = haversine_distance_m(n1.lat, n1.lng, n2.lat, n2.lng);
            g.add_bidirectional_edge(RoadEdge {
                from,
                to,
                distance_m: dist,
                speed_limit_kmh: speed,
                road_type,
                street_name: street.to_string(),
                is_motorcycle_allowed: mc_allowed,
            });
        };

        // ==================== TP. HỒ CHÍ MINH ====================
        // 1. Khu vực trung tâm (Quận 1)
        let hcm_d1_nodes = vec![
            RoadNode { id: 1, lat: 10.7725, lng: 106.6980, name: "Chợ Bến Thành".to_string() },
            RoadNode { id: 2, lat: 10.7738, lng: 106.6994, name: "Lê Lợi - NKKN".to_string() },
            RoadNode { id: 3, lat: 10.7749, lng: 106.7008, name: "Lê Lợi - Pasteur".to_string() },
            RoadNode { id: 4, lat: 10.7766, lng: 106.7032, name: "Nhà hát Thành phố".to_string() },
            RoadNode { id: 5, lat: 10.7774, lng: 106.7018, name: "UBND TP.HCM".to_string() },
            RoadNode { id: 6, lat: 10.7768, lng: 106.6998, name: "Pasteur - Lê Thánh Tôn".to_string() },
            RoadNode { id: 7, lat: 10.7758, lng: 106.6978, name: "Dinh Độc Lập".to_string() },
            RoadNode { id: 8, lat: 10.7750, lng: 106.7038, name: "Phố đi bộ Nguyễn Huệ".to_string() },
            RoadNode { id: 9, lat: 10.7735, lng: 106.7050, name: "Nguyễn Huệ - Mạc Thị Bưởi".to_string() },
            RoadNode { id: 10, lat: 10.7719, lng: 106.7065, name: "Bến Bạch Đằng".to_string() },
            RoadNode { id: 11, lat: 10.7710, lng: 106.6987, name: "Hàm Nghi - Chợ Bến Thành".to_string() },
            RoadNode { id: 12, lat: 10.7698, lng: 106.7015, name: "Hàm Nghi - NKKN".to_string() },
            RoadNode { id: 13, lat: 10.7686, lng: 106.7052, name: "Hàm Nghi - Tôn Đức Thắng".to_string() },
            RoadNode { id: 14, lat: 10.7728, lng: 106.7060, name: "Đồng Khởi - Tôn Đức Thắng".to_string() },
            RoadNode { id: 15, lat: 10.7890, lng: 106.7450, name: "Cao tốc Long Thành Nút Giao 1".to_string() },
            RoadNode { id: 16, lat: 10.7950, lng: 106.7650, name: "Cao tốc Long Thành Nút Giao 2".to_string() },
        ];

        for n in hcm_d1_nodes {
            graph.add_node(n);
        }

        // Đường Lê Lợi
        add_bi(&mut graph, 1, 2, RoadType::Primary, 45.0, "Đường Lê Lợi", true);
        add_bi(&mut graph, 2, 3, RoadType::Primary, 45.0, "Đường Lê Lợi", true);
        add_bi(&mut graph, 3, 4, RoadType::Primary, 45.0, "Đường Lê Lợi", true);

        // Đồng Khởi: 5 -> 4 -> 14
        add_bi(&mut graph, 5, 4, RoadType::Secondary, 35.0, "Đường Đồng Khởi", true);
        add_bi(&mut graph, 4, 14, RoadType::Secondary, 35.0, "Đường Đồng Khởi", true);

        // Lê Thánh Tôn: 7 -> 6 -> 5
        add_bi(&mut graph, 7, 6, RoadType::Secondary, 40.0, "Đường Lê Thánh Tôn", true);
        add_bi(&mut graph, 6, 5, RoadType::Secondary, 40.0, "Đường Lê Thánh Tôn", true);

        // Nam Kỳ Khởi Nghĩa: 7 -> 2 -> 12
        add_bi(&mut graph, 7, 2, RoadType::Primary, 45.0, "Đường Nam Kỳ Khởi Nghĩa", true);
        add_bi(&mut graph, 2, 12, RoadType::Primary, 45.0, "Đường Nam Kỳ Khởi Nghĩa", true);

        // Pasteur: 6 -> 3
        add_bi(&mut graph, 6, 3, RoadType::Secondary, 40.0, "Đường Pasteur", true);

        // Phố đi bộ Nguyễn Huệ: 4 -> 8 -> 9 -> 10
        add_bi(&mut graph, 4, 8, RoadType::Primary, 35.0, "Đường Nguyễn Huệ", true);
        add_bi(&mut graph, 8, 9, RoadType::Primary, 35.0, "Đường Nguyễn Huệ", true);
        add_bi(&mut graph, 9, 10, RoadType::Primary, 35.0, "Đường Nguyễn Huệ", true);

        // Hàm Nghi: 11 -> 12 -> 13
        add_bi(&mut graph, 1, 11, RoadType::Secondary, 35.0, "Đường Hàm Nghi", true);
        add_bi(&mut graph, 11, 12, RoadType::Primary, 50.0, "Đường Hàm Nghi", true);
        add_bi(&mut graph, 12, 13, RoadType::Primary, 50.0, "Đường Hàm Nghi", true);

        // Tôn Đức Thắng: 13 -> 10 -> 14
        add_bi(&mut graph, 13, 10, RoadType::Primary, 50.0, "Đường Tôn Đức Thắng", true);
        add_bi(&mut graph, 10, 14, RoadType::Primary, 50.0, "Đường Tôn Đức Thắng", true);

        // CAO TỐC (Motorway) cấm xe máy tuyệt đối
        add_bi(&mut graph, 15, 16, RoadType::Motorway, 100.0, "Đường Cao tốc Long Thành - Dầu Giây", false);

        // 2. Trục Trung tâm -> Tân Sơn Nhất (Phú Nhuận, Tân Bình)
        let hcm_tsn_nodes = vec![
            RoadNode { id: 101, lat: 10.7850, lng: 106.6900, name: "NKKN - Võ Thị Sáu".to_string() },
            RoadNode { id: 102, lat: 10.7915, lng: 106.6845, name: "Cầu Công Lý - Nhiêu Lộc".to_string() },
            RoadNode { id: 103, lat: 10.7960, lng: 106.6780, name: "Nguyễn Văn Trỗi - Huỳnh Văn Bánh".to_string() },
            RoadNode { id: 104, lat: 10.7995, lng: 106.6660, name: "Nguyễn Văn Trỗi - Hoàng Văn Thụ".to_string() },
            RoadNode { id: 105, lat: 10.8030, lng: 106.6635, name: "Công viên Hoàng Văn Thụ".to_string() },
            RoadNode { id: 106, lat: 10.8120, lng: 106.6610, name: "Đường Trường Sơn - Cổng TSN".to_string() },
            RoadNode { id: 107, lat: 10.8155, lng: 106.6580, name: "Ga Quốc nội Sân bay Tân Sơn Nhất".to_string() },
        ];
        for n in hcm_tsn_nodes {
            graph.add_node(n);
        }

        add_bi(&mut graph, 7, 101, RoadType::Primary, 45.0, "Đường Nam Kỳ Khởi Nghĩa", true);
        add_bi(&mut graph, 101, 102, RoadType::Primary, 45.0, "Đường Nam Kỳ Khởi Nghĩa", true);
        add_bi(&mut graph, 102, 103, RoadType::Primary, 50.0, "Đường Nguyễn Văn Trỗi", true);
        add_bi(&mut graph, 103, 104, RoadType::Primary, 50.0, "Đường Nguyễn Văn Trỗi", true);
        add_bi(&mut graph, 104, 105, RoadType::Primary, 45.0, "Đường Hoàng Văn Thụ", true);
        add_bi(&mut graph, 105, 106, RoadType::Primary, 45.0, "Đường Trường Sơn", true);
        add_bi(&mut graph, 106, 107, RoadType::Primary, 35.0, "Đường vào Ga Sân bay Tân Sơn Nhất", true);

        // 3. Trục Điện Biên Phủ - Cầu Sài Gòn - Xa Lộ Hà Nội - Suối Tiên (Bình Thạnh, TP. Thủ Đức)
        let hcm_xlhn_nodes = vec![
            RoadNode { id: 110, lat: 10.7865, lng: 106.6965, name: "Hai Bà Trưng - Điện Biên Phủ".to_string() },
            RoadNode { id: 111, lat: 10.8015, lng: 106.7115, name: "Vòng xoay Hàng Xanh".to_string() },
            RoadNode { id: 112, lat: 10.7985, lng: 106.7260, name: "Cầu Sài Gòn".to_string() },
            RoadNode { id: 113, lat: 10.8030, lng: 106.7350, name: "Xa Lộ Hà Nội - Thảo Điền".to_string() },
            RoadNode { id: 114, lat: 10.8160, lng: 106.7550, name: "Xa Lộ Hà Nội - Rạch Chiếc".to_string() },
            RoadNode { id: 115, lat: 10.8280, lng: 106.7680, name: "Ngã tư Bình Thái".to_string() },
            RoadNode { id: 116, lat: 10.8480, lng: 106.7725, name: "Ngã tư Thủ Đức".to_string() },
            RoadNode { id: 117, lat: 10.8580, lng: 106.7850, name: "Khu Công nghệ Cao SHTP - Suối Tiên".to_string() },
        ];
        for n in hcm_xlhn_nodes {
            graph.add_node(n);
        }

        add_bi(&mut graph, 7, 110, RoadType::Primary, 40.0, "Đường Hai Bà Trưng", true);
        add_bi(&mut graph, 14, 110, RoadType::Primary, 40.0, "Đường Đinh Tiên Hoàng", true);
        add_bi(&mut graph, 110, 111, RoadType::Primary, 50.0, "Đường Điện Biên Phủ", true);
        add_bi(&mut graph, 111, 112, RoadType::Primary, 50.0, "Đường Điện Biên Phủ", true);
        add_bi(&mut graph, 112, 113, RoadType::Primary, 50.0, "Xa Lộ Hà Nội - Làn xe máy", true);
        add_bi(&mut graph, 113, 114, RoadType::Primary, 50.0, "Xa Lộ Hà Nội", true);
        add_bi(&mut graph, 114, 115, RoadType::Primary, 50.0, "Xa Lộ Hà Nội", true);
        add_bi(&mut graph, 115, 116, RoadType::Primary, 50.0, "Xa Lộ Hà Nội", true);
        add_bi(&mut graph, 116, 117, RoadType::Primary, 50.0, "Xa Lộ Hà Nội", true);

        // 4. Trục Cầu Ba Son - Đại lộ Mai Chí Thọ (Khu Đô thị Thủ Thiêm)
        let hcm_mct_nodes = vec![
            RoadNode { id: 120, lat: 10.7760, lng: 106.7110, name: "Cầu Ba Son (Thủ Thiêm 2)".to_string() },
            RoadNode { id: 121, lat: 10.7740, lng: 106.7210, name: "Mai Chí Thọ - Trần Bạch Đằng".to_string() },
            RoadNode { id: 122, lat: 10.7770, lng: 106.7310, name: "Mai Chí Thọ - Nguyễn Cơ Thạch".to_string() },
            RoadNode { id: 123, lat: 10.7850, lng: 106.7520, name: "Mai Chí Thọ - Đồng Văn Cống".to_string() },
            RoadNode { id: 124, lat: 10.7960, lng: 106.7560, name: "Nút giao An Phú - Mai Chí Thọ".to_string() },
        ];
        for n in hcm_mct_nodes {
            graph.add_node(n);
        }

        add_bi(&mut graph, 14, 120, RoadType::Primary, 50.0, "Cầu Ba Son", true);
        add_bi(&mut graph, 120, 121, RoadType::Primary, 50.0, "Đại lộ Mai Chí Thọ", true);
        add_bi(&mut graph, 121, 122, RoadType::Primary, 50.0, "Đại lộ Mai Chí Thọ", true);
        add_bi(&mut graph, 122, 123, RoadType::Primary, 50.0, "Đại lộ Mai Chí Thọ", true);
        add_bi(&mut graph, 123, 124, RoadType::Primary, 50.0, "Đại lộ Mai Chí Thọ", true);
        add_bi(&mut graph, 124, 114, RoadType::Secondary, 45.0, "Đường Song Hành Xa Lộ Hà Nội", true);

        // 5. Trục Đại lộ Võ Văn Kiệt (Quận 1, 5, 6, Bình Tân)
        let hcm_vvk_nodes = vec![
            RoadNode { id: 130, lat: 10.7650, lng: 106.7010, name: "Võ Văn Kiệt - Cầu Calmette".to_string() },
            RoadNode { id: 131, lat: 10.7600, lng: 106.6960, name: "Võ Văn Kiệt - Cầu Ông Lãnh".to_string() },
            RoadNode { id: 132, lat: 10.7480, lng: 106.6660, name: "Võ Văn Kiệt - Nguyễn Tri Phương".to_string() },
            RoadNode { id: 133, lat: 10.7440, lng: 106.6550, name: "Võ Văn Kiệt - Chợ Lớn".to_string() },
            RoadNode { id: 134, lat: 10.7380, lng: 106.6380, name: "Võ Văn Kiệt - Cầu Lò Gốm".to_string() },
            RoadNode { id: 135, lat: 10.7100, lng: 106.6000, name: "Võ Văn Kiệt - Nút giao QL1A An Lạc".to_string() },
        ];
        for n in hcm_vvk_nodes {
            graph.add_node(n);
        }

        add_bi(&mut graph, 1, 130, RoadType::Secondary, 35.0, "Đường Calmette", true);
        add_bi(&mut graph, 13, 130, RoadType::Primary, 50.0, "Đường Võ Văn Kiệt", true);
        add_bi(&mut graph, 130, 131, RoadType::Primary, 50.0, "Đại lộ Võ Văn Kiệt", true);
        add_bi(&mut graph, 131, 132, RoadType::Primary, 50.0, "Đại lộ Võ Văn Kiệt - Làn xe máy", true);
        add_bi(&mut graph, 132, 133, RoadType::Primary, 50.0, "Đại lộ Võ Văn Kiệt", true);
        add_bi(&mut graph, 133, 134, RoadType::Primary, 50.0, "Đại lộ Võ Văn Kiệt", true);
        add_bi(&mut graph, 134, 135, RoadType::Primary, 50.0, "Đại lộ Võ Văn Kiệt", true);

        // 6. Trục Đại lộ Phạm Văn Đồng & Quốc Lộ 13 (Gò Vấp, Bình Thạnh, Thủ Đức)
        let hcm_pvd_nodes = vec![
            RoadNode { id: 140, lat: 10.8180, lng: 106.6740, name: "Vòng xoay Công viên Gia Định".to_string() },
            RoadNode { id: 141, lat: 10.8220, lng: 106.6920, name: "Phạm Văn Đồng - Phan Văn Trị".to_string() },
            RoadNode { id: 142, lat: 10.8280, lng: 106.7110, name: "Phạm Văn Đồng - Cầu Bình Lợi".to_string() },
            RoadNode { id: 143, lat: 10.8320, lng: 106.7230, name: "Phạm Văn Đồng - Quốc Lộ 13".to_string() },
            RoadNode { id: 144, lat: 10.8360, lng: 106.7400, name: "Phạm Văn Đồng - Đường 20".to_string() },
            RoadNode { id: 145, lat: 10.8520, lng: 106.7580, name: "Phạm Văn Đồng - Ngã tư Linh Đông".to_string() },
            RoadNode { id: 146, lat: 10.8680, lng: 106.7620, name: "Nút giao Gò Dưa - Quốc Lộ 1A".to_string() },
        ];
        for n in hcm_pvd_nodes {
            graph.add_node(n);
        }

        add_bi(&mut graph, 106, 140, RoadType::Primary, 45.0, "Đường Bạch Đằng - Nối Phạm Văn Đồng", true);
        add_bi(&mut graph, 140, 141, RoadType::Primary, 50.0, "Đại lộ Phạm Văn Đồng", true);
        add_bi(&mut graph, 141, 142, RoadType::Primary, 50.0, "Đại lộ Phạm Văn Đồng", true);
        add_bi(&mut graph, 142, 143, RoadType::Primary, 50.0, "Đại lộ Phạm Văn Đồng", true);
        add_bi(&mut graph, 143, 144, RoadType::Primary, 50.0, "Đại lộ Phạm Văn Đồng", true);
        add_bi(&mut graph, 144, 145, RoadType::Primary, 50.0, "Đại lộ Phạm Văn Đồng", true);
        add_bi(&mut graph, 145, 146, RoadType::Primary, 50.0, "Đại lộ Phạm Văn Đồng", true);
        add_bi(&mut graph, 143, 111, RoadType::Primary, 45.0, "Quốc Lộ 13 - Cầu Bình Triệu về Hàng Xanh", true);
        add_bi(&mut graph, 145, 116, RoadType::Secondary, 40.0, "Đường Kha Vạn Cân - Tô Ngọc Vân về Ngã tư Thủ Đức", true);

        // 7. Trục Nam Sài Gòn (Nguyễn Hữu Thọ, Nguyễn Văn Linh, Quận 7)
        let hcm_nvl_nodes = vec![
            RoadNode { id: 150, lat: 10.7500, lng: 106.7020, name: "Cầu Kênh Tẻ - Nguyễn Hữu Thọ".to_string() },
            RoadNode { id: 151, lat: 10.7380, lng: 106.7010, name: "Nguyễn Hữu Thọ - Nguyễn Thị Thập".to_string() },
            RoadNode { id: 152, lat: 10.7310, lng: 106.7000, name: "Nguyễn Văn Linh - Nguyễn Hữu Thọ".to_string() },
            RoadNode { id: 153, lat: 10.7280, lng: 106.7180, name: "Nguyễn Văn Linh - Phú Mỹ Hưng".to_string() },
            RoadNode { id: 154, lat: 10.7420, lng: 106.7320, name: "Nguyễn Văn Linh - Cầu Tân Thuận".to_string() },
            RoadNode { id: 155, lat: 10.7180, lng: 106.6620, name: "Nguyễn Văn Linh - Quốc Lộ 50".to_string() },
        ];
        for n in hcm_nvl_nodes {
            graph.add_node(n);
        }

        add_bi(&mut graph, 131, 150, RoadType::Primary, 40.0, "Cầu Kênh Tẻ", true);
        add_bi(&mut graph, 150, 151, RoadType::Primary, 45.0, "Đường Nguyễn Hữu Thọ", true);
        add_bi(&mut graph, 151, 152, RoadType::Primary, 45.0, "Đường Nguyễn Hữu Thọ", true);
        add_bi(&mut graph, 152, 153, RoadType::Primary, 50.0, "Đại lộ Nguyễn Văn Linh", true);
        add_bi(&mut graph, 153, 154, RoadType::Primary, 50.0, "Đại lộ Nguyễn Văn Linh", true);
        add_bi(&mut graph, 154, 10, RoadType::Primary, 45.0, "Đường Huỳnh Tấn Phát - Cầu Khánh Hội về Bến Bạch Đằng", true);
        add_bi(&mut graph, 152, 155, RoadType::Primary, 50.0, "Đại lộ Nguyễn Văn Linh", true);

        // ==================== HÀ NỘI ====================
        let hn_nodes = vec![
            RoadNode { id: 21, lat: 21.0315, lng: 105.8524, name: "Quảng trường Đông Kinh Nghĩa Thục".to_string() },
            RoadNode { id: 22, lat: 21.0258, lng: 105.8550, name: "Đinh Tiên Hoàng - Tràng Tiền".to_string() },
            RoadNode { id: 23, lat: 21.0245, lng: 105.8576, name: "Nhà Hát Lớn Hà Nội".to_string() },
            RoadNode { id: 24, lat: 21.0286, lng: 105.8495, name: "Tràng Thi - Nhà Chung".to_string() },
            RoadNode { id: 25, lat: 21.0225, lng: 105.8510, name: "Bà Triệu - Lý Thường Kiệt".to_string() },
            RoadNode { id: 26, lat: 21.0050, lng: 105.7800, name: "Cao tốc Đại Lộ Thăng Long KM1".to_string() },
            RoadNode { id: 27, lat: 21.0010, lng: 105.7500, name: "Cao tốc Đại Lộ Thăng Long KM5".to_string() },
            // Trục Cửa Nam - Kim Mã - Cầu Giấy
            RoadNode { id: 201, lat: 21.0275, lng: 105.8420, name: "Tràng Thi - Cửa Nam".to_string() },
            RoadNode { id: 202, lat: 21.0285, lng: 105.8350, name: "Nguyễn Thái Học - Văn Miếu".to_string() },
            RoadNode { id: 203, lat: 21.0310, lng: 105.8130, name: "Kim Mã - Liễu Giai".to_string() },
            RoadNode { id: 204, lat: 21.0325, lng: 105.8010, name: "Cầu Giấy - Đường Láng".to_string() },
            RoadNode { id: 205, lat: 21.0365, lng: 105.7820, name: "Xuân Thủy - ĐHQG Hà Nội".to_string() },
            RoadNode { id: 206, lat: 21.0400, lng: 105.7650, name: "Hồ Tùng Mậu - Cầu Diễn".to_string() },
            RoadNode { id: 207, lat: 21.0460, lng: 105.7830, name: "Phạm Văn Đồng - Hoàng Quốc Việt".to_string() },
            RoadNode { id: 208, lat: 21.0080, lng: 105.7860, name: "Phạm Hùng - Trung tâm Hội nghị Quốc gia".to_string() },
            // Trục Lê Duẩn - Giải Phóng (Hai Bà Trưng, Hoàng Mai)
            RoadNode { id: 209, lat: 21.0235, lng: 105.8410, name: "Lê Duẩn - Ga Hà Nội".to_string() },
            RoadNode { id: 210, lat: 21.0090, lng: 105.8415, name: "Giải Phóng - Hầm Kim Liên".to_string() },
            RoadNode { id: 211, lat: 20.9850, lng: 105.8420, name: "Giải Phóng - Bến xe Giáp Bát".to_string() },
            // Trục Tôn Đức Thắng - Tây Sơn - Nguyễn Trãi (Đống Đa, Thanh Xuân, Hà Đông)
            RoadNode { id: 212, lat: 21.0020, lng: 105.8200, name: "Tây Sơn - Ngã Tư Sở".to_string() },
            RoadNode { id: 213, lat: 20.9920, lng: 105.7980, name: "Nguyễn Trãi - Đại học Hà Nội".to_string() },
            RoadNode { id: 214, lat: 20.9650, lng: 105.7600, name: "Nguyễn Trãi - Bến xe Yên Nghĩa (Hà Đông)".to_string() },
        ];

        for n in hn_nodes {
            graph.add_node(n);
        }

        add_bi(&mut graph, 21, 22, RoadType::Primary, 35.0, "Đường Đinh Tiên Hoàng", true);
        add_bi(&mut graph, 22, 23, RoadType::Primary, 40.0, "Phố Tràng Tiền", true);
        add_bi(&mut graph, 21, 24, RoadType::Secondary, 35.0, "Phố Tràng Thi", true);
        add_bi(&mut graph, 22, 25, RoadType::Primary, 40.0, "Phố Hàng Bài - Bà Triệu", true);

        // Cao tốc Đại lộ Thăng Long - Cấm xe máy
        add_bi(&mut graph, 26, 27, RoadType::Motorway, 100.0, "Đại lộ Thăng Long Làn Cao Tốc", false);

        // Trục Cửa Nam - Kim Mã - Cầu Giấy
        add_bi(&mut graph, 24, 201, RoadType::Primary, 40.0, "Phố Tràng Thi - Cửa Nam", true);
        add_bi(&mut graph, 201, 202, RoadType::Primary, 40.0, "Đường Nguyễn Thái Học", true);
        add_bi(&mut graph, 202, 203, RoadType::Primary, 45.0, "Đường Kim Mã", true);
        add_bi(&mut graph, 203, 204, RoadType::Primary, 45.0, "Đường Cầu Giấy", true);
        add_bi(&mut graph, 204, 205, RoadType::Primary, 45.0, "Đường Xuân Thủy", true);
        add_bi(&mut graph, 205, 206, RoadType::Primary, 45.0, "Đường Hồ Tùng Mậu", true);
        add_bi(&mut graph, 205, 207, RoadType::Primary, 50.0, "Đường Phạm Văn Đồng (Làn xe máy)", true);
        add_bi(&mut graph, 205, 208, RoadType::Primary, 50.0, "Đường Phạm Hùng (Vành đai 3 gom)", true);

        // Trục Lê Duẩn - Giải Phóng
        add_bi(&mut graph, 201, 209, RoadType::Primary, 40.0, "Phố Lê Duẩn", true);
        add_bi(&mut graph, 209, 210, RoadType::Primary, 45.0, "Đường Giải Phóng", true);
        add_bi(&mut graph, 210, 211, RoadType::Primary, 50.0, "Đường Giải Phóng", true);

        // Trục Tây Sơn - Nguyễn Trãi
        add_bi(&mut graph, 202, 212, RoadType::Primary, 40.0, "Phố Tôn Đức Thắng - Tây Sơn", true);
        add_bi(&mut graph, 212, 213, RoadType::Primary, 45.0, "Đường Nguyễn Trãi", true);
        add_bi(&mut graph, 213, 214, RoadType::Primary, 50.0, "Đường Nguyễn Trãi", true);
        add_bi(&mut graph, 204, 212, RoadType::Primary, 45.0, "Đường Láng (Vành đai 2)", true);
        add_bi(&mut graph, 208, 213, RoadType::Primary, 45.0, "Đường Khuất Duy Tiến (Vành đai 3 gom)", true);

        graph
    }
}
