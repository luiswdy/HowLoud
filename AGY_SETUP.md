# Antigravity (`agy`) Setup Guide for HowLoud

This guide describes how to configure **Google Antigravity (`agy`)** with the **Xcode MCP server** and **Apple Xcode skills** after cloning this repository on a Mac.

Local agent tooling directories (`.agents/` and `xcode-skills/`) are intentionally listed in [`.gitignore`](./.gitignore) so machine-specific paths and Apple's bundled Xcode skills stay out of version control.

---

## Prerequisites

* macOS with **Xcode 27+** installed at `/Applications/Xcode.app`
* Active Apple Developer signing identity (for installing to a physical iPhone with HealthKit enabled)
* Antigravity CLI (`agy`) or Antigravity IDE installed

Verify Xcode's command-line tools and MCP bridge exist:

```bash
xcode-select -p
ls -l /Applications/Xcode.app/Contents/Developer/usr/bin/mcpbridge
```

---

## 1. Configure the Xcode MCP Server

### Option A — Global Setup (Recommended, once per Mac)

Add the `xcode` server to `~/.gemini/config/mcp_config.json` so every iOS repository you clone gets Xcode MCP automatically:

```json
{
  "mcpServers": {
    "xcode": {
      "command": "/Applications/Xcode.app/Contents/Developer/usr/bin/mcpbridge",
      "args": [],
      "env": {}
    }
  }
}
```

### Option B — Project-Local Setup (This Repo Only)

Create `.agents/mcp_config.json` at the repository root with the exact same JSON above (already gitignored).

---

## 2. Configure Apple Xcode Skills

If you export or install Apple's Xcode skills (such as `swiftui-specialist`, `swiftui-whats-new-27`, `modernize-tests`, `device-interaction`, `xctrace`, etc.):

* **Global (Recommended):** Place the skill folders under `~/.gemini/config/skills/` so Antigravity discovers them across all your Xcode projects:
  ```bash
  mkdir -p ~/.gemini/config/skills
  cp -R /path/to/xcode-skills/* ~/.gemini/config/skills/
  ```
* **Project-Local:** Place them under `.agents/skills/` (or `xcode-skills/` registered via `.agents/skills.json`), which are kept out of git via `.gitignore`.

---

## 3. Build, Test & Deploy Quick Reference

### Run Unit & UI Tests (iOS Simulator)

```bash
xcodebuild \
  -project HowLoud.xcodeproj \
  -scheme HowLoud \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  test
```

### Build & Install to a Physical iPhone

1. Find your connected device UDID:
   ```bash
   xcrun devicectl list devices
   ```
2. Build with automatic signing & HealthKit provisioning:
   ```bash
   xcodebuild \
     -project HowLoud.xcodeproj \
     -scheme HowLoud \
     -destination 'platform=iOS,id=<DEVICE_UDID>' \
     -allowProvisioningUpdates \
     build
   ```
3. Install and launch on device:
   ```bash
   xcrun devicectl device install app --device <DEVICE_UDID> <PATH_TO_HowLoud.app>
   xcrun devicectl device process launch --device <DEVICE_UDID> com.wdy.HowLoud
   ```

---

## Notes on Capabilities & Permissions

* **Microphone (`NSMicrophoneUsageDescription`)**: Required for real-time `AVAudioEngine` sound pressure level measurement.
* **HealthKit (`HowLoud/HowLoud.entitlements`, `NSHealthShareUsageDescription`)**: Required for `AppleWatchHealthKitCalibrator` to read `environmentalAudioExposure` (`dBASPL`) samples logged by Apple Watch in Apple Health.
