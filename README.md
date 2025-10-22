# Battery SoC, Runtime, and Time-to-Full (Fullriver DC400-6, 8S2P; Schneider MPPT 60-150)

OpenHAB 5.2+ Rules DSL script that computes SoC with voltage–coulomb fusion, temperature and Peukert corrections, smooth 99→100 % ramp, **runtime to 40 % SoC**, and **time-to-full (TTF)** while charging.

## Requirements

**Battery**
- Fullriver DC400-6 AGM, 8S2P, **830 Ah @ C20**.
- Float 54.6 V, Absorption 58.8 V.

**Charge controller**
- Schneider **MPPT 60-150**. Output limited to **60 A**; DC-DC efficiency assumed **0.97**.

## Items to create

Create these in **MainUI → Settings → Items → + Add Item**. Use the shown types. Enable *restoreOnStartup* on the helpers and outputs.

| Item Name | Type | Purpose | Persist |
|---|---|---|---|
| `DCData_Voltage` | Number:ElectricPotential | Battery pack voltage (V) | — |
| `DCData_Current` | Number:ElectricCurrent | Pack current (+A charge, −A discharge) | — |
| `ChargerStatus` | String | “Bulk”, “Absorption”, “Float” | — |
| `AmbientWeatherWS2902A_WH31E_193_Temperature` | Number:Temperature | Battery/ambient °C | — |
| `BatterySoC_CoulombCounter` | Number | Raw coulomb-tracked SoC (%) | yes |
| `BatterySoC_Calculated` | Number | Smoothed display SoC (%.2f) | yes |
| `Battery_Voltage_EMA` | Number | EMA voltage | yes |
| `Battery_Voltage_EMA_Ts` | DateTime | EMA timestamp | yes |
| `Battery_TailOk_Since` | DateTime | Tail-current timer | yes |
| `Battery_Remaining_Ah` | Number | Remaining Ah | yes |
| `Battery_Runtime_Hours` | Number | Runtime to 40 % SoC (h) | yes |
| `PV_Current` | Number or Number:ElectricCurrent | PV array current (A or mA) | — |
| `PV_Power` | Number or Number:Power | PV power (W) | — |
| `PV_Voltage` | Number or Number:ElectricPotential | PV voltage (V or mV) | — |
| `Battery_TimeToFull_Hours` | Number | **Time to full** while charging (h) | yes |

## State descriptions (UI formatting)

Add in **MainUI → Items → [item] → Add metadata → State description**.

- `BatterySoC_Calculated` → **Pattern:** `%.2f %%`
- `Battery_Remaining_Ah` → **Pattern:** `%.1f Ah`
- `Battery_Runtime_Hours` → **Pattern:** `%.2f h`
- `Battery_TimeToFull_Hours` → **Pattern:** `%.2f h`

> Suggested **state description** for `Battery_TimeToFull_Hours`:  
> **Pattern:** `%.2f h`  
> **Options:** leave empty  
> **Read-only:** unchecked

## Rule

Create a rule in **MainUI → Settings → Rules → + Add Rule**.
- **Triggers:** “Item `DCData_Voltage` received update” OR “Item `DCData_Current` received update”.
- **Action:** Script (Rules DSL). Paste the full script from `battery_soc_calc.rules`.

## Tuning knobs (inside script)

- `TOTAL_CAPACITY_AH = 830.0`
- `PEUKERT_EXPONENT = 1.15`
- `RUNTIME_DOD_LIMIT_PCT = 60.0`  → runtime stops at 40 % SoC
- `TAIL_CURRENT_THRESH = C/100`
- `EMA_ALPHA = 0.1`
- `CONTROLLER_MAX_CHG_A = 60.0`, `CONTROLLER_EFF = 0.97`
- Ramp rate near full: `rampRatePctPerMin = 0.2`

## Notes

- TTF is computed only when charging and reports `UNDEF` otherwise.
- PV current/voltage may arrive in mA/mV; the script auto-scales.
- Accuracy improves with valid charger status, temperature, and persistent EMA/tail items.
