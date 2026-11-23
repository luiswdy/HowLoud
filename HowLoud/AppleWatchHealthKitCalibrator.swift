//
//  AppleWatchHealthKitCalibrator.swift
//  HowLoud
//
//  Created by Luis Wu on 11/23/2026.
//  Copyright © 2026 Luis Wu. All rights reserved.
//

import Foundation
import HealthKit

// MARK: - HealthKit Data Abstraction

/// Lightweight value representing a HealthKit environmental audio exposure reading (dBA).
struct EnvironmentalAudioSample: Equatable, Sendable {
    let startDate: Date
    let endDate: Date
    let decibelsA: Double
    let sourceName: String
    let isAppleWatch: Bool

    var duration: TimeInterval {
        max(endDate.timeIntervalSince(startDate), 1.0)
    }
}

/// Protocol abstracting HealthKit queries for `environmentalAudioExposure` so the calibrator
/// can be unit-tested cleanly without requiring a physical Watch or Health store.
protocol HealthKitAudioExposureProvider: Sendable {
    var isHealthDataAvailable: Bool { get }
    func requestReadAuthorization() async throws -> Bool
    func fetchExposureSamples(from startDate: Date, to endDate: Date) async throws -> [EnvironmentalAudioSample]
}

/// Live HealthKit provider querying `HKQuantityTypeIdentifier.environmentalAudioExposure`.
final class LiveHealthKitAudioExposureProvider: HealthKitAudioExposureProvider, @unchecked Sendable {
    private let healthStore: HKHealthStore

    init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    var isHealthDataAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    private var environmentalAudioType: HKQuantityType? {
        HKObjectType.quantityType(forIdentifier: .environmentalAudioExposure)
    }

    func requestReadAuthorization() async throws -> Bool {
        guard isHealthDataAvailable, let audioType = environmentalAudioType else {
            throw CalibrationError.unavailable("HealthKit is not available on this device.")
        }

        return try await withCheckedThrowingContinuation { continuation in
            healthStore.requestAuthorization(toShare: [], read: [audioType]) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: success)
                }
            }
        }
    }

    func fetchExposureSamples(from startDate: Date, to endDate: Date) async throws -> [EnvironmentalAudioSample] {
        guard isHealthDataAvailable, let audioType = environmentalAudioType else {
            throw CalibrationError.unavailable("HealthKit is not available on this device.")
        }

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: [])
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: audioType,
                predicate: predicate,
                limit: 50,
                sortDescriptors: [sortDescriptor]
            ) { _, results, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let unit = HKUnit.decibelAWeightedSoundPressureLevel()
                let samples: [EnvironmentalAudioSample] = (results as? [HKQuantitySample] ?? []).compactMap { sample in
                    let value = sample.quantity.doubleValue(for: unit)
                    guard value.isFinite else { return nil }

                    let sourceName = sample.sourceRevision.source.name
                    let productType = sample.sourceRevision.productType ?? ""
                    let deviceModel = sample.device?.model ?? ""
                    let isWatch = productType.localizedCaseInsensitiveContains("Watch")
                        || deviceModel.localizedCaseInsensitiveContains("Watch")
                        || sourceName.localizedCaseInsensitiveContains("Watch")

                    return EnvironmentalAudioSample(
                        startDate: sample.startDate,
                        endDate: sample.endDate,
                        decibelsA: value,
                        sourceName: sourceName,
                        isAppleWatch: isWatch
                    )
                }

                continuation.resume(returning: samples)
            }

            healthStore.execute(query)
        }
    }
}

// MARK: - Apple Watch HealthKit Calibrator

/// Summary of the Apple Watch HealthKit sample(s) matched during calibration.
struct AppleWatchCalibrationMatch: Equatable, Sendable {
    let referenceDecibelsA: Double
    let sampleCount: Int
    let latestSampleDate: Date
    let usedOverlappingWindow: Bool
    let isAppleWatchSource: Bool
}

/// Automatically calibrates `HowLoud` by syncing `environmentalAudioExposure` (dBA) samples
/// logged to Apple Health by a paired Apple Watch.
struct AppleWatchHealthKitCalibrator: DecibelCalibrator {
    let identifier = "apple_watch_healthkit"
    let displayName = "Apple Watch (HealthKit)"
    let summary = "Syncs calibrated dBA environmental sound readings logged by Apple Watch in Apple Health."
    var requiresAuthorization: Bool { true }

    static let defaultLookbackWindow: TimeInterval = 10 * 60 // 10 minutes

    private let provider: any HealthKitAudioExposureProvider
    private let lookbackWindow: TimeInterval
    private let nowProvider: @Sendable () -> Date

    init(
        provider: any HealthKitAudioExposureProvider = LiveHealthKitAudioExposureProvider(),
        lookbackWindow: TimeInterval = AppleWatchHealthKitCalibrator.defaultLookbackWindow,
        nowProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.lookbackWindow = lookbackWindow
        self.nowProvider = nowProvider
    }

