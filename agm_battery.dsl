// ===================================================================================
// BATTERY STATE-OF-CHARGE RULE v2.1
// ===================================================================================
// System: 48V AGM Bank (8S2P Fullriver DC400-6)
// Capacity: 830Ah @ C20 (2 × 415Ah parallel strings)
// 
// Changelog v2.1:
//   - Added charging efficiency factor (95% → 85% as SoC increases)
//   - Added current sensor zero-offset correction with dead-band
//   - Added OCV-based calibration during rest periods (30+ min)
//   - Added self-discharge modeling (~3%/month per datasheet)
//   - Improved cold-start initialization using voltage estimate
//   - Added new item: Battery_Rest_Since (DateTime)
//
// Changelog v2.0:
//   - Fixed CHARGED_VOLTAGE threshold (53.5V → 54.2V per datasheet)
//   - Corrected Peukert runtime calculation (was double-scaling)
//   - Made SoC ramp time-based instead of execution-cycle dependent
//   - Added voltage stability check for full detection
//   - Improved TTF with absorption phase modeling
//   - Added drift correction for long-term coulomb counter accuracy
// ===================================================================================

// ===================================================================================
// CONFIGURATION CONSTANTS 
// ===================================================================================

// --- Battery Bank Specs (Fullriver DC400-6 datasheet) ---
val TOTAL_CAPACITY_AH    = 830.0    // 2P × 415Ah @ C20 rate
val PEUKERT_EXPONENT     = 1.12     // Adjusted for AGM (datasheet discharge curves)
val C20_DISCHARGE_RATE   = 41.5     // 830Ah / 20hr = reference current for Peukert

// --- Charge Detection Thresholds (per datasheet: Float = 54.4V for 48V bank) ---
val CHARGED_VOLTAGE      = 54.2     // Just below float, above absorption dip
val ABSORPTION_VOLTAGE   = 58.8     // 8 × 7.35V per datasheet
val TAIL_CURRENT_THRESH  = 16.6     // 2% of C20 capacity (830 × 0.02)
val VOLTAGE_STABLE_BAND  = 0.3      // Max V deviation from EMA to consider "stable"

// --- Operational Limits ---
val RUNTIME_DOD_LIMIT_PCT = 60.0    // 60% DoD = 40% SoC floor (preserves cycle life)
val MIN_VOLTAGE_CUTOFF    = 44.0    // Emergency low-voltage protection (5.5V/cell)

// --- Algorithm Tuning ---
val EMA_ALPHA             = 0.1     // Voltage smoothing (0.1 = slow, 0.3 = responsive)
val SOC_RAMP_RATE_PCT_HR  = 5.0     // Float-state SoC convergence rate (%/hour)
val FULL_DETECT_TIME_MS   = 180000  // 3 minutes in tail current = 100% SoC
val MAX_INTEGRATION_GAP   = 600000  // 10 min max gap before skipping integration

// --- Hardware Limits (Schneider MPPT 60-150) ---
val CONTROLLER_MAX_CHG_A  = 60.0    // Max charge current
val CONTROLLER_EFF        = 0.97    // MPPT efficiency factor

// --- v2.1: Current Sensor Calibration ---
// CALIBRATE THIS: With no loads and no charging, observe the current reading.
// Enter that value here to correct for sensor offset. Positive = sensor reads high.
val CURRENT_ZERO_OFFSET   = 0.0     // Amps (measure when system at rest, adjust if non-zero)
val CURRENT_DEAD_BAND     = 0.3     // Ignore currents smaller than this (noise floor)

// --- v2.1: Charging Efficiency ---
// AGM batteries don't accept charge at 100% efficiency. 
// Efficiency decreases as SoC increases (more energy lost as heat).
val CHARGE_EFF_LOW_SOC    = 0.95    // 95% efficient when battery is depleted
val CHARGE_EFF_HIGH_SOC   = 0.85    // 85% efficient when nearly full
val CHARGE_EFF_KNEE_SOC   = 80.0    // SoC% where efficiency starts dropping faster

