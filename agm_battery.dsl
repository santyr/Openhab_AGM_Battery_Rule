// ===============================
// Fullriver DC400-6 (8S2P) AGM SoC + Runtime + Time-To-Full
// OpenHAB 5.2+  |  Rules DSL
// ===============================

// --- Capacity and core battery config ---
val double TOTAL_CAPACITY_AH = 830.0  // 415 Ah per string × 2 strings

// --- Voltage-SoC Points (OCV @ 25°C → 48 V pack) ---
val java.util.List<Double> V_POINTS = new java.util.ArrayList<Double>(java.util.Arrays.asList(
    46.00, 47.04, 48.00, 49.04, 50.00, 51.04
))
val java.util.List<Double> SOC_POINTS = new java.util.ArrayList<Double>(java.util.Arrays.asList(
    0.0, 20.0, 40.0, 60.0, 80.0, 100.0
))

// --- Charger Set Points (spec) ---
val double ABSORPTION_VOLTAGE = 58.8
val double FLOAT_VOLTAGE      = 54.6

// --- Effective internal resistance model (pack ~6.4 mΩ) ---
val double EFFECTIVE_CHARGE_RESISTANCE_NOMINAL    = 0.0064
val double EFFECTIVE_DISCHARGE_RESISTANCE_NOMINAL = 0.0064
val double MAX_CHARGE_OFFSET     = 2.0
val double MAX_DISCHARGE_OFFSET  = 1.5

// --- Temperature compensation ---
val double NOMINAL_TEMPERATURE_C       = 25.0
val double TEMP_COEFF_OCV_VOLTAGE_PACK = -0.096  // V/°C for 48 V pack
val double TEMP_COEFF_RESISTANCE       = -0.015
// Tight operating range
val double MIN_OPERATING_TEMP_C        = -15.0
val double MAX_OPERATING_TEMP_C        = 40.0

// --- Current thresholds ---
val double CHARGE_CURRENT_THRESHOLD              = 0.5
val double DISCHARGE_CURRENT_THRESHOLD           = -0.5
val double LOW_CURRENT_THRESHOLD                 = 6.0
val double COULOMB_MIN_CURRENT_FOR_DELTA_T_CHECK = 0.5

// --- Recalibration thresholds ---
val double COULOMB_RECAL_HIGH_THRESH     = 95.0
val double VOLTAGE_SOC_RECAL_LOW_THRESH  = 90.0
val double MAX_SOC_IN_BULK_ABSORPTION    = 99.0
val double COULOMB_RECAL_LOW_THRESH      = 40.0
val double VOLTAGE_SOC_RECAL_HIGH_THRESH = 60.0

// --- Charge efficiency ---
val double CEF_HIGH_SOC_THRESHOLD = 85.0
val double CEF_NORMAL             = 0.98
val double CEF_HIGH_SOC           = 0.92

// --- Peukert model ---
val double PEUKERT_EXPONENT  = 1.15
val double C20_RATE_CURRENT  = TOTAL_CAPACITY_AH / 20.0  // 41.5 A
val double PEUKERT_MAX_RATIO = 5.0

// --- OCV window / EMA (voltage stability gate) ---
val double EMA_ALPHA                 = 0.1
val double OCV_CURR_THRESH           = TOTAL_CAPACITY_AH / 200.0   // 4.15 A
val double OCV_DVDT_THRESH_V_PER_MIN = 0.005
val long   OCV_MIN_STABLE_MS         = 30L * 60L * 1000L

// --- Tail current “true full” detection ---
val double TAIL_CURRENT_THRESH = TOTAL_CAPACITY_AH / 100.0   // 8.3 A
val long   TAIL_PERSIST_MS     = 20L * 60L * 1000L

// --- Runtime estimator (to 40% SoC remaining) ---
val double RUNTIME_DOD_LIMIT_PCT         = 60.0        // stop estimate at 40% SoC remaining
val double MIN_DISCH_CURRENT_FOR_RUNTIME = 1.0         // A

// --- Time-To-Full (TTF) using Schneider MPPT 60-150 and PV items ---
val double CONTROLLER_MAX_CHG_A = 60.0   // A
val double CONTROLLER_EFF       = 0.97   // DC-DC efficiency estimate

