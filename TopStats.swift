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

// MARK: - Coding Agents Model
//
// `CodingAgentProcess` is intentionally a NEW, independent model — NOT an
// extension of `ProcessConsumer`/`ConsumerRow` above. Those aggregate top
// consumers by process NAME across every PID sharing that name and carry no
// PID, kill, or working-directory field; none of that can be retrofitted
// onto them without breaking every other row type (Top CPU/Memory/GPU-client
// lists) that already depends on `ProcessConsumer`'s per-name-aggregate
// shape. The existing "Top CPU Consumers" list keeps aggregating by name
// across PIDs exactly as it does today — this type never touches it.
struct CodingAgentProcess: Identifiable, Hashable {
    let pid: Int32
    let binaryName: String
    let cpuPercent: Double
    let rssMB: Double
    let etimeSeconds: Int
    let cwd: CwdResolution
    /// v1 heuristic computed once per snapshot (see
    /// `SystemStats.updateCodingAgentsOnQueue`): no controlling tty +
    /// near-zero CPU + running over an hour. Detects orphaned/no-tty
    /// processes ONLY — not a hung sub-agent still parented to a live
    /// session. This field is added beyond the contract's literal struct
    /// listing because Sprint 4's zombie badge and this sprint's own live
    /// false-positive audit both need it attached per-process rather than
    /// recomputed ad hoc by callers.
    let isZombie: Bool

    var id: Int32 { pid }
}

/// Honest working-directory resolution for a `CodingAgentProcess`. Never
/// fabricated: a failed/timed-out/denied lookup must read as unknown/denied
/// in the UI, never as a blank or guessed path.
enum CwdResolution: Hashable {
    case resolved(String)
    case unknown
    case permissionDenied
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
    // Notched built-in displays only expose ~770pt of menu bar space to the right
    // of the camera housing, shared with every system + third-party icon. Compact
    // mode drops labels/padding so TopStats needs far less of that budget and is
    // less likely to be the item macOS drops when the bar is crowded.
    @Published var compactMenuBar: Bool = true

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
        compactMenuBar = defaults.object(forKey: "compactMenuBar") as? Bool ?? true
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
        defaults.set(compactMenuBar, forKey: "compactMenuBar")
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
    @Published var codingAgentProcesses: [CodingAgentProcess] = []
    /// Sprint 2 — scoped-kill-action. Per-PID transient outcome message,
    /// mirroring `lastFreeUpResult`'s ~12 s auto-clear (see `publishKillResult`).
    /// Keyed by PID so each Coding Agents row surfaces only its own result.
    @Published var lastKillResult: [Int32: String] = [:]

    /// Invoked on the main queue after every sample tick; the menu-bar title
    /// refresh piggybacks on this instead of running its own 5 s timer.
    var onSample: (() -> Void)?