// --- v2.1: Self-Discharge ---
// Per datasheet: ~3% per month at 77°F (25°C), faster when hot
val SELF_DISCHARGE_PCT_DAY_25C = 0.10   // 0.1%/day at 25°C (~3%/month)

// --- v2.1: OCV Calibration ---
val OCV_REST_TIME_MS      = 1800000 // 30 minutes of rest before OCV is reliable
val OCV_REST_CURRENT_THRESH = 1.0   // Current must be below this to count as "resting"
val OCV_BLEND_WEIGHT      = 0.3     // How much to trust OCV vs coulomb counter (0.3 = 30% OCV)

// ===================================================================================
// ITEM REFERENCES
// ===================================================================================

// Inputs - Battery Monitoring
val voltsItem    = DCData_Voltage
val ampsItem     = DCData_Current
val tempItem     = AmbientWeatherWS2902A_WH31E_193_Temperature
val statusItem   = ChargerStatus

// Inputs - PV Array
val pvVoltsItem  = PV_Voltage
val pvAmpsItem   = PV_Current

// Outputs - Calculated Values
val socCalcItem  = BatterySoC_Calculated
val socCCItem    = BatterySoC_CoulombCounter
val emaVoltsItem = Battery_Voltage_EMA
val emaTsItem    = Battery_Voltage_EMA_Ts
val tailTimer    = Battery_TailOk_Since
val remainAhItem = Battery_Remaining_Ah
val runtimeItem  = Battery_Runtime_Hours
val ttfItem      = Battery_TimeToFull_Hours
val integTsItem  = Battery_Integration_TS

// v2.1: New item for OCV rest detection
val restTimer    = Battery_Rest_Since   // DateTime item - ADD TO YOUR .items FILE

// ===================================================================================
// HELPER FUNCTION: OCV to SoC Lookup
// ===================================================================================
// Based on DC400-6 datasheet "State of Charge vs Open Circuit Voltage" curve
// Scaled for 48V bank (8 × 6V cells in series)
// 
// Datasheet 6V values → 48V values:
//   6.50V = 100% → 52.0V (but this is right after charge, not true OCV)
//   6.38V = ~90% → 51.04V  
//   6.25V = ~75% → 50.0V
//   6.13V = ~55% → 49.04V
//   6.00V = ~35% → 48.0V
//   5.88V = ~15% → 47.04V
//   5.75V = ~0%  → 46.0V
//
// Note: True OCV requires 30+ minutes of rest. Values during charge/discharge
// will be higher/lower due to internal resistance.
// ===================================================================================

// ===================================================================================
// MAIN RULE LOGIC
// ===================================================================================

// ---------------------------------------------------------------------------------
// 1. SAFE SENSOR READINGS (with offset correction)
// ---------------------------------------------------------------------------------
var volts = 0.0
if (voltsItem.state instanceof Number) { 
    volts = (voltsItem.state as Number).doubleValue 
}

var amps = 0.0
if (ampsItem.state instanceof Number) { 
    amps = (ampsItem.state as Number).doubleValue 
    
    // v2.1: Apply zero-offset correction
    amps = amps - CURRENT_ZERO_OFFSET
    
    // v2.1: Dead-band to eliminate noise accumulation
    if (Math.abs(amps) < CURRENT_DEAD_BAND) {
        amps = 0.0
    }
}

var temp = 20.0
if (tempItem.state instanceof Number) { 
    temp = (tempItem.state as Number).doubleValue 
}

// Sanity check - skip cycle if voltage reading is clearly invalid
if (volts < 20.0 || volts > 70.0) {
    logWarn("Battery", "Invalid voltage reading: " + volts + "V - skipping cycle")
    return;
}

// ---------------------------------------------------------------------------------
// 2. INTEGRATION TIMING (Robust dt Calculation)
// ---------------------------------------------------------------------------------
var dt = 0.0
val nowMillis = now.toInstant.toEpochMilli

