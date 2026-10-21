// Ported from the Sendspin time-filter reference implementation
// (github.com/Sendspin/time-filter, cpp/sendspin_time_filter.cpp).
// Copyright 2025 Sendspin Contributors, licensed under the Apache License, Version 2.0.

import Foundation

/// The time filter every Sendspin client must use (messaging.md, Clock Synchronization):
/// a two-dimensional Kalman filter over the offset and drift between this client's clock and
/// the server's, fed with NTP-style `client/time` / `server/time` exchanges.
struct TimeFilter {
    struct Config {
        /// Offset random walk, µs / sqrt(µs): clock jitter.
        var processStdDev = 0.0
        /// Drift random walk, 1 / sqrt(µs): frequency wander.
        var driftProcessStdDev = 1e-11
        /// Applied to the covariances when a residual is large (> 1: faster recovery).
        var forgetFactor = 2.0
        /// Residuals beyond this multiple of max_error trigger forgetting.
        var adaptiveCutoff = 3.0
        /// Samples before forgetting is enabled.
        var minSamples = 100
        /// Drift is only applied once drift² > threshold² · drift variance.
        var driftSignificanceThreshold = 2.0
        /// max_error times this is the measurement's standard deviation.
        var maxErrorScale = 0.5
    }

    private let processVariance: Double
    private let driftProcessVariance: Double
    private let forgetVarianceFactor: Double
    private let adaptiveCutoff: Double
    private let driftSignificanceThresholdSquared: Double
    private let maxErrorScale: Double
    private let minSamplesForForgetting: Int

    private var lastUpdate: Int64 = 0
    private var offset = 0.0
    private var drift = 0.0
    private var offsetCovariance = Double.infinity
    private var offsetDriftCovariance = 0.0
    private var driftCovariance = 0.0
    private var useDrift = false
    private(set) var count = 0

    init(_ config: Config = Config()) {
        processVariance = config.processStdDev * config.processStdDev
        driftProcessVariance = config.driftProcessStdDev * config.driftProcessStdDev
        forgetVarianceFactor = config.forgetFactor * config.forgetFactor
        adaptiveCutoff = config.adaptiveCutoff
        driftSignificanceThresholdSquared = config.driftSignificanceThreshold * config.driftSignificanceThreshold
        maxErrorScale = config.maxErrorScale
        minSamplesForForgetting = config.minSamples
    }

    /// One measurement: `measurement` = ((T2−T1)+(T3−T4))/2, `maxError` = ((T4−T1)−(T3−T2))/2,
    /// `timeAdded` the client time it was taken, all in µs.
    mutating func update(measurement: Int64, maxError: Int64, timeAdded: Int64) {
        // Non-monotonic samples and nonsensical uncertainties are skipped.
        guard timeAdded > lastUpdate, maxError > 0 else { return }
        let dt = Double(timeAdded - lastUpdate)
        let dtSquared = dt * dt
        lastUpdate = timeAdded

        let updateStdDev = Double(maxError) * maxErrorScale
        let measurementVariance = updateStdDev * updateStdDev
        let measured = Double(measurement)

        // The first measurement sets the offset.
        if count <= 0 {
            count += 1
            offset = measured
            offsetCovariance = measurementVariance
            drift = 0
            return
        }
        // The second gives a first drift estimate from the difference.
        if count == 1 {
            count += 1
            drift = (measured - offset) / dt
            offset = measured
            driftCovariance = (offsetCovariance + measurementVariance) / dtSquared
            offsetCovariance = measurementVariance
            return
        }

        // Predict.
        let predictedOffset = offset + drift * dt
        var newDriftCovariance = driftCovariance + dt * driftProcessVariance
        var newOffsetDriftCovariance = offsetDriftCovariance + driftCovariance * dt
        var newOffsetCovariance = offsetCovariance + 2 * offsetDriftCovariance * dt
            + driftCovariance * dtSquared + dt * processVariance

        // Innovation, with adaptive forgetting after a large residual.
        let residual = measured - predictedOffset
        if count < minSamplesForForgetting {
            count += 1
        } else if abs(residual) > Double(maxError) * adaptiveCutoff {
            newDriftCovariance *= forgetVarianceFactor
            newOffsetDriftCovariance *= forgetVarianceFactor
            newOffsetCovariance *= forgetVarianceFactor
        }

        // Update.
        let uncertainty = 1.0 / (newOffsetCovariance + measurementVariance)
        let offsetGain = newOffsetCovariance * uncertainty
        let driftGain = newOffsetDriftCovariance * uncertainty
        offset = predictedOffset + offsetGain * residual
        drift += driftGain * residual
        driftCovariance = newDriftCovariance - driftGain * newOffsetDriftCovariance
        offsetDriftCovariance = newOffsetDriftCovariance - driftGain * newOffsetCovariance
        offsetCovariance = newOffsetCovariance - offsetGain * newOffsetCovariance
        useDrift = drift * drift > driftSignificanceThresholdSquared * driftCovariance
    }

    /// A client time in the server's clock.
    func serverTime(fromClient clientTime: Int64) -> Int64 {
        let effectiveDrift = useDrift ? drift : 0
        return clientTime + Int64((offset + effectiveDrift * Double(clientTime - lastUpdate)).rounded())
    }

    /// A server time in the client's clock.
    func clientTime(fromServer serverTime: Int64) -> Int64 {
        let effectiveDrift = useDrift ? drift : 0
        return Int64(((Double(serverTime) - offset + effectiveDrift * Double(lastUpdate)) / (1 + effectiveDrift)).rounded())
    }

    /// The offset's standard deviation, µs.
    var error: Double { offsetCovariance.squareRoot() }
}
