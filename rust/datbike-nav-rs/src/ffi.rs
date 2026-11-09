use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};

use serde::{Deserialize, Serialize};
use std::sync::RwLock;
use crate::compiler::OfflineMapPackage;

static CACHED_PACKAGE: RwLock<Option<OfflineMapPackage>> = RwLock::new(None);

use crate::ev_range::calculate_ev_forecast;
use crate::graph::RoadGraph;
use crate::navigator::track_position;
use crate::router::{calculate_route, RouteStep};

#[derive(Debug, Deserialize)]
pub struct RouteRequestJson {
    pub start_lat: f64,
    pub start_lng: f64,
    pub dest_lat: f64,
    pub dest_lng: f64,
    #[serde(default)]
    pub eco_mode: Option<bool>,
    #[serde(default)]
    pub battery_soc: Option<f64>,
    #[serde(default)]
    pub battery_capacity_wh: Option<f64>,
    #[serde(default)]
    pub wh_per_km: Option<f64>,
    #[serde(default)]
    pub corridor_waypoints: Option<Vec<[f64; 2]>>,
    #[serde(default)]
    pub osm_raw_json: Option<String>,
    #[serde(default)]
    pub minimal_filter: Option<bool>,
    #[serde(default)]
    pub save_dbnav_path: Option<String>,
    #[serde(default)]
    pub load_dbnav_path: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct RouteResponseSuccess {
    pub ok: bool,
    pub distance_m: f64,
    pub duration_s: f64,
    pub polyline: Vec<[f64; 2]>,
    pub steps: Vec<RouteStep>,
    pub ev_forecast: RouteEvForecastJson,
}

#[derive(Debug, Serialize)]
pub struct RouteEvForecastJson {
    pub estimated_consumption_wh: f64,
    pub estimated_soc_used_percent: f64,
    pub arrival_soc_percent: f64,
    pub status: String,
    pub warning_message: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct ErrorResponse {
    pub ok: bool,
    pub error: String,
}

#[derive(Debug, Deserialize)]
pub struct TrackRequestJson {
    pub current_lat: f64,
    pub current_lng: f64,
    pub current_speed_kmh: Option<f64>,
    pub current_heading: Option<f64>,
    pub battery_soc: Option<f64>,
    pub battery_capacity_wh: Option<f64>,
    pub wh_per_km: Option<f64>,
    pub eco_mode: Option<bool>,
    pub polyline: Vec<[f64; 2]>,
    pub steps: Option<Vec<RouteStep>>,
}

#[derive(Debug, Serialize)]
pub struct TrackResponseSuccess {
    pub ok: bool,
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
    pub arrival_soc_percent: f64,
    pub energy_status: String,
    pub has_arrived: bool,
}

fn to_c_string(s: &str) -> *mut c_char {
    match CString::new(s) {
        Ok(c_string) => c_string.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

fn make_error_json(err_msg: &str) -> String {
    serde_json::to_string(&ErrorResponse {
        ok: false,
        error: err_msg.to_string(),
    })
    .unwrap_or_else(|_| r#"{"ok":false,"error":"Serialization error"}"#.to_string())
}

/// C-ABI: Calculates route given start/dest coords, eco_mode, OSM raw JSON, and EV battery params.
#[no_mangle]
pub extern "C" fn datbike_nav_calculate_route_json(req_json: *const c_char) -> *mut c_char {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if req_json.is_null() {
            return make_error_json("Con trỏ JSON đầu vào là null");
        }

        let c_str = unsafe { CStr::from_ptr(req_json) };
        let req_str = match c_str.to_str() {
            Ok(s) => s,
            Err(e) => return make_error_json(&format!("Chuỗi JSON không phải UTF-8 hợp lệ: {}", e)),
        };

        let req: RouteRequestJson = match serde_json::from_str(req_str) {
            Ok(r) => r,
            Err(e) => return make_error_json(&format!("Lỗi phân tích JSON yêu cầu: {}", e)),
        };

        let eco_mode = req.eco_mode.unwrap_or(false);
        let battery_soc = req.battery_soc.unwrap_or(100.0);
        let battery_capacity_wh = req.battery_capacity_wh.unwrap_or(3800.0);
        let wh_per_km = req.wh_per_km.unwrap_or(22.0);

        let mut custom_graph = None;

        // 0. Neu caller truyen OSM raw JSON (test mock hoac dynamic corridor)
        if let Some(osm_json) = &req.osm_raw_json {
            if !osm_json.trim().is_empty() {
                let mut g = RoadGraph::new();
                let minimal = req.minimal_filter.unwrap_or(true);
                if g.ingest_osm_overpass_json(osm_json, minimal).is_ok() && !g.nodes.is_empty() {
                    g.build_spatial_index();
                    custom_graph = Some(g);
                }
            }
        }

        // 1. Uu tien dung ban do offline tu bo nho dem hoac file tren may
        if custom_graph.is_none() {
            if let Ok(guard) = CACHED_PACKAGE.read() {
                if let Some(pkg) = guard.as_ref() {
                    custom_graph = Some(pkg.graph.clone());
                }
            }
        }

        if custom_graph.is_none() {
            let candidate_paths = [
                req.load_dbnav_path.as_deref().unwrap_or(""),
                r"D:\CuaMan\dat-bike\osm_data\hcmc_roads.dbnav",
                "hcmc_roads.dbnav",
                "osm_data/hcmc_roads.dbnav",
                "../osm_data/hcmc_roads.dbnav",
            ];

            for path in candidate_paths {
                if !path.is_empty() && std::path::Path::new(path).exists() {
                    if let Ok(pkg) = OfflineMapPackage::load_from_file(path) {
                        custom_graph = Some(pkg.graph.clone());
                        if let Ok(mut w_guard) = CACHED_PACKAGE.write() {
                            *w_guard = Some(pkg);
                        }
                        break;
                    }
                }
            }
        }

        let mut graph = custom_graph.unwrap_or_else(RoadGraph::default_urban_network);

        // 2. Ingest corridor waypoints if provided
        if let Some(waypoints) = &req.corridor_waypoints {
            if !waypoints.is_empty() {
                graph.ingest_corridor(waypoints, Some("Tuyến hành lang động"), Some(40.0));
            }
        }

        // 3. Persist graph to offline .dbnav file if requested
        if let Some(save_path) = &req.save_dbnav_path {
            if !save_path.trim().is_empty() {
                let _ = graph.save_to_file(save_path);
            }
        }

        match calculate_route(
            &graph,
            req.start_lat,
            req.start_lng,
            req.dest_lat,
            req.dest_lng,
            eco_mode,
        ) {
            Ok(route) => {
                let ev = calculate_ev_forecast(
                    route.distance_m,
                    eco_mode,
                    battery_soc,
                    battery_capacity_wh,
                    wh_per_km,
                );

                let resp = RouteResponseSuccess {
                    ok: true,
                    distance_m: route.distance_m,
                    duration_s: route.duration_s,
                    polyline: route.polyline,
                    steps: route.steps,
                    ev_forecast: RouteEvForecastJson {
                        estimated_consumption_wh: ev.estimated_consumption_wh,
                        estimated_soc_used_percent: ev.estimated_soc_used_percent,
                        arrival_soc_percent: ev.arrival_soc_percent,
                        status: ev.status,
                        warning_message: ev.warning_message,
                    },
                };

                serde_json::to_string(&resp)
                    .unwrap_or_else(|e| make_error_json(&format!("Lỗi tạo phản hồi JSON: {}", e)))
            }
            Err(err) => make_error_json(&err),
        }
    }));

    match result {
        Ok(json_str) => to_c_string(&json_str),
        Err(_) => to_c_string(&make_error_json("Panic xảy ra bên trong công cụ định tuyến")),
    }
}

/// C-ABI: Tracks the bike's real-time position along the active polyline.
#[no_mangle]
pub extern "C" fn datbike_nav_track_step_json(req_json: *const c_char) -> *mut c_char {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if req_json.is_null() {
            return make_error_json("Con trỏ JSON đầu vào là null");
        }

        let c_str = unsafe { CStr::from_ptr(req_json) };
        let req_str = match c_str.to_str() {
            Ok(s) => s,
            Err(e) => return make_error_json(&format!("Chuỗi JSON không phải UTF-8 hợp lệ: {}", e)),
        };

        let req: TrackRequestJson = match serde_json::from_str(req_str) {
            Ok(r) => r,
            Err(e) => return make_error_json(&format!("Lỗi phân tích JSON yêu cầu: {}", e)),
        };

        let speed = req.current_speed_kmh.unwrap_or(0.0);
        let heading = req.current_heading.unwrap_or(0.0);
        let eco_mode = req.eco_mode.unwrap_or(false);
        let battery_soc = req.battery_soc.unwrap_or(100.0);
        let battery_capacity_wh = req.battery_capacity_wh.unwrap_or(3800.0);
        let wh_per_km = req.wh_per_km.unwrap_or(22.0);
        let steps = req.steps.unwrap_or_default();

        let track = track_position(
            req.current_lat,
            req.current_lng,
            speed,
            heading,
            &req.polyline,
            &steps,
        );

        let ev = calculate_ev_forecast(
            track.remaining_distance_m,
            eco_mode,
            battery_soc,
            battery_capacity_wh,
            wh_per_km,
        );

        let resp = TrackResponseSuccess {
            ok: true,
            snapped_lat: track.snapped_lat,
            snapped_lng: track.snapped_lng,
            snapped_bearing: track.snapped_bearing,
            cross_track_error_m: track.cross_track_error_m,
            is_off_route: track.is_off_route,
            closest_polyline_index: track.closest_polyline_index,
            current_step_index: track.current_step_index,
            distance_to_next_maneuver_m: track.distance_to_next_maneuver_m,
            remaining_distance_m: track.remaining_distance_m,
            remaining_duration_s: track.remaining_duration_s,
            arrival_soc_percent: ev.arrival_soc_percent,
            energy_status: ev.status,
            has_arrived: track.has_arrived,
        };

        serde_json::to_string(&resp)
            .unwrap_or_else(|e| make_error_json(&format!("Lỗi tạo phản hồi JSON: {}", e)))
    }));

    match result {
        Ok(json_str) => to_c_string(&json_str),
        Err(_) => to_c_string(&make_error_json("Panic xảy ra bên trong bộ theo dõi lộ trình")),
    }
}

