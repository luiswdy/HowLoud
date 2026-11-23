//
//  DecibelMeterViewModel.swift
//  HowLoud
//
//  Created by Luis Wu on 11/23/2026.
//  Copyright © 2026 Luis Wu. All rights reserved.
//

import Foundation
import AVFoundation
import Combine
import UIKit

@MainActor
final class DecibelMeterViewModel: ObservableObject {
    private struct Config {
        /// Nominal uncalibrated full-scale SPL (0 dBFS) for typical iPhone MEMS microphones.
        /// Fine-tuned per device/microphone via `CalibrationProfile`.
        static let nominalFullScaleSPL: Double = 110.0
        static let maxValue: Double = 160.0
        static let minValue: Double = 0.0
    }
    
    @Published var averageDecibels: Double = 0.0
    @Published var peakDecibels: Double = 0.0
    @Published private(set) var leqDecibels: Double = 0.0
    @Published private(set) var latestRawSPL: Double = 0.0
    @Published private(set) var isCapturingCalibrationSample: Bool = false
    @Published var isMeasuring: Bool = false
    @Published var isMicAuthorized: Bool = false
    @Published var showPermissionAlert: Bool = false
    @Published private(set) var isClipping: Bool = false
    @Published private(set) var activeInputRouteUID: String?
    @Published private(set) var sampleRate: Double = 48000.0
    @Published private(set) var calibrationProfile: CalibrationProfile
    
    @Published var frequencyWeighting: FrequencyWeighting = .dBA {
        didSet {
            guard frequencyWeighting != oldValue else { return }
            engine.updateWeighting(frequencyWeighting)
        }
    }
    
    @Published var timeWeighting: TimeWeighting = .fast {
        didSet {
            guard timeWeighting != oldValue else { return }
            engine.updateTimeWeighting(timeWeighting)
        }
    }
    
    let minValue: Double = Config.minValue
    let maxValue: Double = Config.maxValue
    let availableCalibrators: [any DecibelCalibrator]
    
    private let calibrationStore: CalibrationStore
    private let engine: SoundLevelEngine
    private var calibrationCaptureBuffer: [DecibelMeasurementSample]?
    
    var unitLabel: String {
        frequencyWeighting.rawValue
    }
    
    var minDisplayString: String {
        String(format: NSLocalizedString("gauge_range_format_string", comment: "format string"), Int(minValue))
    }
    
    var maxDisplayString: String {
        String(format: NSLocalizedString("gauge_range_format_string", comment: "format string"), Int(maxValue))
    }
    
    var averageDisplayString: String {
        String(format: "AVG: %.1f %@", averageDecibels, unitLabel)
    }
    
    var peakDisplayString: String {
        String(format: "Peak: %.1f %@", peakDecibels, unitLabel)
    }
    
    var leqDisplayString: String {
        String(format: "Leq: %.1f %@", leqDecibels, unitLabel)
    }
    
    init(
        calibrationStore: CalibrationStore = UserDefaultsCalibrationStore(),
        calibrators: [any DecibelCalibrator] = [
            AppleWatchHealthKitCalibrator(),
            ManualOffsetCalibrator(),
            MultiPointLinearCalibrator()
        ]
    ) {
        self.calibrationStore = calibrationStore
        self.availableCalibrators = calibrators
        self.calibrationProfile = calibrationStore.loadProfile(for: nil) ?? .identity
        self.engine = SoundLevelEngine(weighting: .dBA, timeWeighting: .fast)
        checkPermission()
    }
    
    func applyCalibration(
        using calibrator: any DecibelCalibrator,
        context: CalibrationContext
    ) async throws {
        if calibrator.requiresAuthorization {
            let authorized = try await calibrator.requestAuthorization()
            guard authorized else { throw CalibrationError.authorizationDenied }
        }
        let profile = try await calibrator.calibrate(using: context)
        calibrationStore.save(profile)
        calibrationProfile = profile
    }
    
    func resetCalibration(for routeUID: String? = nil) {
        let targetRoute = routeUID ?? activeInputRouteUID
        calibrationStore.removeProfile(for: targetRoute)
        calibrationProfile = calibrationStore.loadProfile(for: nil) ?? .identity
    }
    
