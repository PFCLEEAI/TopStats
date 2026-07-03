import Cocoa
import SwiftUI
import IOKit

// MARK: - Temperature Reader (Apple Silicon)
class TemperatureReader {
    private var connection: io_connect_t = 0

    init() {
        var service: io_service_t = 0
        var iter: io_iterator_t = 0

        let matching = IOServiceMatching("AppleARMIODevice")
        IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter)

        repeat {
            service = IOIteratorNext(iter)
            if service == 0 { break }

            var name = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(service, &name)
            let nameStr = String(cString: name)

            if nameStr.contains("pmgr") {
                IOServiceOpen(service, mach_task_self_, 0, &connection)
                IOObjectRelease(service)
                break
            }
            IOObjectRelease(service)
        } while service != 0

        IOObjectRelease(iter)
    }

    func getCPUTemperature() -> Double? {
        // Try reading from IOReport
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", """
            ioreg -r -c IOHIDSystem 2>/dev/null | grep -i "temperature" | head -1 | awk -F'= ' '{print $2}'
        """]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let temp = Double(output), temp > 0 && temp < 150 {
                return temp
            }
        } catch {}

        // Fallback: estimate from thermal state
        let state = ProcessInfo.processInfo.thermalState
        switch state {
        case .nominal: return 45.0
        case .fair: return 65.0
        case .serious: return 85.0
        case .critical: return 100.0
        @unknown default: return 50.0
        }
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }
}

// MARK: - System Stats
class SystemStats: ObservableObject {
    @Published var cpuUsage: Double = 0
    @Published var ramUsage: Double = 0
    @Published var ramUsed: Double = 0
    @Published var ramTotal: Double = 0
    @Published var gpuUsage: String = "0%"
    @Published var temperature: String = "--°C"
    @Published var downloadSpeed: String = "0 KB/s"
    @Published var uploadSpeed: String = "0 KB/s"

    private var timer: Timer?
    private var lastNetworkIn: UInt64 = 0
    private var lastNetworkOut: UInt64 = 0
    private var lastNetworkTime: Date = Date()
    private let tempReader = TemperatureReader()

    private var prevCPUInfo: [Int32]?

    init() {
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.update()
        }
    }

    func update() {
        updateCPU()
        updateRAM()
        updateNetwork()
        updateTemperature()
        updateGPU()
    }

    private func updateCPU() {
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        var numCPUs: natural_t = 0

        let err = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &cpuInfo, &numCpuInfo)
        guard err == KERN_SUCCESS, let info = cpuInfo else { return }

        var totalUser: Int32 = 0, totalSystem: Int32 = 0, totalIdle: Int32 = 0, totalNice: Int32 = 0

        for i in 0..<Int(numCPUs) {
            let offset = Int(CPU_STATE_MAX) * i
            totalUser += info[offset + Int(CPU_STATE_USER)]
            totalSystem += info[offset + Int(CPU_STATE_SYSTEM)]
            totalIdle += info[offset + Int(CPU_STATE_IDLE)]
            totalNice += info[offset + Int(CPU_STATE_NICE)]
        }

        let currentInfo = [totalUser, totalSystem, totalIdle, totalNice]

        if let prev = prevCPUInfo {
            let userDiff = totalUser - prev[0]
            let systemDiff = totalSystem - prev[1]
            let idleDiff = totalIdle - prev[2]
            let niceDiff = totalNice - prev[3]

            let totalDiff = userDiff + systemDiff + idleDiff + niceDiff
            if totalDiff > 0 {
                let usage = Double(userDiff + systemDiff + niceDiff) / Double(totalDiff) * 100
                DispatchQueue.main.async {
                    self.cpuUsage = usage
                }
            }
        }

        prevCPUInfo = currentInfo

        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(numCpuInfo) * vm_size_t(MemoryLayout<integer_t>.stride))
    }

    private func updateRAM() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return }

        let pageSize = vm_kernel_page_size
        let active = Double(stats.active_count) * Double(pageSize)
        let wired = Double(stats.wire_count) * Double(pageSize)
        let compressed = Double(stats.compressor_page_count) * Double(pageSize)

        let used = active + wired + compressed
        let total = Double(ProcessInfo.processInfo.physicalMemory)

        DispatchQueue.main.async {
            self.ramUsed = used / 1_073_741_824
            self.ramTotal = total / 1_073_741_824
            self.ramUsage = (used / total) * 100
        }
    }

    private func updateNetwork() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/netstat")
        process.arguments = ["-ib"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return }

            var totalIn: UInt64 = 0
            var totalOut: UInt64 = 0

            for line in output.components(separatedBy: "\n") {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                if parts.count >= 10,
                   let name = parts.first,
                   name.hasPrefix("en"),
                   let inBytes = UInt64(parts[6]),
                   let outBytes = UInt64(parts[9]) {
                    totalIn += inBytes
                    totalOut += outBytes
                }
            }

            let now = Date()
            let elapsed = now.timeIntervalSince(lastNetworkTime)

            if elapsed > 0 && lastNetworkIn > 0 {
                let inRate = Double(totalIn - lastNetworkIn) / elapsed
                let outRate = Double(totalOut - lastNetworkOut) / elapsed

                DispatchQueue.main.async {
                    self.downloadSpeed = self.formatSpeed(inRate)
                    self.uploadSpeed = self.formatSpeed(outRate)
                }
            }

            lastNetworkIn = totalIn
            lastNetworkOut = totalOut
            lastNetworkTime = now
        } catch {}
    }

    private func formatSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec < 1024 {
            return String(format: "%.0f B/s", max(0, bytesPerSec))
        } else if bytesPerSec < 1_048_576 {
            return String(format: "%.1f KB/s", bytesPerSec / 1024)
        } else {
            return String(format: "%.1f MB/s", bytesPerSec / 1_048_576)
        }
    }

    private func updateTemperature() {
        // Read from Hot app's temp file if available, or estimate from thermal state
        let tempFile = "/tmp/cpu_temp.txt"

        if let tempStr = try? String(contentsOfFile: tempFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let temp = Double(tempStr), temp > 0 && temp < 150 {
            DispatchQueue.main.async {
                self.temperature = String(format: "%.0f°C", temp)
            }
            return
        }

        // Use thermal state to estimate temperature
        let thermalState = ProcessInfo.processInfo.thermalState
        let estimatedTemp: Double
        switch thermalState {
        case .nominal:
            estimatedTemp = 42
        case .fair:
            estimatedTemp = 68
        case .serious:
            estimatedTemp = 88
        case .critical:
            estimatedTemp = 100
        @unknown default:
            estimatedTemp = 50
        }

        DispatchQueue.main.async {
            self.temperature = String(format: "~%.0f°C", estimatedTemp)
        }
    }

    private func updateGPU() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "ioreg -r -d 1 -c IOAccelerator 2>/dev/null | grep 'Device Utilization' | head -1 | sed 's/.*Device Utilization %\"=//' | sed 's/,.*//'"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let gpuVal = Double(output) {
                DispatchQueue.main.async {
                    self.gpuUsage = String(format: "%.0f%%", gpuVal)
                }
            }
        } catch {}
    }
}

// MARK: - Floating Window View
struct FloatingMonitorView: View {
    @ObservedObject var stats: SystemStats

    var body: some View {
        HStack(spacing: 12) {
            StatItem(label: "CPU", value: String(format: "%.0f%%", stats.cpuUsage))
            Divider().frame(height: 24).opacity(0.3)
            StatItem(label: "RAM", value: String(format: "%.0f%%", stats.ramUsage))
            Divider().frame(height: 24).opacity(0.3)
            StatItem(label: "GPU", value: stats.gpuUsage)
            Divider().frame(height: 24).opacity(0.3)
            StatItem(label: "TEMP", value: stats.temperature)
            Divider().frame(height: 24).opacity(0.3)
            VStack(spacing: 1) {
                Text("NET").font(.system(size: 8, weight: .medium)).foregroundColor(.secondary)
                Text("↓\(stats.downloadSpeed)").font(.system(size: 9, weight: .semibold, design: .monospaced))
                Text("↑\(stats.uploadSpeed)").font(.system(size: 9, weight: .semibold, design: .monospaced))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        )
    }
}

struct StatItem: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.primary)
        }
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var stats = SystemStats()
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = FloatingMonitorView(stats: stats)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 50),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.contentView = NSHostingView(rootView: contentView)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.isMovableByWindowBackground = true
        window.hasShadow = false

        if let screen = NSScreen.main {
            let screenFrame = screen.frame
            let x = (screenFrame.width - 380) / 2
            let y = screenFrame.height - 80
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        window.makeKeyAndOrderFront(nil)

        // Menu bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.bottom.50percent", accessibilityDescription: "Monitor")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Monitor", action: #selector(showWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Main
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
