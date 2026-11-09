use std::env;
use std::path::PathBuf;

use datbike_nav::compiler::{compile_pbf_to_dbnav, BoundingBox};

fn print_usage() {
    println!("Dat Bike OpenStreetMap Offline Compiler");
    println!("Usage:");
    println!("  osm_compiler [OPTIONS]");
    println!();
    println!("Options:");
    println!("  --input <path>      Path to input .osm.pbf (Default: osm_data/vietnam-latest.osm.pbf)");
    println!("  --output <path>     Path to output .dbnav (Default: osm_data/hcmc_roads.dbnav)");
    println!("  --area <name>       Area filter: 'hcmc' or 'vietnam' (Default: hcmc)");
    println!("  --help              Show this help message");
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = env::args().collect();

    let mut input_path = PathBuf::from(r"D:\CuaMan\dat-bike\osm_data\vietnam-latest.osm.pbf");
    let mut output_path = PathBuf::from(r"D:\CuaMan\dat-bike\osm_data\hcmc_roads.dbnav");
    let mut area = "hcmc".to_string();

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--input" | "-i" => {
                if i + 1 < args.len() {
                    input_path = PathBuf::from(&args[i + 1]);
                    i += 1;
                }
            }
            "--output" | "-o" => {
                if i + 1 < args.len() {
                    output_path = PathBuf::from(&args[i + 1]);
                    i += 1;
                }
            }
            "--area" | "-a" => {
                if i + 1 < args.len() {
                    area = args[i + 1].to_lowercase();
                    i += 1;
                }
            }
            "--help" | "-h" => {
                print_usage();
                return Ok(());
            }
            _ => {}
        }
        i += 1;
    }

    if !input_path.exists() {
        eprintln!("Loi: File nguon khong ton tai: {:?}", input_path);
        eprintln!("Hay kiem tra lai duong dan hoac tai file vietnam-latest.osm.pbf truoc.");
        std::process::exit(1);
    }

    let (bbox, area_name) = match area.as_str() {
        "hcmc" | "saigon" | "tphcm" => (Some(BoundingBox::hcmc()), "TP. Hồ Chí Minh"),
        "vietnam" | "all" => (Some(BoundingBox::vietnam()), "Toàn quốc Việt Nam"),
        _ => {
            eprintln!("Khu vuc khong hop le (chi ho tro 'hcmc' hoac 'vietnam')");
            std::process::exit(1);
        }
    };

    println!("Dang khoi dong trinh bien dich ban do...");
    let _pkg = compile_pbf_to_dbnav(&input_path, &output_path, bbox, area_name)?;

    println!("\nHoan thanh thanh cong!");
    println!("File .dbnav san sang tai: {:?}", output_path);

    Ok(())
}
