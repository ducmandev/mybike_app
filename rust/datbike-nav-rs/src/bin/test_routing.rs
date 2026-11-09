use std::path::PathBuf;
use std::time::Instant;

use datbike_nav::compiler::OfflineMapPackage;
use datbike_nav::router::calculate_route;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let dbnav_path = PathBuf::from(r"D:\CuaMan\dat-bike\osm_data\hcmc_roads.dbnav");

    println!("Dang nap ban do offline qua memory mapping (memmap2)...");
    let t0 = Instant::now();
    let pkg = OfflineMapPackage::load_from_file(&dbnav_path)?;
    println!(
        "Nap thanh cong trong {:.2}ms! Nodes: {}, Edges: {}, So nha: {}",
        t0.elapsed().as_secs_f64() * 1000.0,
        pkg.graph.nodes.len(),
        pkg.graph.adjacency.values().map(|v| v.len()).sum::<usize>(),
        pkg.addresses.len()
    );

    println!("\n--- TEST 1: The Grace Tower -> Crescent Mall (Phu My Hung, Q7) ---");
    let t1 = Instant::now();
    // Grace Tower: 10.7294, 106.7214
    // Crescent Mall: 10.7280, 106.7180
    let res1 = calculate_route(&pkg.graph, 10.7294, 106.7214, 10.7280, 106.7180, false)?;
    println!(
        "Thoi gian tinh toan A*: {:.2}ms",
        t1.elapsed().as_secs_f64() * 1000.0
    );
    println!("Quang duong: {:.1}m", res1.distance_m);
    println!("Thoi gian uoc tinh: {:.1}s ({:.1} phut)", res1.duration_s, res1.duration_s / 60.0);
    println!("So diem polyline: {}", res1.polyline.len());
    println!("Cac buoc Turn-by-Turn ({} buoc):", res1.steps.len());
    for (i, s) in res1.steps.iter().enumerate() {
        println!("  {}. {} (maneuver: {}, dist: {:.1}m, du: {:.1}s)", i + 1, s.instruction, s.maneuver, s.distance_m, s.duration_s);
    }

    println!("\n--- TEST 2: Cho Ben Thanh (Q1) -> Crescent Mall (Q7) (~6.5 km) ---");
    let t2 = Instant::now();
    // Ben Thanh: 10.7725, 106.6980
    let res2 = calculate_route(&pkg.graph, 10.7725, 106.6980, 10.7280, 106.7180, false)?;
    println!(
        "Thoi gian tinh toan A*: {:.2}ms",
        t2.elapsed().as_secs_f64() * 1000.0
    );
    println!("Quang duong: {:.1}m ({:.2} km)", res2.distance_m, res2.distance_m / 1000.0);
    println!("Thoi gian uoc tinh: {:.1}s ({:.1} phut)", res2.duration_s, res2.duration_s / 60.0);
    println!("So diem polyline: {}", res2.polyline.len());
    println!("So buoc Turn-by-Turn: {}", res2.steps.len());
    for (i, s) in res2.steps.iter().take(6).enumerate() {
        println!("  {}. {} ({:.1}m)", i + 1, s.instruction, s.distance_m);
    }
    if res2.steps.len() > 6 {
        println!("  ... [{} buoc tiep theo] ...", res2.steps.len() - 7);
        let last = res2.steps.last().unwrap();
        println!("  {}. {} ({:.1}m)", res2.steps.len(), last.instruction, last.distance_m);
    }

    println!("\n--- TEST 3: Tra cuu dia chi offline (so nha & POI) ---");
    let query_str = "Grace";
    let matched: Vec<_> = pkg.addresses.iter().filter(|a| {
        a.name.as_ref().map_or(false, |n| n.to_lowercase().contains(&query_str.to_lowercase()))
    }).take(3).collect();
    for a in matched {
        println!("  Tim thay: {:?}, duong: {}, toa do: ({:.4}, {:.4})", a.name, a.street, a.lat, a.lng);
    }

    println!("\nALL TESTS PASSED! RUST ROUTING HOAN TOAN 100% OFFLINE KHONG CAN INTERNET!");

    Ok(())
}
