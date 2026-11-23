//
//  HowLoudTests.swift
//  HowLoudTests
//
//  Created by Luis Wu on 4/29/16.
//  Copyright © 2016 Luis Wu. All rights reserved.
//

import XCTest
@testable import HowLoud

class HowLoudTests: XCTestCase {
    
    private final class InMemoryCalibrationStore: CalibrationStore {
        private var profiles: [String: CalibrationProfile] = [:]
        
        func loadProfile(for routeUID: String?) -> CalibrationProfile? {
            profiles[routeUID ?? "default"]
        }
        
        func save(_ profile: CalibrationProfile) {
            profiles[profile.inputRouteUID ?? "default"] = profile
        }
        
        func removeProfile(for routeUID: String?) {
            profiles.removeValue(forKey: routeUID ?? "default")
        }
    }
    
    private struct MockWatchCalibrator: DecibelCalibrator {
        let identifier = "mock_apple_watch"
        let displayName = "Mock Apple Watch"
        let summary = "Test conformer simulating Apple Watch reference calibration."
        let offset: Double
        
        func calibrate(using context: CalibrationContext) async throws -> CalibrationProfile {
            CalibrationProfile(
                methodIdentifier: identifier,
                displayName: displayName,
                offsetDB: offset,
                weighting: .dBA,
                confidence: .referenceGrade
            )
        }
    }
    
    @MainActor
    func testViewModelInitialState() {
        let viewModel = DecibelMeterViewModel(calibrationStore: InMemoryCalibrationStore())
        XCTAssertEqual(viewModel.minValue, 0.0)
        XCTAssertEqual(viewModel.maxValue, 160.0)
        XCTAssertEqual(viewModel.averageDecibels, 0.0)
        XCTAssertEqual(viewModel.peakDecibels, 0.0)
        XCTAssertFalse(viewModel.isMeasuring)
        XCTAssertEqual(viewModel.calibrationProfile, .identity)
    }
    
    @MainActor
    func testDisplayStrings() {
        let viewModel = DecibelMeterViewModel(calibrationStore: InMemoryCalibrationStore())
        XCTAssertFalse(viewModel.minDisplayString.isEmpty)
        XCTAssertFalse(viewModel.maxDisplayString.isEmpty)
        XCTAssertFalse(viewModel.averageDisplayString.isEmpty)
        XCTAssertFalse(viewModel.peakDisplayString.isEmpty)
    }
    
    func testManualOffsetCalibratorFromReferenceSamples() async throws {
        let calibrator = ManualOffsetCalibrator()
        let context = CalibrationContext(
            samples: [
                DecibelMeasurementSample(rawDecibels: 65.0, weighting: .dBA),
                DecibelMeasurementSample(rawDecibels: 65.0, weighting: .dBA)
            ],
            referenceDecibels: 70.0,
            weighting: .dBA
        )
        let profile = try await calibrator.calibrate(using: context)
        XCTAssertEqual(profile.offsetDB, 5.0, accuracy: 0.001)
        XCTAssertEqual(profile.slope, 1.0, accuracy: 0.001)
        XCTAssertEqual(profile.apply(to: 65.0), 70.0, accuracy: 0.001)
    }
    
    func testMultiPointLinearCalibrator() async throws {
        let calibrator = MultiPointLinearCalibrator()
        let context = CalibrationContext(
            calibrationPoints: [
                CalibrationPoint(rawDecibels: 40.0, referenceDecibels: 45.0),
                CalibrationPoint(rawDecibels: 80.0, referenceDecibels: 89.0)
            ]
        )
        let profile = try await calibrator.calibrate(using: context)
        XCTAssertEqual(profile.slope, 1.1, accuracy: 0.001)
        XCTAssertEqual(profile.offsetDB, 1.0, accuracy: 0.001)
        XCTAssertEqual(profile.apply(to: 60.0), 67.0, accuracy: 0.001)
    }
    
    @MainActor
    func testViewModelAppliesAndResetsCustomCalibrator() async throws {
        let store = InMemoryCalibrationStore()
        let viewModel = DecibelMeterViewModel(calibrationStore: store)
        let baseline = viewModel.calibratedDecibels(fromRawPower: -40.0)
        
        try await viewModel.applyCalibration(
            using: MockWatchCalibrator(offset: 4.5),
            context: CalibrationContext()
        )
        
        let adjusted = viewModel.calibratedDecibels(fromRawPower: -40.0)
        XCTAssertEqual(adjusted - baseline, 4.5, accuracy: 0.001)
        XCTAssertEqual(store.loadProfile(for: nil)?.methodIdentifier, "mock_apple_watch")
        
        viewModel.resetCalibration()
        XCTAssertEqual(viewModel.calibrationProfile, .identity)
        XCTAssertEqual(viewModel.calibratedDecibels(fromRawPower: -40.0), baseline, accuracy: 0.001)
    }
    
    // MARK: - IEC 61672 Frequency Weighting & DSP Tests
    