    /// Captures timestamped uncalibrated SPL samples for a calibration session.
    func captureCalibrationSamples(duration: TimeInterval = 3.0) async -> [DecibelMeasurementSample] {
        guard !isCapturingCalibrationSample else { return [] }
        
        checkPermission()
        if !isMicAuthorized {
            let granted = await requestRecordPermissionAsync()
            isMicAuthorized = granted
            guard granted else {
                showPermissionAlert = true
                return []
            }
        }
        
        let wasMeasuring = isMeasuring
        if !wasMeasuring {
            startMeasuring()
        }
        guard isMeasuring else { return [] }
        
        isCapturingCalibrationSample = true
        calibrationCaptureBuffer = []
        
        let nanoseconds = UInt64(max(duration, 0.5) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
        
        let captured = calibrationCaptureBuffer ?? []
        calibrationCaptureBuffer = nil
        isCapturingCalibrationSample = false
        
        if !wasMeasuring {
            stopMeasuring()
        }
        
        return captured
    }
    
    private func requestRecordPermissionAsync() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }
    
    /// Converts a weighted dBFS power level into a calibrated, range-clamped SPL estimate.
    func calibratedDecibels(fromRawPower powerDBFS: Double) -> Double {
        let rawSPL = powerDBFS + Config.nominalFullScaleSPL
        let calibrated = calibrationProfile.apply(to: rawSPL)
        return calibrated.isFinite ? min(max(calibrated, Config.minValue), Config.maxValue) : Config.minValue
    }
    
    func checkPermission() {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                isMicAuthorized = true
            case .denied, .undetermined:
                isMicAuthorized = false
            @unknown default:
                isMicAuthorized = false
            }
        } else {
            switch AVAudioSession.sharedInstance().recordPermission {
            case .granted:
                isMicAuthorized = true
            case .denied, .undetermined:
                isMicAuthorized = false
            @unknown default:
                isMicAuthorized = false
            }
        }
    }
    
    func requestPermissionAndStart() {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                Task { @MainActor in
                    self?.isMicAuthorized = granted
                    if granted {
                        self?.startMeasuring()
                    } else {
                        self?.showPermissionAlert = true
                    }
                }
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                Task { @MainActor in
                    self?.isMicAuthorized = granted
                    if granted {
                        self?.startMeasuring()
                    } else {
                        self?.showPermissionAlert = true
                    }
                }
            }
        }
    }
    
    func toggleMeasuring() {
        checkPermission()
        if !isMicAuthorized {
            requestPermissionAndStart()
            return
        }
        
        if isMeasuring {
            stopMeasuring()
        } else {
            startMeasuring()
        }
    }
    
    func startMeasuring() {
        guard !isMeasuring else { return }
        
        engine.updateWeighting(frequencyWeighting)
        engine.updateTimeWeighting(timeWeighting)
        
        do {
            try engine.start { [weak self] measurement in
                Task { @MainActor in
                    self?.handleMeasurement(measurement)
                }
            }
            isMeasuring = true
        } catch {
            print("Failed to start SoundLevelEngine: \(error)")
            isMeasuring = false
        }
    }
    
    func stopMeasuring() {
        guard isMeasuring else { return }
        engine.stop()
        isMeasuring = false
        isClipping = false
    }
    
    private func handleMeasurement(_ measurement: SoundLevelMeasurement) {
        if measurement.inputRouteUID != activeInputRouteUID {
            activeInputRouteUID = measurement.inputRouteUID
            calibrationProfile = calibrationStore.loadProfile(for: measurement.inputRouteUID)
                ?? calibrationStore.loadProfile(for: nil)
                ?? .identity
        }
        
        let rawRMS = measurement.rmsDBFS + Config.nominalFullScaleSPL
        latestRawSPL = rawRMS.isFinite ? min(max(rawRMS, Config.minValue), Config.maxValue) : Config.minValue
        if calibrationCaptureBuffer != nil, rawRMS.isFinite {
            calibrationCaptureBuffer?.append(
                DecibelMeasurementSample(
                    timestamp: Date(),
                    rawDecibels: rawRMS,
                    weighting: measurement.weighting
                )
            )
        }
        
        sampleRate = measurement.sampleRate
        isClipping = measurement.isClipping
        averageDecibels = calibratedDecibels(fromRawPower: measurement.rmsDBFS)
        peakDecibels = calibratedDecibels(fromRawPower: measurement.peakDBFS)
        leqDecibels = calibratedDecibels(fromRawPower: measurement.leqDBFS)
    }
    
    deinit {
        engine.stop()
    }
}
