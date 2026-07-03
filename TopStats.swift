import Cocoa
import SwiftUI
import IOKit
import Network

// MARK: - Models

enum ConsumerMode: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "Memory"
    case gpu = "GPU"

    var id: String { rawValue }
}

struct ProcessConsumer: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let cpuPercent: Double
    let memoryMB: Double
    let processCount: Int
    let gpuClientCount: Int

    var memoryGB: Double {
        memoryMB / 1024
    }
}

private struct ProcessSnapshot {
    let pid: Int
    let name: String
    let cpuPercent: Double
    let memoryMB: Double
}

private struct ProcessAggregate {
    var name: String
    var cpuPercent: Double = 0
    var memoryMB: Double = 0
    var processCount: Int = 0
    var gpuClientCount: Int = 0
    var pids = Set<Int>()

    var consumer: ProcessConsumer {
        ProcessConsumer(
            name: name,
            cpuPercent: cpuPercent,
            memoryMB: memoryMB,
            processCount: processCount,
            gpuClientCount: gpuClientCount
        )
    }
}

// MARK: - Settings

final class AppSettings: ObservableObject {
    @Published var showCPU: Bool = true
    @Published var showRAM: Bool = true
    @Published var showGPU: Bool = true
    @Published var showTemp: Bool = true
    @Published var showNetwork: Bool = false
    @Published var ramShowFree: Bool = false
    @Published var launchAtLogin: Bool = true

    init() {
        loadSettings()
    }

    func loadSettings() {
        let defaults = UserDefaults.standard
        showCPU = defaults.object(forKey: "showCPU") as? Bool ?? true
        showRAM = defaults.object(forKey: "showRAM") as? Bool ?? true
        showGPU = defaults.object(forKey: "showGPU") as? Bool ?? true
        showTemp = defaults.object(forKey: "showTemp") as? Bool ?? true
        // Network is opt-in: it belongs in the dashboard, not permanently in the menu bar.
        showNetwork = defaults.object(forKey: "showNetwork") as? Bool ?? false
        ramShowFree = defaults.object(forKey: "ramShowFree") as? Bool ?? false
        launchAtLogin = defaults.object(forKey: "launchAtLogin") as? Bool ?? true
    }

    func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(showCPU, forKey: "showCPU")
        defaults.set(showRAM, forKey: "showRAM")
        defaults.set(showGPU, forKey: "showGPU")
        defaults.set(showTemp, forKey: "showTemp")
        defaults.set(showNetwork, forKey: "showNetwork")
        defaults.set(ramShowFree, forKey: "ramShowFree")
        defaults.set(launchAtLogin, forKey: "launchAtLogin")
        LoginItemManager.setEnabled(launchAtLogin)
    }
}

// MARK: - Login Item

enum LoginItemManager {
    private static let label = "com.topstats.app"

