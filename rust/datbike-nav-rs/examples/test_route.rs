use datbike_nav::*;
use serde_json::Value;
use std::ffi::{CStr, CString};

fn run_test_case(title: &str, req_json: &str) {
    println!("\n=======================================================");
    println!(">>> {}", title);
    println!("-------------------------------------------------------");

    let c_req = CString::new(req_json).expect("CString conversion failed");
    let res_ptr = datbike_nav_calculate_route_json(c_req.as_ptr());
    let res_str = unsafe { CStr::from_ptr(res_ptr).to_string_lossy().into_owned() };
    datbike_nav_free_string(res_ptr);

    let parsed: Result<Value, _> = serde_json::from_str(&res_str);
    match parsed {
        Ok(v) => {
            let ok = v["ok"].as_bool().unwrap_or(false);
            if ok {
                let dist_m = v["distance_m"].as_f64().unwrap_or(0.0);
                let dur_s = v["duration_s"].as_f64().unwrap_or(0.0);
                let polyline_len = v["polyline"].as_array().map_or(0, |a| a.len());
                let arrival_soc = v["ev_forecast"]["arrival_soc_percent"].as_f64().unwrap_or(0.0);
                let ev_status = v["ev_forecast"]["status"].as_str().unwrap_or("unknown");

                println!("  [OK] Tìm đường THÀNH CÔNG!");
                println!("  - Cự ly: {:.2} km ({:.0} m)", dist_m / 1000.0, dist_m);
                println!("  - Thời gian dự kiến: {:.1} phút ({:.0} giây)", dur_s / 60.0, dur_s);
                println!("  - Số điểm tọa độ polyline: {}", polyline_len);
                println!("  - Dự báo pin khi đến: {:.1}% (Trạng thái: {})", arrival_soc, ev_status);

                if let Some(steps) = v["steps"].as_array() {
                    println!("  - Các bước điều hướng Turn-by-Turn ({} bước):", steps.len());
                    for (i, step) in steps.iter().enumerate() {
                        let inst = step["instruction"].as_str().unwrap_or("");
                        let dist = step["distance_m"].as_f64().unwrap_or(0.0);
                        let maneuver = step["maneuver"].as_str().unwrap_or("");
                        println!("    {}. [{}] {} ({:.0}m)", i + 1, maneuver, inst, dist);
                    }
                }
            } else {
                let err = v["error"].as_str().unwrap_or("Lỗi không xác định");
                println!("  [THÔNG BÁO] {}", err);
            }
        }
        Err(e) => {
            println!("  [LỖI PARSE JSON] {}: {}", e, res_str);
        }
    }
}

