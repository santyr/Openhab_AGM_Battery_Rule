# Battery SoC, Runtime, and Time-to-Full Monitor

**Hardware:** Fullriver DC400-6 (8S2P) | Schneider MPPT 60-150
**Platform:** OpenHAB 5.2+ (Rules DSL)

This script implements a comprehensive Battery Management System (BMS) logic using **Voltage–Coulomb Fusion**. It provides accurate State of Charge (SoC), temperature/Peukert-compensated runtime, and a predictive Time-to-Full (TTF) based on available solar power and hardware limits.

## Key Features

*   **Hybrid SoC Calculation:** Combines Coulomb counting (Ah tracking) with voltage-based drift correction and a smooth 99% → 100% ramp during absorption/float.
*   **Peukert-Compensated Runtime:** Calculates remaining runtime down to a safe **40% SoC** floor, adjusting for current discharge load and Peukert effect.
*   **Smart Time-to-Full (TTF):** Estimates charging time by analyzing available PV power, clamping it to the Schneider MPPT limit (60A), and accounting for DC-DC conversion efficiency.
*   **Auto-Scaling Inputs:** Automatically handles PV inputs in either standard units (V/A) or milli-units (mV/mA).

---

## Hardware Profile

| Parameter | Value | Notes |
| :--- | :--- | :--- |
| **Battery Bank** | Fullriver DC400-6 AGM | 48V System (8S2P Topology) |
| **Capacity** | **830 Ah** @ C20 | |
| **Charging Profile** | Float: 54.6V | Absorption: 58.8V |
| **Charge Controller** | Schneider MPPT 60-150 | **60A** Max Output Limit |
| **Efficiency** | 97% (0.97) | Assumed DC-DC conversion loss |

---

## Items Configuration

Create the following items in **MainUI → Settings → Items**.
*Ensure `restoreOnStartup` is enabled on all Output and Internal Helper items to prevent calculation resets on reboot.*

### 1. Input Sensors (Required)
| Item Name | Type | Description |
| :--- | :--- | :--- |
| `DCData_Voltage` | `Number:ElectricPotential` | Main Battery Bank Voltage |
| `DCData_Current` | `Number:ElectricCurrent` | Net Battery Current (+A charging, -A discharging) |
| `ChargerStatus` | `String` | Charge Stage (e.g., "Bulk", "Absorption", "Float") |
| `AmbientWeather..._Temperature` | `Number:Temperature` | Battery or Ambient Temperature |

### 2. PV Inputs (Required for TTF)
*Used to calculate potential charging power even if the battery is currently limiting current.*
| Item Name | Type | Description |
| :--- | :--- | :--- |
| `PV_Current` | `Number:ElectricCurrent` | PV Array Input Current (A or mA) |
| `PV_Voltage` | `Number:ElectricPotential` | PV Array Input Voltage (V or mV) |
| `PV_Power` | `Number:Power` | (Optional) PV Input Power |

### 3. Outputs & Helpers
| Item Name | Type | Persistence | Description |
| :--- | :--- | :--- | :--- |
| `BatterySoC_Calculated` | `Number` | **YES** | Final Display SoC (%) |
| `BatterySoC_CoulombCounter` | `Number` | **YES** | Raw tracked Ah percentage |
| `Battery_Runtime_Hours` | `Number` | **YES** | Time remaining until 40% SoC |
| `Battery_TimeToFull_Hours` | `Number` | **YES** | Estimated time to 100% SoC |
| `Battery_Remaining_Ah` | `Number` | **YES** | Remaining capacity in Ah |
| `Battery_Voltage_EMA` | `Number` | **YES** | Exponential Moving Average Voltage |
| `Battery_Voltage_EMA_Ts` | `DateTime` | **YES** | Timestamp for EMA calculation |
| `Battery_TailOk_Since` | `DateTime` | **YES** | Timer for tail-current detection |

---

## UI State Descriptions

Add these metadata patterns in **MainUI** (Item → Add Metadata → State Description) to ensure correct formatting in your sitemap/widgets.

*   **`BatterySoC_Calculated`**
    *   Pattern: `%.2f %%`
*   **`Battery_Remaining_Ah`**
    *   Pattern: `%.1f Ah`
*   **`Battery_Runtime_Hours`**
    *   Pattern: `%.2f h`
*   **`Battery_TimeToFull_Hours`**
    *   Pattern: `%.2f h`
    *   *Note: Returns `UNDEF` when not charging.*

---

## Installation

1.  **Create Rule:** Go to **MainUI → Settings → Rules → + Add Rule**.
2.  **Triggers:**
    *   Item `DCData_Voltage` received update
    *   *OR* Item `DCData_Current` received update
3.  **Action:** Run Script (Rules DSL).
4.  **Code:** Paste the contents of `battery_soc_calc.rules` into the script body.

---

## Logic & Tuning

The following constants are defined at the top of the script. Modify them if your hardware changes.

```java
// Battery Physical Constants
val Number TOTAL_CAPACITY_AH = 830.0   // @ C20
val Number PEUKERT_EXPONENT  = 1.15    // AGM standard
val Number TAIL_CURRENT_THRESH = 8.3   // ~1% of Capacity (C/100)

// Calculations Limits
val Number RUNTIME_DOD_LIMIT_PCT = 60.0 // 60% DoD = 40% SoC remaining

// Hardware Limitations (Schneider MPPT 60-150)
val Number CONTROLLER_MAX_CHG_A = 60.0 // Max amps controller can push to battery
val Number CONTROLLER_EFF = 0.97       // Efficiency from PV High Voltage -> Battery Low Voltage

// Smoothing
val Number EMA_ALPHA = 0.1             // Voltage smoothing factor (0.1 = slow, 0.5 = fast)```

### How Time-to-Full (TTF) Works

The script calculates how much power the solar array *could* provide versus how much the battery *needs*.

1.  **Input Normalization:** It reads `PV_Voltage` and `PV_Current`. If sensors report in mV/mA, the script detects this and converts to V/A automatically.
2.  **Power Calculation:** `Raw Solar Power = PV_Volts * PV_Amps`.
3.  **Efficiency Loss:** Applies `CONTROLLER_EFF` (0.97) to account for MPPT conversion heat loss.
4.  **Potential Current:** Converts the available Watts into potential charging Amps at the current battery voltage.
5.  **Hardware Clamping:** If the potential current exceeds the Schneider MPPT limit (`CONTROLLER_MAX_CHG_A` = 60A), the calculation is capped at 60A.
6.  **Final Estimate:** The script divides the missing Amp-hours (Capacity - Current Ah) by this clamped current to determine hours remaining.
