# Battery SoC and Runtime Estimator (Fullriver DC400-6, 8S2P)

This OpenHAB 5.2+ Rules DSL script calculates accurate battery **State-of-Charge (SoC)**, applies temperature and Peukert corrections, smooths transitions near full charge, and estimates **runtime to 40 % remaining SoC** under current load.

---

## ⚙️ Overview

**Key features**
- Voltage- and coulomb-based SoC fusion  
- Temperature- and current-compensated voltage lookup  
- Peukert’s law correction for discharge accuracy  
- Dynamic charge efficiency  
- Smooth ramp from 99 → 100 % after float tail current  
- Runtime and remaining Ah estimation (discharge only)  

**Battery**
- Fullriver DC400-6 AGM (8S × 2P)
- Nominal 48 V, 830 Ah @ C20
- Float 54.6 V, Absorption 58.8 V

---

## 🧩 Required Items

Create these **Number** or **DateTime** items in **MainUI → Settings → Items → + Add Item**  
Assign the labels shown below and enable *restoreOnStartup* persistence where noted.

| Item Name | Type | Purpose | Persistence |
|------------|------|----------|--------------|
| `DCData_Voltage` | Number:ElectricPotential | Pack voltage (V) | — |
| `DCData_Current` | Number:ElectricCurrent | Charge/discharge current (A) | — |
| `ChargerStatus` | String | Text from inverter/charger (“Bulk”, “Absorption”, “Float”) | — |
| `AmbientWeatherWS2902A_WH31E_193_Temperature` | Number:Temperature | Ambient or battery-sensor °C | — |
| `BatterySoC_Calculated` | Number | Smoothed displayed SoC (%.2f) | yes |
| `BatterySoC_CoulombCounter` | Number | Raw coulomb-tracked SoC (%) | yes |
| `Battery_Voltage_EMA` | Number | Exponential moving-average voltage | yes |
| `Battery_Voltage_EMA_Ts` | DateTime | Timestamp of EMA sample | yes |
| `Battery_TailOk_Since` | DateTime | Timer for float tail current | yes |
| `Battery_Remaining_Ah` | Number | Present Ah remaining | yes |
| `Battery_Runtime_Hours` | Number | Hours to 40 % SoC (@ current load) | yes |

---

## 🧠 Rule Creation

1. Open **MainUI → Settings → Rules → + Add Rule**  
2. **Triggers:**  
   - *When Item DCData_Voltage receives update*  
   - *or Item DCData_Current receives update*  
3. **Action:**  
   - Action Type → *Script* → Language **Rules DSL**  
   - Paste the entire script (`battery_soc_calc.rules`)  
4. Save and enable.

---

## 📊 Output Items

- `BatterySoC_Calculated` → Displayed %.2f SoC  
- `BatterySoC_CoulombCounter` → Underlying integrated SoC  
- `Battery_Remaining_Ah` → Current energy reserve (Ah)  
- `Battery_Runtime_Hours` → Estimated hours to 40 % SoC while discharging  

---

## 🔧 Parameters (adjust inside script)

| Variable | Default | Description |
|-----------|----------|-------------|
| `TOTAL_CAPACITY_AH` | 830.0 | Bank capacity (Ah) |
| `PEUKERT_EXPONENT` | 1.15 | AGM Peukert factor |
| `RUNTIME_DOD_LIMIT_PCT` | 60 | Runtime stops at 40 % SoC |
| `TAIL_CURRENT_THRESH` | 8.3 A | C/100 tail current |
| `EMA_ALPHA` | 0.1 | Voltage EMA smoothing |
| `rampRatePctPerMin` | 0.2 | Ramp speed 99→100 % |

---

## 🧪 Validation

View logs with:
```bash
openhab-cli console
log:tail SoC_AGM_Calc