// --- Items: primary measurements ---
val BATTERY_VOLTAGE_ITEM        = DCData_Voltage                   // Number:ElectricPotential
val BATTERY_CURRENT_ITEM        = DCData_Current                   // Number:ElectricCurrent (+A charging, -A discharging)
val CHARGER_STATUS_ITEM         = ChargerStatus                    // String: "Bulk","Absorption","Float"
val BATTERY_TEMPERATURE_ITEM    = AmbientWeatherWS2902A_WH31E_193_Temperature // Number:Temperature

// --- SoC outputs ---
val BATTERY_SOC_CALCULATED_ITEM = BatterySoC_Calculated            // Number (display, %.2f)
val BATTERY_SOC_COULOMB_ITEM    = BatterySoC_CoulombCounter        // Number (raw %)

// --- Helper/persistence Items ---
val V_EMA_ITEM                  = Battery_Voltage_EMA              // Number
val V_EMA_TIME_ITEM             = Battery_Voltage_EMA_Ts           // DateTime
val TAIL_OK_SINCE_ITEM          = Battery_TailOk_Since             // DateTime

// --- Runtime + TTF output Items ---
val BATTERY_REMAINING_AH_ITEM   = Battery_Remaining_Ah             // Number
val BATTERY_RUNTIME_HOURS_ITEM  = Battery_Runtime_Hours            // Number
val BATTERY_TTF_HOURS_ITEM      = Battery_TimeToFull_Hours         // Number

// --- PV Items from Schneider MPPT 60-150 ---
val PV_CURRENT_ITEM             = PV_Current   // may be A or mA
val PV_POWER_ITEM               = PV_Power     // W
val PV_VOLTAGE_ITEM             = PV_Voltage   // may be V or mV

// --- Logs ---
val String MAIN_LOG  = "SoC_AGM_Calc"
val String DEBUG_LOG = "SoC_AGM_Debug"

// ===============================
// Begin execution body
// ===============================

// --- Read states ---
val voltageState         = BATTERY_VOLTAGE_ITEM.state
val currentState         = BATTERY_CURRENT_ITEM.state
val chargerStatusState   = CHARGER_STATUS_ITEM.state
val temperatureState     = BATTERY_TEMPERATURE_ITEM.state
val lastCoulombSoCState  = BATTERY_SOC_COULOMB_ITEM.state
val lastCoulombSoCUpdate = BATTERY_SOC_COULOMB_ITEM.lastUpdate

// --- Initialize Coulomb SoC ---
var double currentCoulombSoC = -1.0
if (lastCoulombSoCState != NULL && lastCoulombSoCState != UNDEF && lastCoulombSoCState instanceof Number) {
  val prev = (lastCoulombSoCState as Number).doubleValue
  if (prev >= 0.0 && prev <= 100.0) currentCoulombSoC = prev
}

// --- Temperature parsing ---
var double currentTemperatureC = NOMINAL_TEMPERATURE_C
if (temperatureState != NULL && temperatureState != UNDEF) {
  try {
    if (temperatureState instanceof QuantityType) {
      currentTemperatureC = (temperatureState as QuantityType<Number>).toUnit("°C").doubleValue
    } else {
      val tempF = (temperatureState as Number).doubleValue
      currentTemperatureC = (tempF - 32.0) * 5.0 / 9.0
    }
  } catch (Exception e) {
    logWarn(MAIN_LOG, "Could not parse temperature. Using nominal {}°C.", NOMINAL_TEMPERATURE_C)
  }
}

// --- Voltage/Current parse guards ---
if (voltageState == NULL || voltageState == UNDEF || currentState == NULL || currentState == UNDEF) {
  logWarn(MAIN_LOG, "Voltage or Current NULL/UNDEF. Abort.")
  return;
}
var double v = if (voltageState instanceof QuantityType) (voltageState as QuantityType<Number>).doubleValue else (voltageState as Number).doubleValue
var double current = if (currentState instanceof QuantityType) (currentState as QuantityType<Number>).doubleValue else (currentState as Number).doubleValue
var String chargeStatusStr = chargerStatusState.toString