    private static var launchAgentsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("LaunchAgents")
    }

    static var plistURL: URL {
        launchAgentsDirectory.appendingPathComponent("\(label).plist")
    }

    static func isEnabled() -> Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool) {
        if enabled {
            installLaunchAgent()
            bootstrapLaunchAgentIfNeeded()
        } else {
            bootoutLaunchAgent()
            try? FileManager.default.removeItem(at: plistURL)
        }
    }

    private static func installLaunchAgent() {
        do {
            try FileManager.default.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
            let appPath = preferredAppPath().replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(label)</string>
                <key>ProgramArguments</key>
                <array>
                    <string>/usr/bin/open</string>
                    <string>-g</string>
                    <string>\(appPath)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>ProcessType</key>
                <string>Interactive</string>
            </dict>
            </plist>
            """
            try plist.write(to: plistURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("TopStats failed to install LaunchAgent: \(error)")
        }
    }

    private static func preferredAppPath() -> String {
        let installedPath = "/Applications/TopStats.app"
        if FileManager.default.fileExists(atPath: installedPath) {
            return installedPath
        }
        return Bundle.main.bundlePath
    }

    private static func bootstrapLaunchAgentIfNeeded() {
        guard launchctl(["print", "gui/\(getuid())/\(label)"]) != 0 else { return }
        _ = launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    private static func bootoutLaunchAgent() {
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        _ = launchctl(["bootout", "gui/\(getuid())", plistURL.path])
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}

// MARK: - System Stats

final class SystemStats: ObservableObject {
    static let refreshInterval: TimeInterval = 5.0

    @Published var cpuUsage: Double = 0
    @Published var ramFree: Double = 0
    @Published var ramUsed: Double = 0
    @Published var ramTotal: Double = 0
    @Published var gpuUsage: Double = 0
    @Published var temperature: String = "--C"
    @Published var temperatureValue: Double = 0
    @Published var downloadSpeed: Double = 0
    @Published var uploadSpeed: Double = 0
    @Published var topCPUConsumers: [ProcessConsumer] = []
    @Published var topMemoryConsumers: [ProcessConsumer] = []
    @Published var gpuClientConsumers: [ProcessConsumer] = []
    @Published var gpuClientCount: Int = 0
    @Published var processCount: Int = 0
    @Published var lastUpdated: Date = Date()
    @Published var isFreeingMemory = false
    @Published var lastFreeUpResult: String?

    private let workQueue = DispatchQueue(label: "TopStats.Sampler", qos: .utility)
    private let cleanerQueue = DispatchQueue(label: "TopStats.MemoryCleaner", qos: .userInitiated)
    private var timer: Timer?
    private var prevCPUInfo: [Int32]?
    private var prevNetworkIn: UInt64 = 0
    private var prevNetworkOut: UInt64 = 0
    private var prevNetworkTime: Date = Date()
    private var lastProcessSample = Date.distantPast
    private var lastGPUSample = Date.distantPast
    private var lastGPUClientSample = Date.distantPast
    private var latestProcessesByPID: [Int: ProcessSnapshot] = [:]

    init() {
        let (inBytes, outBytes) = getNetworkBytes()
        prevNetworkIn = inBytes
        prevNetworkOut = outBytes
        prevNetworkTime = Date()

        refreshAll()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        timer?.invalidate()
    }

    func refreshAll() {
        sample(forceHeavy: true)
    }

    func refresh() {
        sample(forceHeavy: false)
    }

    private func sample(forceHeavy: Bool) {
        workQueue.async {
            self.updateCPU()
            self.updateRAM()
            self.updateTemperature()
            self.updateNetwork()

            let now = Date()
            if forceHeavy || now.timeIntervalSince(self.lastGPUSample) >= Self.refreshInterval {
                self.updateGPU()
                self.lastGPUSample = now
            }

            if forceHeavy || now.timeIntervalSince(self.lastProcessSample) >= 10 {
                self.updateProcessConsumers()
                self.lastProcessSample = now
            }

            if forceHeavy || now.timeIntervalSince(self.lastGPUClientSample) >= 30 {
                self.updateGPUClients()
                self.lastGPUClientSample = now
            }

            DispatchQueue.main.async {
                self.lastUpdated = Date()
            }
        }
    }

    private func updateCPU() {
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0
        var numCPUs: natural_t = 0

        let err = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &cpuInfo, &numCPUInfo)
        guard err == KERN_SUCCESS, let info = cpuInfo else { return }

        var totalUser: Int32 = 0
        var totalSystem: Int32 = 0
        var totalIdle: Int32 = 0
        var totalNice: Int32 = 0

        for index in 0..<Int(numCPUs) {
            let offset = Int(CPU_STATE_MAX) * index
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
        vm_deallocate(
            mach_task_self_,
            vm_address_t(bitPattern: info),
            vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
        )
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

        // Activity Monitor's "Memory Used" = app memory (internal - purgeable) + wired + compressed.
        // Using active pages instead counts reclaimable file cache as used and inactive app pages as free.
        let pageSize = Double(vm_kernel_page_size)
        let appMemory = max(0, Double(stats.internal_page_count) - Double(stats.purgeable_count)) * pageSize
        let wired = Double(stats.wire_count) * pageSize
        let compressed = Double(stats.compressor_page_count) * pageSize
        let used = appMemory + wired + compressed
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        let free = max(0, total - used)

        DispatchQueue.main.async {
            self.ramUsed = used / 1_073_741_824
            self.ramFree = free / 1_073_741_824
            self.ramTotal = total / 1_073_741_824
        }
    }

    private struct MemorySnapshot {
        let freeBytes: Double
        let availableBytes: Double
    }

    private func memorySnapshot() -> MemorySnapshot? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return nil }

        let pageSize = Double(vm_kernel_page_size)
        let appMemory = max(0, Double(stats.internal_page_count) - Double(stats.purgeable_count)) * pageSize
        let used = appMemory + Double(stats.wire_count) * pageSize + Double(stats.compressor_page_count) * pageSize
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        return MemorySnapshot(
            freeBytes: Double(stats.free_count) * pageSize,
            availableBytes: max(0, total - used)
        )
    }

    /// CleanMyMac-style RAM reclaim without privileges: allocate and touch memory until
    /// the kernel is pressured into evicting inactive pages and stale file cache, then
    /// release everything at once. The freed pages come back as available memory.
    func freeUpMemory() {
        guard !isFreeingMemory else { return }
        isFreeingMemory = true
        lastFreeUpResult = nil

        cleanerQueue.async {
            let before = self.memorySnapshot()

            let chunkBytes = 256 * 1024 * 1024
            let availableFloor = 2.0 * 1_073_741_824
            let emergencyFreeFloor = 96.0 * 1024 * 1024
            let hardCap = ProcessInfo.processInfo.physicalMemory / 2
            let deadline = Date().addingTimeInterval(15)
            var chunks: [UnsafeMutableRawPointer] = []
            var allocated: UInt64 = 0

            // The compressor squeezes uniform pages to nothing, so only
            // incompressible (random) content produces real memory pressure.
            guard let template = malloc(chunkBytes) else {
                DispatchQueue.main.async { self.isFreeingMemory = false }
                return
            }
            arc4random_buf(template, chunkBytes)

            var stallRetries = 0
            while allocated < hardCap, Date() < deadline {
                guard let snapshot = self.memorySnapshot(), snapshot.availableBytes > availableFloor else { break }
                if snapshot.freeBytes < emergencyFreeFloor {
                    // Free pages dip transiently while the kernel reclaims; wait it out.
                    stallRetries += 1
                    if stallRetries > 30 { break }
                    Thread.sleep(forTimeInterval: 0.1)
                    continue
                }
                stallRetries = 0
                guard let chunk = malloc(chunkBytes) else { break }
                memcpy(chunk, template, chunkBytes)
                chunks.append(chunk)
                allocated += UInt64(chunkBytes)
            }

            free(template)
            Thread.sleep(forTimeInterval: 0.5)
            chunks.forEach { free($0) }
            chunks.removeAll()
            Thread.sleep(forTimeInterval: 2.0)

            var message = "nothing to reclaim"
            if let before, let after = self.memorySnapshot() {
                let freedGB = (after.availableBytes - before.availableBytes) / 1_073_741_824
                if freedGB >= 0.1 {
                    message = String(format: "freed %.1f GB", freedGB)
                }
            }

            self.sample(forceHeavy: false)
            DispatchQueue.main.async {
                self.isFreeingMemory = false
                self.lastFreeUpResult = message
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                if self.lastFreeUpResult == message {
                    self.lastFreeUpResult = nil
                }
            }
        }
    }

    private func updateGPU() {
        guard let output = runCommand("/usr/sbin/ioreg", ["-r", "-d", "1", "-c", "IOAccelerator", "-w", "0"]) else {
            return
        }

        let gpuValue = output
            .split(separator: "\n")
            .lazy
            .compactMap { line -> Double? in
                guard let marker = line.range(of: "\"Device Utilization %\"=") else { return nil }
                let tail = line[marker.upperBound...]
                let digits = tail.prefix { $0.isNumber || $0 == "." }
                return Double(digits)
            }
            .first

        guard let gpuValue else { return }

        DispatchQueue.main.async {
            self.gpuUsage = gpuValue
        }
    }

    private func updateTemperature() {
        let tempFile = "/tmp/cpu_temp.txt"
        if let tempString = try? String(contentsOfFile: tempFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let temp = Double(tempString),
           temp > 0,
           temp < 150 {
            DispatchQueue.main.async {
                self.temperature = String(format: "%.0fC", temp)
                self.temperatureValue = temp
            }
            return
        }

        let estimatedTemp: Double
        switch ProcessInfo.processInfo.thermalState {
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
            self.temperature = String(format: "~%.0fC", estimatedTemp)
            self.temperatureValue = estimatedTemp
        }
    }

    private func getNetworkBytes() -> (UInt64, UInt64) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return (0, 0)
        }
        defer { freeifaddrs(ifaddr) }

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        var ptr = firstAddr

        while true {
            let name = String(cString: ptr.pointee.ifa_name)
            if name.hasPrefix("en"), let data = ptr.pointee.ifa_data {
                let networkData = data.assumingMemoryBound(to: if_data.self).pointee
                totalIn += UInt64(networkData.ifi_ibytes)
                totalOut += UInt64(networkData.ifi_obytes)
            }

            guard let next = ptr.pointee.ifa_next else { break }
            ptr = next
        }

        return (totalIn, totalOut)
    }

    private func updateNetwork() {
        let (currentIn, currentOut) = getNetworkBytes()
        let now = Date()
        let elapsed = now.timeIntervalSince(prevNetworkTime)

        if elapsed > 0, prevNetworkIn > 0, currentIn >= prevNetworkIn, currentOut >= prevNetworkOut {
            let inRate = Double(currentIn - prevNetworkIn) / elapsed
            let outRate = Double(currentOut - prevNetworkOut) / elapsed
            DispatchQueue.main.async {
                self.downloadSpeed = inRate
                self.uploadSpeed = outRate
            }
        }

        prevNetworkIn = currentIn
        prevNetworkOut = currentOut
        prevNetworkTime = now
    }

    private func updateProcessConsumers() {
        guard let output = runCommand("/bin/ps", ["-axo", "pid=,pcpu=,rss=,command="]) else { return }

        var byPID: [Int: ProcessSnapshot] = [:]
        var aggregates: [String: ProcessAggregate] = [:]

        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4,
                  let pid = Int(parts[0]),
                  let cpu = Double(parts[1]),
                  let rssKB = Double(parts[2]) else {
                continue
            }

            let command = String(parts[3])
            let name = normalizeProcessName(command)
            let memoryMB = rssKB / 1024
            let snapshot = ProcessSnapshot(pid: pid, name: name, cpuPercent: cpu, memoryMB: memoryMB)
            byPID[pid] = snapshot

            var aggregate = aggregates[name] ?? ProcessAggregate(name: name)
            aggregate.cpuPercent += cpu
            aggregate.memoryMB += memoryMB
            aggregate.processCount += 1
            aggregate.pids.insert(pid)
            aggregates[name] = aggregate
        }

        latestProcessesByPID = byPID
        let consumers = aggregates.values.map(\.consumer)
        let cpu = consumers.sorted { $0.cpuPercent == $1.cpuPercent ? $0.memoryMB > $1.memoryMB : $0.cpuPercent > $1.cpuPercent }
            .prefix(8)
        let memory = consumers.sorted { $0.memoryMB == $1.memoryMB ? $0.cpuPercent > $1.cpuPercent : $0.memoryMB > $1.memoryMB }
            .prefix(8)

        DispatchQueue.main.async {
            self.processCount = byPID.count
            self.topCPUConsumers = Array(cpu)
            self.topMemoryConsumers = Array(memory)
        }
    }

    private func updateGPUClients() {
        guard let output = runCommand("/usr/sbin/ioreg", ["-r", "-c", "AGXDeviceUserClient", "-w", "0", "-l"]) else {
            return
        }

        var aggregates: [String: ProcessAggregate] = [:]
        var totalClients = 0

        for line in output.split(separator: "\n") where line.contains("IOUserClientCreator") {
            guard let match = parseGPUClientLine(String(line)) else { continue }
            totalClients += 1

            let process = latestProcessesByPID[match.pid]
            let name = process?.name ?? cleanDisplayName(match.name)
            var aggregate = aggregates[name] ?? ProcessAggregate(name: name)
            aggregate.gpuClientCount += 1
            aggregate.pids.insert(match.pid)
            aggregates[name] = aggregate
        }

        for (name, aggregate) in aggregates {
            var updated = aggregate
            for pid in aggregate.pids {
                if let process = latestProcessesByPID[pid] {
                    updated.cpuPercent += process.cpuPercent
                    updated.memoryMB += process.memoryMB
                    updated.processCount += 1
                }
            }
            aggregates[name] = updated
        }

        let consumers = aggregates.values.map(\.consumer)
            .sorted {
                if $0.gpuClientCount == $1.gpuClientCount {
                    return $0.memoryMB > $1.memoryMB
                }
                return $0.gpuClientCount > $1.gpuClientCount
            }
            .prefix(8)

        DispatchQueue.main.async {
            self.gpuClientCount = totalClients
            self.gpuClientConsumers = Array(consumers)
        }
    }

    private func parseGPUClientLine(_ line: String) -> (pid: Int, name: String)? {
        guard let pidRange = line.range(of: #"pid [0-9]+"#, options: .regularExpression) else {
            return nil
        }
        let pidText = line[pidRange].replacingOccurrences(of: "pid ", with: "")
        guard let pid = Int(pidText) else { return nil }

        let name: String
        if let comma = line[pidRange.upperBound...].firstIndex(of: ",") {
            let afterComma = line[line.index(after: comma)...]
            name = afterComma.replacingOccurrences(of: "\"", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            name = "PID \(pid)"
        }

        return (pid, name)
    }

    private func normalizeProcessName(_ command: String) -> String {
        if let appName = firstRegexCapture(in: command, pattern: #"/([^/]+)\.app/"#) {
            return cleanDisplayName(appName)
        }

        let executable = command.split(separator: " ").first.map(String.init) ?? command
        let last = URL(fileURLWithPath: executable).lastPathComponent
        return cleanDisplayName(last.isEmpty ? executable : last)
    }

    private func cleanDisplayName(_ name: String) -> String {
        var cleaned = name
            .replacingOccurrences(of: ".app", with: "")
            .replacingOccurrences(of: " Helper (Renderer)", with: "")
            .replacingOccurrences(of: " Helper (GPU)", with: "")
            .replacingOccurrences(of: " Helper", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let aliases: [(String, String)] = [
            ("Microsoft Edge H", "Microsoft Edge"),
            ("Google Chrome He", "Google Chrome"),
            ("ChatGPTHelper", "ChatGPT"),
            ("WindowServer", "WindowServer"),
            ("ControlCenter", "Control Center"),
            ("NotificationCent", "Notification Center")
        ]
        for (prefix, replacement) in aliases where cleaned.hasPrefix(prefix) {
            cleaned = replacement
        }
        return cleaned.isEmpty ? "Unknown" : cleaned
    }

    private func firstRegexCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else {
            return nil
        }
        guard let captureRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captureRange])
    }

    private func runCommand(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

// MARK: - Formatting

/// Network speeds display in bits per second (Kbps/Mbps/Gbps) with decimal units,
/// matching how ISPs and speed tests report bandwidth.
func formatBitsPerSecond(_ bytesPerSecond: Double, compact: Bool) -> String {
    let bits = max(0, bytesPerSecond) * 8
    let value: Double
    let unit: String
    if bits < 1_000_000 {
        value = bits / 1000
        unit = "Kbps"
    } else if bits < 1_000_000_000 {
        value = bits / 1_000_000
        unit = "Mbps"
    } else {
        value = bits / 1_000_000_000
        unit = "Gbps"
    }

    let number = (value >= 100 || unit == "Kbps")
        ? String(format: "%.0f", value)
        : String(format: "%.1f", value)

    if compact {
        return number + unit.prefix(1)
    }
    return "\(number) \(unit)"
}

// MARK: - Views

private enum Palette {
    static let ink = Color(red: 0.08, green: 0.03, blue: 0.16)
    static let panel = Color(red: 0.15, green: 0.08, blue: 0.27)
    static let panelStrong = Color(red: 0.20, green: 0.12, blue: 0.36)
    static let border = Color.white.opacity(0.10)
    static let text = Color.white.opacity(0.94)
    static let muted = Color.white.opacity(0.62)
    static let blue = Color(red: 0.34, green: 0.62, blue: 1.00)
    static let cyan = Color(red: 0.29, green: 0.86, blue: 0.92)
    static let yellow = Color(red: 1.00, green: 0.83, blue: 0.27)
    static let green = Color(red: 0.40, green: 0.84, blue: 0.35)
    static let red = Color(red: 1.00, green: 0.33, blue: 0.42)
    static let purple = Color(red: 0.50, green: 0.36, blue: 1.00)
}

struct TopStatsDashboardView: View {
    @ObservedObject var stats: SystemStats
    @ObservedObject var settings: AppSettings
    @State private var selectedMode: ConsumerMode = .memory

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            overviewGrid
            modePicker
            consumerList
            footer
        }
        .padding(16)
        .frame(width: 430, height: 706, alignment: .topLeading)
        .background(Palette.ink)
        .foregroundColor(Palette.text)
    }

    private var header: some View {
        Text("TopStats")
            .font(.system(size: 20, weight: .bold, design: .rounded))
    }

    private var overviewGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            MetricCard(
                icon: "cpu",
                title: "CPU",
                value: String(format: "%.0f%%", stats.cpuUsage),
                caption: "\(stats.processCount) processes",
                accent: usageColor(stats.cpuUsage),
                gaugeValue: stats.cpuUsage / 100
            )
            MetricCard(
                icon: "memorychip",
                title: "Memory",
                value: String(format: "%.1f GB", settings.ramShowFree ? stats.ramFree : stats.ramUsed),
                caption: stats.lastFreeUpResult ?? (settings.ramShowFree ? "available of \(formatGB(stats.ramTotal))" : "used of \(formatGB(stats.ramTotal))"),
                accent: memoryColor,
                gaugeValue: stats.ramTotal > 0 ? stats.ramUsed / stats.ramTotal : 0,
                actionLabel: stats.isFreeingMemory ? "Freeing…" : "Free Up",
                actionBusy: stats.isFreeingMemory,
                action: { stats.freeUpMemory() }
            )
            MetricCard(
                icon: "cube.fill",
                title: "GPU",
                value: String(format: "%.0f%%", stats.gpuUsage),
                caption: "\(stats.gpuClientCount) active clients",
                accent: Palette.purple,
                gaugeValue: stats.gpuUsage / 100
            )
            MetricCard(
                icon: tempIcon,
                title: "Thermal",
                value: stats.temperature,
                caption: thermalCaption,
                accent: temperatureColor,
                gaugeValue: (stats.temperatureValue - 30) / 70
            )
        }
    }

    private var modePicker: some View {
        Picker("", selection: $selectedMode) {
            ForEach(ConsumerMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    private var consumerList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(listTitle)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Spacer()
                Text(listRightLabel)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(Palette.muted)
            }

            ScrollView(.vertical) {
                VStack(spacing: 8) {
                    ForEach(activeConsumers) { consumer in
                        ConsumerRow(
                            consumer: consumer,
                            mode: selectedMode,
                            maxValue: maxRowValue,
                            accent: accentForMode
                        )
                    }
                }
            }
            .frame(height: 240)
        }
        .padding(12)
        .background(cardBackground)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                NotificationCenter.default.post(name: .topStatsOpenSettings, object: nil)
            } label: {
                Label("Settings", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(FooterButtonStyle())

            Button {
                selectedMode = .gpu
            } label: {
                Label("GPU Clients", systemImage: "display")
            }
            .buttonStyle(FooterButtonStyle())

            Spacer()

            Button {
                NotificationCenter.default.post(name: .topStatsQuit, object: nil)
            } label: {
                Image(systemName: "power")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(IconButtonStyle(tint: Palette.red))
            .help("Quit TopStats")
        }
    }

    private var activeConsumers: [ProcessConsumer] {
        switch selectedMode {
        case .cpu:
            return stats.topCPUConsumers
        case .memory:
            return stats.topMemoryConsumers
        case .gpu:
            return stats.gpuClientConsumers
        }
    }

    private var maxRowValue: Double {
        let values = activeConsumers.map { consumer -> Double in
            switch selectedMode {
            case .cpu:
                return consumer.cpuPercent
            case .memory:
                return consumer.memoryMB
            case .gpu:
                return Double(consumer.gpuClientCount)
            }
        }
        return max(values.max() ?? 1, 1)
    }

    private var listTitle: String {
        switch selectedMode {
        case .cpu:
            return "Top CPU Consumers"
        case .memory:
            return "Top Memory Consumers"
        case .gpu:
            return "Active GPU Clients"
        }
    }

    private var listRightLabel: String {
        switch selectedMode {
        case .cpu:
            return "% CPU"
        case .memory:
            return "RSS"
        case .gpu:
            return "CLIENTS"
        }
    }

    private var accentForMode: Color {
        switch selectedMode {
        case .cpu:
            return Palette.cyan
        case .memory:
            return Palette.blue
        case .gpu:
            return Palette.purple
        }
    }

    private var memoryColor: Color {
        guard stats.ramTotal > 0 else { return Palette.blue }
        let usage = stats.ramUsed / stats.ramTotal * 100
        return usageColor(usage)
    }

    private var temperatureColor: Color {
        if stats.temperatureValue >= 85 { return Palette.red }
        if stats.temperatureValue >= 70 { return Palette.yellow }
        return Palette.cyan
    }

    private var tempIcon: String {
        if stats.temperatureValue >= 85 { return "thermometer.high" }
        if stats.temperatureValue >= 65 { return "thermometer.medium" }
        return "thermometer.low"
    }

    private var thermalCaption: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            return "normal"
        case .fair:
            return "warm"
        case .serious:
            return "hot"
        case .critical:
            return "critical"
        @unknown default:
            return "unknown"
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Palette.panel)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Palette.border, lineWidth: 1)
            )
    }

    private func formatGB(_ value: Double) -> String {
        String(format: "%.0f GB", value)
    }

    private func usageColor(_ value: Double) -> Color {
        if value >= 85 { return Palette.red }
        if value >= 60 { return Palette.yellow }
        return Palette.green
    }
}

struct MetricCard: View {
    let icon: String
    let title: String
    let value: String
    let caption: String
    let accent: Color
    let gaugeValue: Double
    var actionLabel: String? = nil
    var actionBusy: Bool = false
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(accent)
                Spacer()
                HalfGaugeView(value: gaugeValue, accent: accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(Palette.muted)
                Text(value)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                HStack(spacing: 6) {
                    Text(caption)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Palette.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    if let actionLabel, let action {
                        Spacer(minLength: 4)
                        Button(action: action) {
                            Text(actionLabel)
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundColor(Palette.text)
                                .padding(.horizontal, 9)
                                .frame(height: 21)
                                .background(Capsule().fill(Color.white.opacity(0.10)))
                                .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(actionBusy)
                        .opacity(actionBusy ? 0.55 : 1)
                    }
                }
            }
        }
        .padding(12)
        .frame(height: 118)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Palette.panelStrong)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Palette.border, lineWidth: 1)
                )
        )
    }
}

/// Half-circle gauge: needle points left at 0, right at 100%.
struct HalfGaugeView: View {
    let value: Double
    let accent: Color

    private let width: CGFloat = 66
    private let lineWidth: CGFloat = 5.5

    private var clamped: Double {
        min(max(value, 0), 1)
    }

    private var needleAngle: Double {
        -90 + clamped * 180
    }

    var body: some View {
        let diameter = width - lineWidth
        let needleLength = diameter / 2 - lineWidth - 1

        ZStack {
            Circle()
                .trim(from: 0.5, to: 1.0)
                .stroke(Color.white.opacity(0.10), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .frame(width: diameter, height: diameter)

            Circle()
                .trim(from: 0.5, to: 0.5 + clamped / 2)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [Palette.green, Palette.yellow, Palette.red]),
                        center: .center,
                        startAngle: .degrees(180),
                        endAngle: .degrees(360)
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .frame(width: diameter, height: diameter)

            ForEach(0..<5) { tick in
                Capsule()
                    .fill(Color.white.opacity(tick == 0 || tick == 4 ? 0.45 : 0.28))
                    .frame(width: 1.5, height: 4)
                    .offset(y: -diameter / 2)
                    .rotationEffect(.degrees(-90 + Double(tick) * 45))
            }

            Capsule()
                .fill(Color.white)
                .frame(width: 2.5, height: needleLength)
                .offset(y: -needleLength / 2)
                .rotationEffect(.degrees(needleAngle))
                .shadow(color: accent.opacity(0.8), radius: 2)

            Circle()
                .fill(accent)
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
        }
        .frame(width: width, height: width)
        .animation(.easeInOut(duration: 0.6), value: clamped)
        .frame(width: width, height: width / 2 + 7, alignment: .top)
        .clipped()
    }
}

struct ConsumerRow: View {
    let consumer: ProcessConsumer
    let mode: ConsumerMode
    let maxValue: Double
    let accent: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(accent)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(consumer.name)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Spacer()
                    Text(primaryMetric)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(accent)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    bar
                    Text(secondaryMetric)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(Palette.muted)
                        .frame(width: 92, alignment: .trailing)
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
    }

    private var bar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(accent)
                    .frame(width: max(5, geometry.size.width * barRatio))
            }
        }
        .frame(height: 5)
    }

    private var barRatio: CGFloat {
        let value: Double
        switch mode {
        case .cpu:
            value = consumer.cpuPercent
        case .memory:
            value = consumer.memoryMB
        case .gpu:
            value = Double(consumer.gpuClientCount)
        }
        return CGFloat(min(max(value / maxValue, 0), 1))
    }

    private var icon: String {
        switch mode {
        case .cpu:
            return "cpu"
        case .memory:
            return "memorychip"
        case .gpu:
            return "display"
        }
    }

    private var primaryMetric: String {
        switch mode {
        case .cpu:
            return String(format: "%.1f%%", consumer.cpuPercent)
        case .memory:
            return String(format: "%.2f GB", consumer.memoryGB)
        case .gpu:
            return "\(consumer.gpuClientCount)"
        }
    }

    private var secondaryMetric: String {
        switch mode {
        case .cpu:
            return String(format: "%.2f GB", consumer.memoryGB)
        case .memory:
            return String(format: "%.1f%% CPU", consumer.cpuPercent)
        case .gpu:
            return String(format: "%.1f%% CPU  %.1fGB", consumer.cpuPercent, consumer.memoryGB)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("TopStats Settings")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .padding(.top, 4)

            GroupBox("Menu Bar") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("CPU", isOn: $settings.showCPU)
                    Toggle("Memory", isOn: $settings.showRAM)
                    Toggle("GPU", isOn: $settings.showGPU)
                    Toggle("Temperature", isOn: $settings.showTemp)
                    Toggle("Network", isOn: $settings.showNetwork)
                }
                .padding(.top, 4)
            }

            GroupBox("Memory") {
                Picker("Display", selection: $settings.ramShowFree) {
                    Text("Used").tag(false)
                    Text("Available").tag(true)
                }
                .pickerStyle(.radioGroup)
                .padding(.top, 4)
            }

            GroupBox("Startup") {
                Toggle("Launch at Login", isOn: $settings.launchAtLogin)
                    .padding(.top, 4)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Save") {
                    settings.saveSettings()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 320, height: 430)
    }
}

struct IconButtonStyle: ButtonStyle {
    var tint: Color = Palette.blue

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(configuration.isPressed ? .white : tint)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(configuration.isPressed ? tint.opacity(0.32) : Color.white.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            )
    }
}

struct FooterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundColor(Palette.text)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(configuration.isPressed ? Palette.blue.opacity(0.25) : Color.white.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            )
    }
}

extension Notification.Name {
    static let topStatsOpenSettings = Notification.Name("TopStatsOpenSettings")
    static let topStatsQuit = Notification.Name("TopStatsQuit")
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var settingsWindow: NSWindow?
    private let stats = SystemStats()
    private let settings = AppSettings()
    private var statusItem: NSStatusItem!
    private var statusRefreshTimer: Timer?
    private var tempHelperProcess: Process?
    private var dashboardHost: NSHostingView<TopStatsDashboardView>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if settings.launchAtLogin {
            LoginItemManager.setEnabled(true)
        }

        cleanupStaleTempHelpers()
        startTempHelper()
        configureStatusItem()
        updateMenuBarTitle()
        observeCommands()

        statusRefreshTimer = Timer.scheduledTimer(withTimeInterval: SystemStats.refreshInterval, repeats: true) { [weak self] _ in
            self?.updateMenuBarTitle()
        }
    }

    private func observeCommands() {
        NotificationCenter.default.addObserver(self, selector: #selector(openSettings), name: .topStatsOpenSettings, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(quitApp), name: .topStatsQuit, object: nil)
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "TopStatsStatusItem"

        if let button = statusItem.button {
            button.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            button.image = nil
            button.imagePosition = .noImage
            button.toolTip = "TopStats"
        }

        statusItem.menu = makeDashboardMenu()
    }

    private func makeDashboardMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let item = NSMenuItem()
        let host = NSHostingView(rootView: TopStatsDashboardView(stats: stats, settings: settings))
        host.frame = NSRect(x: 0, y: 0, width: 430, height: 706)
        item.view = host
        menu.addItem(item)
        dashboardHost = host
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        stats.refreshAll()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let settingsView = SettingsView(settings: settings)
            settingsWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 430),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            settingsWindow?.contentView = NSHostingView(rootView: settingsView)
            settingsWindow?.title = "TopStats Settings"
            settingsWindow?.center()
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        tempHelperProcess?.terminate()
        NSApplication.shared.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusRefreshTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        tempHelperProcess?.terminate()
    }

    private func updateMenuBarTitle() {
        guard let button = statusItem?.button else { return }
        button.title = menuBarTitle()
        button.toolTip = menuBarTooltip()
    }

    private func menuBarTitle() -> String {
        var parts: [String] = []

        if settings.showCPU {
            parts.append(String(format: "CPU %.0f%%", stats.cpuUsage))
        }

        if settings.showRAM {
            let label = settings.ramShowFree ? "RAM A" : "RAM U"
            let value = settings.ramShowFree ? stats.ramFree : stats.ramUsed
            parts.append(String(format: "%@ %.1fG", label, value))
        }

        if settings.showGPU {
            parts.append(String(format: "GPU %.0f%%", stats.gpuUsage))
        }

        if settings.showTemp {
            parts.append(stats.temperature)
        }

        if settings.showNetwork {
            parts.append("D\(formatBitsPerSecond(stats.downloadSpeed, compact: true)) U\(formatBitsPerSecond(stats.uploadSpeed, compact: true))")
        }

        return parts.isEmpty ? "TopStats" : parts.joined(separator: "  ")
    }

    private func menuBarTooltip() -> String {
        [
            "TopStats",
            String(format: "CPU: %.0f%%", stats.cpuUsage),
            String(format: "RAM used estimate: %.1f GB", stats.ramUsed),
            String(format: "RAM available estimate: %.1f GB", stats.ramFree),
            String(format: "GPU: %.0f%%", stats.gpuUsage),
            "GPU clients: \(stats.gpuClientCount)",
            "Temperature: \(stats.temperature)",
            "Download: \(formatBitsPerSecond(stats.downloadSpeed, compact: false))",
            "Upload: \(formatBitsPerSecond(stats.uploadSpeed, compact: false))"
        ].joined(separator: "\n")
    }

    private func cleanupStaleTempHelpers() {
        guard let helperPath = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("TempHelper").path else {
            return
        }
        guard let output = runCommand("/usr/bin/pgrep", ["-f", helperPath]) else { return }
        for line in output.split(separator: "\n") {
            guard let pid = Int32(line.trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
            kill(pid, SIGTERM)
        }
    }

    private func startTempHelper() {
        guard let bundlePath = Bundle.main.executableURL?.deletingLastPathComponent() else { return }
        let helperPath = bundlePath.appendingPathComponent("TempHelper")

        guard FileManager.default.fileExists(atPath: helperPath.path) else {
            NSLog("TempHelper not found at \(helperPath.path)")
            return
        }

        tempHelperProcess = Process()
        tempHelperProcess?.executableURL = helperPath
        tempHelperProcess?.standardOutput = FileHandle.nullDevice
        tempHelperProcess?.standardError = FileHandle.nullDevice

        do {
            try tempHelperProcess?.run()
        } catch {
            NSLog("Failed to start TempHelper: \(error)")
        }
    }

    private func runCommand(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
