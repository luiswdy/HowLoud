//
//  ContentView.swift
//  HowLoud
//
//  Created by Luis Wu on 11/23/2026.
//  Copyright © 2026 Luis Wu. All rights reserved.
//

import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var viewModel = DecibelMeterViewModel()
    @State private var showCalibrationSheet = false

    var body: some View {
        ZStack {
            HowLoudColors.background
                .ignoresSafeArea()

            VStack(spacing: HowLoudSpacing.lg) {
                // Header
                HeaderView(
                    isMeasuring: viewModel.isMeasuring,
                    isClipping: viewModel.isClipping,
                    calibrationOffset: viewModel.calibrationProfile.offsetDB,
                    onCalibrationTap: {
                        showCalibrationSheet = true
                    }
                )
                .padding(.horizontal, HowLoudSpacing.xl)
                .padding(.top, HowLoudSpacing.sm)

                // Material Segmented Controls (Weighting & Response)
                WeightingControlBar(
                    frequencyWeighting: $viewModel.frequencyWeighting,
                    timeWeighting: $viewModel.timeWeighting
                )
                .padding(.horizontal, HowLoudSpacing.xl)

                Spacer(minLength: HowLoudSpacing.sm)

                // Flat Material-Inspired Gauge
                GaugeView(
                    value: viewModel.averageDecibels,
                    minValue: viewModel.minValue,
                    maxValue: viewModel.maxValue,
                    unitLabel: viewModel.unitLabel,
                    isMeasuring: viewModel.isMeasuring
                )
                .frame(maxWidth: 400, maxHeight: 400)
                .padding(.horizontal, HowLoudSpacing.xl)
                .aspectRatio(1, contentMode: .fit)

                Spacer(minLength: HowLoudSpacing.sm)

                // Tonal Flat Metric Cards
                MetricsView(
                    averageValue: viewModel.averageDecibels,
                    peakValue: viewModel.peakDecibels,
                    unitLabel: viewModel.unitLabel
                )
                .padding(.horizontal, HowLoudSpacing.xl)

                Spacer(minLength: HowLoudSpacing.md)

                // Material 3 Extended FAB Control Button
                ControlButton(isMeasuring: viewModel.isMeasuring) {
                    let impact = UIImpactFeedbackGenerator(style: .medium)
                    impact.impactOccurred()
                    viewModel.toggleMeasuring()
                }
                .padding(.bottom, HowLoudSpacing.xxl)
            }
        }
        .sheet(isPresented: $showCalibrationSheet) {
            CalibrationView(viewModel: viewModel)
        }
        .alert(isPresented: $viewModel.showPermissionAlert) {
            Alert(
                title: Text(NSLocalizedString("mic_perm_req", comment: "")),
                message: Text(String(format: NSLocalizedString("mic_perm_description", comment: ""), "HowLoud")),
                primaryButton: .default(Text("Settings"), action: {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }),
                secondaryButton: .cancel(Text(NSLocalizedString("got_it", comment: "")))
            )
        }
    }
}

// MARK: - Header

private struct HeaderView: View {
    let isMeasuring: Bool
    let isClipping: Bool
    let calibrationOffset: Double
    let onCalibrationTap: () -> Void

    var body: some View {
        ZStack {
            HStack(spacing: HowLoudSpacing.sm) {
                Image(systemName: isMeasuring ? "waveform" : "waveform.slash")
                    .font(.headline.weight(.semibold))
                    .foregroundColor(isMeasuring ? HowLoudColors.primary : HowLoudColors.onSurfaceVariant)

                Text("HowLoud")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundColor(HowLoudColors.onSurface)

                if isClipping {
                    Text("CLIP")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(HowLoudColors.onErrorContainer)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(HowLoudColors.errorContainer))
                }
            }

            HStack {
                Spacer()
                Button(action: onCalibrationTap) {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.subheadline.weight(.semibold))
                        if abs(calibrationOffset) >= 0.05 {
                            Text(String(format: "%+.1f", calibrationOffset))
                                .font(.caption2.monospacedDigit().weight(.semibold))
                        }
                    }
                    .foregroundColor(abs(calibrationOffset) >= 0.05 ? HowLoudColors.onPrimaryContainer : HowLoudColors.onSurface)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(abs(calibrationOffset) >= 0.05 ? HowLoudColors.primaryContainer : HowLoudColors.surfaceContainer)
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(HowLoudColors.outlineVariant.opacity(0.6), lineWidth: 1)
                    )
                }
                .accessibilityLabel("Calibration")
                .accessibilityIdentifier("calibrationButton")
            }
        }
    }
}