    private func measureSineGainDB(
        weighting: FrequencyWeighting,
        frequencyHz: Double,
        sampleRate: Double = 48000.0
    ) -> Double {
        let filter = AudioWeightingFilter(weighting: weighting, sampleRate: sampleRate)
        let totalSamples = Int(sampleRate * 0.5) // 500 ms to reach steady state
        let skipSamples = Int(sampleRate * 0.25) // ignore initial transient
        let input = (0..<totalSamples).map { i in
            sin(2.0 * Double.pi * frequencyHz * Double(i) / sampleRate)
        }
        let output = filter.process(input)
        
        let inSlice = input[skipSamples...]
        let outSlice = output[skipSamples...]
        let inPower = inSlice.reduce(0.0) { $0 + $1 * $1 } / Double(inSlice.count)
        let outPower = outSlice.reduce(0.0) { $0 + $1 * $1 } / Double(outSlice.count)
        return 10.0 * log10(outPower / inPower)
    }
    
    func testAWeightingMatchesIEC61672At48kHz() {
        // IEC 61672-1 reference targets:
        // 100 Hz: -19.1 dB, 250 Hz: -8.6 dB, 500 Hz: -3.2 dB, 1 kHz: 0.0 dB, 4 kHz: +1.0 dB, 8 kHz: -1.1 dB
        XCTAssertEqual(measureSineGainDB(weighting: .dBA, frequencyHz: 100.0), -19.1, accuracy: 0.6)
        XCTAssertEqual(measureSineGainDB(weighting: .dBA, frequencyHz: 250.0), -8.6, accuracy: 0.5)
        XCTAssertEqual(measureSineGainDB(weighting: .dBA, frequencyHz: 500.0), -3.2, accuracy: 0.4)
        XCTAssertEqual(measureSineGainDB(weighting: .dBA, frequencyHz: 1000.0), 0.0, accuracy: 0.1)
        XCTAssertEqual(measureSineGainDB(weighting: .dBA, frequencyHz: 4000.0), 1.0, accuracy: 0.5)
        XCTAssertEqual(measureSineGainDB(weighting: .dBA, frequencyHz: 8000.0), -1.1, accuracy: 1.0)
    }
    
    func testAWeightingNormalizedAt44100Hz() {
        XCTAssertEqual(measureSineGainDB(weighting: .dBA, frequencyHz: 1000.0, sampleRate: 44100.0), 0.0, accuracy: 0.1)
        XCTAssertEqual(measureSineGainDB(weighting: .dBA, frequencyHz: 100.0, sampleRate: 44100.0), -19.1, accuracy: 0.6)
    }
    
    func testCWeightingAndZWeightingResponses() {
        // C-weighting is nearly flat at 100 Hz (-0.3 dB) and 0 dB at 1 kHz
        XCTAssertEqual(measureSineGainDB(weighting: .dBC, frequencyHz: 100.0), -0.3, accuracy: 0.5)
        XCTAssertEqual(measureSineGainDB(weighting: .dBC, frequencyHz: 1000.0), 0.0, accuracy: 0.1)
        
        // Z-weighting is flat at 100 Hz & 1 kHz, while rejecting DC offset
        XCTAssertEqual(measureSineGainDB(weighting: .dBZ, frequencyHz: 100.0), 0.0, accuracy: 0.2)
        XCTAssertEqual(measureSineGainDB(weighting: .dBZ, frequencyHz: 1000.0), 0.0, accuracy: 0.1)
        
        let zFilter = AudioWeightingFilter(weighting: .dBZ, sampleRate: 48000.0)
        let dcSignal = Array(repeating: 0.5, count: 48000)
        let filteredDC = zFilter.process(dcSignal)
        let settledTail = filteredDC.suffix(4800)
        let maxResidual = settledTail.map(abs).max() ?? 1.0
        XCTAssertLessThan(maxResidual, 0.001)
    }
    
    func testSoundLevelProcessorRMSClippingAndTimeWeighting() {
        let sampleRate = 48000.0
        let processor = SoundLevelProcessor(weighting: .dBA, timeWeighting: .fast, sampleRate: sampleRate)
        
        // 1 kHz sine at 0.5 amplitude -> RMS = 0.5 / sqrt(2) -> -9.03 dBFS, no clipping
        let halfScaleSine: [Float] = (0..<24000).map { i in
            Float(0.5 * sin(2.0 * Double.pi * 1000.0 * Double(i) / sampleRate))
        }
        let steady = processor.process(samples: halfScaleSine)
        XCTAssertFalse(steady.isClipping)
        XCTAssertEqual(steady.rmsDBFS, -9.03, accuracy: 0.3)
        
        // Full-scale sample triggers clipping flag
        let clippedBuffer: [Float] = [0.0, 0.5, 1.0, -0.5]
        let clippedResult = processor.process(samples: clippedBuffer)
        XCTAssertTrue(clippedResult.isClipping)
        
        // Fast (125 ms) responds faster than Slow (1000 ms) to a sudden +20 dB burst
        let fastProc = SoundLevelProcessor(weighting: .dBZ, timeWeighting: .fast, sampleRate: sampleRate)
        let slowProc = SoundLevelProcessor(weighting: .dBZ, timeWeighting: .slow, sampleRate: sampleRate)
        
        let quiet: [Float] = (0..<4800).map { i in
            Float(0.05 * sin(2.0 * Double.pi * 1000.0 * Double(i) / sampleRate))
        }
        let loud: [Float] = (0..<4800).map { i in // 100 ms burst
            Float(0.5 * sin(2.0 * Double.pi * 1000.0 * Double(i) / sampleRate))
        }
        
        _ = fastProc.process(samples: quiet)
        _ = slowProc.process(samples: quiet)
        
        let fastAfterBurst = fastProc.process(samples: loud)
        let slowAfterBurst = slowProc.process(samples: loud)
        XCTAssertGreaterThan(fastAfterBurst.rmsDBFS, slowAfterBurst.rmsDBFS + 2.0)
    }
    
