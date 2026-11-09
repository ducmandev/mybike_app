use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EvForecast {
    pub estimated_consumption_wh: f64,
    pub estimated_soc_used_percent: f64,
    pub arrival_soc_percent: f64,
    pub status: String,
    pub warning_message: Option<String>,
}

/// Computes energy consumption and SOC forecast for Dat Bike electric motorcycle.
pub fn calculate_ev_forecast(
    distance_m: f64,
    eco_mode: bool,
    battery_soc: f64,
    battery_capacity_wh: f64,
    wh_per_km: f64,
) -> EvForecast {
    let capacity_wh = if battery_capacity_wh <= 0.0 {
        3800.0 // Default Dat Bike Quantum / Weaver++ capacity ~ 3800 Wh (72V / 53Ah)
    } else {
        battery_capacity_wh
    };

    let base_rate = if wh_per_km <= 0.0 { 22.0 } else { wh_per_km };
    let effective_wh_per_km = if eco_mode {
        base_rate * 0.88 // 12% energy reduction in eco mode
    } else {
        base_rate
    };

    let distance_km = distance_m.max(0.0) / 1000.0;
    let estimated_consumption_wh = distance_km * effective_wh_per_km;
    let estimated_soc_used_percent = (estimated_consumption_wh / capacity_wh) * 100.0;
    let arrival_soc_percent = (battery_soc - estimated_soc_used_percent).clamp(-100.0, 100.0);

    let (status, warning_message) = if arrival_soc_percent >= 20.0 {
        ("safe".to_string(), None)
    } else if arrival_soc_percent >= 5.0 {
        (
            "warning".to_string(),
            Some(format!(
                "Pin sắp yếu khi đến đích ({:.1}%), hãy tìm trạm sạc gần nhất.",
                arrival_soc_percent
            )),
        )
    } else {
        (
            "critical".to_string(),
            Some(format!(
                "Mức pin không đủ để đến đích (dự kiến còn {:.1}%). Cần sạc xe ngay!",
                arrival_soc_percent
            )),
        )
    };

    EvForecast {
        estimated_consumption_wh,
        estimated_soc_used_percent,
        arrival_soc_percent,
        status,
        warning_message,
    }
}