// MARK: - Material Segmented Controls

private struct WeightingControlBar: View {
    @Binding var frequencyWeighting: FrequencyWeighting
    @Binding var timeWeighting: TimeWeighting

    var body: some View {
        HStack(spacing: HowLoudSpacing.md) {
            HStack(spacing: 2) {
                ForEach(FrequencyWeighting.allCases, id: \.self) { weighting in
                    Button {
                        frequencyWeighting = weighting
                    } label: {
                        Text(weighting.rawValue)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(
                                frequencyWeighting == weighting
                                    ? HowLoudColors.onPrimaryContainer
                                    : HowLoudColors.onSurfaceVariant
                            )
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                Capsule()
                                    .fill(frequencyWeighting == weighting ? HowLoudColors.primaryContainer : Color.clear)
                            )
                    }
                    .accessibilityIdentifier("weighting_\(weighting.rawValue)")
                }
            }
            .padding(3)
            .background(Capsule().fill(HowLoudColors.surfaceContainer))
            .overlay(Capsule().strokeBorder(HowLoudColors.outlineVariant.opacity(0.6), lineWidth: 1))

            HStack(spacing: 2) {
                ForEach(TimeWeighting.allCases, id: \.self) { mode in
                    Button {
                        timeWeighting = mode
                    } label: {
                        Text(mode.shortLabel)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(
                                timeWeighting == mode
                                    ? HowLoudColors.onPrimaryContainer
                                    : HowLoudColors.onSurfaceVariant
                            )
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                Capsule()
                                    .fill(timeWeighting == mode ? HowLoudColors.primaryContainer : Color.clear)
                            )
                    }
                    .accessibilityIdentifier("response_\(mode.rawValue)")
                }
            }
            .padding(3)
            .background(Capsule().fill(HowLoudColors.surfaceContainer))
            .overlay(Capsule().strokeBorder(HowLoudColors.outlineVariant.opacity(0.6), lineWidth: 1))
        }
    }
}

// MARK: - Flat Tonal Metric Cards

private struct MetricsView: View {
    let averageValue: Double
    let peakValue: Double
    let unitLabel: String

    var body: some View {
        HStack(spacing: HowLoudSpacing.md) {
            MetricCard(title: "AVERAGE", value: averageValue, unitLabel: unitLabel)
            MetricCard(title: "PEAK", value: peakValue, unitLabel: unitLabel)
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: Double
    let unitLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundColor(HowLoudColors.onSurfaceVariant)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: "%.1f", value))
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(HowLoudColors.onSurface)

                Text(unitLabel)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(HowLoudColors.onSurfaceVariant)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: HowLoudRadius.card, style: .continuous)
                .fill(HowLoudColors.surfaceContainer)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HowLoudRadius.card, style: .continuous)
                .strokeBorder(HowLoudColors.outlineVariant.opacity(0.5), lineWidth: 1)
        )
    }
}

// MARK: - Material 3 Extended FAB Control Button

private struct ControlButton: View {
    let isMeasuring: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isMeasuring ? "pause.fill" : "play.fill")
                    .font(.body.weight(.semibold))

                Text(isMeasuring ? "Pause" : "Start")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
            }
            .foregroundColor(isMeasuring ? HowLoudColors.onErrorContainer : HowLoudColors.onPrimary)
            .frame(minWidth: 184, minHeight: 56)
            .background(
                Capsule()
                    .fill(isMeasuring ? HowLoudColors.errorContainer : HowLoudColors.primary)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 4, x: 0, y: 2)
        }
        .accessibilityIdentifier("toggleButton")
        .animation(.easeInOut(duration: 0.18), value: isMeasuring)
    }
}