    // MARK: - Apple Watch HealthKit Calibrator Tests
    
    private struct MockHealthKitProvider: HealthKitAudioExposureProvider {
        let isHealthDataAvailable: Bool
        let authorized: Bool
        let samples: [EnvironmentalAudioSample]
        
        func requestReadAuthorization() async throws -> Bool { authorized }
        func fetchExposureSamples(from startDate: Date, to endDate: Date) async throws -> [EnvironmentalAudioSample] {
            samples.filter { $0.endDate >= startDate && $0.startDate <= endDate }
        }
    }
    
    func testAppleWatchHealthKitCalibratorPrefersOverlappingWatchSample() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let provider = MockHealthKitProvider(
            isHealthDataAvailable: true,
            authorized: true,
            samples: [
                // Older Watch sample (5 min ago)
                EnvironmentalAudioSample(
                    startDate: now.addingTimeInterval(-320),
                    endDate: now.addingTimeInterval(-300),
                    decibelsA: 72.0,
                    sourceName: "Dong-Yi’s Apple Watch",
                    isAppleWatch: true
                ),
                // Overlapping non-Watch source (should be ignored in favor of Watch)
                EnvironmentalAudioSample(
                    startDate: now.addingTimeInterval(-5),
                    endDate: now,
                    decibelsA: 80.0,
                    sourceName: "Other App",
                    isAppleWatch: false
                ),
                // Overlapping Apple Watch sample
                EnvironmentalAudioSample(
                    startDate: now.addingTimeInterval(-10),
                    endDate: now,
                    decibelsA: 55.5,
                    sourceName: "Dong-Yi’s Apple Watch",
                    isAppleWatch: true
                )
            ]
        )
        
        let calibrator = AppleWatchHealthKitCalibrator(provider: provider, nowProvider: { now })
        let context = CalibrationContext(
            samples: [
                DecibelMeasurementSample(timestamp: now.addingTimeInterval(-3), rawDecibels: 50.0, weighting: .dBA),
                DecibelMeasurementSample(timestamp: now.addingTimeInterval(-1), rawDecibels: 50.0, weighting: .dBA)
            ],
            weighting: .dBA
        )
        
        let profile = try await calibrator.calibrate(using: context)
        XCTAssertEqual(profile.methodIdentifier, "apple_watch_healthkit")
        XCTAssertEqual(profile.offsetDB, 5.5, accuracy: 0.01)
        XCTAssertEqual(profile.weighting, .dBA)
        XCTAssertEqual(profile.confidence, .referenceGrade)
    }
    
    func testAppleWatchHealthKitCalibratorFallsBackToRecentSample() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let provider = MockHealthKitProvider(
            isHealthDataAvailable: true,
            authorized: true,
            samples: [
                EnvironmentalAudioSample(
                    startDate: now.addingTimeInterval(-180),
                    endDate: now.addingTimeInterval(-120),
                    decibelsA: 64.0,
                    sourceName: "Apple Watch",
                    isAppleWatch: true
                )
            ]
        )
        
        let calibrator = AppleWatchHealthKitCalibrator(provider: provider, nowProvider: { now })
        let context = CalibrationContext(
            samples: [DecibelMeasurementSample(timestamp: now, rawDecibels: 58.0, weighting: .dBA)],
            weighting: .dBA
        )
        
        let profile = try await calibrator.calibrate(using: context)
        XCTAssertEqual(profile.offsetDB, 6.0, accuracy: 0.01)
        XCTAssertEqual(profile.confidence, .userVerified)
    }
    
    func testAppleWatchHealthKitCalibratorThrowsWhenNoSamples() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let provider = MockHealthKitProvider(isHealthDataAvailable: true, authorized: true, samples: [])
        let calibrator = AppleWatchHealthKitCalibrator(provider: provider, nowProvider: { now })
        let context = CalibrationContext(
            samples: [DecibelMeasurementSample(timestamp: now, rawDecibels: 50.0, weighting: .dBA)],
            weighting: .dBA
        )
        
        do {
            _ = try await calibrator.calibrate(using: context)
            XCTFail("Expected unavailable error when no HealthKit samples exist")
        } catch let error as CalibrationError {
            if case .unavailable = error {
                // expected
            } else {
                XCTFail("Unexpected CalibrationError: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
