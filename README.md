# TopStats

A lightweight menu-bar system monitor for macOS. Displays CPU, RAM, GPU, and temperature directly in the macOS status area, with a dashboard of gauge cards and top app consumers one click away.

![TopStats Screenshot](screenshot.png)

## Features

- **CPU Usage** - real-time processor utilization with process count
- **Top CPU Apps** - grouped per-app CPU consumers from `ps`
- **RAM** - used/available in GB using Activity Monitor's formula (app memory − purgeable + wired + compressed)
- **Top Memory Apps** - grouped per-app RSS consumers from `ps`
- **GPU** - Apple Silicon total GPU utilization percentage
- **GPU Clients** - active apps with AGX GPU client connections from IOKit
- **Temperature** - CPU temperature through the bundled helper, with thermal-state fallback
- **Gauge cards** - each dashboard card has an animated half-circle needle gauge (0% = left, 100% = right) over a green→yellow→red arc
- **Free Up** - CleanMyMac-style RAM reclaim in the Memory tab: briefly applies incompressible memory pressure so the kernel evicts stale pages, then reports the actual gain in available memory (no admin rights needed)
- **Network** - download/upload in Kbps/Mbps/Gbps, shown in the menu-bar tooltip on hover; the menu-bar text readout is off by default and can be enabled in Settings

## Requirements

- macOS 13.0 (Ventura) or later
- Apple Silicon (M1/M2/M3) recommended

## Installation

### Option 1: Download Release
Download the latest `TopStats.app` from [Releases](../../releases) and move to `/Applications`.

### Option 2: Build from Source
```bash
# Clone the repo
git clone https://github.com/YOUR_USERNAME/TopStats.git
cd TopStats

# Build
./build.sh

# Install
rm -rf /Applications/TopStats.app
cp -R TopStats.app /Applications/
open /Applications/TopStats.app
```

## Usage

1. Launch TopStats from Applications
2. The live stats appear in the macOS menu bar/status area (e.g. `CPU 19%  RAM A 6.0G  GPU 17%  52C`)
3. Click the TopStats menu-bar item for the dashboard: gauge cards, network speed, top consumers, settings, refresh, and quit
4. Settings → Menu Bar toggles which metrics appear in the status area (Network is off by default)

### Auto-start at Login

The app writes and loads a user LaunchAgent at `~/Library/LaunchAgents/com.topstats.app.plist` when "Launch at Login" is enabled in settings. To disable from the terminal:
```bash
launchctl bootout "gui/$(id -u)/com.topstats.app" 2>/dev/null || true
rm -f ~/Library/LaunchAgents/com.topstats.app.plist
```

## Building

```bash
# Compile main app
swiftc -o TopStats TopStats.swift -framework Cocoa -framework SwiftUI -framework IOKit -framework Network

# Compile temperature helper
clang -Wall -framework IOKit -framework Foundation -o TempHelper TempHelper.m

# Create app bundle
./build.sh
```

## How It Works

- **CPU**: Uses `host_processor_info` to get accurate CPU load
- **RAM**: Uses `host_statistics64`; used = (internal − purgeable) + wired + compressed, matching Activity Monitor's "Memory Used"
- **GPU**: Reads total GPU utilization and active AGX GPU clients from IOKit
- **Temperature**: Uses the bundled `TempHelper` process to read the calibrated `PMU tcal` sensor on Apple Silicon
- **Network**: Uses `getifaddrs` for interface byte counters, converted to bits per second for display

## License

MIT License - feel free to use, modify, and distribute.

## Contributing

Pull requests welcome! Please open an issue first to discuss changes.
