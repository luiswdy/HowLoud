# HowLoud

A native iOS decibel meter built with **SwiftUI**, **AVAudioEngine**, **Accelerate (`vDSP`)**, and **HealthKit**. HowLoud provides IEC 61672-1 frequency- and time-weighted sound pressure level (SPL) measurement, real-time clipping detection, and extensible microphone calibration—including automatic Apple Watch HealthKit syncing—with zero third-party dependencies.

---

## Features

### Real-Time Acoustic DSP (`SoundLevelEngine`)
* **IEC 61672-1 Frequency Weighting**: Double-precision cascaded biquad filters (`vDSP_biquadD`), gain-normalized to 0 dB at 1 kHz at the device's native sample rate:
  * **dBA** — A-weighting matching human hearing sensitivity and the Apple Watch Noise app.
  * **dBC** — C-weighting suited for high-SPL and bass-heavy environments.
  * **dBZ** — Flat/unweighted response with a 10 Hz DC-blocking high-pass filter.
* **Exponential Time Weighting**:
  * **Fast** (`125 ms` time constant) for fluctuating everyday noise.
  * **Slow** (`1000 ms` time constant) for smoother readings in steady ambient sound.
* **Acoustic Metrics & Clipping Indicator**: Tracks time-weighted **Average (RMS)**, instantaneous **Peak**, session energy-equivalent continuous level (**Leq**), and flags ADC full-scale overload with a **CLIP** badge (`|sample| >= 0.999`).
* **Repeatable Microphone Selection**: Configures `AVAudioSession` in `.record` / `.measurement` mode, automatically prefers the built-in bottom omnidirectional microphone when no external USB/headset mic is attached, and recovers seamlessly from audio route changes and interruptions.

### Extensible Microphone Calibration
* **Auto-Sync from Apple Watch (HealthKit)**: Queries `HKQuantityTypeIdentifier.environmentalAudioExposure` (`dBASPL`) readings logged by a paired Apple Watch in Apple Health, matches overlapping or recent samples via duration-weighted energy averaging, and calculates the iPhone microphone offset automatically.
* **Manual Reference Match**: Captures a 3-second energy-averaged ambient sample and computes the offset against a side-by-side reference reading (such as the Apple Watch Noise app or a dedicated SPL meter).
* **Direct Offset Adjustment**: Fine-tune calibration manually with a slider and `±0.5 dB` controls plus a live preview.
* **Per-Route Persistence & Extensibility**: Built around the `DecibelCalibrator` and `CalibrationStore` protocols (including a built-in `MultiPointLinearCalibrator` for multi-level slope + offset fitting) with profiles persisted per audio input route UID in `UserDefaults`.

### Clean, Adaptive UI
* **Material 3-Inspired Flat Design** with automatic **Light and Dark Mode** color tokens.
* **240° Animated Gauge (`0–160 dB`)** with tabular numeric readouts and semantic acoustic level zones:
  * **Quiet**: `< 70 dB`
  * **Moderate**: `70–85 dB`
  * **Loud**: `≥ 85 dB`
* **Localization**: Includes English (`en`) and Traditional Chinese (`zh-Hant`) localization resources.

---

## Requirements

* **iOS 16.0+**
* **Xcode** with Swift 5+
* **Physical iPhone** recommended for live microphone measurement and Apple Watch HealthKit calibration (with an Apple Developer signing identity configured for the HealthKit capability).

---

## Getting Started

HowLoud has **no external package dependencies**—just clone and open the Xcode project.

```bash
git clone https://github.com/luiswdy/HowLoud.git
cd HowLoud
open HowLoud.xcodeproj
```

1. Select the **HowLoud** scheme in Xcode.
2. Under **Signing & Capabilities**, select your development team if deploying to a physical device (required for the HealthKit entitlement in `HowLoud/HowLoud.entitlements`).
3. Build and run (`⌘R`).

> **Using Google Antigravity (`agy`) with Xcode MCP?** See [`AGY_SETUP.md`](./AGY_SETUP.md) for MCP server, Apple Xcode skills, and CLI deployment instructions.

---

## Running Tests

Unit tests cover the IEC 61672-1 A/C/Z weighting filter curves at 48 kHz and 44.1 kHz, exponential Fast/Slow time weighting, clipping detection, manual and multi-point linear calibrators, and HealthKit sample matching. UI tests verify app launch and calibration sheet navigation.

Run tests in Xcode (`⌘U`) or from the command line:

```bash
xcodebuild \
  -project HowLoud.xcodeproj \
  -scheme HowLoud \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  test
```

*(Adjust the simulator name to match an available simulator on your Mac via `xcrun simctl list devices`.)*

---

## Project Structure

```text
HowLoud/
├── HowLoud/
│   ├── HowLoudApp.swift                     # SwiftUI app entry point
│   ├── ContentView.swift                    # Main meter screen, weighting bar, metric cards, and FAB control
│   ├── GaugeView.swift                      # Custom 240° flat vector decibel gauge
│   ├── HowLoudTheme.swift                   # Adaptive Material 3 color tokens, spacing, and sound level zones
│   ├── DecibelMeterViewModel.swift          # ObservableObject bridging DSP engine, calibration, and permissions
│   ├── SoundLevelEngine.swift               # AVAudioEngine capture + vDSP IEC 61672-1 weighting & RMS/Peak/Leq DSP
│   ├── DecibelCalibration.swift             # CalibrationProfile, protocols, UserDefaults store, manual & linear calibrators
│   ├── AppleWatchHealthKitCalibrator.swift  # HealthKit environmentalAudioExposure reader & sample matcher
│   ├── CalibrationView.swift                # Calibration sheet UI (HealthKit sync, reference match, direct offset)
│   ├── HowLoud.entitlements                 # HealthKit entitlement
│   ├── Info.plist                           # Microphone & HealthKit usage descriptions
│   └── {Base,en,zh-Hant}.lproj/             # Localization strings
├── HowLoudTests/
│   └── HowLoudTests.swift                   # DSP, calibration, and ViewModel unit tests
└── HowLoudUITests/
    └── HowLoudUITests.swift                 # Launch and calibration UI tests
```

---

## Permissions & Calibration Tips

* **Microphone (`NSMicrophoneUsageDescription`)**: Required to sample ambient audio via `AVAudioEngine`.
* **Apple Health (`NSHealthShareUsageDescription`)**: Optional; only requested when using **Auto-Sync from Apple Watch (HealthKit)** to read `environmentalAudioExposure` samples.
* **For best calibration accuracy**:
  * Use **dBA** weighting when comparing against the Apple Watch Noise app.
  * Hold your iPhone in free air—resting it on a desk or table can add `+3` to `+6 dB` due to boundary reflections.
  * Thick or waterproof phone cases can attenuate high-frequency sensitivity; recalibrate if you change cases.

---

## License

HowLoud is released under the [MIT License](./LICENSE).
