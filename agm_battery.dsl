// ===============================
// Fullriver DC400-6 (8S2P) AGM SoC + Runtime + Time-To-Full
// OpenHAB 5.2+  |  Rules DSL | FIXED & OPTIMIZED
// ===============================

// --- Capacity and core battery config ---
val double TOTAL_CAPACITY_AH = 830.0

// --- Voltage-SoC Points (OCV @ 25°C → 48 V pack) ---
val java.util.List<Double> V_POINTS = new java.util.ArrayList<Double>(java.util.Arrays.asList(
    46.00, 47.04, 48.00, 49.04, 50.00, 51.04
))
val java.util.List<Double> SOC_POINTS = new java.util.ArrayList<Double>(java.util.Arrays.asList(
    0.0, 20.0, 40.0, 60.0, 80.0, 100.0
))

// --- Physics Models ---
val double EFFECTIVE_R_NOMINAL   = 0.0064
val double NOMINAL_TEMP_C        = 25.0
val double TEMP_COEFF_OCV_PACK   = -0.096
val double TEMP_COEFF_R          = -0.015

// --- Integration Settings ---
val double MAX_INTEGRATION_INTERVAL_SEC = 300.0 // 5 Minutes. If gap is larger, DO NOT integrate.
val double CEF_NORMAL            = 0.98
val double CEF_HIGH_SOC          = 0.92
val double CEF_HIGH_SOC_THRESH   = 85.0
val double PEUKERT_EXPONENT      = 1.15
val double C20_RATE              = TOTAL_CAPACITY_AH / 20.0

// --- Full Detection ---
val double TAIL_CURRENT_THRESH   = 6.5
val long   TAIL_PERSIST_MS       = 15L * 60L * 1000L
val double ABSORPTION_V_MIN      = 58.0

// --- OCV Stability ---
val double EMA_ALPHA             = 0.05
val double REST_CURRENT_THRESH   = 2.0
val long   OCV_MIN_STABLE_MS     = 45L * 60L * 1000L

// --- Items ---
val BATTERY_VOLTAGE_ITEM        = DCData_Voltage
val BATTERY_CURRENT_ITEM        = DCData_Current
val CHARGER_STATUS_ITEM         = ChargerStatus
val BATTERY_TEMPERATURE_ITEM    = AmbientWeatherWS2902A_WH31E_193_Temperature
val BATTERY_SOC_CALCULATED_ITEM = BatterySoC_Calculated
val BATTERY_SOC_COULOMB_ITEM    = BatterySoC_CoulombCounter
val V_EMA_ITEM                  = Battery_Voltage_EMA
val V_EMA_TIME_ITEM             = Battery_Voltage_EMA_Ts
val TAIL_OK_SINCE_ITEM          = Battery_TailOk_Since

// --- Outputs ---
val BATTERY_REMAINING_AH_ITEM   = Battery_Remaining_Ah
val BATTERY_RUNTIME_HOURS_ITEM  = Battery_Runtime_Hours
val BATTERY_TTF_HOURS_ITEM      = Battery_TimeToFull_Hours

// --- PV Items ---
val PV_POWER_ITEM               = PV_Power

// --- Logging ---
val String MAIN_LOG  = "SoC_AGM_Calc"

// ===============================
// Execution
// ===============================

// 1. Validate Inputs
if (BATTERY_VOLTAGE_ITEM.state == NULL || BATTERY_CURRENT_ITEM.state == NULL) return;

val long nowMs = java.time.ZonedDateTime::now().toInstant().toEpochMilli()

// Fetch Inputs
var double vRaw = (BATTERY_VOLTAGE_ITEM.state as Number).doubleValue
var double iRaw = (BATTERY_CURRENT_ITEM.state as Number).doubleValue
var double tempC = NOMINAL_TEMP_C
if (BATTERY_TEMPERATURE_ITEM.state instanceof QuantityType) {
    tempC = (BATTERY_TEMPERATURE_ITEM.state as QuantityType<Number>).toUnit("°C").doubleValue
}

