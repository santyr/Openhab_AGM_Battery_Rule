// ===============================
// Fullriver DC400-6 (8S2P) AGM SoC + Runtime
// OpenHAB 5.2+  |  Rules DSL | PRO GRADE
// ===============================

// --- Battery Configuration ---
val double TOTAL_CAPACITY_AH = 830.0

// --- Voltage-SoC Points (OCV @ 25°C) ---
val java.util.List<Double> V_POINTS = new java.util.ArrayList<Double>(java.util.Arrays.asList(
    46.00, 47.04, 48.00, 49.04, 50.00, 51.04
))
val java.util.List<Double> SOC_POINTS = new java.util.ArrayList<Double>(java.util.Arrays.asList(
    0.0, 20.0, 40.0, 60.0, 80.0, 100.0
))

// --- Physics Constants ---
val double NOMINAL_TEMP_C        = 25.0
val double TEMP_COEFF_OCV_PACK   = -0.096
val double PEUKERT_EXPONENT      = 1.15
val double C20_RATE              = TOTAL_CAPACITY_AH / 20.0
val double CEF_NORMAL            = 0.98
val double CEF_HIGH_SOC          = 0.92
val double CEF_HIGH_SOC_THRESH   = 85.0

// --- Thresholds & Timers ---
val double MAX_INTEGRATION_INTERVAL_SEC = 300.0  // Gap limit
val double ZERO_CURRENT_THRESHOLD       = 0.3    // Amps. Treat anything less as 0.0 (Noise Filter)
val double REST_CURRENT_THRESH          = 2.0    // Amps. Threshold for "Resting"
val double TAIL_CURRENT_THRESH          = 6.5    // Amps. For Full detection
val long   TAIL_PERSIST_MS              = 15L * 60L * 1000L

// --- Dynamic Settling Times ---
// Surface charge takes longer to dissipate than voltage sag recovers
val long   REST_TIME_AFTER_CHARGE_MS    = 60L * 60L * 1000L // 60 Mins
val long   REST_TIME_AFTER_DISCHARGE_MS = 15L * 60L * 1000L // 15 Mins

// --- Slew Rate Limit ---
val double MAX_SOC_JUMP_PER_RUN         = 1.0    // Max % change per execution to prevent jagged graphs

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
val LAST_ACTIVITY_ITEM          = Battery_LastActivityType // String: "CHARGE" or "DISCHARGE"

// --- Outputs ---
val BATTERY_REMAINING_AH_ITEM   = Battery_Remaining_Ah
val BATTERY_RUNTIME_HOURS_ITEM  = Battery_Runtime_Hours
val BATTERY_TTF_HOURS_ITEM      = Battery_TimeToFull_Hours

val String MAIN_LOG  = "SoC_Pro_Calc"

// ===============================
// Execution
// ===============================

if (BATTERY_VOLTAGE_ITEM.state == NULL || BATTERY_CURRENT_ITEM.state == NULL) return;
val long nowMs = java.time.ZonedDateTime::now().toInstant().toEpochMilli()

// 1. Fetch Inputs & Filter Noise
var double vRaw = (BATTERY_VOLTAGE_ITEM.state as Number).doubleValue
var double iRaw = (BATTERY_CURRENT_ITEM.state as Number).doubleValue

// Noise Suppression (Ghost Current)
if (java.lang.Math::abs(iRaw) <= ZERO_CURRENT_THRESHOLD) iRaw = 0.0

var double tempC = NOMINAL_TEMP_C
if (BATTERY_TEMPERATURE_ITEM.state instanceof QuantityType) {
    tempC = (BATTERY_TEMPERATURE_ITEM.state as QuantityType<Number>).toUnit("°C").doubleValue
}

// 2. Track Activity Type (for dynamic rest times)
// If we are moving significantly, record what we are doing
if (iRaw > REST_CURRENT_THRESH) postUpdate(LAST_ACTIVITY_ITEM, "CHARGE")
else if (iRaw < -REST_CURRENT_THRESH) postUpdate(LAST_ACTIVITY_ITEM, "DISCHARGE")

