//
//  CalibrationView.swift
//  HowLoud
//
//  Created by Luis Wu on 11/23/2026.
//  Copyright © 2026 Luis Wu. All rights reserved.
//

import SwiftUI
import UIKit

struct CalibrationView: View {
    private struct FeedbackBanner: Equatable {
        let message: String
        let isError: Bool
    }

    @ObservedObject var viewModel: DecibelMeterViewModel
    @Environment(\.dismiss) private var dismiss

    @FocusState private var isReferenceFieldFocused: Bool
    @State private var manualOffset: Double
    @State private var referenceInput: String = ""
    @State private var capturedSamples: [DecibelMeasurementSample] = []
    @State private var isSyncingHealthKit: Bool = false
    @State private var latestWatchMatch: AppleWatchCalibrationMatch?
    @State private var feedbackBanner: FeedbackBanner?
    @State private var bannerDismissTask: Task<Void, Never>?

    init(viewModel: DecibelMeterViewModel) {
        self.viewModel = viewModel
        _manualOffset = State(initialValue: min(max(viewModel.calibrationProfile.offsetDB, -30.0), 30.0))
    }

    private var parsedReferenceDB: Double? {
        let cleaned = referenceInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty, let value = Double(cleaned), value.isFinite else {
            return nil
        }
        return value
    }

    private var capturedEnergyAverage: Double? {
        CalibrationContext(samples: capturedSamples).energyAveragedRawDecibels
    }

    private var projectedReferenceOffset: Double? {
        guard let ref = parsedReferenceDB, let avg = capturedEnergyAverage else {
            return nil
        }
        return ref - avg
    }