if (integTsItem.state instanceof DateTimeType) {
    val lastMillis = (integTsItem.state as DateTimeType).zonedDateTime.toInstant.toEpochMilli
    val diffMillis = nowMillis - lastMillis
    
    if (diffMillis > 0 && diffMillis < MAX_INTEGRATION_GAP) {
        dt = diffMillis / 3600000.0  // Convert ms → hours
    } else if (diffMillis >= MAX_INTEGRATION_GAP) {
        logInfo("Battery", "Integration gap (" + (diffMillis/1000) + "s) exceeded limit. Skipping Ah integration.")
    }
}

// Update timestamp for next cycle
integTsItem.postUpdate(new DateTimeType())

// ---------------------------------------------------------------------------------
// 3. TEMPERATURE COMPENSATION
// ---------------------------------------------------------------------------------
// Convert Fahrenheit to Celsius if needed (Colorado ambient can be in F)
var tempC = temp
if (temp > 45.0) {  // Assume F if > 45 (unlikely to be 45°C in Colorado)
    tempC = (temp - 32.0) * 5.0 / 9.0
}

// Piecewise linear compensation based on DC400-6 Temperature vs Capacity curve:
//   - Below 25°C: ~1.0% capacity loss per °C
//   - Above 25°C: ~0.3% capacity gain per °C (capped at 107%)
var tempFactor = 1.0
if (tempC < 25.0) {
    tempFactor = 1.0 + ((tempC - 25.0) * 0.010)  // 1% per °C below 25
} else {
    tempFactor = 1.0 + ((tempC - 25.0) * 0.003)  // 0.3% per °C above 25
}

// Clamp temperature factor to reasonable bounds
if (tempFactor < 0.50) tempFactor = 0.50  // -25°C limit
if (tempFactor > 1.07) tempFactor = 1.07  // 48°C limit

val capacityNow = TOTAL_CAPACITY_AH * tempFactor

// ---------------------------------------------------------------------------------
// 4. VOLTAGE EMA (Calculate early - needed for stability check)
// ---------------------------------------------------------------------------------
var oldEma = volts
if (emaVoltsItem.state instanceof Number) {
    oldEma = (emaVoltsItem.state as Number).doubleValue
}
var newEma = (EMA_ALPHA * volts) + ((1.0 - EMA_ALPHA) * oldEma)

emaVoltsItem.postUpdate(newEma)
emaTsItem.postUpdate(new DateTimeType())

// ---------------------------------------------------------------------------------
// 5. COULOMB COUNTING (with efficiency and self-discharge)
// ---------------------------------------------------------------------------------

// v2.1: Improved cold-start initialization
var currentSoCCoulomb = 50.0
var boolean coldStart = false

if (socCCItem.state instanceof Number) {
    currentSoCCoulomb = (socCCItem.state as Number).doubleValue
} else {
    // Cold start - estimate from OCV (assumes some rest, but better than 50%)
    coldStart = true
    if (volts > 53.0) {
        currentSoCCoulomb = 90.0
    } else if (volts > 52.0) {
        currentSoCCoulomb = 80.0
    } else if (volts > 51.0) {
        currentSoCCoulomb = 65.0
    } else if (volts > 50.0) {
        currentSoCCoulomb = 50.0
    } else if (volts > 49.0) {
        currentSoCCoulomb = 35.0
    } else if (volts > 48.0) {
        currentSoCCoulomb = 25.0
    } else if (volts > 47.0) {
        currentSoCCoulomb = 15.0
    } else {
        currentSoCCoulomb = 5.0
    }
    logWarn("Battery", "Cold start detected. Initializing SoC to " + currentSoCCoulomb + "% based on voltage " + volts + "V")
}

