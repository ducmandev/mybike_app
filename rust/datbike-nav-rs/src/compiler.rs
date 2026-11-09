use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::Write;
use std::path::Path;
use std::time::Instant;

use osmpbf::{Element, ElementReader};
use serde::{Deserialize, Serialize};

use crate::graph::{
    clean_map_label, haversine_distance_m, RoadEdge, RoadGraph, RoadNode, RoadType,
};

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct BoundingBox {
    pub min_lat: f64,
    pub max_lat: f64,
    pub min_lng: f64,
    pub max_lng: f64,
}

impl BoundingBox {
    pub fn hcmc() -> Self {
        Self {
            min_lat: 10.35,
            max_lat: 11.15,
            min_lng: 106.35,
            max_lng: 107.05,
        }
    }

    pub fn vietnam() -> Self {
        Self {
            min_lat: 8.0,
            max_lat: 24.0,
            min_lng: 102.0,
            max_lng: 110.0,
        }
    }

    #[inline]
    pub fn contains(&self, lat: f64, lng: f64) -> bool {
        lat >= self.min_lat && lat <= self.max_lat && lng >= self.min_lng && lng <= self.max_lng
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AddressEntry {
    pub housenumber: String,
    pub street: String,
    pub name: Option<String>,
    pub lat: f64,
    pub lng: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OfflineMapPackage {
    pub version: u32,
    pub area_name: String,
    pub bbox: BoundingBox,
    pub total_nodes: usize,
    pub total_edges: usize,
    pub total_addresses: usize,
    pub graph: RoadGraph,
    pub addresses: Vec<AddressEntry>,
}

impl OfflineMapPackage {
    pub fn save_to_file<P: AsRef<Path>>(&self, path: P) -> Result<(), Box<dyn std::error::Error>> {
        let bytes = bincode::serialize(self)?;
        let mut file = File::create(path)?;
        file.write_all(&bytes)?;
        Ok(())
    }

    pub fn load_from_file<P: AsRef<Path>>(path: P) -> Result<Self, Box<dyn std::error::Error>> {
        let file = File::open(path)?;
        let mmap = unsafe { memmap2::Mmap::map(&file)? };
        let pkg: OfflineMapPackage = bincode::deserialize(&mmap[..])?;
        Ok(pkg)
    }
}

struct TempWay {
    id: i64,
    refs: Vec<i64>,
    street_name: String,
    road_type: RoadType,
    speed_limit: f64,
    is_motorcycle_allowed: bool,
    is_forward_only: bool,
    is_reverse_only: bool,
}

fn parse_road_type(val: &str) -> Option<RoadType> {
    match val {
        "motorway" | "motorway_link" => Some(RoadType::Motorway),
        "trunk" | "trunk_link" => Some(RoadType::Trunk),
        "primary" | "primary_link" => Some(RoadType::Primary),
        "secondary" | "secondary_link" => Some(RoadType::Secondary),
        "tertiary" | "tertiary_link" => Some(RoadType::Tertiary),
        "residential" | "living_street" => Some(RoadType::Residential),
        "service" | "unclassified" | "track" | "cycleway" => Some(RoadType::Service),
        _ => None,
    }
}

fn default_speed(rt: RoadType) -> f64 {
    match rt {
        RoadType::Motorway => 60.0,
        RoadType::Trunk => 50.0,
        RoadType::Primary => 50.0,
        RoadType::Secondary => 40.0,
        RoadType::Tertiary => 35.0,
        RoadType::Residential => 30.0,
        RoadType::Service => 20.0,
    }
}

pub fn compile_pbf_to_dbnav<P: AsRef<Path>, Q: AsRef<Path>>(
    pbf_path: P,
    out_path: Q,
    bbox: Option<BoundingBox>,
    area_name: &str,
) -> Result<OfflineMapPackage, Box<dyn std::error::Error>> {
    let start_all = Instant::now();
    println!("=== BAT DAU BIEN DICH BAN DO OFFLINE DAT BIKE ===");
    println!("File nguon: {:?}", pbf_path.as_ref());
    println!("File dich:   {:?}", out_path.as_ref());
    println!("Khu vuc:    {}", area_name);
    if let Some(b) = bbox {
        println!("Bounding box: Lat [{:.4} .. {:.4}], Lng [{:.4} .. {:.4}]", b.min_lat, b.max_lat, b.min_lng, b.max_lng);
    }

    // PASS 1: Doc cac Way (duong di) de loc duong xe may chay duoc
    println!("\n[Pass 1/3] Quet toan bo mang luoi tuyen duong xe may...");
    let p1_start = Instant::now();
    let reader1 = ElementReader::from_path(pbf_path.as_ref())?;

    let mut drivable_ways = Vec::new();
    let mut needed_node_ids = HashSet::new();
    let mut address_ways = Vec::new();

    reader1.for_each(|element| {
        if let Element::Way(way) = element {
            let mut highway_val = None;
            let mut name_val = None;
            let mut maxspeed_val = None;
            let mut oneway_val = None;
            let mut oneway_mc_val = None;
            let mut motorcycle_val = None;
            let mut access_val = None;
            let mut motor_vehicle_val = None;
            let mut junction_val = None;

            let mut housenumber_val = None;
            let mut street_val = None;
            let mut building_val = None;

            for (k, v) in way.tags() {
                match k {
                    "highway" => highway_val = Some(v),
                    "name:vi" | "name" if name_val.is_none() => name_val = Some(v),
                    "maxspeed" => maxspeed_val = Some(v),
                    "oneway" => oneway_val = Some(v),
                    "oneway:motorcycle" | "motorcycle:oneway" => oneway_mc_val = Some(v),
                    "motorcycle" => motorcycle_val = Some(v),
                    "access" => access_val = Some(v),
                    "motor_vehicle" => motor_vehicle_val = Some(v),
                    "junction" => junction_val = Some(v),
                    "addr:housenumber" => housenumber_val = Some(v),
                    "addr:street" => street_val = Some(v),
                    "building" => building_val = Some(v),
                    _ => {}
                }
            }

            // Kiem tra nha / dia chi tren khoi nha (building way)
            if (housenumber_val.is_some() || name_val.is_some()) && (building_val.is_some() || street_val.is_some()) {
                let refs: Vec<i64> = way.refs().collect();
                if !refs.is_empty() {
                    address_ways.push((
                        housenumber_val.unwrap_or("").to_string(),
                        street_val.unwrap_or("").to_string(),
                        name_val.map(|s| s.to_string()),
                        refs[0], // Lay node goc lam moc toa do
                    ));
                    needed_node_ids.insert(refs[0]);
                }
            }

            // Kiem tra duong xe may
            if let Some(hw) = highway_val {
                if let Some(rt) = parse_road_type(hw) {
                    if access_val == Some("private") || access_val == Some("no") {
                        return;
                    }
                    if motor_vehicle_val == Some("no") || motorcycle_val == Some("no") {
                        return;
                    }

                    let is_mc_allowed = if rt == RoadType::Motorway {
                        motorcycle_val == Some("yes")
                    } else {
                        true
                    };

                    let speed = maxspeed_val
                        .and_then(|s| s.split_whitespace().next()?.parse::<f64>().ok())
                        .unwrap_or_else(|| default_speed(rt));

                    let raw_name = name_val.unwrap_or("Đường nội bộ");
                    let cleaned = clean_map_label(raw_name, true);
                    let street_name = if cleaned.is_empty() { "Đường nội bộ".to_string() } else { cleaned };

                    let is_roundabout = junction_val.map_or(false, |j| j == "roundabout" || j == "circular");

                    let (is_forward_only, is_reverse_only) = if oneway_mc_val == Some("no") || oneway_mc_val == Some("false") {
                        (false, false)
                    } else if oneway_mc_val == Some("yes") {
                        (true, false)
                    } else if oneway_val == Some("-1") {
                        (false, true)
                    } else if oneway_val == Some("yes") || oneway_val == Some("1") || is_roundabout {
                        (true, false)
                    } else {
                        (false, false)
                    };

                    let refs: Vec<i64> = way.refs().collect();
                    for &r in &refs {
                        needed_node_ids.insert(r);
                    }

                    drivable_ways.push(TempWay {
                        id: way.id(),
                        refs,
                        street_name,
                        road_type: rt,
                        speed_limit: speed,
                        is_motorcycle_allowed: is_mc_allowed,
                        is_forward_only,
                        is_reverse_only,
                    });
                }
            }
        }
    })?;

    println!(
        "Pass 1 hoan thanh trong {:.2}s. Tim thay {} tuyen duong xe may va {} toa do node can trich xuat.",
        p1_start.elapsed().as_secs_f64(),
        drivable_ways.len(),
        needed_node_ids.len()
    );

    // PASS 2: Doc cac Node de lay toa do GPS va so nha
    println!("\n[Pass 2/3] Trich xuat toa do GPS va danh muc so nha/dia chi...");
    let p2_start = Instant::now();
    let reader2 = ElementReader::from_path(pbf_path.as_ref())?;

    let mut node_coords: HashMap<i64, (f64, f64, String)> = HashMap::with_capacity(needed_node_ids.len());
    let mut address_list: Vec<AddressEntry> = Vec::new();

    reader2.for_each(|element| {
        match element {
            Element::DenseNode(dense) => {
                let id = dense.id;
                let lat = dense.lat();
                let lon = dense.lon();

                let in_bounds = bbox.map_or(true, |b| b.contains(lat, lon));

                if in_bounds && needed_node_ids.contains(&id) {
                    node_coords.insert(id, (lat, lon, String::new()));
                }

                // Kiem tra the dia chi tren node
                let mut housenumber_val = None;
                let mut street_val = None;
                let mut name_val = None;

                for (k, v) in dense.tags() {
                    match k {
                        "addr:housenumber" => housenumber_val = Some(v),
                        "addr:street" => street_val = Some(v),
                        "name:vi" | "name" if name_val.is_none() => name_val = Some(v),
                        _ => {}
                    }
                }

                if in_bounds && (housenumber_val.is_some() || name_val.is_some()) {
                    address_list.push(AddressEntry {
                        housenumber: housenumber_val.unwrap_or("").to_string(),
                        street: street_val.unwrap_or("").to_string(),
                        name: name_val.map(|s| s.to_string()),
                        lat,
                        lng: lon,
                    });
                }
            }
            Element::Node(node) => {
                let id = node.id();
                let lat = node.lat();
                let lon = node.lon();

                let in_bounds = bbox.map_or(true, |b| b.contains(lat, lon));

                if in_bounds && needed_node_ids.contains(&id) {
                    node_coords.insert(id, (lat, lon, String::new()));
                }
            }
            _ => {}
        }
    })?;

    // Bo sung cac dia chi tu khoi nha (building way) co toa do node
    for (hn, st, nm, nid) in address_ways {
        if let Some(&(lat, lon, _)) = node_coords.get(&nid) {
            address_list.push(AddressEntry {
                housenumber: hn,
                street: st,
                name: nm,
                lat,
                lng: lon,
            });
        }
    }

    println!(
        "Pass 2 hoan thanh trong {:.2}s. Da nhat duoc {} node hop le va {} dia chi/so nha.",
        p2_start.elapsed().as_secs_f64(),
        node_coords.len(),
        address_list.len()
    );

    // PASS 3: Xay dung do thi RoadGraph va Spatial Grid Index
    println!("\n[Pass 3/3] Xay dung do thi duong bo va Spatial Grid Index...");
    let p3_start = Instant::now();
    let mut graph = RoadGraph::new();

    let mut added_nodes = 0;
    let mut added_edges = 0;

    for way in &drivable_ways {
        let valid_nodes: Vec<i64> = way
            .refs
            .iter()
            .copied()
            .filter(|id| node_coords.contains_key(id))
            .collect();

        if valid_nodes.len() < 2 {
            continue;
        }

        // Them cac node vao do thi
        for &nid in &valid_nodes {
            let uid = nid as u64;
            if !graph.nodes.contains_key(&uid) {
                let (lat, lng, _) = node_coords[&nid];
                graph.add_node(RoadNode {
                    id: uid,
                    lat,
                    lng,
                    name: format!("Node {}", uid),
                });
                added_nodes += 1;
            }
        }

        // Them cac canh noi tiep
        for i in 0..(valid_nodes.len() - 1) {
            let u = valid_nodes[i] as u64;
            let v = valid_nodes[i + 1] as u64;

            let n1 = &graph.nodes[&u];
            let n2 = &graph.nodes[&v];
            let dist = haversine_distance_m(n1.lat, n1.lng, n2.lat, n2.lng);

            if !way.is_reverse_only {
                graph.add_edge(RoadEdge {
                    from: u,
                    to: v,
                    distance_m: dist.max(0.5),
                    speed_limit_kmh: way.speed_limit,
                    road_type: way.road_type,
                    street_name: way.street_name.clone(),
                    is_motorcycle_allowed: way.is_motorcycle_allowed,
                });
                added_edges += 1;
            }

            if !way.is_forward_only {
                graph.add_edge(RoadEdge {
                    from: v,
                    to: u,
                    distance_m: dist.max(0.5),
                    speed_limit_kmh: way.speed_limit,
                    road_type: way.road_type,
                    street_name: way.street_name.clone(),
                    is_motorcycle_allowed: way.is_motorcycle_allowed,
                });
                added_edges += 1;
            }
        }
    }

    // Xay dung Spatial Grid Index
    graph.build_spatial_index();

    println!(
        "Pass 3 hoan thanh trong {:.2}s. Do thi: {} nodes, {} edges (chieu di chuyen).",
        p3_start.elapsed().as_secs_f64(),
        added_nodes,
        added_edges
    );

    let pkg = OfflineMapPackage {
        version: 1,
        area_name: area_name.to_string(),
        bbox: bbox.unwrap_or_else(BoundingBox::vietnam),
        total_nodes: added_nodes,
        total_edges: added_edges,
        total_addresses: address_list.len(),
        graph,
        addresses: address_list,
    };

    println!("\nDang ghi ra file nhi phan: {:?}...", out_path.as_ref());
    let write_start = Instant::now();
    pkg.save_to_file(out_path.as_ref())?;
    let file_size_mb = std::fs::metadata(out_path.as_ref())?.len() as f64 / (1024.0 * 1024.0);

    println!(
        "GHI FILE THANH CONG! Kich thuoc: {:.2} MB (Thoi gian ghi: {:.2}s)",
        file_size_mb,
        write_start.elapsed().as_secs_f64()
    );
    println!("TONG THOI GIAN BIEN DICH: {:.2}s", start_all.elapsed().as_secs_f64());
    println!("=== HOAN TAT DONG GOI OFFLINE MAP ===");

    Ok(pkg)
}