// 3. Temperature Compensated OCV & EMA
val double vCompensated = vRaw - (tempC - NOMINAL_TEMP_C) * TEMP_COEFF_OCV_PACK
val double EMA_ALPHA = 0.05
var double vEma  = if (V_EMA_ITEM.state instanceof Number) (V_EMA_ITEM.state as Number).doubleValue else vCompensated
val double vEmaNew = (1.0 - EMA_ALPHA) * vEma + EMA_ALPHA * vCompensated
postUpdate(V_EMA_ITEM, vEmaNew)

// 4. Smart Rest Detection
val boolean isResting = java.lang.Math::abs(iRaw) < REST_CURRENT_THRESH
var long stableSince = nowMs
if (V_EMA_TIME_ITEM.state instanceof DateTimeType) {
    stableSince = (V_EMA_TIME_ITEM.state as DateTimeType).zonedDateTime.toInstant().toEpochMilli()
}

// Reset timer if not resting OR voltage is jumping
if (!isResting || java.lang.Math::abs(vEmaNew - vEma) > 0.05) {
    postUpdate(V_EMA_TIME_ITEM, new DateTimeType(java.time.ZonedDateTime::now()))
    stableSince = nowMs
}

// Determine required wait time based on previous activity
var long requiredWait = REST_TIME_AFTER_DISCHARGE_MS // default short
if (LAST_ACTIVITY_ITEM.state.toString == "CHARGE") {
    requiredWait = REST_TIME_AFTER_CHARGE_MS
}

val boolean ocvValid = isResting && ((nowMs - stableSince) >= requiredWait)

// 5. Calculate Voltage-Lookup SoC
var double voltageSoC = -1.0
if (ocvValid) {
    if (vEmaNew <= V_POINTS.get(0)) voltageSoC = 0.0
    else if (vEmaNew >= V_POINTS.get(V_POINTS.size() - 1)) voltageSoC = 100.0
    else {
        for (var i = 0; i < V_POINTS.size() - 1; i++) {
            if (vEmaNew >= V_POINTS.get(i) && vEmaNew < V_POINTS.get(i+1)) {
                val double v1 = V_POINTS.get(i); val double v2 = V_POINTS.get(i+1)
                val double s1 = SOC_POINTS.get(i); val double s2 = SOC_POINTS.get(i+1)
                voltageSoC = s1 + (vEmaNew - v1) / (v2 - v1) * (s2 - s1)
            }
        }
    }
}

// 6. Coulomb Counting
var double currentSoC = 50.0
if (BATTERY_SOC_COULOMB_ITEM.state instanceof Number) {
    val double prev = (BATTERY_SOC_COULOMB_ITEM.state as Number).doubleValue
    if (prev >= 0 && prev <= 100) currentSoC = prev
}

if (BATTERY_SOC_COULOMB_ITEM.lastUpdate !== null) {
    val long lastUpdateMs = BATTERY_SOC_COULOMB_ITEM.lastUpdate.toInstant().toEpochMilli()
    val double dt = (nowMs - lastUpdateMs) / 1000.0

    if (dt > 0 && dt <= MAX_INTEGRATION_INTERVAL_SEC) {
        var double iEffective = iRaw
        if (iRaw > 0) {
            val double cef = if (currentSoC > CEF_HIGH_SOC_THRESH) CEF_HIGH_SOC else CEF_NORMAL
            iEffective = iRaw * cef
        } else if (iRaw < 0) {
            val double ratio = java.lang.Math::min((java.lang.Math::abs(iRaw) / C20_RATE), 5.0)
            if (ratio > 1.0) iEffective = iRaw * java.lang.Math.pow(ratio, PEUKERT_EXPONENT - 1.0)
        }

        // Only integrate if Current is not 0 (Optimization)
        if (iRaw != 0.0) {
            val double ahDelta = (iEffective * dt) / 3600.0
            val double socDelta = (ahDelta / TOTAL_CAPACITY_AH) * 100.0
            currentSoC = currentSoC + socDelta
        }
    } else if (dt > MAX_INTEGRATION_INTERVAL_SEC) {
        // GAP RECOVERY
        logWarn(MAIN_LOG, "Gap Detected ({}s).", dt)
        if (ocvValid && voltageSoC >= 0) {
            // We trust voltage completely after a gap if resting
            currentSoC = voltageSoC
            logInfo(MAIN_LOG, "Gap Recovery: Snapped to Voltage SoC {}%", voltageSoC)
        }
    }
}