if (dt > 0 && !coldStart) {
    // Calculate Ah change
    var ahChange = amps * dt
    
    // v2.1: Apply charging efficiency factor
    if (amps > 0) {
        // Charging - efficiency decreases as SoC increases
        // Linear interpolation: 95% at 0% SoC → 85% at 100% SoC
        // With faster dropoff above the knee point
        var chargeEfficiency = CHARGE_EFF_LOW_SOC
        
        if (currentSoCCoulomb > CHARGE_EFF_KNEE_SOC) {
            // Above knee: steeper efficiency drop
            val socAboveKnee = currentSoCCoulomb - CHARGE_EFF_KNEE_SOC
            val rangeAboveKnee = 100.0 - CHARGE_EFF_KNEE_SOC
            val effDrop = (CHARGE_EFF_LOW_SOC - CHARGE_EFF_HIGH_SOC) * (socAboveKnee / rangeAboveKnee)
            chargeEfficiency = CHARGE_EFF_LOW_SOC - effDrop
        } else {
            // Below knee: gradual efficiency drop
            val effDropBelowKnee = (CHARGE_EFF_LOW_SOC - CHARGE_EFF_HIGH_SOC) * 0.3  // 30% of total drop below knee
            chargeEfficiency = CHARGE_EFF_LOW_SOC - (effDropBelowKnee * (currentSoCCoulomb / CHARGE_EFF_KNEE_SOC))
        }
        
        ahChange = ahChange * chargeEfficiency
        
        logDebug("Battery", "Charge efficiency at " + String.format("%.1f", currentSoCCoulomb) + "% SoC: " + String.format("%.1f", chargeEfficiency * 100) + "%")
    }
    
    // v2.1: Apply self-discharge when idle
    if (Math.abs(amps) < 0.5) {
        // Not charging or discharging significantly - apply self-discharge
        // Self-discharge increases with temperature (roughly doubles per 10°C)
        val tempMultiplier = Math.pow(2.0, (tempC - 25.0) / 10.0)
        val selfDischargePctPerHour = (SELF_DISCHARGE_PCT_DAY_25C / 24.0) * tempMultiplier
        val selfDischargeThisCycle = selfDischargePctPerHour * dt
        
        currentSoCCoulomb = currentSoCCoulomb - selfDischargeThisCycle
        
        // Only log occasionally (when > 0.01% discharged)
        if (selfDischargeThisCycle > 0.01) {
            logDebug("Battery", "Self-discharge: " + String.format("%.3f", selfDischargeThisCycle) + "% (temp multiplier: " + String.format("%.2f", tempMultiplier) + ")")
        }
    }
    
    // Apply Ah change to SoC
    val pctChange = (ahChange / capacityNow) * 100.0
    currentSoCCoulomb = currentSoCCoulomb + pctChange
}

// ---------------------------------------------------------------------------------
// 6. OCV-BASED CALIBRATION (during extended rest)
// ---------------------------------------------------------------------------------
val boolean isResting = (Math.abs(amps) < OCV_REST_CURRENT_THRESH)