/// C-ABI: Cleans an OpenStreetMap address or street label in Rust.
/// Strips postal codes, "Việt Nam", and administrative prefixes (Khu phố, Phường, etc.) if minimal == true.
#[no_mangle]
pub extern "C" fn datbike_nav_clean_osm_label(raw_ptr: *const c_char, minimal: bool) -> *mut c_char {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if raw_ptr.is_null() {
            return String::new();
        }
        let c_str = unsafe { CStr::from_ptr(raw_ptr) };
        let raw_str = match c_str.to_str() {
            Ok(s) => s,
            Err(_) => return String::new(),
        };
        crate::graph::clean_map_label(raw_str, minimal)
    }));

    match result {
        Ok(cleaned) => to_c_string(&cleaned),
        Err(_) => to_c_string(""),
    }
}

/// C-ABI: Frees any string allocated and returned across the FFI boundary.
#[no_mangle]
pub extern "C" fn datbike_nav_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            let _ = CString::from_raw(ptr);
        }
    }
}


#[derive(Debug, Deserialize)]
pub struct SearchPlacesRequestJson {
    pub query: String,
    pub limit: Option<usize>,
}

#[derive(Debug, Serialize)]
pub struct SearchPlaceItemJson {
    pub display_name: String,
    pub short_name: String,
    pub street: String,
    pub lat: f64,
    pub lng: f64,
    pub category: String,
}

