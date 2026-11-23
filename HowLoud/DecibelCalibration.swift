//
//  DecibelCalibration.swift
//  HowLoud
//
//  Created by Luis Wu on 11/23/2026.
//  Copyright © 2026 Luis Wu. All rights reserved.
//

import Foundation

// MARK: - Acoustic Weighting & Metadata

/// Frequency weighting standard associated with a measurement or calibration profile.
enum FrequencyWeighting: String, Codable, CaseIterable, Sendable {
    /// A-weighting (IEC 61672): matches human hearing sensitivity and Apple Watch Noise app.
    case dBA
    /// C-weighting: suited for high-SPL or bass-heavy measurements.
    case dBC
    /// Z-weighting (flat / unweighted): raw microphone response.
    case dBZ
}

/// Indicates the expected reliability of a calibration profile.
enum CalibrationConfidence: String, Codable, Sendable {
    case uncalibrated
    case estimated
    case userVerified
    case referenceGrade
}

/// Optional frequency-specific correction entry (e.g., from an external microphone `.cal` file).
struct FrequencyCorrectionPoint: Codable, Equatable, Sendable {
    let frequencyHz: Double
    let offsetDB: Double
}

/// A single timestamped uncalibrated decibel reading captured during a calibration session.
struct DecibelMeasurementSample: Equatable, Sendable {
    let timestamp: Date
    let rawDecibels: Double
    let weighting: FrequencyWeighting

    init(timestamp: Date = Date(), rawDecibels: Double, weighting: FrequencyWeighting = .dBZ) {
        self.timestamp = timestamp
        self.rawDecibels = rawDecibels
        self.weighting = weighting
    }
}

/// A paired (measured, reference) observation used by multi-point calibration methods.
struct CalibrationPoint: Codable, Equatable, Sendable {
    let rawDecibels: Double
    let referenceDecibels: Double
}

// MARK: - Calibration Profile

/// Serializable calibration parameters applied to raw decibel measurements.
struct CalibrationProfile: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let methodIdentifier: String
    let displayName: String
    /// Scalar offset in dB applied after optional linear slope scaling.
    let offsetDB: Double
    /// Linear gain multiplier (1.0 for standard single-point offset calibration).
    let slope: Double
    let weighting: FrequencyWeighting
    /// Optional frequency-response curve for external microphones or device EQ compensation.
    let frequencyCorrections: [FrequencyCorrectionPoint]
    /// Optional `AVAudioSessionPortDescription.uid` to bind calibration to a specific microphone.
    let inputRouteUID: String?
    let calibratedAt: Date
    let confidence: CalibrationConfidence

    static let identity = CalibrationProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000000") ?? UUID(),
        methodIdentifier: "uncalibrated",
        displayName: "Default (Uncalibrated)",
        offsetDB: 0.0,
        slope: 1.0,
        weighting: .dBZ,
        frequencyCorrections: [],
        inputRouteUID: nil,
        calibratedAt: .distantPast,
        confidence: .uncalibrated
    )

    init(
        id: UUID = UUID(),
        methodIdentifier: String,
        displayName: String,
        offsetDB: Double,
        slope: Double = 1.0,
        weighting: FrequencyWeighting = .dBA,
        frequencyCorrections: [FrequencyCorrectionPoint] = [],
        inputRouteUID: String? = nil,
        calibratedAt: Date = Date(),
        confidence: CalibrationConfidence = .userVerified
    ) {
        self.id = id
        self.methodIdentifier = methodIdentifier
        self.displayName = displayName
        self.offsetDB = offsetDB
        self.slope = slope
        self.weighting = weighting
        self.frequencyCorrections = frequencyCorrections
        self.inputRouteUID = inputRouteUID
        self.calibratedAt = calibratedAt
        self.confidence = confidence
    }

    /// Applies linear slope and offset correction to a raw decibel reading.
    func apply(to rawDecibels: Double) -> Double {
        guard rawDecibels.isFinite else { return rawDecibels }
        return (rawDecibels * slope) + offsetDB
    }
}

// MARK: - Calibration Context & Errors