// --- Temp-compensated OCV ---
val double ocvAtNominalTemp = v - (currentTemperatureC - NOMINAL_TEMPERATURE_C) * TEMP_COEFF_OCV_VOLTAGE_PACK

// --- EMA + dV/dt for OCV window ---
val long nowMs = java.time.ZonedDateTime::now().toInstant().toEpochMilli()
var double vEma  = if (V_EMA_ITEM.state instanceof Number) (V_EMA_ITEM.state as Number).doubleValue else v
var long   vTsMs = if (V_EMA_TIME_ITEM.state instanceof DateTimeType) (V_EMA_TIME_ITEM.state as DateTimeType).zonedDateTime.toInstant.toEpochMilli else nowMs
val double dtSec = java.lang.Math::max(1.0, (nowMs - vTsMs) / 1000.0)
val double vEmaNew = (1.0 - EMA_ALPHA) * vEma + EMA_ALPHA * v
val double dVdt_V_per_min = ((vEmaNew - vEma) / dtSec) * 60.0
postUpdate(V_EMA_ITEM, vEmaNew)
postUpdate(V_EMA_TIME_ITEM, new DateTimeType(java.time.ZonedDateTime::now()))

// --- Voltage-based SoC when OCV window is valid ---
var double voltageBasedSoC = -1.0
val double Iabs = java.lang.Math::abs(current)
val boolean ocvWindow = (Iabs < OCV_CURR_THRESH) && (java.lang.Math::abs(dVdt_V_per_min) < OCV_DVDT_THRESH_V_PER_MIN) && ((nowMs - vTsMs) >= OCV_MIN_STABLE_MS)

if (ocvWindow) {
  if (V_POINTS.size() != SOC_POINTS.size() || V_POINTS.isEmpty()) {
    logError(MAIN_LOG, "V_POINTS/SOC_POINTS misconfigured.")
  } else {
    var double vLookup = ocvAtNominalTemp
    val double tR = java.lang.Math::max(0.1, (1.0 + TEMP_COEFF_RESISTANCE * (currentTemperatureC - NOMINAL_TEMPERATURE_C)))
    val double rChg = EFFECTIVE_CHARGE_RESISTANCE_NOMINAL * tR
    val double rDis = EFFECTIVE_DISCHARGE_RESISTANCE_NOMINAL * tR
    val boolean bulkOrAbs = "Bulk".equals(chargeStatusStr) || "Absorption".equals(chargeStatusStr)
    if (current >= CHARGE_CURRENT_THRESHOLD || bulkOrAbs) {
      if (current >= CHARGE_CURRENT_THRESHOLD) vLookup = ocvAtNominalTemp - java.lang.Math::min(MAX_CHARGE_OFFSET, java.lang.Math::abs(current) * rChg)
    } else if (current <= DISCHARGE_CURRENT_THRESHOLD) {
      vLookup = ocvAtNominalTemp + java.lang.Math::min(MAX_DISCHARGE_OFFSET, java.lang.Math::abs(current) * rDis)
    }

    if (vLookup <= V_POINTS.get(0)) {
      voltageBasedSoC = SOC_POINTS.get(0)
    } else if (vLookup >= V_POINTS.get(V_POINTS.size() - 1)) {
      voltageBasedSoC = SOC_POINTS.get(V_POINTS.size() - 1)
    } else {
      var boolean done = false
      for (var i = 0; i < V_POINTS.size() - 1 && !done; i++) {
        if (vLookup >= V_POINTS.get(i) && vLookup < V_POINTS.get(i+1)) {
          val double v1 = V_POINTS.get(i); val double v2 = V_POINTS.get(i+1)
          val double s1 = SOC_POINTS.get(i); val double s2 = SOC_POINTS.get(i+1)
          voltageBasedSoC = s1 + (vLookup - v1) / (v2 - v1) * (s2 - s1)
          done = true
        }
      }
    }
  }
}

// --- Seed Coulomb SoC if invalid ---
if ((currentCoulombSoC < 0.0 || currentCoulombSoC > 100.0) && voltageBasedSoC >= 0.0) currentCoulombSoC = voltageBasedSoC

// === Smooth full detection and ramp-to-100 ===
val boolean inAbsorbOrFloat = "Absorption".equals(chargeStatusStr) || "Float".equals(chargeStatusStr)
val boolean tailCurrentOk = Iabs <= TAIL_CURRENT_THRESH
var long tailOkSince = if (TAIL_OK_SINCE_ITEM.state instanceof DateTimeType) (TAIL_OK_SINCE_ITEM.state as DateTimeType).zonedDateTime.toInstant.toEpochMilli else nowMs

if (inAbsorbOrFloat && tailCurrentOk) {
  if (!(TAIL_OK_SINCE_ITEM.state instanceof DateTimeType)) {
    postUpdate(TAIL_OK_SINCE_ITEM, new DateTimeType(java.time.ZonedDateTime::now()))
    tailOkSince = nowMs
  }
  val long tailHeldMs = nowMs - tailOkSince
  if (tailHeldMs >= TAIL_PERSIST_MS) {
    val double minutesBeyond = (tailHeldMs - TAIL_PERSIST_MS) / 60000.0
    val double rampRatePctPerMin = 0.2
    val double rampStartPct = 99.0
    val double target = java.lang.Math::min(100.0, rampStartPct + minutesBeyond * rampRatePctPerMin)
    if (currentCoulombSoC < target) currentCoulombSoC = target
  }
} else {
  postUpdate(TAIL_OK_SINCE_ITEM, new DateTimeType(java.time.ZonedDateTime::now()))
}

// --- State labels (info only) ---
val boolean isBulkOrAbsorption = "Bulk".equals(chargeStatusStr) || "Absorption".equals(chargeStatusStr)
var double voltageForSoCLookup = ocvAtNominalTemp
var String batteryState = "Idle"
if (current >= CHARGE_CURRENT_THRESHOLD) {
  batteryState = if (isBulkOrAbsorption) "Charging (Status: " + chargeStatusStr + ")" else "Charging (Current)"
  val double tR1 = java.lang.Math::max(0.1, (1.0 + TEMP_COEFF_RESISTANCE * (currentTemperatureC - NOMINAL_TEMPERATURE_C)))
  val double rChg1 = EFFECTIVE_CHARGE_RESISTANCE_NOMINAL * tR1
  voltageForSoCLookup = ocvAtNominalTemp - java.lang.Math::min(MAX_CHARGE_OFFSET, java.lang.Math::abs(current) * rChg1)
} else if (current <= DISCHARGE_CURRENT_THRESHOLD) {
  batteryState = "Discharging"
  val double tR2 = java.lang.Math::max(0.1, (1.0 + TEMP_COEFF_RESISTANCE * (currentTemperatureC - NOMINAL_TEMPERATURE_C)))
  val double rDis1 = EFFECTIVE_DISCHARGE_RESISTANCE_NOMINAL * tR2
  voltageForSoCLookup = ocvAtNominalTemp + java.lang.Math::min(MAX_DISCHARGE_OFFSET, java.lang.Math::abs(current) * rDis1)
}

// --- Recalibration gates ---
val boolean atRest = (Iabs < CHARGE_CURRENT_THRESHOLD)
if (currentCoulombSoC >= 0.0 && (isBulkOrAbsorption || atRest)) {
  val double initial = currentCoulombSoC
  var boolean did = false
  var String reason = ""
  if (isBulkOrAbsorption && initial > COULOMB_RECAL_HIGH_THRESH && voltageBasedSoC >= 0.0 && voltageBasedSoC < VOLTAGE_SOC_RECAL_LOW_THRESH) {
    currentCoulombSoC = voltageBasedSoC; did = true; reason = "Coulomb High vs VSoC Low"
  } else if (atRest && initial < COULOMB_RECAL_LOW_THRESH && voltageBasedSoC > VOLTAGE_SOC_RECAL_HIGH_THRESH) {
    currentCoulombSoC = voltageBasedSoC; did = true; reason = "Coulomb Low vs VSoC High (rest)"
  } else if (isBulkOrAbsorption && initial > MAX_SOC_IN_BULK_ABSORPTION) {
    currentCoulombSoC = MAX_SOC_IN_BULK_ABSORPTION; did = true; reason = "Cap in Bulk/Absorption"
  }
  if (did) logInfo(MAIN_LOG, "SoC Recalibration: Init {}%, VSoC {}%, New {}%. {}",
      String::format("%.1f", initial),
      if (voltageBasedSoC == -1.0) "N/A" else String::format("%.1f", voltageBasedSoC),
      String::format("%.1f", currentCoulombSoC),
      reason)
}

// --- Coulomb counting with CEF and Peukert clamp ---
if (currentCoulombSoC >= 0.0 && currentCoulombSoC <= 100.0) {
  if (lastCoulombSoCUpdate != null && TOTAL_CAPACITY_AH > 0) {
    val long lastUpdateMillis = lastCoulombSoCUpdate.toInstant().toEpochMilli()
    var double deltaTimeSeconds = (nowMs - lastUpdateMillis) / 1000.0
    if (deltaTimeSeconds < 0) deltaTimeSeconds = 0
    if (deltaTimeSeconds > (2 * 3600.0) && java.lang.Math::abs(current) > COULOMB_MIN_CURRENT_FOR_DELTA_T_CHECK) {
      logWarn(MAIN_LOG, "Large dT ({}s), recalibrating with VSoC.", String::format("%.0f", deltaTimeSeconds))
      if (voltageBasedSoC >= 0.0) currentCoulombSoC = voltageBasedSoC
      deltaTimeSeconds = 0
    }
    if (deltaTimeSeconds > 0) {
      var double effectiveCurrent = current
      if (current > 0) {
        val double baseSoC = currentCoulombSoC
        effectiveCurrent = if (baseSoC >= CEF_HIGH_SOC_THRESHOLD) current * CEF_HIGH_SOC else current * CEF_NORMAL
      } else if (current < 0) {
        val double ratioRaw = java.lang.Math::abs(current) / C20_RATE_CURRENT
        val double ratio = java.lang.Math::min(ratioRaw, PEUKERT_MAX_RATIO)
        if (ratio > (20.0/30.0)) { // > ~C/30
          val double peukertFactor = java.lang.Math.pow(ratio, PEUKERT_EXPONENT - 1.0)
          effectiveCurrent = current * peukertFactor
        }
      }
      val double ahChange = (effectiveCurrent * deltaTimeSeconds) / 3600.0
      val double socChange = (ahChange / TOTAL_CAPACITY_AH) * 100.0
      currentCoulombSoC += socChange
      logDebug(DEBUG_LOG, "Coulomb: Prev: {}%, I_raw: {}A, I_eff: {}A, dT: {}s, SoCChg: {}, New: {}%",
          String::format("%.2f", (currentCoulombSoC - socChange)),
          String::format("%.2f", current), String::format("%.2f", effectiveCurrent),
          String::format("%.1f", deltaTimeSeconds), String::format("%.3f", socChange),
          String::format("%.2f", currentCoulombSoC))
    }
  }
}

// --- Complementary fusion of V-SoC and Coulomb ---
var double fusedSoC = currentCoulombSoC
if (voltageBasedSoC >= 0.0) {
  var double vConfidence = if (Iabs < CHARGE_CURRENT_THRESHOLD) 1.0 else java.lang.Math::max(0.0, 1.0 - (Iabs / 10.0))
  vConfidence = java.lang.Math::min(1.0, vConfidence)
  fusedSoC = vConfidence * voltageBasedSoC + (1.0 - vConfidence) * currentCoulombSoC
  currentCoulombSoC = fusedSoC
}

// --- Final clamp + post Coulomb SoC ---
if (currentCoulombSoC > 100.0) currentCoulombSoC = 100.0
if (currentCoulombSoC < 0.0)  currentCoulombSoC = 0.0
if (currentCoulombSoC >= 0.0) postUpdate(BATTERY_SOC_COULOMB_ITEM, currentCoulombSoC)

