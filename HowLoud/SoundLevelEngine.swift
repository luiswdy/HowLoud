//
//  SoundLevelEngine.swift
//  HowLoud
//
//  Created by Luis Wu on 11/23/2026.
//  Copyright © 2026 Luis Wu. All rights reserved.
//

import Foundation
import Accelerate
import AVFoundation

// MARK: - Time Weighting & Measurement Model

/// Standard IEC 61672 exponential time weighting constants.
enum TimeWeighting: String, Codable, CaseIterable, Sendable {
    /// Fast response (125 ms time constant): standard for everyday and fluctuating noise.
    case fast
    /// Slow response (1000 ms time constant): smoother reading for steady ambient noise.
    case slow

    var timeConstantSeconds: Double {
        switch self {
        case .fast: return 0.125
        case .slow: return 1.0
        }
    }

    var shortLabel: String {
        switch self {
        case .fast: return "Fast"
        case .slow: return "Slow"
        }
    }
}

/// Snapshot produced by the DSP pipeline for each analyzed audio buffer.
struct SoundLevelMeasurement: Equatable, Sendable {
    /// Time-weighted RMS level in dBFS (relative to full scale, <= 0 dBFS).
    let rmsDBFS: Double
    /// Instantaneous peak level of the weighted buffer in dBFS.
    let peakDBFS: Double
    /// Session energy-equivalent continuous sound level (Leq) in dBFS.
    let leqDBFS: Double
    /// True if raw ADC samples hit digital full scale (>= 0.999).
    let isClipping: Bool
    let weighting: FrequencyWeighting
    let timeWeighting: TimeWeighting
    let sampleRate: Double
    let inputRouteUID: String?
}

// MARK: - IEC 61672 Frequency Weighting Filter

/// Double-precision cascaded biquad filter implementing IEC 61672-1 A-weighting,
/// C-weighting, and Z-weighting (with 10 Hz DC-blocking high-pass) at any sample rate.
final class AudioWeightingFilter {
    private struct BiquadSection {
        var b0: Double
        var b1: Double
        var b2: Double
        var a1: Double
        var a2: Double

        func magnitudeSquared(at normalizedFrequency: Double) -> Double {
            let omega = 2.0 * Double.pi * normalizedFrequency
            let cos1 = cos(omega)
            let sin1 = sin(omega)
            let cos2 = cos(2.0 * omega)
            let sin2 = sin(2.0 * omega)

            let numRe = b0 + b1 * cos1 + b2 * cos2
            let numIm = -b1 * sin1 - b2 * sin2
            let denRe = 1.0 + a1 * cos1 + a2 * cos2
            let denIm = -a1 * sin1 - a2 * sin2

            let denMagSq = denRe * denRe + denIm * denIm
            guard denMagSq > 0 else { return 0 }
            return (numRe * numRe + numIm * numIm) / denMagSq
        }
    }

    // Standard IEC 61672-1 analog corner frequencies (Hz)
    private static let f1: Double = 20.598997
    private static let f2: Double = 107.65265
    private static let f3: Double = 737.86223
    private static let f4: Double = 12194.217
    private static let dcBlockHz: Double = 10.0

    let weighting: FrequencyWeighting
    let sampleRate: Double

    private var setup: vDSP_biquad_SetupD?
    private var delayBuffer: [Double]
    private let sectionCount: vDSP_Length