/// Input data passed to a `DecibelCalibrator` when computing a `CalibrationProfile`.
struct CalibrationContext: Sendable {
    let samples: [DecibelMeasurementSample]
    let referenceDecibels: Double?
    let manualOffsetDB: Double?
    let calibrationPoints: [CalibrationPoint]
    let weighting: FrequencyWeighting
    let inputRouteUID: String?
    let deviceModelIdentifier: String

    init(
        samples: [DecibelMeasurementSample] = [],
        referenceDecibels: Double? = nil,
        manualOffsetDB: Double? = nil,
        calibrationPoints: [CalibrationPoint] = [],
        weighting: FrequencyWeighting = .dBA,
        inputRouteUID: String? = nil,
        deviceModelIdentifier: String = ""
    ) {
        self.samples = samples
        self.referenceDecibels = referenceDecibels
        self.manualOffsetDB = manualOffsetDB
        self.calibrationPoints = calibrationPoints
        self.weighting = weighting
        self.inputRouteUID = inputRouteUID
        self.deviceModelIdentifier = deviceModelIdentifier
    }

    /// Computes the true acoustic energy average (Leq) across captured samples in linear power space.
    var energyAveragedRawDecibels: Double? {
        let finiteSamples = samples.map(\.rawDecibels).filter(\.isFinite)
        guard !finiteSamples.isEmpty else { return nil }
        let linearSum = finiteSamples.reduce(0.0) { partial, db in
            partial + pow(10.0, db / 10.0)
        }
        let averagePower = linearSum / Double(finiteSamples.count)
        guard averagePower > 0 else { return nil }
        return 10.0 * log10(averagePower)
    }
}

enum CalibrationError: Error, LocalizedError, Equatable, Sendable {
    case unavailable(String)
    case authorizationDenied
    case insufficientSamples(minimumRequired: Int)
    case missingReferenceValue
    case invalidConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return reason
        case .authorizationDenied:
            return "Permission required for this calibration method was denied."
        case .insufficientSamples(let minimumRequired):
            return "At least \(minimumRequired) measurement sample(s) are required to calibrate."
        case .missingReferenceValue:
            return "A reference decibel level or manual offset is required."
        case .invalidConfiguration(let message):
            return message
        }
    }
}

// MARK: - Extensible Calibrator Protocol

/// Interface implemented by all calibration methods (e.g., manual offset, Apple Watch HealthKit,
/// per-device hardware baseline, two-point linear, or external microphone `.cal` profile).
protocol DecibelCalibrator: Sendable {
    /// Stable unique identifier for persistence and analytics (e.g., `"manual_offset"`).
    var identifier: String { get }
    /// User-facing name shown in a calibration picker.
    var displayName: String { get }
    /// Short explanation of how the method works.
    var summary: String { get }
    /// Whether this method needs an OS permission prompt (e.g., HealthKit).
    var requiresAuthorization: Bool { get }
    /// Checks whether this method can run on the current device (e.g., HealthKit availability).
    var isAvailable: Bool { get async }

    /// Requests any OS authorization required before calling `calibrate(using:)`.
    func requestAuthorization() async throws -> Bool
    /// Produces a new `CalibrationProfile` from the supplied measurement context.
    func calibrate(using context: CalibrationContext) async throws -> CalibrationProfile
}

extension DecibelCalibrator {
    var requiresAuthorization: Bool { false }
    var isAvailable: Bool { true }

    func requestAuthorization() async throws -> Bool { true }
}

// MARK: - Persistence Protocol

/// Storage abstraction for persisting calibration profiles per audio input route.
protocol CalibrationStore {
    func loadProfile(for routeUID: String?) -> CalibrationProfile?
    func save(_ profile: CalibrationProfile)
    func removeProfile(for routeUID: String?)
}

final class UserDefaultsCalibrationStore: CalibrationStore {
    private let defaults: UserDefaults
    private let keyPrefix: String

