# OpenHAB AGM Battery SoC Rule  
**Fullriver DC400-6 Bank (8S2P, 48 V nominal)**  

This OpenHAB 5.2.x rule calculates and smooths the **State of Charge (SoC)** for an AGM battery bank using a hybrid of **Coulomb counting** and **voltage-based estimation** with dynamic offsets, temperature compensation, Peukert’s law, and tail-current detection.  
Designed for a dual-string (8S2P) Fullriver DC400-6 bank (~800 Ah @ C20).

---

## 📋 Features
- Voltage-SoC mapping from Fullriver OCV spec  
- Coulomb counting with Charge Efficiency Factor and Peukert compensation  
- Adaptive complementary fusion of voltage- and current-based SoC  
- Automatic recalibration during float or at rest  
- Temperature-compensated OCV and internal resistance  
- EMA-based OCV stability gating  
- Smooth ramp-to-100 % when tail-current condition holds  
- Optional persistence for voltage EMA and tail-current timing  
- Outputs display SoC to **two decimal places**

---

## 🧩 Required Items

Create these **Items** in MainUI:

| Item Name | Type | Purpose |
|------------|------|----------|
| `DCData_Voltage` | Number:ElectricPotential | Battery voltage input |
| `DCData_Current` | Number:ElectricCurrent | Charge/discharge current |
| `ChargerStatus` | String | Charger stage: *Bulk*, *Absorption*, *Float* |
| `AmbientWeatherWS2902A_WH31E_193_Temperature` | Number:Temperature | Battery or ambient temperature |
| `BatterySoC_Calculated` | Number | Displayed SoC (%.2f) |
| `BatterySoC_CoulombCounter` | Number | Internal Coulomb counter |

**Helper Items (no channels):**

| Item Name | Type | Description |
|------------|------|--------------|
| `Battery_Voltage_EMA` | Number | Stores smoothed voltage (EMA) |
| `Battery_Voltage_EMA_Ts` | DateTime | Timestamp of last EMA update |
| `Battery_TailOk_Since` | DateTime | Tail-current timer reference |

### Recommended Metadata
For `Battery_Voltage_EMA` → Metadata → *State Description* → `%.2f V`

---

## 💾 Persistence Configuration

Install **MapDB** or **JDBC** persistence and enable:
