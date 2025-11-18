// ===================================================================================
// CONFIGURATION CONSTANTS (Typed as 'double' to prevent math errors)
// ===================================================================================

// --- Battery Physics ---
val double TOTAL_CAPACITY_AH    = 830.0   // Rated Capacity @ C20
val double PEUKERT_EXPONENT     = 1.15    // Peukert's Constant
val double TAIL_CURRENT_THRESH  = 8.3     // Amps
val double CHARGED_VOLTAGE      = 54.6    // Float/Absorb voltage trigger

// --- Logic Thresholds ---
val double RUNTIME_DOD_LIMIT_PCT = 60.0   // 60% DoD = 40% SoC floor. (Adjust to 80.0 for 20% floor)
val double EMA_ALPHA             = 0.1    // Smoothing factor

// --- Solar/Hardware Limits ---
val double CONTROLLER_MAX_CHG_A = 60.0    // Schneider MPPT Limit
val double CONTROLLER_EFF       = 0.97    // Efficiency

// ===================================================================================
// RULE LOGIC
// ===================================================================================

// Inputs
val voltsItem    = DCData_Voltage
val ampsItem     = DCData_Current
val tempItem     = AmbientWeatherWS2902A_WH31E_193_Temperature
val statusItem   = ChargerStatus

// PV Inputs
val pvVoltsItem  = PV_Voltage
val pvAmpsItem   = PV_Current

// Outputs
val socCalcItem  = BatterySoC_Calculated
val socCCItem    = BatterySoC_CoulombCounter
val emaVoltsItem = Battery_Voltage_EMA
val emaTsItem    = Battery_Voltage_EMA_Ts
val tailTimer    = Battery_TailOk_Since
val remainAhItem = Battery_Remaining_Ah
val runtimeItem  = Battery_Runtime_Hours
val ttfItem      = Battery_TimeToFull_Hours
val integTsItem  = Battery_Integration_TS 

// 1. Get Valid Sensor Readings (Safety Check)
var double volts = 0.0
if (voltsItem.state instanceof Number) { volts = (voltsItem.state as Number).doubleValue }

var double amps = 0.0
if (ampsItem.state instanceof Number) { amps = (ampsItem.state as Number).doubleValue }

var double temp = 20.0
if (tempItem.state instanceof Number) { temp = (tempItem.state as Number).doubleValue }

// 2. ROBUST INTEGRATOR TIMING
var double dt = 0.0
val long nowMillis = now.toInstant.toEpochMilli

if (integTsItem.state instanceof DateTimeType) {
    val long lastMillis = (integTsItem.state as DateTimeType).zonedDateTime.toInstant.toEpochMilli
    val long diffMillis = nowMillis - lastMillis
    
    // Sanity: Only integrate if gap is < 10 mins (600,000ms) to avoid ghost data after reboot
    if (diffMillis > 0 && diffMillis < 600000) {
        dt = diffMillis / 3600000.0 // Convert ms to Hours
    } else {
        logInfo("Battery", "Integrator Sync: Gap detected or first run. Skipping one cycle.")
    }
}
// Update timestamp immediately for next loop
integTsItem.postUpdate(new DateTimeType())

// 3. Temperature Compensation (FIXED for Fahrenheit)
// If temp > 40.0, assume Fahrenheit and convert to Celsius.
var double tempC = temp
if (temp > 40.0) {
    tempC = (temp - 32.0) * 5.0 / 9.0
}

// Lead acid capacity increases with heat, decreases with cold. Ref 25C.
// Approx 1% change per 3 degrees C deviation from 25C.
val double tempFactor = 1.0 + ((tempC - 25.0) * 0.006) 
val double capacityNow = TOTAL_CAPACITY_AH * tempFactor

// 4. Coulomb Counting
var double currentSoCCoulomb = 50.0 // Default if null
if (socCCItem.state instanceof Number) {
    currentSoCCoulomb = (socCCItem.state as Number).doubleValue
}

if (dt > 0) {
    val double ahChange = amps * dt
    val double pctChange = (ahChange / capacityNow) * 100.0
    currentSoCCoulomb = currentSoCCoulomb + pctChange
}

// 5. Full Detection & Tail Current Logic
var boolean isTailCondition = (volts > CHARGED_VOLTAGE && amps > 0 && amps < TAIL_CURRENT_THRESH)

if (isTailCondition) {
    if (tailTimer.state === NULL || tailTimer.state === UNDEF) {
        tailTimer.postUpdate(new DateTimeType()) // Start timer
    } else {
        // Check how long we've been in tail state
        val long tailStart = (tailTimer.state as DateTimeType).zonedDateTime.toInstant.toEpochMilli
        if ((nowMillis - tailStart) > 180000) { // 3 minutes
             currentSoCCoulomb = 100.0
        }
    }
} else {
    if (tailTimer.state !== NULL && tailTimer.state !== UNDEF) {
        tailTimer.postUpdate(UNDEF) 
    }
}

// Clamp Limits
if (currentSoCCoulomb > 100.0) currentSoCCoulomb = 100.0
if (currentSoCCoulomb < 0.0)   currentSoCCoulomb = 0.0
socCCItem.postUpdate(currentSoCCoulomb)

// 6. Hybrid SoC (Smooth Ramp)
var double finalSoC = currentSoCCoulomb

// If voltage is high or Float, pull SoC up gently if it's lagging
if (statusItem.state.toString == "Float" || (volts > CHARGED_VOLTAGE)) {
    if (finalSoC < 95.0) { 
         finalSoC = finalSoC + 0.05 
    }
}
socCalcItem.postUpdate(finalSoC)

// 7. Remaining Ah
val double remainingAh = (finalSoC / 100.0) * capacityNow
remainAhItem.postUpdate(remainingAh)

// 8. Peukert-Corrected Runtime
var double runtimeHours = 0.0
val double targetFloorAh = capacityNow * (RUNTIME_DOD_LIMIT_PCT / 100.0)
val double dischargeAhAvailable = remainingAh - targetFloorAh

if (amps < -0.5 && dischargeAhAvailable > 0) {
    val double dischargeCurrent = Math.abs(amps)
    // Peukert Math: Time = Capacity / (I^k) 
    val double effectiveAmps = Math.pow(dischargeCurrent, PEUKERT_EXPONENT)
    
    val double hoursToEmptyTotal = (capacityNow / effectiveAmps)
    
    // Scale total hours by the % of useful battery remaining
    val double pctAvailable = (finalSoC - (100.0 - RUNTIME_DOD_LIMIT_PCT)) / 100.0
    
    if (pctAvailable > 0) {
        runtimeHours = hoursToEmptyTotal * pctAvailable
    }
}
runtimeItem.postUpdate(runtimeHours)

// 9. Time-To-Full (TTF)
var double ttfHours = 0.0

if (amps > 0.5) {
    // Get PV Data safely
    var double pvV = 0.0
    if (pvVoltsItem.state instanceof Number) pvV = (pvVoltsItem.state as Number).doubleValue
    
    var double pvA = 0.0
    if (pvAmpsItem.state instanceof Number) pvA = (pvAmpsItem.state as Number).doubleValue
    
    // Auto-scale milli-units
    if (pvV > 10000) pvV = pvV / 1000.0
    if (pvA > 10000) pvA = pvA / 1000.0
    
    val double pvWatts = pvV * pvA * CONTROLLER_EFF
    
    // Calculate Potential Charging Amps
    var double potentialAmps = 0.0
    if (volts > 10) {
        potentialAmps = pvWatts / volts
    }
    
    // Clamp to Hardware Limit
    if (potentialAmps > CONTROLLER_MAX_CHG_A) potentialAmps = CONTROLLER_MAX_CHG_A
    
    if (potentialAmps > 0.5) {
        val double ahNeeded = capacityNow - remainingAh
        ttfHours = ahNeeded / potentialAmps
    }
    
    // If already near full, show 0
    if (finalSoC >= 99.0) ttfHours = 0.0
    
    ttfItem.postUpdate(ttfHours)
} else {
    ttfItem.postUpdate(UNDEF)
}

// 10. Voltage EMA (Smoothing)
var double oldEma = volts
if (emaVoltsItem.state instanceof Number) {
    oldEma = (emaVoltsItem.state as Number).doubleValue
}
var double newEma = (EMA_ALPHA * volts) + ((1.0 - EMA_ALPHA) * oldEma)

emaVoltsItem.postUpdate(newEma)
emaTsItem.postUpdate(new DateTimeType())