    init(defaults: UserDefaults = .standard, keyPrefix: String = "com.howloud.calibration.") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    func loadProfile(for routeUID: String?) -> CalibrationProfile? {
        guard let data = defaults.data(forKey: storageKey(for: routeUID)) else {
            return nil
        }
        return try? JSONDecoder().decode(CalibrationProfile.self, from: data)
    }

    func save(_ profile: CalibrationProfile) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        defaults.set(data, forKey: storageKey(for: profile.inputRouteUID))
    }

    func removeProfile(for routeUID: String?) {
        defaults.removeObject(forKey: storageKey(for: routeUID))
    }

    private func storageKey(for routeUID: String?) -> String {
        keyPrefix + (routeUID ?? "default")
    }
}

// MARK: - Built-In Calibration Methods

/// Calibrates using either a direct dB offset or a side-by-side reference reading
/// (e.g., from an Apple Watch Noise app or dedicated SPL meter).
struct ManualOffsetCalibrator: DecibelCalibrator {
    let identifier = "manual_offset"
    let displayName = "Manual / Reference Meter"
    let summary = "Adjust offset directly or match a reading from an Apple Watch Noise app or SPL meter."

    static let allowedOffsetRange: ClosedRange<Double> = -40.0...40.0

    func calibrate(using context: CalibrationContext) async throws -> CalibrationProfile {
        let computedOffset: Double

        if let manualOffset = context.manualOffsetDB {
            computedOffset = manualOffset
        } else if let referenceDB = context.referenceDecibels {
            guard let measuredAvg = context.energyAveragedRawDecibels else {
                throw CalibrationError.insufficientSamples(minimumRequired: 1)
            }
            computedOffset = referenceDB - measuredAvg
        } else {
            throw CalibrationError.missingReferenceValue
        }

        guard computedOffset.isFinite, Self.allowedOffsetRange.contains(computedOffset) else {
            throw CalibrationError.invalidConfiguration(
                "Calibration offset must be within \(Int(Self.allowedOffsetRange.lowerBound)) to +\(Int(Self.allowedOffsetRange.upperBound)) dB."
            )
        }

        return CalibrationProfile(
            methodIdentifier: identifier,
            displayName: displayName,
            offsetDB: computedOffset,
            slope: 1.0,
            weighting: context.weighting,
            inputRouteUID: context.inputRouteUID,
            confidence: .userVerified
        )
    }
}

/// Calibrates both linear slope and offset from two or more (measured, reference) points
/// to improve accuracy across quiet and loud environments.
struct MultiPointLinearCalibrator: DecibelCalibrator {
    let identifier = "multi_point_linear"
    let displayName = "Multi-Point Linear"
    let summary = "Fits slope and offset across two or more reference sound levels."

    func calibrate(using context: CalibrationContext) async throws -> CalibrationProfile {
        let points = context.calibrationPoints.filter {
            $0.rawDecibels.isFinite && $0.referenceDecibels.isFinite
        }
        guard points.count >= 2 else {
            throw CalibrationError.insufficientSamples(minimumRequired: 2)
        }

        let n = Double(points.count)
        let meanX = points.reduce(0.0) { $0 + $1.rawDecibels } / n
        let meanY = points.reduce(0.0) { $0 + $1.referenceDecibels } / n

        let numerator = points.reduce(0.0) { $0 + ($1.rawDecibels - meanX) * ($1.referenceDecibels - meanY) }
        let denominator = points.reduce(0.0) { $0 + pow($1.rawDecibels - meanX, 2) }

        guard denominator > 1e-6 else {
            throw CalibrationError.invalidConfiguration("Calibration points must span distinct sound levels.")
        }

        let slope = numerator / denominator
        let offset = meanY - slope * meanX

        guard slope > 0.5 && slope < 1.5 else {
            throw CalibrationError.invalidConfiguration("Computed slope (\(String(format: "%.2f", slope))) is out of valid range.")
        }

        return CalibrationProfile(
            methodIdentifier: identifier,
            displayName: displayName,
            offsetDB: offset,
            slope: slope,
            weighting: context.weighting,
            inputRouteUID: context.inputRouteUID,
            confidence: .referenceGrade
        )
    }
}
