pub mod compiler;
pub mod ev_range;
pub mod ffi;
pub mod graph;
pub mod navigator;
pub mod router;

pub use ev_range::{calculate_ev_forecast, EvForecast};
pub use ffi::{
    datbike_nav_calculate_route_json, datbike_nav_clean_osm_label, datbike_nav_free_string,
    datbike_nav_track_step_json,
};
pub use graph::{clean_map_label, haversine_distance_m, RoadEdge, RoadGraph, RoadNode, RoadType};
pub use navigator::{track_position, TrackingResult};
pub use router::{astar_route_multi, calculate_route, RouteResult, RouteStep};
pub use compiler::{compile_pbf_to_dbnav, AddressEntry, BoundingBox, OfflineMapPackage};

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::{CStr, CString};

    #[test]
    fn test_graph_and_dbnav_binary_serialization() {
        let graph = RoadGraph::default_urban_network();
        assert!(!graph.nodes.is_empty());
        assert!(!graph.adjacency.is_empty());

        let temp_dir = std::env::temp_dir();
        let dbnav_path = temp_dir.join("test_network.dbnav");

        // Test save to .dbnav
        graph.save_to_file(&dbnav_path).expect("Failed to save .dbnav file");
        assert!(dbnav_path.exists());

        // Test load from .dbnav with memmap2
        let loaded_graph = RoadGraph::load_from_file(&dbnav_path).expect("Failed to load .dbnav file");
        assert_eq!(graph.nodes.len(), loaded_graph.nodes.len());
        assert_eq!(graph.adjacency.len(), loaded_graph.adjacency.len());

        let _ = std::fs::remove_file(dbnav_path);
    }

    #[test]
    fn test_clean_map_label_admin_and_country_stripping() {
        // 1. With minimal = true: strip country, postal codes, and granular admin prefixes
        let raw1 = "12, Đường Lê Lợi, Phường Bến Nghé, Quận 1, 700000, Việt Nam";
        let cleaned1 = clean_map_label(raw1, true);
        assert_eq!(cleaned1, "12, Đường Lê Lợi, Quận 1");

        // 2. With minimal = false: keep administrative levels, only strip country and postal code
        let cleaned1_full = clean_map_label(raw1, false);
        assert_eq!(cleaned1_full, "12, Đường Lê Lợi, Phường Bến Nghé, Quận 1");

        // 3. Multi-level admin prefixes (Khu phố, Tổ dân phố, Ấp, Xã)
        let raw2 = "Khu phố 3, Tổ dân phố 12, Ấp 4, Xã Bình Hưng, Huyện Bình Chánh, 71800, Vietnam";
        let cleaned2 = clean_map_label(raw2, true);
        assert_eq!(cleaned2, "Huyện Bình Chánh");

        let raw_rural = "Khóm 3, Thôn 5, Xã Hòa Phú, Đắk Lắk";
        let cleaned_rural = clean_map_label(raw_rural, true);
        assert_eq!(cleaned_rural, "Đắk Lắk");

        let cleaned_rural_detailed = clean_map_label(raw_rural, false);
        assert_eq!(cleaned_rural_detailed, "Khóm 3, Thôn 5, Xã Hòa Phú, Đắk Lắk");

        // 4. Edge case: only administrative info, fallback to first non-empty
        let raw3 = "Phường Bến Thành, Việt Nam";
        let cleaned3 = clean_map_label(raw3, true);
        assert_eq!(cleaned3, "Phường Bến Thành");

        // 5. Empty string
        assert_eq!(clean_map_label("", true), "");
        assert_eq!(clean_map_label("   ", false), "");
    }

    #[test]
    fn test_osm_overpass_json_ingestion_and_routing() {
        let mut graph = RoadGraph::new();

        // Node 1001 -> 1002: Lê Lợi (Primary, oneway = yes)
        // Node 1002 -> 1003: Cao tốc (Motorway, CẤM XE MÁY)
        // Node 1002 <-> 1004 <-> 1005: Pasteur (Secondary, 2 chiều)
        // Node 9999: Isolated node with no edges
        let osm_json = r#"{
            "elements": [
                {"type": "node", "id": 1001, "lat": 10.7725, "lon": 106.6980, "tags": {"name": "Ngã tư Bến Thành"}},
                {"type": "node", "id": 1002, "lat": 10.7738, "lon": 106.6994},
                {"type": "node", "id": 1003, "lat": 10.7780, "lon": 106.7050},
                {"type": "node", "id": 1004, "lat": 10.7750, "lon": 106.7000},
                {"type": "node", "id": 1005, "lat": 10.7766, "lon": 106.7010},
                {"type": "node", "id": 9999, "lat": 10.7720, "lon": 106.6975},
                {
                    "type": "way",
                    "id": 5001,
                    "nodes": [1001, 1002],
                    "tags": {
                        "highway": "primary",
                        "name": "Đường Lê Lợi, Phường Bến Nghé",
                        "oneway": "yes",
                        "maxspeed": "45"
                    }
                },
                {
                    "type": "way",
                    "id": 5002,
                    "nodes": [1002, 1003],
                    "tags": {
                        "highway": "motorway",
                        "name": "Đường Cao tốc Đô thị"
                    }
                },
                {
                    "type": "way",
                    "id": 5003,
                    "nodes": [1002, 1004, 1005],
                    "tags": {
                        "highway": "secondary",
                        "name": "Đường Pasteur",
                        "oneway": "no",
                        "maxspeed": "40 km/h"
                    }
                }
            ]
        }"#;

        let added_edges = graph
            .ingest_osm_overpass_json(osm_json, true)
            .expect("Ingesting OSM JSON must succeed");
        assert!(added_edges >= 4);

        // 1. Verify node name cleaned
        assert_eq!(graph.nodes[&1001].name, "Ngã tư Bến Thành");

        // 2. Verify oneway = yes (1001 -> 1002 exists, but 1002 -> 1001 does not)
        let edges_1001 = &graph.adjacency[&1001];
        assert!(edges_1001.iter().any(|e| e.to == 1002));
        assert_eq!(edges_1001[0].street_name, "Đường Lê Lợi"); // Stripped "Phường Bến Nghé"
        assert_eq!(edges_1001[0].speed_limit_kmh, 45.0);

        let edges_1002 = &graph.adjacency[&1002];
        assert!(!edges_1002.iter().any(|e| e.to == 1001)); // One-way respected!

        // 3. Verify motorway is marked is_motorcycle_allowed = false
        let motorway_edge = edges_1002.iter().find(|e| e.to == 1003).unwrap();
        assert!(!motorway_edge.is_motorcycle_allowed);
        assert_eq!(motorway_edge.road_type, RoadType::Motorway);

        // 4. Verify find_nearest_nodes ignores isolated node 9999 (which has no valid outgoing motorcycle edge)
        let candidates = graph.find_nearest_nodes(10.7720, 106.6975, 500.0, 5);
        assert!(!candidates.is_empty());
        assert!(!candidates.iter().any(|&(id, _)| id == 9999));
        assert_eq!(candidates[0].0, 1001);

        // 5. Calculate route from 1001 to 1005: A* must avoid motorway 1003 and take Pasteur (1001 -> 1002 -> 1004 -> 1005)
        let route = router::calculate_route(&graph, 10.7725, 106.6980, 10.7766, 106.7010, false)
            .expect("Routing on ingested OSM graph must succeed");

        assert_eq!(route.polyline.len(), 4);
        assert_eq!(route.polyline[0], [10.7725, 106.6980]); // Node 1001
        assert_eq!(route.polyline[1], [10.7738, 106.6994]); // Node 1002
        assert_eq!(route.polyline[2], [10.7750, 106.7000]); // Node 1004
        assert_eq!(route.polyline[3], [10.7766, 106.7010]); // Node 1005
    }

    #[test]
    fn test_dynamic_corridor_ingestion() {
        let mut graph = RoadGraph::default_urban_network();
        let initial_node_count = graph.nodes.len();

        let corridor = vec![
            [10.7710, 106.7020],
            [10.7715, 106.7025],
            [10.7720, 106.7030],
        ];

        let added_nodes = graph.ingest_corridor(&corridor, Some("Đường Hoa Nguyễn Huệ"), Some(30.0));
        assert_eq!(added_nodes.len(), 3);
        assert_eq!(graph.nodes.len(), initial_node_count + 3);
        assert_eq!(graph.corridor_start_id, Some(1_000_000));
        assert_eq!(graph.corridor_end_id, Some(1_000_002));

        // Verify corridor connectivity
        let n1_adj = &graph.adjacency[&added_nodes[0]];
        assert!(n1_adj.iter().any(|e| e.to == added_nodes[1]));

        // Verify corridor nodes are NEVER connected to default District 1 nodes (< 1_000_000)
        for &nid in &added_nodes {
            if let Some(edges) = graph.adjacency.get(&nid) {
                for edge in edges {
                    assert!(
                        edge.to >= 1_000_000,
                        "Corridor node {} must not connect to default node {}",
                        nid,
                        edge.to
                    );
                }
            }
        }
    }

    #[test]
    fn test_corridor_routing_outside_d1_no_bird_flight() {
        let mut graph = RoadGraph::default_urban_network();

        // Corridor waypoints in Thu Duc (far away from District 1)
        let corridor = vec![
            [10.8500, 106.7700],
            [10.8520, 106.7720],
            [10.8550, 106.7750],
        ];

        graph.ingest_corridor(&corridor, Some("Võ Văn Ngân"), Some(40.0));

        let route = router::calculate_route(
            &graph,
            10.8500,
            106.7700,
            10.8550,
            106.7750,
            false,
        )
        .expect("Route calculation for corridor must succeed");

        // The polyline must match the corridor points exactly and NOT jump to District 1
        assert_eq!(route.polyline.len(), 3);
        assert_eq!(route.polyline[0], [10.8500, 106.7700]);
        assert_eq!(route.polyline[1], [10.8520, 106.7720]);
        assert_eq!(route.polyline[2], [10.8550, 106.7750]);

        // Total distance must be reasonable (~800m), NOT ~15km bird flight across the city!
        assert!(route.distance_m < 1500.0);
    }

    #[test]
    fn test_offline_routing_outside_coverage_returns_error() {
        let graph = RoadGraph::default_urban_network();

        // Remote area > 5km away from any urban arterial network
        let res = router::calculate_route(
            &graph,
            10.4100,
            107.0500,
            10.4200,
            107.0600,
            false,
        );

        assert!(res.is_err());
        assert_eq!(
            res.unwrap_err(),
            "Khu vực này cần kết nối mạng để tải dữ liệu đường bộ chi tiết"
        );
    }

    #[test]
    fn test_arterial_route_ben_thanh_to_tan_son_nhat() {
        let graph = RoadGraph::default_urban_network();

        // Bến Thành (Quận 1) -> Sân bay Tân Sơn Nhất (Tân Bình)
        let route = router::calculate_route(
            &graph,
            10.7725,
            106.6980,
            10.8155,
            106.6580,
            false,
        )
        .expect("Tuyến đường từ Bến Thành đi Sân bay Tân Sơn Nhất phải thành công");

        assert!(route.distance_m > 4000.0);
        assert!(route.polyline.len() >= 6);
        assert!(route.steps.iter().any(|s| s.street_name.contains("Nguyễn Văn Trỗi") || s.street_name.contains("Trường Sơn")));
    }

    #[test]
    fn test_arterial_route_ben_thanh_to_thu_duc() {
        let graph = RoadGraph::default_urban_network();

        // Bến Thành (Quận 1) -> Ngã tư Thủ Đức (TP. Thủ Đức qua Xa Lộ Hà Nội)
        let route = router::calculate_route(
            &graph,
            10.7725,
            106.6980,
            10.8480,
            106.7725,
            false,
        )
        .expect("Tuyến đường từ Bến Thành đi Thủ Đức phải thành công");

        assert!(route.distance_m > 8000.0);
        assert!(route.polyline.len() >= 8);
        assert!(route.steps.iter().any(|s| s.street_name.contains("Xa Lộ Hà Nội")));
    }

    #[test]
    fn test_arterial_route_hanoi_hoan_kiem_to_cau_giay() {
        let graph = RoadGraph::default_urban_network();

        // Quảng trường Đông Kinh Nghĩa Thục (Hoàn Kiếm) -> Đại học Quốc Gia (Cầu Giấy)
        let route = router::calculate_route(
            &graph,
            21.0315,
            105.8524,
            21.0365,
            105.7820,
            false,
        )
        .expect("Tuyến đường từ Hoàn Kiếm đi Cầu Giấy phải thành công");

        assert!(route.distance_m > 5000.0);
        assert!(route.polyline.len() >= 5);
        assert!(route.steps.iter().any(|s| s.street_name.contains("Kim Mã") || s.street_name.contains("Cầu Giấy")));
    }

    #[test]
    fn test_micro_segment_merging_avoids_phantom_turns() {
        let mut graph = RoadGraph::new();

        // Create a curving road on the same street with tiny segments (< 8m)
        let nodes = vec![
            RoadNode { id: 1, lat: 10.77000, lng: 106.70000, name: "N1".to_string() },
            RoadNode { id: 2, lat: 10.77004, lng: 106.70004, name: "N2".to_string() }, // ~6m
            RoadNode { id: 3, lat: 10.77008, lng: 106.70008, name: "N3".to_string() }, // ~6m
            RoadNode { id: 4, lat: 10.77050, lng: 106.70050, name: "N4".to_string() }, // ~65m
        ];
        for n in nodes {
            graph.add_node(n);
        }

        let add_e = |g: &mut RoadGraph, from, to| {
            let n1 = &g.nodes[&from];
            let n2 = &g.nodes[&to];
            let dist = haversine_distance_m(n1.lat, n1.lng, n2.lat, n2.lng);
            g.add_bidirectional_edge(RoadEdge {
                from,
                to,
                distance_m: dist,
                speed_limit_kmh: 40.0,
                road_type: RoadType::Primary,
                street_name: "Đường Nguyễn Huệ".to_string(),
                is_motorcycle_allowed: true,
            });
        };

        add_e(&mut graph, 1, 2);
        add_e(&mut graph, 2, 3);
        add_e(&mut graph, 3, 4);

        let edges = router::astar_route(&graph, 1, 4, false).unwrap();
        let steps = router::build_route_steps(&graph, &edges, 4);

        // Should only have depart step (consolidated straight on Nguyễn Huệ) + arrive step, NO phantom turns!
        assert_eq!(steps.len(), 2);
        assert_eq!(steps[0].maneuver, "depart");
        assert_eq!(steps[1].maneuver, "arrive");
    }

    #[test]
    fn test_vietnamese_motorcycle_law_motorway_exclusion() {
        let graph = RoadGraph::default_urban_network();

        // Node 15 -> 16 is Motorway (Cao tốc Long Thành - Dầu Giây) with is_motorcycle_allowed = false
        let route_res = router::astar_route(&graph, 15, 16, false);
        assert!(
            route_res.is_err(),
            "Motorcycles must be strictly forbidden on motorways!"
        );
    }

    #[test]
    fn test_routing_ben_thanh_to_opera_house() {
        let graph = RoadGraph::default_urban_network();

        // 1: Chợ Bến Thành, 4: Nhà hát Thành phố
        let route = router::calculate_route(
            &graph,
            10.7725,
            106.6980,
            10.7766,
            106.7032,
            false,
        )
        .expect("Route calculation failed");

        assert!(route.distance_m > 300.0);
        assert!(route.duration_s > 10.0);
        assert!(!route.polyline.is_empty());
        assert!(!route.steps.is_empty());

        // Check turn-by-turn steps
        let first_step = &route.steps[0];
        assert_eq!(first_step.maneuver, "depart");
        assert!(first_step.instruction.contains("Lê Lợi"));

        let last_step = route.steps.last().unwrap();
        assert_eq!(last_step.maneuver, "arrive");
        assert_eq!(last_step.instruction, "Đã đến điểm đích");
    }

    #[test]
    fn test_eco_mode_vs_fastest_mode() {
        let graph = RoadGraph::default_urban_network();

        let route_fast = router::calculate_route(
            &graph,
            10.7725,
            106.6980,
            10.7719,
            106.7065,
            false,
        )
        .expect("Fast route failed");

        let route_eco = router::calculate_route(
            &graph,
            10.7725,
            106.6980,
            10.7719,
            106.7065,
            true,
        )
        .expect("Eco route failed");

        assert!(route_fast.distance_m > 0.0);
        assert!(route_eco.distance_m > 0.0);
    }

    #[test]
    fn test_navigator_tracking_snapping_and_arrival() {
        let polyline = vec![
            [10.7725, 106.6980],
            [10.7738, 106.6994],
            [10.7749, 106.7008],
            [10.7766, 106.7032],
        ];

        let steps = vec![
            RouteStep {
                instruction: "Bắt đầu di chuyển trên Lê Lợi".to_string(),
                street_name: "Đường Lê Lợi".to_string(),
                maneuver: "depart".to_string(),
                distance_m: 350.0,
                duration_s: 30.0,
                lat: 10.7725,
                lng: 106.6980,
            },
            RouteStep {
                instruction: "Đã đến điểm đích".to_string(),
                street_name: "".to_string(),
                maneuver: "arrive".to_string(),
                distance_m: 0.0,
                duration_s: 0.0,
                lat: 10.7766,
                lng: 106.7032,
            },
        ];

        // 1. Normal on-route position (close to segment 1)
        let track = track_position(10.7731, 106.6987, 40.0, 45.0, &polyline, &steps);
        assert!(!track.is_off_route);
        assert!(track.cross_track_error_m < 15.0);
        assert_eq!(track.closest_polyline_index, 0);
        assert!(!track.has_arrived);

        // 2. Off-route position (> 35m away)
        let track_off = track_position(10.7800, 106.6900, 40.0, 45.0, &polyline, &steps);
        assert!(track_off.is_off_route);
        assert!(track_off.cross_track_error_m > 35.0);

        // 3. Arrived at destination
        let track_arrived = track_position(10.7766, 106.7032, 5.0, 45.0, &polyline, &steps);
        assert!(track_arrived.has_arrived);
        assert!(track_arrived.remaining_distance_m < 20.0);
    }

    #[test]
    fn test_ev_forecast_battery_ranges() {
        // Safe: 10km with 90% SOC
        let safe = calculate_ev_forecast(10_000.0, false, 90.0, 3800.0, 22.0);
        assert_eq!(safe.status, "safe");
        assert!(safe.warning_message.is_none());
        assert!(safe.arrival_soc_percent > 80.0);

        // Warning: arrival SOC between 5% and 20%
        let warning = calculate_ev_forecast(100_000.0, false, 70.0, 3800.0, 22.0);
        assert_eq!(warning.status, "warning");
        assert!(warning.warning_message.is_some());

        // Critical: arrival SOC < 5%
        let critical = calculate_ev_forecast(150_000.0, false, 50.0, 3800.0, 22.0);
        assert_eq!(critical.status, "critical");
        assert!(critical.warning_message.is_some());

        // Eco mode 12% saving check
        let normal = calculate_ev_forecast(50_000.0, false, 80.0, 3800.0, 22.0);
        let eco = calculate_ev_forecast(50_000.0, true, 80.0, 3800.0, 22.0);
        assert!(eco.estimated_consumption_wh < normal.estimated_consumption_wh);
        assert!((eco.estimated_consumption_wh - normal.estimated_consumption_wh * 0.88).abs() < 1e-4);
    }

    #[test]
    fn test_ffi_calculate_route_and_memory_safety() {
        let req_json = serde_json::json!({
            "start_lat": 10.7725,
            "start_lng": 106.6980,
            "dest_lat": 10.7766,
            "dest_lng": 106.7032,
            "eco_mode": false,
            "battery_soc": 85.0,
            "battery_capacity_wh": 3800.0,
            "wh_per_km": 22.0
        })
        .to_string();

        let c_req = CString::new(req_json).unwrap();
        let res_ptr = datbike_nav_calculate_route_json(c_req.as_ptr());
        assert!(!res_ptr.is_null());

        let res_cstr = unsafe { CStr::from_ptr(res_ptr) };
        let res_str = res_cstr.to_str().unwrap();
        let val: serde_json::Value = serde_json::from_str(res_str).unwrap();

        assert_eq!(val["ok"], true);
        assert!(val["distance_m"].as_f64().unwrap() > 0.0);
        assert!(val["polyline"].as_array().unwrap().len() >= 2);
        assert_eq!(val["ev_forecast"]["status"], "safe");

        // Safely free
        datbike_nav_free_string(res_ptr);
    }

    #[test]
    fn test_ffi_clean_osm_label() {
        let input = CString::new("123, Đường Hai Bà Trưng, Phường Đa Kao, Quận 1, 700000, Việt Nam").unwrap();
        let cleaned_ptr = datbike_nav_clean_osm_label(input.as_ptr(), true);
        assert!(!cleaned_ptr.is_null());

        let cleaned_cstr = unsafe { CStr::from_ptr(cleaned_ptr) };
        let cleaned_str = cleaned_cstr.to_str().unwrap();
        assert_eq!(cleaned_str, "123, Đường Hai Bà Trưng, Quận 1");
        datbike_nav_free_string(cleaned_ptr);

        // Null pointer safety
        let null_ptr = datbike_nav_clean_osm_label(std::ptr::null(), true);
        assert!(!null_ptr.is_null());
        let null_cstr = unsafe { CStr::from_ptr(null_ptr) };
        assert_eq!(null_cstr.to_str().unwrap(), "");
        datbike_nav_free_string(null_ptr);
    }

    #[test]
    fn test_ffi_track_step_and_null_safety() {
        let req_json = serde_json::json!({
            "current_lat": 10.7731,
            "current_lng": 106.6987,
            "current_speed_kmh": 35.0,
            "current_heading": 45.0,
            "battery_soc": 80.0,
            "polyline": [
                [10.7725, 106.6980],
                [10.7738, 106.6994],
                [10.7749, 106.7008]
            ],
            "steps": [
                {
                    "instruction": "Bắt đầu di chuyển trên Lê Lợi",
                    "street_name": "Đường Lê Lợi",
                    "maneuver": "depart",
                    "distance_m": 350.0,
                    "duration_s": 30.0,
                    "lat": 10.7725,
                    "lng": 106.6980
                }
            ]
        })
        .to_string();

        let c_req = CString::new(req_json).unwrap();
        let res_ptr = datbike_nav_track_step_json(c_req.as_ptr());
        assert!(!res_ptr.is_null());

        let res_cstr = unsafe { CStr::from_ptr(res_ptr) };
        let res_str = res_cstr.to_str().unwrap();
        let val: serde_json::Value = serde_json::from_str(res_str).unwrap();

        assert_eq!(val["ok"], true);
        assert_eq!(val["is_off_route"], false);
        assert!(val["cross_track_error_m"].as_f64().unwrap() < 15.0);

        datbike_nav_free_string(res_ptr);

        // Null pointer safety test
        let null_res_ptr = datbike_nav_calculate_route_json(std::ptr::null());
        assert!(!null_res_ptr.is_null());
        let null_cstr = unsafe { CStr::from_ptr(null_res_ptr) };
        let null_val: serde_json::Value = serde_json::from_str(null_cstr.to_str().unwrap()).unwrap();
        assert_eq!(null_val["ok"], false);
        datbike_nav_free_string(null_res_ptr);
    }

    #[test]
    fn test_ffi_osm_raw_json_and_save_dbnav() {
        let temp_dir = std::env::temp_dir();
        let dbnav_path = temp_dir.join("ffi_saved_network.dbnav");
        let dbnav_str = dbnav_path.to_str().unwrap().to_string();

        let osm_json = r#"{
            "elements": [
                {"type": "node", "id": 2001, "lat": 10.8000, "lon": 106.7000},
                {"type": "node", "id": 2002, "lat": 10.8020, "lon": 106.7020},
                {
                    "type": "way",
                    "id": 6001,
                    "nodes": [2001, 2002],
                    "tags": {
                        "highway": "primary",
                        "name": "Đường Điện Biên Phủ, Phường 15, Bình Thạnh",
                        "oneway": "no",
                        "maxspeed": "50"
                    }
                }
            ]
        }"#;

        let req_json = serde_json::json!({
            "start_lat": 10.8000,
            "start_lng": 106.7000,
            "dest_lat": 10.8020,
            "dest_lng": 106.7020,
            "eco_mode": true,
            "osm_raw_json": osm_json,
            "minimal_filter": true,
            "save_dbnav_path": dbnav_str
        }).to_string();

        let c_req = CString::new(req_json).unwrap();
        let res_ptr = datbike_nav_calculate_route_json(c_req.as_ptr());
        assert!(!res_ptr.is_null());

        let res_cstr = unsafe { CStr::from_ptr(res_ptr) };
        let res_str = res_cstr.to_str().unwrap();
        let val: serde_json::Value = serde_json::from_str(res_str).unwrap();

        assert_eq!(val["ok"], true);
        assert!(val["distance_m"].as_f64().unwrap() > 200.0);
        let steps = val["steps"].as_array().unwrap();
        assert!(!steps.is_empty());
        // Verify street name was cleaned (stripped Phường 15)
        assert_eq!(steps[0]["street_name"].as_str().unwrap(), "Đường Điện Biên Phủ, Bình Thạnh");

        datbike_nav_free_string(res_ptr);

        // Verify .dbnav was persisted to disk
        assert!(dbnav_path.exists());
        let _ = std::fs::remove_file(dbnav_path);
    }

    #[test]
    fn test_osm_advanced_filtering_and_offline_dbnav_roundtrip() {
        let mut graph = RoadGraph::new();

        let raw_osm = r#"{
            "elements": [
                {"type": "node", "id": 3001, "lat": 10.7800, "lon": 106.6900},
                {"type": "node", "id": 3002, "lat": 10.7820, "lon": 106.6920},
                {"type": "node", "id": 3003, "lat": 10.7840, "lon": 106.6940},
                {"type": "node", "id": 3004, "lat": 10.7860, "lon": 106.6960},
                {
                    "type": "way",
                    "id": 7001,
                    "nodes": [3001, 3002],
                    "tags": {
                        "highway": "primary",
                        "name": "Đường Hai Bà Trưng, Phường Tân Định",
                        "oneway": "yes",
                        "oneway:motorcycle": "no",
                        "maxspeed": "VN:urban"
                    }
                },
                {
                    "type": "way",
                    "id": 7002,
                    "nodes": [3002, 3003],
                    "tags": {
                        "highway": "secondary",
                        "name": "Đường Trần Quang Khải",
                        "oneway": "no"
                    }
                },
                {
                    "type": "way",
                    "id": 7003,
                    "nodes": [3002, 3004],
                    "tags": {
                        "building": "apartments",
                        "name": "Chung cư Horizon"
                    }
                },
                {
                    "type": "way",
                    "id": 7004,
                    "nodes": [3001, 3004],
                    "tags": {
                        "highway": "pedestrian",
                        "area": "yes",
                        "name": "Sân sinh hoạt cộng đồng"
                    }
                },
                {
                    "type": "way",
                    "id": 7005,
                    "nodes": [3003, 3004],
                    "tags": {
                        "highway": "steps",
                        "indoor": "yes"
                    }
                }
            ]
        }"#;

        let added_edges = graph.ingest_osm_overpass_json(raw_osm, true).unwrap();
        // Should only add edges from way 7001 (bidirectional = 2) and 7002 (bidirectional = 2) = 4 edges!
        assert_eq!(added_edges, 4);

        // Verify motorcycle bidirectional exemption on 7001 (Hai Bà Trưng)
        let edges_3002 = &graph.adjacency[&3002];
        assert!(edges_3002.iter().any(|e| e.to == 3001), "Motorcycle must be allowed reverse on oneway:motorcycle=no");

        // Verify maxspeed VN:urban parsed as 50.0 km/h
        let edge_3001_3002 = graph.adjacency[&3001].iter().find(|e| e.to == 3002).unwrap();
        assert_eq!(edge_3001_3002.speed_limit_kmh, 50.0);
        assert_eq!(edge_3001_3002.street_name, "Đường Hai Bà Trưng"); // Cleaned Phường Tân Định

        // Calculate route in reverse (3003 -> 3001) to verify 2-way motorcycle connectivity
        let route = router::calculate_route(&graph, 10.7840, 106.6940, 10.7800, 106.6900, false)
            .expect("Routing on 2-way motorcycle road must succeed");
        assert_eq!(route.polyline.len(), 3);
        assert_eq!(route.polyline[0], [10.7840, 106.6940]);
        assert_eq!(route.polyline[1], [10.7820, 106.6920]);
        assert_eq!(route.polyline[2], [10.7800, 106.6900]);

        // Test Offline .dbnav Persistence & Zero-copy loading
        let temp_dir = std::env::temp_dir();
        let dbnav_path = temp_dir.join("offline_advanced_network.dbnav");
        graph.save_to_file(&dbnav_path).expect("Failed to save .dbnav");

        let loaded_graph = RoadGraph::load_from_file(&dbnav_path).expect("Failed to load .dbnav with memmap2");
        let loaded_route = router::calculate_route(&loaded_graph, 10.7800, 106.6900, 10.7840, 106.6940, true)
            .expect("Offline routing on loaded .dbnav must succeed");
        assert_eq!(loaded_route.polyline.len(), 3);
        assert!(loaded_route.distance_m > 500.0);

        let _ = std::fs::remove_file(dbnav_path);
    }
}