    init(weighting: FrequencyWeighting, sampleRate: Double) {
        self.weighting = weighting
        self.sampleRate = max(sampleRate, 8000.0)

        var sections = Self.designSections(for: weighting, sampleRate: self.sampleRate)
        Self.normalizeGainAt1kHz(sections: &sections, sampleRate: self.sampleRate)

        let coeffs = sections.flatMap { [$0.b0, $0.b1, $0.b2, $0.a1, $0.a2] }
        self.sectionCount = vDSP_Length(sections.count)
        self.delayBuffer = Array(repeating: 0.0, count: 2 * sections.count + 2)
        self.setup = coeffs.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return nil }
            return vDSP_biquad_CreateSetupD(base, self.sectionCount)
        }
    }

    deinit {
        if let setup {
            vDSP_biquad_DestroySetupD(setup)
        }
    }

    func reset() {
        for i in delayBuffer.indices {
            delayBuffer[i] = 0.0
        }
    }

    /// Processes `count` samples from `input` into `output`. Both buffers must have capacity >= `count`.
    func process(input: [Double], output: inout [Double], count: Int) {
        guard count > 0 else { return }
        guard let setup else {
            for i in 0..<count { output[i] = input[i] }
            return
        }
        vDSP_biquadD(setup, &delayBuffer, input, 1, &output, 1, vDSP_Length(count))
    }

    /// Convenience helper for testing or offline processing.
    func process(_ samples: [Double]) -> [Double] {
        var output = Array(repeating: 0.0, count: samples.count)
        process(input: samples, output: &output, count: samples.count)
        return output
    }

    /// Returns the theoretical digital magnitude response (in dB) at a given frequency.
    static func theoreticalResponseDB(
        for weighting: FrequencyWeighting,
        at frequencyHz: Double,
        sampleRate: Double
    ) -> Double {
        var sections = designSections(for: weighting, sampleRate: sampleRate)
        normalizeGainAt1kHz(sections: &sections, sampleRate: sampleRate)
        let normFreq = frequencyHz / sampleRate
        let magSq = sections.reduce(1.0) { $0 * $1.magnitudeSquared(at: normFreq) }
        return 10.0 * log10(max(magSq, 1e-20))
    }

    // MARK: - Bilinear Transform Section Design

    private static func designSections(
        for weighting: FrequencyWeighting,
        sampleRate: Double
    ) -> [BiquadSection] {
        let nyquistSafeMax = sampleRate * 0.45

        switch weighting {
        case .dBZ:
            // Flat response across the audible spectrum with a 10 Hz DC-blocking high-pass filter.
            return [secondOrderHighPass(frequencyHz: min(dcBlockHz, nyquistSafeMax), sampleRate: sampleRate)]

        case .dBC:
            let hp1 = secondOrderHighPass(frequencyHz: min(f1, nyquistSafeMax), sampleRate: sampleRate)
            let lp4 = secondOrderLowPass(frequencyHz: min(f4, nyquistSafeMax), sampleRate: sampleRate)
            return [hp1, lp4]

        case .dBA:
            let hp1 = secondOrderHighPass(frequencyHz: min(f1, nyquistSafeMax), sampleRate: sampleRate)
            let hp23 = twoPoleHighPass(
                fLowHz: min(f2, nyquistSafeMax),
                fHighHz: min(f3, nyquistSafeMax),
                sampleRate: sampleRate
            )
            let lp4 = secondOrderLowPass(frequencyHz: min(f4, nyquistSafeMax), sampleRate: sampleRate)
            return [hp1, hp23, lp4]
        }
    }

    /// Bilinear transform of s^2 / (s + w0)^2 with frequency pre-warping.
    private static func secondOrderHighPass(frequencyHz: Double, sampleRate: Double) -> BiquadSection {
        let alpha = tan(Double.pi * frequencyHz / sampleRate)
        let a0 = (1.0 + alpha) * (1.0 + alpha)
        return BiquadSection(
            b0: 1.0 / a0,
            b1: -2.0 / a0,
            b2: 1.0 / a0,
            a1: 2.0 * (alpha * alpha - 1.0) / a0,
            a2: ((1.0 - alpha) * (1.0 - alpha)) / a0
        )
    }

    /// Bilinear transform of w0^2 / (s + w0)^2 with frequency pre-warping.
    private static func secondOrderLowPass(frequencyHz: Double, sampleRate: Double) -> BiquadSection {
        let alpha = tan(Double.pi * frequencyHz / sampleRate)
        let alphaSq = alpha * alpha
        let a0 = (1.0 + alpha) * (1.0 + alpha)
        return BiquadSection(
            b0: alphaSq / a0,
            b1: (2.0 * alphaSq) / a0,
            b2: alphaSq / a0,
            a1: 2.0 * (alphaSq - 1.0) / a0,
            a2: ((1.0 - alpha) * (1.0 - alpha)) / a0
        )
    }

    /// Bilinear transform of s^2 / ((s + wLow)(s + wHigh)) with frequency pre-warping.
    private static func twoPoleHighPass(fLowHz: Double, fHighHz: Double, sampleRate: Double) -> BiquadSection {
        let aLow = tan(Double.pi * fLowHz / sampleRate)
        let aHigh = tan(Double.pi * fHighHz / sampleRate)
        let a0 = (1.0 + aLow) * (1.0 + aHigh)
        return BiquadSection(
            b0: 1.0 / a0,
            b1: -2.0 / a0,
            b2: 1.0 / a0,
            a1: 2.0 * (aLow * aHigh - 1.0) / a0,
            a2: ((1.0 - aLow) * (1.0 - aHigh)) / a0
        )
    }

    private static func normalizeGainAt1kHz(sections: inout [BiquadSection], sampleRate: Double) {
        guard !sections.isEmpty else { return }
        let norm1k = min(1000.0 / sampleRate, 0.45)
        let magSq = sections.reduce(1.0) { $0 * $1.magnitudeSquared(at: norm1k) }
        let gain = sqrt(magSq)
        guard gain > 0, gain.isFinite else { return }
        sections[0].b0 /= gain
        sections[0].b1 /= gain
        sections[0].b2 /= gain
    }
}