    private var livePreviewValue: Double {
        let raw = viewModel.latestRawSPL
        return min(max(raw + manualOffset, viewModel.minValue), viewModel.maxValue)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Form {
                    activeProfileSection
                    appleWatchHealthKitSection
                    appleWatchReferenceSection
                    manualOffsetSection
                    tipsSection
                }
                .scrollDismissesKeyboard(.interactively)

                if let banner = feedbackBanner {
                    HStack(spacing: 10) {
                        Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.headline)
                        Text(banner.message)
                            .font(.subheadline.weight(.semibold))
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 4)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(banner.isError ? Color.red.opacity(0.95) : Color.green.opacity(0.92))
                            .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityIdentifier("calibrationFeedbackBanner")
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: feedbackBanner)
            .navigationTitle("Calibration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        isReferenceFieldFocused = false
                        dismiss()
                    }
                    .accessibilityIdentifier("calibrationDoneButton")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        isReferenceFieldFocused = false
                    }
                }
            }
            .accessibilityIdentifier("calibrationSheet")
        }
    }

    // MARK: - Sections

    private var activeProfileSection: some View {
        Section("Active Calibration") {
            HStack {
                Text("Method")
                Spacer()
                Text(viewModel.calibrationProfile.displayName)
                    .foregroundColor(.secondary)
            }

            HStack {
                Text("Offset")
                Spacer()
                Text(String(format: "%+.1f dB", viewModel.calibrationProfile.offsetDB))
                    .font(.body.monospacedDigit().weight(.semibold))
                    .foregroundColor(viewModel.calibrationProfile.offsetDB == 0 ? .secondary : .accentColor)
            }

            if abs(viewModel.calibrationProfile.slope - 1.0) > 0.001 {
                HStack {
                    Text("Linear Slope")
                    Spacer()
                    Text(String(format: "%.2fx", viewModel.calibrationProfile.slope))
                        .font(.body.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                Text("Live Reading")
                Spacer()
                if viewModel.isMeasuring {
                    Text(String(format: "%.1f %@", viewModel.averageDecibels, viewModel.unitLabel))
                        .font(.body.monospacedDigit().weight(.semibold))
                } else {
                    Text("Paused")
                        .foregroundColor(.secondary)
                }
            }

            if viewModel.calibrationProfile != .identity {
                Button(role: .destructive) {
                    isReferenceFieldFocused = false
                    viewModel.resetCalibration()
                    manualOffset = 0.0
                    showFeedback("Calibration reset to default.", isError: false)
                } label: {
                    Label("Reset to Default", systemImage: "arrow.counterclockwise")
                }
                .accessibilityIdentifier("resetCalibrationButton")
            }
        }
    }

    private var appleWatchHealthKitSection: some View {
        Section {
            Button {
                isReferenceFieldFocused = false
                syncWithAppleWatchHealthKit()
            } label: {
                HStack {
                    if isSyncingHealthKit {
                        ProgressView()
                            .padding(.trailing, 6)
                        Text("Sampling & syncing Apple Watch...")
                    } else {
                        Label("Auto-Sync from Apple Watch (HealthKit)", systemImage: "heart.text.square.fill")
                            .font(.body.weight(.semibold))
                    }
                }
            }
            .disabled(isSyncingHealthKit || viewModel.isCapturingCalibrationSample)
            .accessibilityIdentifier("healthKitSyncButton")

            if let match = latestWatchMatch {
                HStack {
                    Text(match.isAppleWatchSource ? "Apple Watch Sample" : "HealthKit Sample")
                    Spacer()
                    Text(String(format: "%.1f dBA", match.referenceDecibelsA))
                        .font(.body.monospacedDigit().weight(.semibold))
                        .foregroundColor(.green)
                }

                HStack {
                    Text("Recorded")
                    Spacer()
                    Text(match.latestSampleDate, style: .relative)
                        .foregroundColor(.secondary)
                    Text("ago")
                        .foregroundColor(.secondary)
                }
                .font(.caption)
            }
        } header: {
            Text("Automatic Apple Watch Calibration")
        } footer: {
            Text("Reads calibrated environmental sound levels (dBA) logged by your Apple Watch in Apple Health. Open the Noise app on your Watch for ~10s in steady sound, then tap Auto-Sync.")
        }
    }

    private var appleWatchReferenceSection: some View {
        Section {
            HStack {
                Text("Weighting")
                Spacer()
                Text(viewModel.frequencyWeighting.rawValue)
                    .foregroundColor(.secondary)
            }

            Button {
                isReferenceFieldFocused = false
                captureReferenceSample()
            } label: {
                HStack {
                    if viewModel.isCapturingCalibrationSample {
                        ProgressView()
                            .padding(.trailing, 6)
                        Text("Sampling ambient sound (3s)...")
                    } else {
                        Label("Step 1: Capture 3s Sample", systemImage: "waveform.badge.magnifyingglass")
                    }
                }
            }
            .disabled(viewModel.isCapturingCalibrationSample)
            .accessibilityIdentifier("captureSampleButton")

            if let avg = capturedEnergyAverage {
                HStack {
                    Text("Captured Raw Average")
                    Spacer()
                    Text(String(format: "%.1f %@", avg, viewModel.unitLabel))
                        .font(.body.monospacedDigit().weight(.semibold))
                        .foregroundColor(.accentColor)
                }
            }

            HStack {
                Text("Step 2: Reference")
                Spacer()
                TextField("e.g. 68.5", text: $referenceInput)
                    .focused($isReferenceFieldFocused)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 110)
                    .accessibilityIdentifier("referenceDecibelsField")
                Text(viewModel.unitLabel)
                    .foregroundColor(.secondary)
            }

            if let projected = projectedReferenceOffset {
                HStack {
                    Text("Calculated Offset")
                    Spacer()
                    Text(String(format: "%+.1f dB", projected))
                        .font(.body.monospacedDigit().weight(.semibold))
                        .foregroundColor(.green)
                }
            }

            Button {
                isReferenceFieldFocused = false
                applyReferenceMatch()
            } label: {
                Label("Step 3: Match Reference Reading", systemImage: "applewatch.radiowaves.left.and.right")
                    .font(.body.weight(.semibold))
            }
            .accessibilityIdentifier("matchReferenceButton")
        } header: {
            Text("Manual Reference Match (Watch / SPL Meter)")
        } footer: {
            Text("Open the Noise app on Apple Watch (or use an SPL meter), play steady pink noise ~1 m away, hold your iPhone ~10 cm from the Watch, tap Step 1, enter the Watch's reading, then tap Step 3.")
        }
    }

    private var manualOffsetSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Manual Offset")
                    Spacer()
                    Text(String(format: "%+.1f dB", manualOffset))
                        .font(.headline.monospacedDigit())
                        .foregroundColor(.accentColor)
                }

                Slider(value: $manualOffset, in: -30.0...30.0, step: 0.5)
                    .accessibilityIdentifier("manualOffsetSlider")

                HStack(spacing: 12) {
                    Button("-0.5 dB") {
                        manualOffset = max(-30.0, (manualOffset - 0.5).roundedToHalf())
                    }
                    .buttonStyle(.bordered)

                    Button("+0.5 dB") {
                        manualOffset = min(30.0, (manualOffset + 0.5).roundedToHalf())
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    if viewModel.isMeasuring {
                        Text(String(format: "Preview: %.1f %@", livePreviewValue, viewModel.unitLabel))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)

            Button {
                isReferenceFieldFocused = false
                applyManualOffset()
            } label: {
                Label("Apply Manual Offset", systemImage: "checkmark.circle.fill")
            }
            .accessibilityIdentifier("applyManualOffsetButton")
        } header: {
            Text("Direct Offset")
        } footer: {
            Text("Adjust directly if you already know your microphone's offset.")
        }
    }

    private var tipsSection: some View {
        Section("Calibration Tips") {
            Label("Use dBA weighting to match Apple Watch's Noise app.", systemImage: "ear")
            Label("Hold the phone in free air—resting on a desk adds +3 to +6 dB.", systemImage: "hand.raised")
            Label("Thick or waterproof cases can reduce high-frequency sensitivity.", systemImage: "iphone.case")
        }
        .font(.footnote)
        .foregroundColor(.secondary)
    }

    // MARK: - Actions & Feedback

    private func showFeedback(_ message: String, isError: Bool) {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(isError ? .error : .success)

        feedbackBanner = FeedbackBanner(message: message, isError: isError)
        bannerDismissTask?.cancel()
        bannerDismissTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            feedbackBanner = nil
        }
    }

    private func syncWithAppleWatchHealthKit() {
        let calibrator = AppleWatchHealthKitCalibrator()
        isSyncingHealthKit = true

        if viewModel.frequencyWeighting != .dBA {
            viewModel.frequencyWeighting = .dBA
        }

        Task {
            defer { isSyncingHealthKit = false }

            do {
                let authorized = try await calibrator.requestAuthorization()
                guard authorized else {
                    throw CalibrationError.authorizationDenied
                }

                let samples = await viewModel.captureCalibrationSamples(duration: 3.0)
                guard !samples.isEmpty else {
                    showFeedback("No microphone samples captured. Grant microphone permission and try again.", isError: true)
                    return
                }
                capturedSamples = samples

                let match = try await calibrator.matchHealthKitReference(for: samples)
                latestWatchMatch = match

                let context = CalibrationContext(
                    samples: samples,
                    weighting: .dBA,
                    inputRouteUID: viewModel.activeInputRouteUID
                )
                try await viewModel.applyCalibration(using: calibrator, context: context)
                manualOffset = min(max(viewModel.calibrationProfile.offsetDB.roundedToHalf(), -30.0), 30.0)

                showFeedback(
                    String(
                        format: "Synced with Apple Watch (%.1f dBA → offset %+.1f dB).",
                        match.referenceDecibelsA,
                        viewModel.calibrationProfile.offsetDB
                    ),
                    isError: false
                )
            } catch {
                showFeedback(error.localizedDescription, isError: true)
            }
        }
    }

    private func applyManualOffset() {
        let context = CalibrationContext(
            manualOffsetDB: manualOffset,
            weighting: viewModel.frequencyWeighting,
            inputRouteUID: viewModel.activeInputRouteUID
        )

        Task {
            do {
                try await viewModel.applyCalibration(using: ManualOffsetCalibrator(), context: context)
                showFeedback(String(format: "Applied %+.1f dB offset.", manualOffset), isError: false)
            } catch {
                showFeedback(error.localizedDescription, isError: true)
            }
        }
    }

    private func captureReferenceSample() {
        if viewModel.frequencyWeighting != .dBA {
            viewModel.frequencyWeighting = .dBA
        }

        Task {
            let samples = await viewModel.captureCalibrationSamples(duration: 3.0)
            capturedSamples = samples
            if samples.isEmpty {
                showFeedback("No audio samples captured. Check microphone permission and try again.", isError: true)
            } else if let avg = CalibrationContext(samples: samples).energyAveragedRawDecibels {
                showFeedback(
                    String(format: "Captured %d samples (raw avg: %.1f %@). Enter reference reading.", samples.count, avg, viewModel.unitLabel),
                    isError: false
                )
            }
        }
    }

    private func applyReferenceMatch() {
        guard !capturedSamples.isEmpty else {
            showFeedback("Tap \"Step 1: Capture 3s Sample\" first.", isError: true)
            return
        }

        guard let referenceDB = parsedReferenceDB else {
            showFeedback("Enter a valid reference dB reading first.", isError: true)
            return
        }

        let context = CalibrationContext(
            samples: capturedSamples,
            referenceDecibels: referenceDB,
            weighting: viewModel.frequencyWeighting,
            inputRouteUID: viewModel.activeInputRouteUID
        )

        Task {
            do {
                try await viewModel.applyCalibration(using: ManualOffsetCalibrator(), context: context)
                manualOffset = min(max(viewModel.calibrationProfile.offsetDB.roundedToHalf(), -30.0), 30.0)
                showFeedback(
                    String(
                        format: "Calibrated to %.1f %@ (offset %+.1f dB).",
                        referenceDB,
                        viewModel.unitLabel,
                        viewModel.calibrationProfile.offsetDB
                    ),
                    isError: false
                )
            } catch {
                showFeedback(error.localizedDescription, isError: true)
            }
        }
    }
}

private extension Double {
    func roundedToHalf() -> Double {
        (self * 2.0).rounded() / 2.0
    }
}