// --- Runtime estimate to DOD limit (discharging only, to 40% SoC remaining) ---
val double finalSoC = currentCoulombSoC
val double reservePct = 100.0 - RUNTIME_DOD_LIMIT_PCT         // 40% remaining
val double remainingAh = (finalSoC / 100.0) * TOTAL_CAPACITY_AH
postUpdate(BATTERY_REMAINING_AH_ITEM, String::format("%.1f", remainingAh))

if (current < -MIN_DISCH_CURRENT_FOR_RUNTIME) {
  var double Ieff = java.lang.Math::abs(current)
  val double ratioRaw = Ieff / C20_RATE_CURRENT
  val double ratio = java.lang.Math::min(ratioRaw, PEUKERT_MAX_RATIO)
  if (ratio > (20.0/30.0)) {
    val double peukertFactor = java.lang.Math::pow(ratio, PEUKERT_EXPONENT - 1.0)
    Ieff = Ieff * peukertFactor
  }
  val double usablePct = java.lang.Math::max(0.0, finalSoC - reservePct)
  val double usableAh = (usablePct / 100.0) * TOTAL_CAPACITY_AH
  val double runtimeHours = if (Ieff > 0) (usableAh / Ieff) else 0.0
  postUpdate(BATTERY_RUNTIME_HOURS_ITEM, String::format("%.2f", runtimeHours))
} else {
  postUpdate(BATTERY_RUNTIME_HOURS_ITEM, UNDEF)
}

// --- Time-To-Full (charging only) using PV Items and controller caps ---
var double battV = v
if (BATTERY_VOLTAGE_ITEM.state instanceof QuantityType)
  battV = (BATTERY_VOLTAGE_ITEM.state as QuantityType<Number>).doubleValue
battV = java.lang.Math::max(10.0, battV) // guard

// Pack current if available
var double Ipack = 0.0
if (BATTERY_CURRENT_ITEM.state instanceof QuantityType)
  Ipack = (BATTERY_CURRENT_ITEM.state as QuantityType<Number>).doubleValue
else if (BATTERY_CURRENT_ITEM.state instanceof Number)
  Ipack = (BATTERY_CURRENT_ITEM.state as Number).doubleValue

// PV current (may come in mA)
var double pvI = 0.0
if (PV_CURRENT_ITEM.state instanceof QuantityType)
  pvI = (PV_CURRENT_ITEM.state as QuantityType<Number>).toUnit("A").doubleValue
else if (PV_CURRENT_ITEM.state instanceof Number) {
  val nI = (PV_CURRENT_ITEM.state as Number).doubleValue
  pvI = if (nI > 1000) nI / 1000.0 else nI
}

// PV voltage (may come in mV)
var double pvV = 0.0
if (PV_VOLTAGE_ITEM.state instanceof QuantityType)
  pvV = (PV_VOLTAGE_ITEM.state as QuantityType<Number>).toUnit("V").doubleValue
else if (PV_VOLTAGE_ITEM.state instanceof Number) {
  val nV = (PV_VOLTAGE_ITEM.state as Number).doubleValue
  pvV = if (nV > 1000) nV / 1000.0 else nV
}

// PV power (prefer direct W; else derive)
var double pvW = 0.0
if (PV_POWER_ITEM.state instanceof QuantityType)
  pvW = (PV_POWER_ITEM.state as QuantityType<Number>).toUnit("W").doubleValue
else if (PV_POWER_ITEM.state instanceof Number)
  pvW = (PV_POWER_ITEM.state as Number).doubleValue
if (pvW <= 0 && pvI > 0 && pvV > 0) pvW = pvI * pvV

// Estimate controller output current from PV, limited by controller
var double IfromPV = 0.0
if (pvW > 0) IfromPV = java.lang.Math::min(CONTROLLER_MAX_CHG_A, (pvW * CONTROLLER_EFF) / battV)

// Choose the charge-current source
var double Ichg = if (Ipack > 0.0) Ipack else IfromPV