    private let workQueue = DispatchQueue(label: "TopStats.Sampler", qos: .utility)
    private let cleanerQueue = DispatchQueue(label: "TopStats.MemoryCleaner", qos: .userInitiated)
    /// Sprint 2 — scoped-kill-action runs off both the main queue and the
    /// sampler `workQueue`: its SIGTERM→poll→SIGKILL flow blocks for up to ~5 s
    /// on `Thread.sleep`, which must never stall metric sampling or the UI.
    private let agentActionQueue = DispatchQueue(label: "TopStats.AgentAction", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var prevCPUInfo: [Int32]?
    private var prevNetworkIn: UInt64 = 0
    private var prevNetworkOut: UInt64 = 0
    private var prevNetworkTime: Date = Date()
    private var lastProcessSample = Date.distantPast
    private var lastGPUSample = Date.distantPast
    private var lastGPUClientSample = Date.distantPast
    private var latestProcessesByPID: [Int: ProcessSnapshot] = [:]
    /// Dashboard visibility; read and written only on `workQueue`.
    private var menuIsOpen = false
    /// Cached IOAccelerator service handle; touched only on `workQueue`.
    /// 0 = not yet matched (or dropped after a stale read).
    private var gpuAcceleratorService: io_object_t = 0
    /// Last idle malloc purge; `Date.distantPast` makes the first idle tick
    /// purge immediately (that one reclaims the launch-time churn). On `workQueue`.
    private var lastMallocRelief = Date.distantPast

    /// Coding Agents sub-toggle visibility; read/written only on `workQueue`,
    /// same pattern as `menuIsOpen`. This does NOT add a new timer — it only
    /// adds a second gate on top of the existing 10 s `lastProcessSample`
    /// cadence that already drives `updateProcessConsumers()`.
    private var codingAgentsTabVisible = false
    /// Resolved cwd cache, keyed by "pid:lstart" so a reused PID never
    /// inherits a stale path. Only *successful* lookups are stored here
    /// permanently — timeouts/permission failures are deliberately never
    /// cached so they retry on the next manual refresh / view-open instead
    /// of sticking forever. workQueue-confined.
    private var codingAgentCwdCache: [String: String] = [:]
    /// (pid, lstart) pairs matched on the most recent ps tick, so the
    /// separate/coarser lsof resolve pass knows which PIDs to look up
    /// without re-parsing ps itself. workQueue-confined.
    private var latestCodingAgentKeys: [(pid: Int32, lstart: String)] = []
    /// TopStats's own PID plus its full ancestor chain up to PID 1, computed
    /// once (a running process's ancestry doesn't change) so a self/ancestor
    /// row can never be constructed by the matching step below.
    /// workQueue-confined (first touched from `sampleBody`, always on `workQueue`).
    private lazy var codingAgentSelfExclusionSet: Set<Int32> = computeSelfAndAncestorPIDs()

    private static let appBundleRegex = try? NSRegularExpression(pattern: #"/([^/]+)\.app/"#)
    private static let gpuClientPIDRegex = try? NSRegularExpression(pattern: #"pid [0-9]+"#)
    /// Matching rule (a): top-level CLI agents match ONLY these exact
    /// basenames. background-throttle.sh's PATTERNS list was verified to
    /// also include non-agent iCloud daemons (bird/cloudd) — deliberately
    /// NOT reused here.
    private static let cliAgentBasenames: Set<String> = ["claude", "claude.exe", "codex", "cursor-agent"]
    /// Electron/Sparkle child markers: a CLI-basename match riding inside one
    /// of these is a GUI helper process, not a top-level agent.
    private static let electronChildMarkers = ["Helper (Renderer)", "Helper (GPU)", "Helper (Plugin)", "crashpad_handler", "Squirrel"]
    /// Matching rule (b): MCP/Playwright children match by FULL COMMAND LINE
    /// substring only — this intentionally never matches bare `node` by name.
    private static let mcpCommandMarkers = ["modelcontextprotocol/server", "g-search-mcp", "@upstash/context7-mcp", "chrome-headless-shell"]
    /// Live-verified on this machine (see _pm/work-log.md): denied-owner
    /// `lsof -d cwd` lookups produce NO distinguishing stderr text and exit
    /// 1 — identical to "no such fd/PID". Since the two are indistinguishable
    /// here, this stays hardcoded false and every non-zero lsof exit resolves
    /// to `.unknown` ("folder unknown"), never `.permissionDenied` — the
    /// always-safe fallback copy the contract calls for when the exact
    /// "Permission denied" signature can't be confirmed on this macOS version.
    private static let lsofPermissionDeniedConfirmed = false

    /// `mach_host_self()` returns a send right whose uref count grows on every
    /// call (and can overflow after days of 5 s ticks); fetch it once and reuse.
    private static let machHost: mach_port_t = mach_host_self()

    /// Sprint 2: parses BSD `ps -o lstart=` ("Sat Jul  5 16:36:00 2026") for
    /// the kill-time TOCTOU start-time re-check. POSIX locale + fixed pattern;
    /// double-space day padding is collapsed before parsing (see `parseLstart`).
    private static let lstartFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f
    }()

    init() {
        let (inBytes, outBytes) = getNetworkBytes()
        prevNetworkIn = inBytes
        prevNetworkOut = outBytes
        prevNetworkTime = Date()

        refreshAll()
        // DispatchSourceTimer fires straight on the sampling queue: no main
        // run-loop timer wakeup and no main->work queue hop per tick.
        let source = DispatchSource.makeTimerSource(queue: workQueue)
        source.schedule(
            deadline: .now() + Self.refreshInterval,
            repeating: Self.refreshInterval,
            leeway: .seconds(1) // let the system coalesce wakeups
        )
        source.setEventHandler { [weak self] in
            self?.sampleOnQueue(forceHeavy: false)
        }
        source.resume()
        timer = source
    }

    deinit {
        timer?.cancel()
        if gpuAcceleratorService != 0 {
            IOObjectRelease(gpuAcceleratorService)
        }
    }

    func refreshAll() {
        sample(forceHeavy: true)
    }

    /// Dashboard menu is opening: resume dashboard-only sampling and refresh everything now.
    func dashboardWillOpen() {
        workQueue.async { self.menuIsOpen = true }
        refreshAll()
    }

    /// Dashboard closed: the idle loop only needs what the menu-bar title shows.
    func dashboardDidClose() {
        workQueue.async { self.menuIsOpen = false }
    }

    /// Coding Agents sub-toggle switched on while the dashboard is open
    /// (Sprint 4 wires this to the segmented-control selection). Marks the
    /// section visible so the next 10 s ps ticks include coding-agent
    /// sampling, and immediately resolves cwds for whatever is already
    /// matched — this call is itself the "first-open" cwd-resolution trigger.
    func codingAgentsTabWillAppear() {
        workQueue.async {
            self.codingAgentsTabVisible = true
            self.updateCodingAgentsOnQueue()
            self.resolveCodingAgentCwdsOnQueue()
        }
    }

    /// Coding Agents sub-toggle switched away from, or dashboard closed.
    func codingAgentsTabDidDisappear() {
        workQueue.async { self.codingAgentsTabVisible = false }
    }

    /// Manual refresh action (Sprint 4). Re-samples ps immediately and
    /// re-resolves cwds for anything not already cached.
    func refreshCodingAgents() {
        workQueue.async {
            self.updateCodingAgentsOnQueue()
            self.resolveCodingAgentCwdsOnQueue()
        }
    }

    private func sample(forceHeavy: Bool) {
        workQueue.async {
            self.sampleOnQueue(forceHeavy: forceHeavy)
        }
    }

    /// Must run on `workQueue` (the timer fires here directly).
    /// Explicit autorelease pool: GCD worker threads drain lazily, and the
    /// per-tick Foundation/CF churn (file read, IORegistry dictionary)
    /// otherwise lingers between 5 s ticks.
    private func sampleOnQueue(forceHeavy: Bool) {
        autoreleasepool { sampleBody(forceHeavy: forceHeavy) }
    }

    private func sampleBody(forceHeavy: Bool) {
        let cpu = readCPU()
        let ram = readRAM()
        let temp = readTemperature()
        let net = readNetwork()

        let now = Date()
        var gpu: Double?
        if forceHeavy || now.timeIntervalSince(lastGPUSample) >= Self.refreshInterval {
            gpu = readGPU()
            lastGPUSample = now
        }

        // The process list (ps) and GPU-client scan (ioreg) only feed the
        // dashboard, so at idle (menu closed) they are skipped entirely;
        // the menu-bar title needs none of them.
        if forceHeavy || menuIsOpen {
            if forceHeavy || now.timeIntervalSince(lastProcessSample) >= 10 {
                updateProcessConsumers()
                // Coding Agents ps-based fields ride this SAME 10 s cadence
                // (no new timer); the extra `codingAgentsTabVisible` gate is
                // the only thing deciding whether this actually does work.
                if codingAgentsTabVisible {
                    updateCodingAgentsOnQueue()
                }
                lastProcessSample = now
            }

            if forceHeavy || now.timeIntervalSince(lastGPUClientSample) >= 30 {
                updateGPUClients()
                lastGPUClientSample = now
            }
        }

        // One main-thread hop per tick; assign only values that actually
        // changed so observers are not invalidated by identical data.
        DispatchQueue.main.async {
            var changed = false
            if let cpu, cpu != self.cpuUsage { self.cpuUsage = cpu; changed = true }
            if let ram {
                if ram.used != self.ramUsed { self.ramUsed = ram.used; changed = true }
                if ram.free != self.ramFree { self.ramFree = ram.free; changed = true }
                if ram.total != self.ramTotal { self.ramTotal = ram.total; changed = true }
            }
            if temp.text != self.temperature { self.temperature = temp.text; changed = true }
            if temp.value != self.temperatureValue { self.temperatureValue = temp.value; changed = true }
            if let net {
                if net.down != self.downloadSpeed { self.downloadSpeed = net.down; changed = true }
                if net.up != self.uploadSpeed { self.uploadSpeed = net.up; changed = true }
            }
            if let gpu, gpu != self.gpuUsage { self.gpuUsage = gpu; changed = true }
            if changed { self.lastUpdated = Date() }
            self.onSample?()
        }

        // At idle, hand freed malloc pages back to the OS so the resident
        // footprint tracks what the app actually uses — the launch-time heavy
        // sample (ps parse) and menu churn otherwise linger in malloc bins.
        // Once a minute, not every tick: the relief walks every malloc zone
        // (the nano zone scan is not free) and purged pages re-fault on the
        // next allocation, so per-tick calls trade CPU for no extra RSS win.
        // Skipped while the dashboard is open so interactive use never pays it.
        if !forceHeavy && !menuIsOpen && now.timeIntervalSince(lastMallocRelief) >= 60 {
            malloc_zone_pressure_relief(nil, 0)
            lastMallocRelief = now
        }
    }

    private func readCPU() -> Double? {
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0
        var numCPUs: natural_t = 0

        let err = host_processor_info(Self.machHost, PROCESSOR_CPU_LOAD_INFO, &numCPUs, &cpuInfo, &numCPUInfo)
        guard err == KERN_SUCCESS, let info = cpuInfo else { return nil }

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
        var usage: Double?
        if let prev = prevCPUInfo {
            let userDiff = totalUser - prev[0]
            let systemDiff = totalSystem - prev[1]
            let idleDiff = totalIdle - prev[2]
            let niceDiff = totalNice - prev[3]
            let totalDiff = userDiff + systemDiff + idleDiff + niceDiff
            if totalDiff > 0 {
                usage = Double(userDiff + systemDiff + niceDiff) / Double(totalDiff) * 100
            }
        }

        prevCPUInfo = currentInfo
        vm_deallocate(
            mach_task_self_,
            vm_address_t(bitPattern: info),
            vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
        )
        return usage
    }

    private func readRAM() -> (used: Double, free: Double, total: Double)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(Self.machHost, HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return nil }

        // Activity Monitor's "Memory Used" = app memory (internal - purgeable) + wired + compressed.
        // Using active pages instead counts reclaimable file cache as used and inactive app pages as free.
        let pageSize = Double(vm_kernel_page_size)
        let appMemory = max(0, Double(stats.internal_page_count) - Double(stats.purgeable_count)) * pageSize
        let wired = Double(stats.wire_count) * pageSize
        let compressed = Double(stats.compressor_page_count) * pageSize
        let used = appMemory + wired + compressed
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        let free = max(0, total - used)

        return (used / 1_073_741_824, free / 1_073_741_824, total / 1_073_741_824)
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
                host_statistics64(Self.machHost, HOST_VM_INFO64, $0, &count)
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

    /// Reads GPU utilization straight from the IORegistry (same
    /// "Device Utilization %" the old `ioreg` subprocess reported) so the
    /// idle loop spawns zero processes. The matched service handle is cached;
    /// re-reading one property is microseconds versus a fork/exec every tick.
    private func readGPU() -> Double? {
        if gpuAcceleratorService == 0 {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
                return nil
            }
            defer { IOObjectRelease(iterator) }

            var service = IOIteratorNext(iterator)
            while service != 0 {
                if let usage = Self.deviceUtilization(of: service) {
                    gpuAcceleratorService = service // keep the handle
                    return usage
                }
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            return nil
        }

        if let usage = Self.deviceUtilization(of: gpuAcceleratorService) {
            return usage
        }

        // Stale handle (GPU reset / sleep-wake): drop it and rematch next tick.
        IOObjectRelease(gpuAcceleratorService)
        gpuAcceleratorService = 0
        return nil
    }

    private static func deviceUtilization(of service: io_object_t) -> Double? {
        guard let raw = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let stats = raw as? [String: Any],
              let value = stats["Device Utilization %"] as? NSNumber else {
            return nil
        }
        return value.doubleValue
    }

    private func readTemperature() -> (text: String, value: Double) {
        let tempFile = "/tmp/cpu_temp.txt"
        if let tempString = try? String(contentsOfFile: tempFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let temp = Double(tempString),
           temp > 0,
           temp < 150 {
            return (String(format: "%.0fC", temp), temp)
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

        return (String(format: "~%.0fC", estimatedTemp), estimatedTemp)
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

    private func readNetwork() -> (down: Double, up: Double)? {
        let (currentIn, currentOut) = getNetworkBytes()
        let now = Date()
        let elapsed = now.timeIntervalSince(prevNetworkTime)

        var rates: (down: Double, up: Double)?
        if elapsed > 0, prevNetworkIn > 0, currentIn >= prevNetworkIn, currentOut >= prevNetworkOut {
            rates = (
                Double(currentIn - prevNetworkIn) / elapsed,
                Double(currentOut - prevNetworkOut) / elapsed
            )
        }

        prevNetworkIn = currentIn
        prevNetworkOut = currentOut
        prevNetworkTime = now
        return rates
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

    // MARK: Coding Agents Engine (Sprint 1 — process-enumeration-engine)

    private func computeSelfAndAncestorPIDs() -> Set<Int32> {
        var result: Set<Int32> = [ProcessInfo.processInfo.processIdentifier]
        var current = ProcessInfo.processInfo.processIdentifier
        var hops = 0
        while current > 1, hops < 4096 {
            guard let raw = runCommand("/bin/ps", ["-o", "ppid=", "-p", "\(current)"]) else { break }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let ppid = Int32(trimmed), ppid > 0 else { break }
            result.insert(ppid)
            if ppid == 1 { break }
            current = ppid
            hops += 1
        }
        return result
    }

    /// Runs only while `codingAgentsTabVisible`, and only on the existing
    /// 10 s `lastProcessSample` cadence already gated on `menuIsOpen` (see
    /// `sampleBody`) — no new timer. Two `ps` calls rather than one:
    /// `lstart` and `args` are both variable-width fields that would clobber
    /// each other if crammed into one non-last column, so each gets its own
    /// call with itself as the final (unsplit) column.
    private func updateCodingAgentsOnQueue() {
        guard let dataOutput = runCommand("/bin/ps", ["-axo", "pid=,tty=,pcpu=,rss=,etime=,lstart="]),
              let argsOutput = runCommand("/bin/ps", ["-axo", "pid=,args="]) else {
            return
        }

        var argsByPID: [Int32: String] = [:]
        for line in argsOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            argsByPID[pid] = String(parts[1])
        }

        // Hard rule: exclude TopStats's own PID and its full ancestor chain
        // BEFORE any match/filter step below, so a self/ancestor row can
        // never be constructed in the first place (reinforced again in
        // Sprint 4's UI layer as a second, independent check).
        let excluded = codingAgentSelfExclusionSet

        var results: [CodingAgentProcess] = []
        var keys: [(pid: Int32, lstart: String)] = []

        for line in dataOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
            guard tokens.count >= 6,
                  let pid = Int32(tokens[0]),
                  !excluded.contains(pid),
                  let cpu = Double(tokens[2]),
                  let rssKB = Double(tokens[3]) else { continue }

            // One PID's bad/missing args row must never blank/abort the rest
            // of the list — just skip this PID and keep going.
            guard let args = argsByPID[pid],
                  let binaryName = matchCodingAgentBinaryName(args: args) else { continue }

            let tty = String(tokens[1])
            let etimeSeconds = parseEtimeSeconds(String(tokens[4]))
            let lstart = tokens[5...].joined(separator: " ")

            let cacheKey = cwdCacheKey(pid: pid, lstart: lstart)
            let cwd: CwdResolution = codingAgentCwdCache[cacheKey].map { .resolved($0) } ?? .unknown

            // Zombie flag v1 (see `CodingAgentProcess.isZombie` doc comment):
            // no controlling tty + near-zero CPU + running over an hour,
            // computed only for these already-matched CLI/MCP rows. Narrowed
            // to drop a PPID==1 check after live data showed Codex.app's own
            // backend process sits at PPID==1 permanently as normal GUI
            // reparenting, not as a zombie signal — see _pm/work-log.md.
            let isZombie = tty == "??" && cpu < 0.5 && etimeSeconds > 3600

            results.append(CodingAgentProcess(
                pid: pid,
                binaryName: binaryName,
                cpuPercent: cpu,
                rssMB: rssKB / 1024,
                etimeSeconds: etimeSeconds,
                cwd: cwd,
                isZombie: isZombie
            ))
            keys.append((pid: pid, lstart: lstart))
        }

        latestCodingAgentKeys = keys

        DispatchQueue.main.async {
            self.codingAgentProcesses = results
        }
    }

    /// Rule (a): top-level CLI agents match ONLY an exact basename in the
    /// allowed set, where the resolved executable path does not run through
    /// a GUI app bundle's `Contents/MacOS/` and the command line carries no
    /// Electron/Sparkle child markers — GUI wrapper apps are out of scope.
    /// Rule (b): MCP/Playwright children match by FULL COMMAND LINE
    /// substring only — this never matches bare `node` by name alone.
    private func matchCodingAgentBinaryName(args: String) -> String? {
        let firstToken = args.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        let basename = URL(fileURLWithPath: firstToken).lastPathComponent

        if Self.cliAgentBasenames.contains(basename) {
            if firstToken.contains("/Contents/MacOS/") { return nil }
            for marker in Self.electronChildMarkers where args.contains(marker) {
                return nil
            }
            return basename
        }

        for marker in Self.mcpCommandMarkers where args.contains(marker) {
            return basename.isEmpty ? "node" : basename
        }
        return nil
    }

    /// Parses BSD `ps -o etime=` (`[[dd-]hh:]mm:ss`) into whole seconds.
    private func parseEtimeSeconds(_ etime: String) -> Int {
        var remainder = etime
        var days = 0
        if let dashIndex = etime.firstIndex(of: "-") {
            days = Int(etime[etime.startIndex..<dashIndex]) ?? 0
            remainder = String(etime[etime.index(after: dashIndex)...])
        }
        let parts = remainder.split(separator: ":").compactMap { Int($0) }
        var seconds = 0
        switch parts.count {
        case 3: seconds = parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: seconds = parts[0] * 60 + parts[1]
        case 1: seconds = parts[0]
        default: seconds = 0
        }
        return days * 86400 + seconds
    }

    private func cwdCacheKey(pid: Int32, lstart: String) -> String {
        "\(pid):\(lstart)"
    }

    /// Coarser than the ps sampling above: one `lsof -a -p <pid> -d cwd`
    /// call per already-matched PID, never batched/unscoped, each under its
    /// own 2 s timeout. Runs only from `codingAgentsTabWillAppear()` /
    /// `refreshCodingAgents()` — NEVER from the 10 s ps tick.
    private func resolveCodingAgentCwdsOnQueue() {
        let keys = latestCodingAgentKeys
        guard !keys.isEmpty else { return }

        var resolvedByPID: [Int32: CwdResolution] = [:]
        for entry in keys {
            let key = cwdCacheKey(pid: entry.pid, lstart: entry.lstart)
            if let cachedPath = codingAgentCwdCache[key] {
                // Already-cached PIDs are never re-queried on reopen.
                resolvedByPID[entry.pid] = .resolved(cachedPath)
                continue
            }

            // One PID's lsof failure must never blank/abort the rest of the list.
            let result = resolveCwd(forPID: entry.pid)
            if case .resolved(let path) = result {
                codingAgentCwdCache[key] = path
            }
            // Deliberately NOT caching .unknown/.permissionDenied: a failed
            // lookup must retry on the next manual refresh, not stick forever.
            resolvedByPID[entry.pid] = result
        }

        DispatchQueue.main.async {
            self.codingAgentProcesses = self.codingAgentProcesses.map { process in
                guard let newCwd = resolvedByPID[process.pid] else { return process }
                return CodingAgentProcess(
                    pid: process.pid,
                    binaryName: process.binaryName,
                    cpuPercent: process.cpuPercent,
                    rssMB: process.rssMB,
                    etimeSeconds: process.etimeSeconds,
                    cwd: newCwd,
                    isZombie: process.isZombie
                )
            }
        }
    }

    private func resolveCwd(forPID pid: Int32) -> CwdResolution {
        // SAFETY: this lsof access works only while TopStats stays ad-hoc-signed
        // with no App Sandbox entitlement — see _pm/memory.md "Coding Agents
        // feature" gotcha; re-verify before any signing/notarization change.
        let result = runCommandWithTimeout("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"], timeout: 2.0)

        if result.timedOut {
            // A timeout resolves to .unknown, never .permissionDenied —
            // retried only on the next manual refresh (see caching note above).
            return .unknown
        }

        if result.exitCode == 0 {
            for line in result.stdout.split(separator: "\n") {
                if line.hasPrefix("n") {
                    let path = String(line.dropFirst())
                    if !path.isEmpty { return .resolved(path) }
                }
            }
            return .unknown
        }

        if Self.lsofPermissionDeniedConfirmed, result.stderr.localizedCaseInsensitiveContains("Permission denied") {
            return .permissionDenied
        }
        return .unknown
    }

    /// `runCommand` has no timeout; this variant exists only for the coarser
    /// per-PID lsof cwd lookup above, which is explicitly required to be
    /// bounded. Note: the process this can `terminate()` on timeout is the
    /// `lsof` HELPER SUBPROCESS THIS FUNCTION ITSELF SPAWNED a few lines
    /// above — never a claude/codex/cursor-agent/MCP process being inspected.
    private func runCommandWithTimeout(
        _ launchPath: String,
        _ arguments: [String],
        timeout: TimeInterval
    ) -> (stdout: String, stderr: String, exitCode: Int32, timedOut: Bool) {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = outPipe
        process.standardError = errPipe

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }

        do {
            try process.run()
        } catch {
            return ("", "", -1, false)
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            // Terminates only the `lsof` child handle created above — never
            // any other PID on the system.
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 0.3)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            return (
                String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? "",
                -1,
                true
            )
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return (
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? "",
            process.terminationStatus,
            false
        )
    }

    // MARK: Coding Agents — Scoped Kill (Sprint 2 — scoped-kill-action)

    /// Live count of a target PID's immediate children, for the Sprint 4
    /// confirmation dialog. v1 signals ONLY the target PID — these children are
    /// orphaned, not reclaimed; the dialog copy states that explicitly. Called
    /// by the caller BEFORE presenting the dialog, not from inside `killAgentProcess`.
    func liveChildCount(ofPID pid: Int32) -> Int {
        guard let out = runCommand("/usr/bin/pgrep", ["-P", "\(pid)"]) else { return 0 }
        return out.split(separator: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            .count
    }

    /// Scoped, TOCTOU-guarded kill of a single coding-agent PID. Re-verifies the
    /// live process identity (matched binary name AND start time — never name
    /// alone, which fails against PID reuse with concurrent same-named
    /// node/chrome-headless-shell instances) immediately before signaling; on
    /// any mismatch it aborts WITHOUT signaling. On match: SIGTERM, poll up to
    /// 3 s, then one SIGKILL + poll up to 2 s. Every outcome is recorded to
    /// `lastKillResult[pid]` — success is never assumed silently.
    ///
    /// SAFETY: kill() reaches non-child PIDs only while TopStats stays
    /// ad-hoc-signed with no App Sandbox entitlement — see _pm/memory.md
    /// "Coding Agents feature" gotcha; re-verify before any signing change.
    func killAgentProcess(pid: Int32, expectedBinaryName: String, expectedStartTime: TimeInterval) {
        agentActionQueue.async { [weak self] in
            self?.performKill(pid: pid, expectedBinaryName: expectedBinaryName, expectedStartTime: expectedStartTime)
        }
    }

    private enum KillSignalOutcome {
        case signaled
        case alreadyGone       // ESRCH — no such process (already exited)
        case permissionDenied  // EPERM — cannot signal this process
        case otherError(Int32)
    }

    private func performKill(pid: Int32, expectedBinaryName: String, expectedStartTime: TimeInterval) {
        // Defense-in-depth (on top of Sprint 1's self/ancestor candidate
        // exclusion and Sprint 4's UI-layer assert): the app must never signal
        // its own PID, even if a caller passes it by mistake.
        guard pid != ProcessInfo.processInfo.processIdentifier else {
            publishKillResult(pid, "process no longer matches — kill cancelled")
            return
        }

        // TOCTOU guard: fresh-read the live identity RIGHT NOW and require BOTH
        // the matched binary name AND the start time to equal what was captured
        // when the user clicked Kill. A gone/reused/swapped PID fails here and
        // is never signaled.
        let (liveName, liveStart) = freshIdentity(ofPID: pid)
        guard let liveName, let liveStart,
              liveName == expectedBinaryName,
              abs(liveStart - expectedStartTime) < 1.5 else {
            publishKillResult(pid, "process no longer matches — kill cancelled")
            return
        }

        // Identity confirmed — SIGTERM first, inspecting the syscall's own errno.
        // SAFETY: see _pm/memory.md "Coding Agents feature" — kill() access
        // depends on TopStats remaining ad-hoc-signed with no App Sandbox.
        switch signalAndClassify(pid: pid, signal: SIGTERM) {
        case .alreadyGone:
            publishKillResult(pid, "already exited")
            return
        case .permissionDenied:
            // Ad-hoc signed with zero entitlements and no OS backstop — never
            // silently no-op, and never escalate to SIGKILL.
            publishKillResult(pid, "Permission denied — this process cannot be terminated by this app.")
            return
        case .otherError(let e):
            publishKillResult(pid, "kill failed (errno \(e))")
            return
        case .signaled:
            break
        }

        // Poll every 250 ms up to 3 s for a graceful exit.
        if pollForExit(pid: pid, deadline: 3.0) {
            publishKillResult(pid, "terminated")
            return
        }

        // Still alive after 3 s — escalate to a single SIGKILL (same errno rules).
        switch signalAndClassify(pid: pid, signal: SIGKILL) {
        case .alreadyGone:
            // Exited in the race between the last poll and this SIGKILL: SIGTERM won.
            publishKillResult(pid, "terminated")
            return
        case .permissionDenied:
            publishKillResult(pid, "Permission denied — this process cannot be terminated by this app.")
            return
        case .otherError(let e):
            publishKillResult(pid, "force-stop failed (errno \(e))")
            return
        case .signaled:
            break
        }

        if pollForExit(pid: pid, deadline: 2.0) {
            publishKillResult(pid, "force-stopped")
        } else {
            publishKillResult(pid, "still running — could not stop")
        }
    }

    /// Sends `sig` to `pid` and classifies the result by the syscall's own
    /// errno. `sig == 0` (no signal) doubles as a liveness probe.
    private func signalAndClassify(pid: Int32, signal sig: Int32) -> KillSignalOutcome {
        if kill(pid, sig) == 0 { return .signaled }
        switch errno {
        case ESRCH: return .alreadyGone
        case EPERM: return .permissionDenied
        default:    return .otherError(errno)
        }
    }

    /// True once the PID is gone. `kill(pid, 0)` returning EPERM means the
    /// process still exists (owned by someone we can't signal) → still alive.
    private func processIsAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Polls every 250 ms until `deadline` seconds elapse; returns true as soon
    /// as the PID has exited. Runs on `agentActionQueue`, never main/workQueue.
    private func pollForExit(pid: Int32, deadline seconds: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if !processIsAlive(pid) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return !processIsAlive(pid)
    }

    /// Fresh, at-signal-time identity read: the matched coding-agent binary
    /// name (re-run through the exact Sprint 1 matcher, so a PID that is no
    /// longer a coding agent reads as `nil`) and the start time parsed from
    /// `ps -o lstart=`. Two `ps` calls keep each variable/fixed field unsplit.
    private func freshIdentity(ofPID pid: Int32) -> (binaryName: String?, startTime: TimeInterval?) {
        let args = runCommand("/bin/ps", ["-p", "\(pid)", "-o", "args="])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (args?.isEmpty == false) ? matchCodingAgentBinaryName(args: args!) : nil

        let lstart = runCommand("/bin/ps", ["-p", "\(pid)", "-o", "lstart="])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let start = (lstart?.isEmpty == false) ? parseLstart(lstart!) : nil

        return (name, start)
    }

    /// Parses a BSD `lstart` string into an epoch `TimeInterval`. Collapses the
    /// space-padded single-digit day ("Jul  5" → "Jul 5") so `DateFormatter`
    /// with a fixed pattern parses cleanly.
    private func parseLstart(_ lstart: String) -> TimeInterval? {
        let normalized = lstart.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return Self.lstartFormatter.date(from: normalized)?.timeIntervalSince1970
    }

    /// Publishes a per-PID kill outcome and schedules the same ~12 s auto-clear
    /// as `lastFreeUpResult`, clearing only if the message hasn't been replaced.
    private func publishKillResult(_ pid: Int32, _ message: String) {
        DispatchQueue.main.async {
            self.lastKillResult[pid] = message
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                if self.lastKillResult[pid] == message {
                    self.lastKillResult[pid] = nil
                }
            }
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
        guard let regex = Self.gpuClientPIDRegex,
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
              let pidRange = Range(match.range, in: line) else {
            return nil
        }
        guard let pid = Int(line[pidRange].dropFirst(4)) else { return nil }

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
        if let appName = firstRegexCapture(in: command, regex: Self.appBundleRegex) {
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

    private func firstRegexCapture(in text: String, regex: NSRegularExpression?) -> String? {
        guard let regex else { return nil }
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
                    Divider()
                    Toggle("Compact width", isOn: $settings.compactMenuBar)
                    Text("Drops labels so the title takes less menu bar space — recommended on notched displays, where it competes with every other icon for a fixed-width strip beside the camera housing.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
        .frame(width: 320, height: 480)
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
    private var tempHelperProcess: Process?
    private var dashboardHost: NSHostingView<TopStatsDashboardView>?
    private var dashboardItem: NSMenuItem?
    private var lastTitle = ""
    private var lastTooltip = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        if settings.launchAtLogin {
            LoginItemManager.setEnabled(true)
        }

        cleanupStaleTempHelpers()
        startTempHelper()
        configureStatusItem()
        updateMenuBarTitle()
        observeCommands()

        // The title refreshes when a sample tick publishes (same 5 s cadence);
        // no dedicated main-run-loop timer needed.
        stats.onSample = { [weak self] in
            self?.updateMenuBarTitle()
        }
    }

    private func observeCommands() {
        NotificationCenter.default.addObserver(self, selector: #selector(openSettings), name: .topStatsOpenSettings, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(quitApp), name: .topStatsQuit, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screenParametersChanged), name: NSWorkspace.didWakeNotification, object: nil)
    }

    // On multi-display setups (especially with a mirrored primary display alongside
    // extended secondaries), WindowServer/Dock can leave the status item out of the
    // recomposited menu bar on one screen after a docking, sleep/wake, or arrangement
    // change. Toggling isVisible forces a redraw across every screen's menu bar
    // without losing the autosaved position. A short delay lets the new display
    // arrangement settle before the nudge.
    @objc private func screenParametersChanged() {
        guard let item = statusItem else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            item.isVisible = false
            item.isVisible = true
        }
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

        // The 430×706 SwiftUI dashboard is created lazily on first open,
        // so an idle launch never pays for the view hierarchy.
        let item = NSMenuItem()
        menu.addItem(item)
        dashboardItem = item
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        if dashboardHost == nil {
            let host = NSHostingView(rootView: TopStatsDashboardView(stats: stats, settings: settings))
            host.frame = NSRect(x: 0, y: 0, width: 430, height: 706)
            dashboardItem?.view = host
            dashboardHost = host
        }
        stats.dashboardWillOpen()
    }

    func menuDidClose(_ menu: NSMenu) {
        stats.dashboardDidClose()
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
        NotificationCenter.default.removeObserver(self)
        tempHelperProcess?.terminate()
    }

    private func updateMenuBarTitle() {
        guard let button = statusItem?.button else { return }
        // Skip redraws when the rendered strings have not changed.
        let title = menuBarTitle()
        if title != lastTitle {
            lastTitle = title
            button.title = title
        }
        let tooltip = menuBarTooltip()
        if tooltip != lastTooltip {
            lastTooltip = tooltip
            button.toolTip = tooltip
        }
    }

    private func menuBarTitle() -> String {
        var parts: [String] = []
        let compact = settings.compactMenuBar

        if settings.showCPU {
            parts.append(compact ? String(format: "%.0f%%", stats.cpuUsage) : String(format: "CPU %.0f%%", stats.cpuUsage))
        }

        if settings.showRAM {
            let value = settings.ramShowFree ? stats.ramFree : stats.ramUsed
            if compact {
                parts.append(String(format: "%.0fG", value))
            } else {
                let label = settings.ramShowFree ? "RAM A" : "RAM U"
                parts.append(String(format: "%@ %.1fG", label, value))
            }
        }

        if settings.showGPU {
            parts.append(compact ? String(format: "%.0f%%", stats.gpuUsage) : String(format: "GPU %.0f%%", stats.gpuUsage))
        }

        if settings.showTemp {
            parts.append(stats.temperature)
        }

        if settings.showNetwork {
            parts.append("D\(formatBitsPerSecond(stats.downloadSpeed, compact: true)) U\(formatBitsPerSecond(stats.uploadSpeed, compact: true))")
        }

        return parts.isEmpty ? "TopStats" : parts.joined(separator: compact ? " " : "  ")
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