// Fetch Previous SoC
var double currentSoC = 50.0
var double lastSoCVal = -1.0
if (BATTERY_SOC_COULOMB_ITEM.state instanceof Number) {
    lastSoCVal = (BATTERY_SOC_COULOMB_ITEM.state as Number).doubleValue
    if (lastSoCVal >= 0 && lastSoCVal <= 100) currentSoC = lastSoCVal
}

// --- 2. Temperature Compensated OCV & EMA ---
val double vCompensated = vRaw - (tempC - NOMINAL_TEMP_C) * TEMP_COEFF_OCV_PACK

var double vEma  = if (V_EMA_ITEM.state instanceof Number) (V_EMA_ITEM.state as Number).doubleValue else vCompensated
val double vEmaNew = (1.0 - EMA_ALPHA) * vEma + EMA_ALPHA * vCompensated
postUpdate(V_EMA_ITEM, vEmaNew)

// --- 3. Determine State & OCV Validity ---
val double iAbs = java.lang.Math::abs(iRaw)
val boolean isResting = iAbs < REST_CURRENT_THRESH

var long stableSince = nowMs
if (V_EMA_TIME_ITEM.state instanceof DateTimeType) {
    stableSince = (V_EMA_TIME_ITEM.state as DateTimeType).zonedDateTime.toInstant().toEpochMilli()
}

if (!isResting || java.lang.Math::abs(vEmaNew - vEma) > 0.05) {
    postUpdate(V_EMA_TIME_ITEM, new DateTimeType(java.time.ZonedDateTime::now()))
    stableSince = nowMs
}

val boolean ocvValid = isResting && ((nowMs - stableSince) >= OCV_MIN_STABLE_MS)

// --- 4. Calculate Voltage-Lookup SoC ---
var double voltageSoC = -1.0
if (ocvValid) {
    if (vEmaNew <= V_POINTS.get(0)) voltageSoC = 0.0
    else if (vEmaNew >= V_POINTS.get(V_POINTS.size() - 1)) voltageSoC = 100.0
    else {
        for (var i = 0; i < V_POINTS.size() - 1; i++) {
            if (vEmaNew >= V_POINTS.get(i) && vEmaNew < V_POINTS.get(i+1)) {
                val double v1 = V_POINTS.get(i)
                val double v2 = V_POINTS.get(i+1)
                val double s1 = SOC_POINTS.get(i)
                val double s2 = SOC_POINTS.get(i+1)
                voltageSoC = s1 + (vEmaNew - v1) / (v2 - v1) * (s2 - s1)
            }
        }
    }
}

// --- 5. COULOMB COUNTING (With Gap Protection) ---
if (BATTERY_SOC_COULOMB_ITEM.lastUpdate !== null) {
    val long lastUpdateMs = BATTERY_SOC_COULOMB_ITEM.lastUpdate.toInstant().toEpochMilli()
    val double dt = (nowMs - lastUpdateMs) / 1000.0

    if (dt > 0 && dt <= MAX_INTEGRATION_INTERVAL_SEC) {
        var double iEffective = iRaw

        if (iRaw > 0) {
            val double cef = if (currentSoC > CEF_HIGH_SOC_THRESH) CEF_HIGH_SOC else CEF_NORMAL
            iEffective = iRaw * cef
        } else {
            val double ratio = java.lang.Math::min((iAbs / C20_RATE), 5.0)
            if (ratio > 1.0) {
                 val double peukertFactor = java.lang.Math.pow(ratio, PEUKERT_EXPONENT - 1.0)
                 iEffective = iRaw * peukertFactor
            }
        }

        val double ahDelta = (iEffective * dt) / 3600.0
        val double socDelta = (ahDelta / TOTAL_CAPACITY_AH) * 100.0
        currentSoC = currentSoC + socDelta

    } else if (dt > MAX_INTEGRATION_INTERVAL_SEC) {
        logWarn(MAIN_LOG, "Data Gap Detected ({}s). Skipping integration.", dt)
        if (ocvValid && voltageSoC >= 0) {
            currentSoC = voltageSoC
            logInfo(MAIN_LOG, "Restored from Gap using Voltage SoC: {}%", voltageSoC)
        }
    }
} else {
    if (voltageSoC >= 0) currentSoC = voltageSoC
}