// Compute TTF only when actually charging
if (Ichg > 0.2 && ("Bulk".equals(chargeStatusStr) || "Absorption".equals(chargeStatusStr) || "Float".equals(chargeStatusStr))) {
  val double cef = if (finalSoC >= CEF_HIGH_SOC_THRESHOLD) CEF_HIGH_SOC else CEF_NORMAL
  var double ttfHours = -1.0   // sentinel for invalid

  if ("Bulk".equals(chargeStatusStr)) {
    val double ahNeeded = ((100.0 - finalSoC) / 100.0) * TOTAL_CAPACITY_AH
    val double Ieff = Ichg * cef
    ttfHours = if (Ieff > 0) ahNeeded / Ieff else -1.0

  } else if ("Absorption".equals(chargeStatusStr)) {
    val double targetPct = 99.0
    val double pctRemain = java.lang.Math::max(0.0, targetPct - finalSoC)
    val double ahRemain  = (pctRemain / 100.0) * TOTAL_CAPACITY_AH
    val double tauH      = 1.2  // heuristic time constant
    val double I0        = java.lang.Math::max(Ichg, TAIL_CURRENT_THRESH)
    val double Iavg      = java.lang.Math::max(TAIL_CURRENT_THRESH, 0.5 * (I0 + TAIL_CURRENT_THRESH))
    val double IeffAbs   = Iavg * CEF_HIGH_SOC
    ttfHours = if (IeffAbs > 0) ahRemain / IeffAbs else -1.0
    if (pctRemain < 0.2) ttfHours = 0.1

  } else { // Float
    val double rampRatePctPerMin = 0.2
    val double pctRemain = java.lang.Math::max(0.0, 100.0 - finalSoC)
    ttfHours = if (rampRatePctPerMin > 0) pctRemain / (rampRatePctPerMin * 60.0) else -1.0
  }

  if (ttfHours <= 0 || ttfHours > 1.0E5 || (ttfHours as Double).isNaN || (ttfHours as Double).isInfinite) {
    postUpdate(BATTERY_TTF_HOURS_ITEM, UNDEF)
  } else {
    postUpdate(BATTERY_TTF_HOURS_ITEM, String::format("%.2f", ttfHours))
  }
} else {
  postUpdate(BATTERY_TTF_HOURS_ITEM, UNDEF)
}

// --- Smoothed display output to two decimals ---
var double displayPrev = if (BATTERY_SOC_CALCULATED_ITEM.state instanceof Number) (BATTERY_SOC_CALCULATED_ITEM.state as Number).doubleValue else finalSoC
val double displaySoC = 0.8 * displayPrev + 0.2 * finalSoC

if (finalSoC >= 0.0 && finalSoC <= 100.0) {
  val String formattedSoC = String::format("%.2f", displaySoC)
  postUpdate(BATTERY_SOC_CALCULATED_ITEM, formattedSoC)
  logInfo(MAIN_LOG, "Final SoC: {}% (VSoC: {}%, Coulomb: {}%, V_adj_lookup: {}V, I: {}A, dV/dt: {} mV/min, OCVwin: {}, T: {}°C, Status: {}, Runtime_h: {}, TTF_h: {})",
      formattedSoC,
      if (voltageBasedSoC == -1.0) "N/A" else String::format("%.1f", voltageBasedSoC),
      String::format("%.1f", currentCoulombSoC),
      String::format("%.2f", ocvAtNominalTemp),
      String::format("%.1f", current),
      String::format("%.1f", dVdt_V_per_min * 1000.0),
      String::format("%s", ocvWindow),
      String::format("%.1f", currentTemperatureC),
      chargeStatusStr + "/" + batteryState,
      if (BATTERY_RUNTIME_HOURS_ITEM.state instanceof Number) String::format("%.2f", (BATTERY_RUNTIME_HOURS_ITEM.state as Number).doubleValue) else "N/A",
      if (BATTERY_TTF_HOURS_ITEM.state instanceof Number) String::format("%.2f", (BATTERY_TTF_HOURS_ITEM.state as Number).doubleValue) else "N/A")
} else {
  if (voltageBasedSoC >= 0.0 && voltageBasedSoC <= 100.0) {
    val String formattedVSoC = String::format("%.2f", voltageBasedSoC)
    postUpdate(BATTERY_SOC_CALCULATED_ITEM, formattedVSoC)
  } else {
    postUpdate(BATTERY_SOC_CALCULATED_ITEM, UNDEF)
  }
}