fn main() {
    println!("*****************************************************************");
    println!("*   THỰC NGHIỆM ĐỘNG CƠ ĐIỀU HƯỚNG TÌM ĐƯỜNG RUST TRÊN WINDOWS  *");
    println!("*          Dự án: datbike-nav-rs | Hệ xe điện Dat Bike           *");
    println!("*****************************************************************");

    // Tuyến 1: Chợ Bến Thành -> Nhà Hát Thành Phố (Quận 1 nội bộ)
    run_test_case(
        "Tuyến 1: TP.HCM - Chợ Bến Thành -> Nhà hát Thành phố (Quận 1)",
        r#"{
            "start_lat": 10.7725,
            "start_lng": 106.6980,
            "dest_lat": 10.7766,
            "dest_lng": 106.7032,
            "eco_mode": false,
            "battery_soc": 90.0
        }"#,
    );

    // Tuyến 2: Chợ Bến Thành -> Sân bay Tân Sơn Nhất (Trục NKKN - Nguyễn Văn Trỗi)
    run_test_case(
        "Tuyến 2: TP.HCM - Chợ Bến Thành -> Ga Quốc Nội Sân bay Tân Sơn Nhất",
        r#"{
            "start_lat": 10.7725,
            "start_lng": 106.6980,
            "dest_lat": 10.8155,
            "dest_lng": 106.6580,
            "eco_mode": false,
            "battery_soc": 85.0
        }"#,
    );

    // Tuyến 3: Chợ Bến Thành -> Ngã tư Thủ Đức (Trục Điện Biên Phủ - Xa Lộ Hà Nội)
    run_test_case(
        "Tuyến 3: TP.HCM - Chợ Bến Thành -> Ngã tư Thủ Đức (Xa Lộ Hà Nội)",
        r#"{
            "start_lat": 10.7725,
            "start_lng": 106.6980,
            "dest_lat": 10.8480,
            "dest_lng": 106.7725,
            "eco_mode": true,
            "battery_soc": 75.0
        }"#,
    );

    // Tuyến 4: Bến Bạch Đằng -> Mai Chí Thọ / An Phú (Trục Cầu Ba Son)
    run_test_case(
        "Tuyến 4: TP.HCM - Bến Bạch Đằng -> Mai Chí Thọ (Qua Cầu Ba Son)",
        r#"{
            "start_lat": 10.7719,
            "start_lng": 106.7065,
            "dest_lat": 10.7850,
            "dest_lng": 106.7520,
            "eco_mode": false,
            "battery_soc": 60.0
        }"#,
    );

    // Tuyến 5: Chợ Bến Thành -> Chợ Lớn (Trục Đại lộ Võ Văn Kiệt)
    run_test_case(
        "Tuyến 5: TP.HCM - Chợ Bến Thành -> Chợ Lớn (Đại lộ Võ Văn Kiệt)",
        r#"{
            "start_lat": 10.7725,
            "start_lng": 106.6980,
            "dest_lat": 10.7440,
            "dest_lng": 106.6550,
            "eco_mode": false,
            "battery_soc": 55.0
        }"#,
    );

    // Tuyến 6: Sân bay Tân Sơn Nhất -> Bình Lợi -> Hiệp Bình Chánh (Trục Phạm Văn Đồng)
    run_test_case(
        "Tuyến 6: TP.HCM - Sân bay Tân Sơn Nhất -> Phạm Văn Đồng (Thủ Đức)",
        r#"{
            "start_lat": 10.8120,
            "start_lng": 106.6610,
            "dest_lat": 10.8360,
            "dest_lng": 106.7400,
            "eco_mode": true,
            "battery_soc": 40.0
        }"#,
    );

    // Tuyến 7: Hà Nội - Quảng trường Đông Kinh Nghĩa Thục -> ĐHQG Hà Nội (Cầu Giấy)
    run_test_case(
        "Tuyến 7: HÀ NỘI - Hồ Hoàn Kiếm -> Cầu Giấy (Kim Mã - Xuân Thủy)",
        r#"{
            "start_lat": 21.0315,
            "start_lng": 105.8524,
            "dest_lat": 21.0365,
            "dest_lng": 105.7820,
            "eco_mode": false,
            "battery_soc": 80.0
        }"#,
    );

    // Tuyến 8: Hà Nội - Hồ Hoàn Kiếm -> Bến xe Giáp Bát (Lê Duẩn - Giải Phóng)
    run_test_case(
        "Tuyến 8: HÀ NỘI - Hồ Hoàn Kiếm -> Bến xe Giáp Bát (Giải Phóng)",
        r#"{
            "start_lat": 21.0315,
            "start_lng": 105.8524,
            "dest_lat": 20.9850,
            "dest_lng": 105.8420,
            "eco_mode": false,
            "battery_soc": 30.0
        }"#,
    );

    // Tuyến 9: Tọa độ ngoài đường chính (test snap-to-road linh hoạt < 5km)
    run_test_case(
        "Tuyến 9: Test Snap-to-Road - Tọa độ thực tế người dùng cách trục chính ~1km",
        r#"{
            "start_lat": 10.8000,
            "start_lng": 106.7200,
            "dest_lat": 10.8200,
            "dest_lng": 106.7300,
            "eco_mode": false,
            "battery_soc": 85.0
        }"#,
    );

    // Tuyến 10: Vùng sâu vùng xa > 5km (báo lỗi chuẩn để app kích hoạt tải bản đồ online)
    run_test_case(
        "Tuyến 10: Khu vực xa ngoài độ phủ > 5km (Cần Giờ / Vũng Tàu)",
        r#"{
            "start_lat": 10.4100,
            "start_lng": 107.0500,
            "dest_lat": 10.4200,
            "dest_lng": 107.0600,
            "eco_mode": false,
            "battery_soc": 85.0
        }"#,
    );

    println!("\n=======================================================");
    println!(">>> TẤT CẢ CÁC BÀI THỰC NGHIỆM ĐÃ HOÀN TẤT THÀNH CÔNG! <<<");
    println!("=======================================================\n");
}