// --- 6. Drift Correction ---
if (ocvValid && voltageSoC >= 0) {
    val double diff = java.lang.Math::abs(currentSoC - voltageSoC)
    if (diff > 5.0) {
        logInfo(MAIN_LOG, "Drift > 5%. Correcting Coulomb {}% -> Voltage {}%", String::format("%.1f", currentSoC), String::format("%.1f", voltageSoC))
        currentSoC = currentSoC + (voltageSoC - currentSoC) * 0.2
    }
}

// --- 7. "True Full" Reset (FIXED VARIABLES HERE) ---
var String chgStatus = CHARGER_STATUS_ITEM.state.toString
val boolean isAbsorb = "Absorption".equals(chgStatus) || "Float".equals(chgStatus) || vRaw > ABSORPTION_V_MIN

if (isAbsorb && iRaw < TAIL_CURRENT_THRESH && iRaw > 0) {
    var long tailSince = nowMs
    if (TAIL_OK_SINCE_ITEM.state instanceof DateTimeType) {
        tailSince = (TAIL_OK_SINCE_ITEM.state as DateTimeType).zonedDateTime.toInstant().toEpochMilli()
    } else {
        postUpdate(TAIL_OK_SINCE_ITEM, new DateTimeType(java.time.ZonedDateTime::now()))
    }

    if ((nowMs - tailSince) > TAIL_PERSIST_MS) {
        if (currentSoC < 100.0) {
            logInfo(MAIN_LOG, "Full Charge Detected (Tail Current). Resetting to 100%.")
            currentSoC = 100.0
        }
    }
} else {
    postUpdate(TAIL_OK_SINCE_ITEM, new DateTimeType(java.time.ZonedDateTime::now()))
}

// --- 8. Bounds & Persistence ---
currentSoC = java.lang.Math::min(100.0, java.lang.Math::max(0.0, currentSoC))
postUpdate(BATTERY_SOC_COULOMB_ITEM, currentSoC)

var double displaySoC = currentSoC
if (BATTERY_SOC_CALCULATED_ITEM.state instanceof Number) {
    val double oldDisp = (BATTERY_SOC_CALCULATED_ITEM.state as Number).doubleValue
    displaySoC = (oldDisp * 0.7) + (currentSoC * 0.3)
}
if (currentSoC >= 99.9) displaySoC = 100.0
postUpdate(BATTERY_SOC_CALCULATED_ITEM, String::format("%.1f", displaySoC))

// --- 9. Runtime & TTF ---
if (iRaw < -1.0) {
    val double remainingAh = (currentSoC / 100.0) * TOTAL_CAPACITY_AH
    val double hours = remainingAh / java.lang.Math::abs(iRaw)
    postUpdate(BATTERY_REMAINING_AH_ITEM, remainingAh)
    postUpdate(BATTERY_RUNTIME_HOURS_ITEM, hours)
    postUpdate(BATTERY_TTF_HOURS_ITEM, UNDEF)
}
else if (iRaw > 1.0 && currentSoC < 99.0) {
    val double ahNeeded = ((100.0 - currentSoC) / 100.0) * TOTAL_CAPACITY_AH
    val double hours = ahNeeded / (iRaw * CEF_NORMAL)
    postUpdate(BATTERY_TTF_HOURS_ITEM, hours)
    postUpdate(BATTERY_RUNTIME_HOURS_ITEM, UNDEF)
}
else {
    postUpdate(BATTERY_TTF_HOURS_ITEM, UNDEF)
    postUpdate(BATTERY_RUNTIME_HOURS_ITEM, UNDEF)
}