// 7. Drift Correction with Slew Rate Limit
var double targetSoC = currentSoC
if (ocvValid && voltageSoC >= 0) {
    val double diff = java.lang.Math::abs(currentSoC - voltageSoC)
    // Only correct if diff is relevant (>3%) to avoid micro-jitter
    if (diff > 3.0) {
         // Move 10% of the way towards the voltage target
         targetSoC = currentSoC + (voltageSoC - currentSoC) * 0.1
         logInfo(MAIN_LOG, "Drift Correction: Coulomb {}% -> Target {}% (via VSoC {}%)", 
             String::format("%.2f", currentSoC), String::format("%.2f", targetSoC), String::format("%.2f", voltageSoC))
    }
}

// 8. True Full Reset
val boolean isAbsorb = vRaw > 58.0 || "Absorption".equals(CHARGER_STATUS_ITEM.state.toString) || "Float".equals(CHARGER_STATUS_ITEM.state.toString)
if (isAbsorb && iRaw < TAIL_CURRENT_THRESH && iRaw > 0) {
    var long tailSince = nowMs
    if (TAIL_OK_SINCE_ITEM.state instanceof DateTimeType) {
        tailSince = (TAIL_OK_SINCE_ITEM.state as DateTimeType).zonedDateTime.toInstant().toEpochMilli()
    } else {
        postUpdate(TAIL_OK_SINCE_ITEM, new DateTimeType(java.time.ZonedDateTime::now()))
    }
    if ((nowMs - tailSince) > TAIL_PERSIST_MS) {
        targetSoC = 100.0 // Force Full
    }
} else {
    postUpdate(TAIL_OK_SINCE_ITEM, new DateTimeType(java.time.ZonedDateTime::now()))
}

// 9. Apply Slew Rate Limiting (The "Anti-Jump" Logic)
// We calculated a 'targetSoC', but we restrict how fast we can get there
var double finalSoC = currentSoC
val double change = targetSoC - currentSoC

if (java.lang.Math::abs(change) > MAX_SOC_JUMP_PER_RUN) {
    if (change > 0) finalSoC = currentSoC + MAX_SOC_JUMP_PER_RUN
    else finalSoC = currentSoC - MAX_SOC_JUMP_PER_RUN
} else {
    finalSoC = targetSoC
}

// 10. Final Bounds & Update
finalSoC = java.lang.Math::min(100.0, java.lang.Math::max(0.0, finalSoC))
postUpdate(BATTERY_SOC_COULOMB_ITEM, finalSoC)
postUpdate(BATTERY_SOC_CALCULATED_ITEM, String::format("%.1f", finalSoC))

// 11. Runtime Estimates
if (iRaw < -1.0) {
    val double remainingAh = (finalSoC / 100.0) * TOTAL_CAPACITY_AH
    val double hours = remainingAh / java.lang.Math::abs(iRaw)
    postUpdate(BATTERY_REMAINING_AH_ITEM, remainingAh)
    postUpdate(BATTERY_RUNTIME_HOURS_ITEM, hours)
    postUpdate(BATTERY_TTF_HOURS_ITEM, UNDEF)
} else if (iRaw > 1.0 && finalSoC < 99.0) {
    val double ahNeeded = ((100.0 - finalSoC) / 100.0) * TOTAL_CAPACITY_AH
    val double hours = ahNeeded / (iRaw * CEF_NORMAL)
    postUpdate(BATTERY_TTF_HOURS_ITEM, hours)
    postUpdate(BATTERY_RUNTIME_HOURS_ITEM, UNDEF)
} else {
    postUpdate(BATTERY_TTF_HOURS_ITEM, UNDEF)
    postUpdate(BATTERY_RUNTIME_HOURS_ITEM, UNDEF)
}