if (isResting) {
    if (restTimer.state === NULL || restTimer.state === UNDEF) {
        // Start rest timer
        restTimer.postUpdate(new DateTimeType())
        logDebug("Battery", "Rest period started. Current: " + amps + "A")
    } else {
        // Check how long we've been resting
        val restStart = (restTimer.state as DateTimeType).zonedDateTime.toInstant.toEpochMilli
        val restDuration = nowMillis - restStart
        
        if (restDuration > OCV_REST_TIME_MS) {
            // Battery has rested long enough - OCV is now reliable
            // Calculate SoC from OCV using datasheet curve (48V bank)
            var ocvSoC = 0.0
            
            // Piecewise linear interpolation based on DC400-6 datasheet
            // 48V bank OCV values (8 cells × 6V nominal)
            if (volts >= 52.0) {
                // 52.0V = 100%, but cap since true 100% is hard to measure via OCV
                ocvSoC = 95.0 + ((volts - 52.0) / 2.0) * 5.0
                if (ocvSoC > 100.0) ocvSoC = 100.0
            } else if (volts >= 51.0) {
                // 51.0V ≈ 85%, 52.0V ≈ 95%
                ocvSoC = 85.0 + ((volts - 51.0) / 1.0) * 10.0
            } else if (volts >= 50.0) {
                // 50.0V ≈ 70%, 51.0V ≈ 85%
                ocvSoC = 70.0 + ((volts - 50.0) / 1.0) * 15.0
            } else if (volts >= 49.0) {
                // 49.0V ≈ 50%, 50.0V ≈ 70%
                ocvSoC = 50.0 + ((volts - 49.0) / 1.0) * 20.0
            } else if (volts >= 48.0) {
                // 48.0V ≈ 30%, 49.0V ≈ 50%
                ocvSoC = 30.0 + ((volts - 48.0) / 1.0) * 20.0
            } else if (volts >= 47.0) {
                // 47.0V ≈ 15%, 48.0V ≈ 30%
                ocvSoC = 15.0 + ((volts - 47.0) / 1.0) * 15.0
            } else if (volts >= 46.0) {
                // 46.0V ≈ 5%, 47.0V ≈ 15%
                ocvSoC = 5.0 + ((volts - 46.0) / 1.0) * 10.0
            } else {
                // Below 46.0V - nearly empty
                ocvSoC = Math.max(0.0, (volts - 44.0) / 2.0 * 5.0)
            }
            
            // Check if OCV estimate differs significantly from coulomb counter
            val ocvDiff = Math.abs(ocvSoC - currentSoCCoulomb)
            
            if (ocvDiff > 5.0) {
                // Significant difference - blend toward OCV estimate
                val oldSoC = currentSoCCoulomb
                currentSoCCoulomb = (ocvSoC * OCV_BLEND_WEIGHT) + (currentSoCCoulomb * (1.0 - OCV_BLEND_WEIGHT))
                
                logInfo("Battery", "OCV calibration after " + (restDuration / 60000) + " min rest: V=" + 
                    String.format("%.2f", volts) + "V → OCV suggests " + String.format("%.1f", ocvSoC) + 
                    "% (was " + String.format("%.1f", oldSoC) + "%, adjusted to " + 
                    String.format("%.1f", currentSoCCoulomb) + "%)")
            }
        }
    }
} else {
    // Not resting - clear rest timer
    if (restTimer.state !== NULL && restTimer.state !== UNDEF) {
        restTimer.postUpdate(UNDEF)
    }
}

// ---------------------------------------------------------------------------------
// 7. FULL CHARGE DETECTION (Multi-condition with stability)
// ---------------------------------------------------------------------------------
val boolean voltageStable = Math.abs(volts - newEma) < VOLTAGE_STABLE_BAND
val boolean voltageAboveThreshold = (volts > CHARGED_VOLTAGE)
val boolean currentInTailRange = (amps > 0 && amps < TAIL_CURRENT_THRESH)
val boolean isFloatStatus = (statusItem.state !== null && statusItem.state.toString == "Float")

// Primary condition: Voltage stable above threshold AND current in tail range
// Secondary condition: Charger explicitly reports Float status
val boolean isTailCondition = (voltageAboveThreshold && voltageStable && currentInTailRange)
val boolean shouldTriggerFull = (isTailCondition || isFloatStatus)

if (shouldTriggerFull) {
    if (tailTimer.state === NULL || tailTimer.state === UNDEF) {
        // Start the tail current timer
        tailTimer.postUpdate(new DateTimeType())
        logDebug("Battery", "Tail condition started. V=" + volts + " A=" + amps)
    } else {
        // Check duration in tail state
        val tailStart = (tailTimer.state as DateTimeType).zonedDateTime.toInstant.toEpochMilli
        val tailDuration = nowMillis - tailStart
        
        if (tailDuration > FULL_DETECT_TIME_MS) {
            // Confirmed full - reset coulomb counter
            if (currentSoCCoulomb < 99.0) {
                logInfo("Battery", "Full charge detected after " + (tailDuration/1000) + "s. Resetting SoC from " + 
                    String.format("%.1f", currentSoCCoulomb) + "% to 100%")
            }
            currentSoCCoulomb = 100.0
        }
    }
} else {
    // Not in tail condition - reset timer
    if (tailTimer.state !== NULL && tailTimer.state !== UNDEF) {
        tailTimer.postUpdate(UNDEF)
    }
}