// MARK: - Pure DSP Sound Level Processor

/// Stateful real-time DSP processor converting raw PCM Float buffers into IEC 61672
/// frequency-weighted, exponentially time-weighted RMS, Peak, and Leq readings.
final class SoundLevelProcessor {
    private static let minPowerFloor: Double = 1e-16 // -160 dBFS
    private static let clippingThreshold: Float = 0.999

    private(set) var weighting: FrequencyWeighting
    private(set) var timeWeighting: TimeWeighting
    private(set) var sampleRate: Double

    private var filter: AudioWeightingFilter
    private var exponentialMeanSquare: Double = 0.0
    private var hasInitializedEnvelope: Bool = false
    private var leqEnergySum: Double = 0.0
    private var leqSampleCount: Int = 0

    // Reusable scratch buffers to avoid per-callback heap allocations
    private var inputScratch: [Double] = []
    private var outputScratch: [Double] = []

    init(
        weighting: FrequencyWeighting = .dBA,
        timeWeighting: TimeWeighting = .fast,
        sampleRate: Double = 48000.0
    ) {
        self.weighting = weighting
        self.timeWeighting = timeWeighting
        self.sampleRate = max(sampleRate, 8000.0)
        self.filter = AudioWeightingFilter(weighting: weighting, sampleRate: self.sampleRate)
    }

    func reconfigure(
        weighting: FrequencyWeighting? = nil,
        timeWeighting: TimeWeighting? = nil,
        sampleRate: Double? = nil
    ) {
        let newWeighting = weighting ?? self.weighting
        let newTimeWeighting = timeWeighting ?? self.timeWeighting
        let newSampleRate = max(sampleRate ?? self.sampleRate, 8000.0)

        let filterChanged = (newWeighting != self.weighting) || (abs(newSampleRate - self.sampleRate) > 0.5)
        self.weighting = newWeighting
        self.timeWeighting = newTimeWeighting
        self.sampleRate = newSampleRate

        if filterChanged {
            self.filter = AudioWeightingFilter(weighting: newWeighting, sampleRate: newSampleRate)
            resetSession()
        }
    }

    func resetSession() {
        filter.reset()
        exponentialMeanSquare = 0.0
        hasInitializedEnvelope = false
        leqEnergySum = 0.0
        leqSampleCount = 0
    }