    var isAvailable: Bool {
        get async {
            provider.isHealthDataAvailable
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await provider.requestReadAuthorization()
    }

    /// Fetches the most recent environmental audio exposure sample from HealthKit (preferring Apple Watch).
    func fetchLatestSample() async throws -> EnvironmentalAudioSample? {
        let now = nowProvider()
        let start = now.addingTimeInterval(-lookbackWindow)
        let samples = try await provider.fetchExposureSamples(from: start, to: now)
        let preferred = samples.filter(\.isAppleWatch)
        let pool = preferred.isEmpty ? samples : preferred
        return pool.max(by: { $0.endDate < $1.endDate })
    }

    /// Resolves the best HealthKit reference match for a given capture window.
    func matchHealthKitReference(for captureSamples: [DecibelMeasurementSample]) async throws -> AppleWatchCalibrationMatch {
        guard provider.isHealthDataAvailable else {
            throw CalibrationError.unavailable("HealthKit is not available on this device.")
        }

        let captureStart = captureSamples.map(\.timestamp).min() ?? nowProvider()
        let captureEnd = captureSamples.map(\.timestamp).max() ?? nowProvider()
        let queryStart = captureStart.addingTimeInterval(-lookbackWindow)
        let queryEnd = max(captureEnd, nowProvider()).addingTimeInterval(5.0)

        let fetched = try await provider.fetchExposureSamples(from: queryStart, to: queryEnd)
        guard !fetched.isEmpty else {
            throw CalibrationError.unavailable(
                "No recent Apple Watch Noise readings found in Apple Health (last \(Int(lookbackWindow / 60)) min). Open the Noise app on your Watch briefly, ensure HowLoud has Health read permission, and try again."
            )
        }

        // Prefer Apple Watch samples if any exist; otherwise fall back to any HealthKit dBA exposure source.
        let watchSamples = fetched.filter(\.isAppleWatch)
        let pool = watchSamples.isEmpty ? fetched : watchSamples
        let isWatchSource = !watchSamples.isEmpty

        // Prefer samples overlapping the capture window (with ±15s tolerance for Watch batching).
        let overlapStart = captureStart.addingTimeInterval(-15.0)
        let overlapEnd = captureEnd.addingTimeInterval(15.0)
        let overlapping = pool.filter { sample in
            sample.endDate >= overlapStart && sample.startDate <= overlapEnd
        }

        let selected: [EnvironmentalAudioSample]
        let usedOverlap: Bool
        if !overlapping.isEmpty {
            selected = overlapping
            usedOverlap = true
        } else {
            // Fall back to the most recent sample(s) within 60s of the newest reading.
            let sorted = pool.sorted { $0.endDate > $1.endDate }
            if let newest = sorted.first {
                let cutoff = newest.endDate.addingTimeInterval(-60.0)
                selected = sorted.filter { $0.endDate >= cutoff }
            } else {
                selected = []
            }
            usedOverlap = false
        }

        guard let watchAvgDB = Self.durationWeightedEnergyAverage(of: selected),
              let latestDate = selected.map(\.endDate).max() else {
            throw CalibrationError.missingReferenceValue
        }

        return AppleWatchCalibrationMatch(
            referenceDecibelsA: watchAvgDB,
            sampleCount: selected.count,
            latestSampleDate: latestDate,
            usedOverlappingWindow: usedOverlap,
            isAppleWatchSource: isWatchSource
        )
    }

    func calibrate(using context: CalibrationContext) async throws -> CalibrationProfile {
        guard !context.samples.isEmpty, let measuredAvg = context.energyAveragedRawDecibels else {
            throw CalibrationError.insufficientSamples(minimumRequired: 1)
        }

        let match = try await matchHealthKitReference(for: context.samples)
        let offsetDB = match.referenceDecibelsA - measuredAvg

        guard offsetDB.isFinite, ManualOffsetCalibrator.allowedOffsetRange.contains(offsetDB) else {
            throw CalibrationError.invalidConfiguration(
                String(format: "Computed offset (%+.1f dB) is outside the allowed range. Ensure both devices hear the same steady sound.", offsetDB)
            )
        }

        return CalibrationProfile(
            methodIdentifier: identifier,
            displayName: displayName,
            offsetDB: offsetDB,
            slope: 1.0,
            weighting: .dBA,
            inputRouteUID: context.inputRouteUID,
            confidence: match.usedOverlappingWindow ? .referenceGrade : .userVerified
        )
    }

    /// Computes duration-weighted energy average (Leq) in linear acoustic power space.
    static func durationWeightedEnergyAverage(of samples: [EnvironmentalAudioSample]) -> Double? {
        let valid = samples.filter { $0.decibelsA.isFinite }
        guard !valid.isEmpty else { return nil }

        var weightedEnergySum = 0.0
        var totalDuration = 0.0
        for sample in valid {
            let duration = sample.duration
            weightedEnergySum += duration * pow(10.0, sample.decibelsA / 10.0)
            totalDuration += duration
        }

        guard totalDuration > 0 else { return nil }
        let meanPower = weightedEnergySum / totalDuration
        guard meanPower > 0 else { return nil }
        return 10.0 * log10(meanPower)
    }
}