// ---------------------------------------------------------------------------------
// 8. SOC BOUNDS & DRIFT CORRECTION
// ---------------------------------------------------------------------------------

// Hard clamp to valid range
if (currentSoCCoulomb > 100.0) currentSoCCoulomb = 100.0
if (currentSoCCoulomb < 0.0) currentSoCCoulomb = 0.0

// Voltage-based sanity bounds (catch major drift)
// If voltage drops below cutoff, SoC cannot be above 10%
if (volts < MIN_VOLTAGE_CUTOFF && currentSoCCoulomb > 10.0) {
    logWarn("Battery", "Voltage (" + volts + "V) indicates near-empty. Capping SoC from " + 
        String.format("%.1f", currentSoCCoulomb) + "% to 10%")
    currentSoCCoulomb = 10.0
}

// If voltage is at/above absorption and stable, SoC must be at least 80%
if (volts >= ABSORPTION_VOLTAGE && voltageStable && currentSoCCoulomb < 80.0) {
    logInfo("Battery", "Voltage at absorption (" + volts + "V) but SoC low. Adjusting from " + 
        String.format("%.1f", currentSoCCoulomb) + "% to 80%")
    currentSoCCoulomb = 80.0
}

socCCItem.postUpdate(currentSoCCoulomb)

// ---------------------------------------------------------------------------------
// 9. HYBRID SOC (Time-based convergence to 100% during float)
// ---------------------------------------------------------------------------------
var finalSoC = currentSoCCoulomb

// When in float state, gently ramp SoC toward 100% at controlled rate
// This compensates for cumulative coulomb counting errors
if (isFloatStatus || (voltageAboveThreshold && voltageStable && amps > 0 && amps < TAIL_CURRENT_THRESH)) {
    if (finalSoC < 100.0 && dt > 0) {
        // Time-based ramp: SOC_RAMP_RATE_PCT_HR per hour
        val rampIncrement = SOC_RAMP_RATE_PCT_HR * dt
        finalSoC = Math.min(100.0, finalSoC + rampIncrement)
    }
}

socCalcItem.postUpdate(finalSoC)

// ---------------------------------------------------------------------------------
// 10. REMAINING CAPACITY (Ah)
// ---------------------------------------------------------------------------------
val remainingAh = (finalSoC / 100.0) * capacityNow
remainAhItem.postUpdate(remainingAh)

// ---------------------------------------------------------------------------------
// 11. PEUKERT-CORRECTED RUNTIME (Fixed Formula)
// ---------------------------------------------------------------------------------
var runtimeHours = 0.0

// Calculate usable Ah above the DoD floor
val floorSoC = 100.0 - RUNTIME_DOD_LIMIT_PCT  // 40% SoC floor
val usableAh = ((finalSoC - floorSoC) / 100.0) * capacityNow

if (amps < -0.5 && usableAh > 0) {
    val dischargeCurrent = Math.abs(amps)
    
    // Peukert's Law: Effective capacity decreases at higher discharge rates
    // Formula: t = C / I^k  where C is capacity at reference rate
    // 
    // Correction factor relative to C20 rate:
    //   factor = (I_actual / I_c20) ^ (k - 1)
    // 
    // Effective usable Ah at this discharge rate:
    //   effectiveAh = usableAh / factor
    
    val peukertFactor = Math.pow(dischargeCurrent / C20_DISCHARGE_RATE, PEUKERT_EXPONENT - 1.0)
    val effectiveUsableAh = usableAh / peukertFactor
    
    // Runtime = Effective Ah / Discharge Current
    runtimeHours = effectiveUsableAh / dischargeCurrent
    
    // Sanity cap at 100 hours (prevents display issues)
    if (runtimeHours > 100.0) runtimeHours = 100.0
}