    func process(
        samples: UnsafeBufferPointer<Float>,
        inputRouteUID: String? = nil
    ) -> SoundLevelMeasurement {
        let count = samples.count
        guard count > 0, let base = samples.baseAddress else {
            return SoundLevelMeasurement(
                rmsDBFS: -160.0,
                peakDBFS: -160.0,
                leqDBFS: -160.0,
                isClipping: false,
                weighting: weighting,
                timeWeighting: timeWeighting,
                sampleRate: sampleRate,
                inputRouteUID: inputRouteUID
            )
        }

        if inputScratch.count < count {
            inputScratch = Array(repeating: 0.0, count: count)
            outputScratch = Array(repeating: 0.0, count: count)
        }

        var isClipping = false
        for i in 0..<count {
            let sample = base[i]
            if abs(sample) >= Self.clippingThreshold {
                isClipping = true
            }
            inputScratch[i] = Double(sample)
        }

        filter.process(input: inputScratch, output: &outputScratch, count: count)

        // Compute buffer mean-square and peak
        var bufferEnergy = 0.0
        var maxAbsWeighted = 0.0
        for i in 0..<count {
            let y = outputScratch[i]
            let absY = abs(y)
            if absY > maxAbsWeighted {
                maxAbsWeighted = absY
            }
            bufferEnergy += y * y
        }

        let bufferMeanSquare = bufferEnergy / Double(count)
        let alpha = 1.0 - exp(-1.0 / (sampleRate * timeWeighting.timeConstantSeconds))
        let oneMinusAlpha = 1.0 - alpha

        if !hasInitializedEnvelope {
            exponentialMeanSquare = bufferMeanSquare
            hasInitializedEnvelope = true
        } else {
            var env = exponentialMeanSquare
            for i in 0..<count {
                let y = outputScratch[i]
                env = oneMinusAlpha * env + alpha * (y * y)
            }
            exponentialMeanSquare = env
        }

        leqEnergySum += bufferEnergy
        leqSampleCount += count

        let rmsDBFS = 10.0 * log10(max(exponentialMeanSquare, Self.minPowerFloor))
        let peakDBFS = 20.0 * log10(max(maxAbsWeighted, sqrt(Self.minPowerFloor)))
        let leqMeanSquare = leqSampleCount > 0 ? (leqEnergySum / Double(leqSampleCount)) : 0.0
        let leqDBFS = 10.0 * log10(max(leqMeanSquare, Self.minPowerFloor))

        return SoundLevelMeasurement(
            rmsDBFS: rmsDBFS,
            peakDBFS: peakDBFS,
            leqDBFS: leqDBFS,
            isClipping: isClipping,
            weighting: weighting,
            timeWeighting: timeWeighting,
            sampleRate: sampleRate,
            inputRouteUID: inputRouteUID
        )
    }

    func process(samples: [Float], inputRouteUID: String? = nil) -> SoundLevelMeasurement {
        samples.withUnsafeBufferPointer { buffer in
            process(samples: buffer, inputRouteUID: inputRouteUID)
        }
    }
}

// MARK: - AVAudioEngine Hardware Capture

/// Real-time audio engine using `AVAudioEngine`, native hardware sample rate,
/// bottom omnidirectional built-in mic preference, and `SoundLevelProcessor`.
/// All `AVAudioSession` and `AVAudioEngine` lifecycle work executes on a dedicated
/// serial background queue to avoid blocking the main thread.
final class SoundLevelEngine: @unchecked Sendable {
    enum EngineError: Error, LocalizedError {
        case invalidAudioFormat

        var errorDescription: String? {
            switch self {
            case .invalidAudioFormat:
                return "Unable to read a valid audio input format from the device microphone."
            }
        }
    }

    private let audioQueue = DispatchQueue(label: "com.howloud.audio-engine", qos: .userInitiated)
    private let audioEngine = AVAudioEngine()
    private let processorLock = NSLock()
    private let processor: SoundLevelProcessor
    private let minDispatchInterval: TimeInterval = 0.06 // ~16 Hz UI updates

    private var lastDispatchTime: CFAbsoluteTime = 0
    private var isRunning = false
    private var measurementHandler: (@Sendable (SoundLevelMeasurement) -> Void)?
    private var routeChangeObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?

    init(
        weighting: FrequencyWeighting = .dBA,
        timeWeighting: TimeWeighting = .fast
    ) {
        self.processor = SoundLevelProcessor(weighting: weighting, timeWeighting: timeWeighting)
    }

