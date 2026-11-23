//
//  GaugeView.swift
//  HowLoud
//
//  Created by Luis Wu on 11/23/2026.
//  Copyright © 2026 Luis Wu. All rights reserved.
//

import SwiftUI

struct GaugeView: View {
    let value: Double
    let minValue: Double
    let maxValue: Double
    var unitLabel: String = "dBA"
    var isMeasuring: Bool = false

    // 240° sweep: 150° (bottom-left) clockwise through 270° (top) to 390° (bottom-right)
    private let startAngle: Double = 150.0
    private let sweepAngle: Double = 240.0

    private var normalizedProgress: Double {
        guard maxValue > minValue else { return 0.0 }
        let clamped = min(max(value, minValue), maxValue)
        return (clamped - minValue) / (maxValue - minValue)
    }

    private var needleRotationAngle: Angle {
        let currentDeg = startAngle + sweepAngle * normalizedProgress
        return Angle(degrees: currentDeg - 270.0)
    }

    private var levelZone: SoundLevelZone {
        SoundLevelZone.forDecibels(value)
    }

    private var activeArcColor: Color {
        isMeasuring ? levelZone.accentColor : HowLoudColors.primary
    }

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let radius = (size / 2) * 0.80
            let trackWidth = max(14, size * 0.056)
            let hubDiameter = max(14, size * 0.055)
            let needleLength = radius * 0.78
            let needleBaseWidth = max(5, size * 0.022)

            ZStack {
                // Flat Inactive Track Arc
                ArcShape(
                    startAngle: Angle(degrees: startAngle),
                    endAngle: Angle(degrees: startAngle + sweepAngle)
                )
                .stroke(
                    HowLoudColors.surfaceContainerHigh,
                    style: StrokeStyle(lineWidth: trackWidth, lineCap: .round)
                )
                .frame(width: radius * 2, height: radius * 2)
                .position(center)

                // Flat Single-Color Active Progress Arc
                if normalizedProgress > 0.002 {
                    ArcShape(
                        startAngle: Angle(degrees: startAngle),
                        endAngle: Angle(degrees: startAngle + (sweepAngle * normalizedProgress))
                    )
                    .stroke(
                        activeArcColor,
                        style: StrokeStyle(lineWidth: trackWidth, lineCap: .round)
                    )
                    .frame(width: radius * 2, height: radius * 2)
                    .position(center)
                    .animation(.easeOut(duration: 0.14), value: normalizedProgress)
                    .animation(.easeInOut(duration: 0.2), value: levelZone)
                }

                // Minimal Flat Tick Marks & Clean Scale Labels (0, 40, 80, 120, 160)
                ForEach(0...16, id: \.self) { i in
                    let stepFraction = Double(i) / 16.0
                    let angleDeg = startAngle + sweepAngle * stepFraction
                    let isMajor = i % 2 == 0
                    let showLabel = i % 4 == 0
                    let tickLen = isMajor ? size * 0.038 : size * 0.020
                    let tickRadius = radius - trackWidth / 2 - 8

                    TickMark(
                        angle: Angle(degrees: angleDeg),
                        center: center,
                        radius: tickRadius,
                        length: tickLen,
                        width: isMajor ? 2.0 : 1.2,
                        color: isMajor ? HowLoudColors.onSurfaceVariant.opacity(0.75) : HowLoudColors.outlineVariant
                    )

                    if showLabel {
                        let labelRadius = tickRadius - tickLen - (size * 0.068)
                        let labelVal = Int(minValue + (maxValue - minValue) * stepFraction)
                        TickLabel(
                            text: "\(labelVal)",
                            angle: Angle(degrees: angleDeg),
                            center: center,
                            radius: labelRadius,
                            fontSize: size * 0.038
                        )
                    }
                }

                // Flat 2D Tapered Needle (zero shadow, zero gradient)
                FlatNeedlePointer()
                    .fill(HowLoudColors.onSurface)
                    .frame(width: needleBaseWidth, height: needleLength)
                    .rotationEffect(needleRotationAngle, anchor: .bottom)
                    .position(x: center.x, y: center.y - needleLength / 2)
                    .animation(.easeOut(duration: 0.14), value: needleRotationAngle)

                // Flat Solid Circular Pivot Dot
                ZStack {
                    Circle()
                        .fill(HowLoudColors.onSurface)
                        .frame(width: hubDiameter, height: hubDiameter)

                    Circle()
                        .fill(HowLoudColors.background)
                        .frame(width: hubDiameter * 0.42, height: hubDiameter * 0.42)
                }
                .position(center)

                // Hero Tabular Readout & Semantic Status Pill
                VStack(spacing: 4) {
                    Text(String(format: "%.1f", value))
                        .font(.system(size: size * 0.16, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(HowLoudColors.onSurface)
                        .contentTransition(.numericText())

                    HStack(spacing: 6) {
                        Text(unitLabel)
                            .font(.system(size: size * 0.044, weight: .semibold, design: .rounded))
                            .foregroundColor(HowLoudColors.onSurfaceVariant)

                        if isMeasuring {
                            Text(levelZone.label)
                                .font(.system(size: size * 0.036, weight: .semibold))
                                .foregroundColor(levelZone.accentColor)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(levelZone.containerColor)
                                )
                        }
                    }
                }
                .position(x: center.x, y: center.y + size * 0.24)
            }
        }
    }
}

// MARK: - Flat Vector Shapes & Subviews

private struct ArcShape: Shape {
    let startAngle: Angle
    let endAngle: Angle

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        path.addArc(
            center: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: false
        )
        return path
    }
}

private struct TickMark: View {
    let angle: Angle
    let center: CGPoint
    let radius: CGFloat
    let length: CGFloat
    let width: CGFloat
    let color: Color

    var body: some View {
        let radians = CGFloat(angle.radians)
        let outerX = center.x + radius * cos(radians)
        let outerY = center.y + radius * sin(radians)
        let innerX = center.x + (radius - length) * cos(radians)
        let innerY = center.y + (radius - length) * sin(radians)

        Path { path in
            path.move(to: CGPoint(x: outerX, y: outerY))
            path.addLine(to: CGPoint(x: innerX, y: innerY))
        }
        .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
    }
}

private struct TickLabel: View {
    let text: String
    let angle: Angle
    let center: CGPoint
    let radius: CGFloat
    let fontSize: CGFloat

    var body: some View {
        let radians = CGFloat(angle.radians)
        let x = center.x + radius * cos(radians)
        let y = center.y + radius * sin(radians)

        Text(text)
            .font(.system(size: fontSize, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundColor(HowLoudColors.onSurfaceVariant)
            .position(x: x, y: y)
    }
}

private struct FlatNeedlePointer: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tipRadius = rect.width * 0.22
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX - tipRadius, y: rect.minY + tipRadius))
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.minY + tipRadius),
            radius: tipRadius,
            startAngle: .degrees(180),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