runtimeItem.postUpdate(runtimeHours)

// ---------------------------------------------------------------------------------
// 12. TIME-TO-FULL WITH CHARGE PHASE MODELING
// ---------------------------------------------------------------------------------
var ttfHours = 0.0

if (amps > 0.5) {
    // Get PV data safely
    var pvV = 0.0
    if (pvVoltsItem.state instanceof Number) pvV = (pvVoltsItem.state as Number).doubleValue
    
    var pvA = 0.0
    if (pvAmpsItem.state instanceof Number) pvA = (pvAmpsItem.state as Number).doubleValue
    
    // Handle milli-unit scaling (some sensors report mV/mA)
    if (pvV > 10000) pvV = pvV / 1000.0
    if (pvA > 10000) pvA = pvA / 1000.0
    
    val pvWatts = pvV * pvA * CONTROLLER_EFF
    
    // Calculate potential charging amps based on available PV power
    var potentialAmps = 0.0
    if (volts > 10) {
        potentialAmps = pvWatts / volts
    }
    
    // Clamp to hardware limit
    if (potentialAmps > CONTROLLER_MAX_CHG_A) potentialAmps = CONTROLLER_MAX_CHG_A
    
    if (potentialAmps > 0.5 && finalSoC < 100.0) {
        val ahNeeded = capacityNow - remainingAh
        
        // Three-stage charge model:
        //   Bulk (0-80%): Constant current, linear time
        //   Absorption (80-95%): Declining current, ~2x time per Ah
        //   Float (95-100%): Trickle, ~3x time per Ah
        
        val bulkThreshold = 80.0
        val absThreshold = 95.0
        
        if (finalSoC < bulkThreshold) {
            // Currently in bulk phase
            val ahToBulkEnd = (bulkThreshold - finalSoC) / 100.0 * capacityNow
            val ahInAbsorption = (absThreshold - bulkThreshold) / 100.0 * capacityNow
            val ahInFloat = (100.0 - absThreshold) / 100.0 * capacityNow
            
            val bulkTime = ahToBulkEnd / potentialAmps
            val absTime = (ahInAbsorption / potentialAmps) * 2.0   // 2x penalty
            val floatTime = (ahInFloat / potentialAmps) * 3.0      // 3x penalty
            
            ttfHours = bulkTime + absTime + floatTime
            
        } else if (finalSoC < absThreshold) {
            // Currently in absorption phase
            val ahToAbsEnd = (absThreshold - finalSoC) / 100.0 * capacityNow
            val ahInFloat = (100.0 - absThreshold) / 100.0 * capacityNow
            
            val absTime = (ahToAbsEnd / potentialAmps) * 2.0
            val floatTime = (ahInFloat / potentialAmps) * 3.0
            
            ttfHours = absTime + floatTime
            
        } else {
            // Currently in float phase
            val ahRemaining = ahNeeded
            ttfHours = (ahRemaining / potentialAmps) * 3.0
        }
    }
    
    // If essentially full, show 0
    if (finalSoC >= 99.5) ttfHours = 0.0
    
    // Cap at reasonable maximum
    if (ttfHours > 24.0) ttfHours = 24.0
    
    ttfItem.postUpdate(ttfHours)
    
} else {
    // Not charging - clear TTF
    ttfItem.postUpdate(UNDEF)
}

// ---------------------------------------------------------------------------------
// 13. LOGGING
// ---------------------------------------------------------------------------------
if (dt > 0) {
    logDebug("Battery", String.format(
        "SoC=%.1f%% | V=%.2f (EMA=%.2f) | A=%.1f | Ah=%.0f/%.0f | Runtime=%.1fh | TempC=%.1f | TempFactor=%.3f",
        finalSoC, volts, newEma, amps, remainingAh, capacityNow, runtimeHours, tempC, tempFactor
    ))
}