#[derive(Debug, Serialize)]
pub struct SearchPlacesResponseJson {
    pub ok: bool,
    pub results: Vec<SearchPlaceItemJson>,
}

/// Tim kiem dia chi va so nha offline tu CSDL ban do
#[no_mangle]
pub extern "C" fn datbike_nav_search_offline_places_json(req_json: *const c_char) -> *mut c_char {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if req_json.is_null() {
            return make_error_json("Con trỏ JSON đầu vào là null");
        }

        let c_str = unsafe { CStr::from_ptr(req_json) };
        let req_str = match c_str.to_str() {
            Ok(s) => s,
            Err(e) => return make_error_json(&format!("Chuỗi JSON không phải UTF-8: {}", e)),
        };

        let req: SearchPlacesRequestJson = match serde_json::from_str(req_str) {
            Ok(r) => r,
            Err(e) => return make_error_json(&format!("Lỗi phân tích JSON tìm kiếm: {}", e)),
        };

        let query = req.query.trim().to_lowercase();
        let limit = req.limit.unwrap_or(15);

        let mut results = Vec::new();
        if let Ok(guard) = CACHED_PACKAGE.read() {
            if let Some(pkg) = guard.as_ref() {
                for a in &pkg.addresses {
                    let matches_name = a.name.as_ref().map_or(false, |n| n.to_lowercase().contains(&query));
                    let matches_street = a.street.to_lowercase().contains(&query);
                    let matches_house = !a.housenumber.is_empty() && format!("{} {}", a.housenumber, a.street).to_lowercase().contains(&query);

                    if matches_name || matches_street || matches_house {
                        let name_display = a.name.clone().unwrap_or_else(|| {
                            if !a.housenumber.is_empty() {
                                format!("{} {}", a.housenumber, a.street)
                            } else {
                                a.street.clone()
                            }
                        });

                        results.push(SearchPlaceItemJson {
                            display_name: format!("{}, TP. Hồ Chí Minh", name_display),
                            short_name: name_display,
                            street: a.street.clone(),
                            lat: a.lat,
                            lng: a.lng,
                            category: if a.name.is_some() { "landmark".to_string() } else { "address".to_string() },
                        });

                        if results.len() >= limit {
                            break;
                        }
                    }
                }
            }
        }

        serde_json::to_string(&SearchPlacesResponseJson { ok: true, results })
            .unwrap_or_else(|e| make_error_json(&format!("Lỗi tạo phản hồi JSON: {}", e)))
    }));

    match result {
        Ok(json_str) => to_c_string(&json_str),
        Err(_) => to_c_string(&make_error_json("Panic xảy ra khi tìm kiếm địa chỉ offline")),
    }
}