    deinit {
        unregisterNotifications()
        let engine = audioEngine
        let wasRunning = isRunning
        audioQueue.async {
            if wasRunning {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    func updateWeighting(_ weighting: FrequencyWeighting) {
        processorLock.lock()
        processor.reconfigure(weighting: weighting)
        processorLock.unlock()
    }

    func updateTimeWeighting(_ timeWeighting: TimeWeighting) {
        processorLock.lock()
        processor.reconfigure(timeWeighting: timeWeighting)
        processorLock.unlock()
    }

    func resetSessionMetrics() {
        processorLock.lock()
        processor.resetSession()
        processorLock.unlock()
    }

    func start(onMeasurement: @escaping @Sendable (SoundLevelMeasurement) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            audioQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }

                self.processorLock.lock()
                self.measurementHandler = onMeasurement
                self.processorLock.unlock()

                guard !self.isRunning else {
                    continuation.resume()
                    return
                }

                do {
                    try self.configureAudioSession()
                    try self.startAudioEngineTap()
                    self.registerNotifications()
                    self.isRunning = true
                    continuation.resume()
                } catch {
                    self.processorLock.lock()
                    self.measurementHandler = nil
                    self.processorLock.unlock()
                    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        processorLock.lock()
        measurementHandler = nil
        processorLock.unlock()

        audioQueue.async { [weak self] in
            self?.stopOnAudioQueue()
        }
    }

    private func stopOnAudioQueue() {
        unregisterNotifications()

        guard isRunning else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isRunning = false

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Audio Session & Mic Selection

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        selectPreferredBuiltInMicrophone(on: session)
        try session.setActive(true)
    }

    /// Prefers the built-in bottom omnidirectional microphone when available for repeatable acoustics.
    private func selectPreferredBuiltInMicrophone(on session: AVAudioSession) {
        guard let inputs = session.availableInputs,
              let builtInMic = inputs.first(where: { $0.portType == .builtInMic }) else {
            return
        }

        // Only override input if no external wired/USB measurement mic is currently attached.
        let hasExternalMic = inputs.contains {
            $0.portType == .usbAudio || $0.portType == .headsetMic
        }
        guard !hasExternalMic else { return }

        try? session.setPreferredInput(builtInMic)

        if let dataSources = builtInMic.dataSources,
           let bottomSource = dataSources.first(where: { $0.orientation == .bottom }) ?? dataSources.first {
            if let patterns = bottomSource.supportedPolarPatterns,
               patterns.contains(.omnidirectional) {
                try? bottomSource.setPreferredPolarPattern(.omnidirectional)
            }
            try? builtInMic.setPreferredDataSource(bottomSource)
        }
    }

    private func startAudioEngineTap() throws {
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw EngineError.invalidAudioFormat
        }

        let activeRouteUID = AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid

        processorLock.lock()
        processor.reconfigure(sampleRate: format.sampleRate)
        processor.resetSession()
        lastDispatchTime = 0
        processorLock.unlock()

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self,
                  let channelData = buffer.floatChannelData?[0] else {
                return
            }

            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }

            let sampleBuffer = UnsafeBufferPointer(start: channelData, count: frameLength)

            self.processorLock.lock()
            let measurement = self.processor.process(samples: sampleBuffer, inputRouteUID: activeRouteUID)
            let now = CFAbsoluteTimeGetCurrent()
            let shouldEmit = (now - self.lastDispatchTime) >= self.minDispatchInterval
            if shouldEmit {
                self.lastDispatchTime = now
            }
            let handler = self.measurementHandler
            self.processorLock.unlock()

            if shouldEmit {
                handler?(measurement)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    // MARK: - Route Change & Interruption Handling

    private func registerNotifications() {
        unregisterNotifications()
        let center = NotificationCenter.default

        routeChangeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.audioQueue.async { [weak self] in
                self?.restartTapAfterRouteChange()
            }
        }

        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType),
                  type == .ended else {
                return
            }

            self?.audioQueue.async { [weak self] in
                self?.restartTapAfterRouteChange()
            }
        }
    }

    private func unregisterNotifications() {
        let center = NotificationCenter.default
        if let observer = routeChangeObserver {
            center.removeObserver(observer)
            routeChangeObserver = nil
        }
        if let observer = interruptionObserver {
            center.removeObserver(observer)
            interruptionObserver = nil
        }
    }

    private func restartTapAfterRouteChange() {
        guard isRunning else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        do {
            try configureAudioSession()
            try startAudioEngineTap()
        } catch {
            print("Failed to restart SoundLevelEngine after route change: \(error)")
        }
    }
}
