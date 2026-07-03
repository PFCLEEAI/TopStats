import Foundation
import IOKit

// Apple Silicon Temperature Reader
// Reads from HID thermal sensors

class AppleSiliconTemp {
    private var connection: io_connect_t = 0

    init?() {
        var service: io_service_t = 0
        var iterator: io_iterator_t = 0

        // Try to find Apple M-series thermal sensors
        let matchingDict = IOServiceMatching("AppleARMIODevice")

        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator)
        guard result == KERN_SUCCESS else { return nil }

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            service = entry
            IOObjectRelease(entry)
        }

        IOObjectRelease(iterator)
        guard service != 0 else { return nil }
    }

    static func readTemperature() -> Double? {
        // Use IOReport for Apple Silicon
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ioreg")
        process.arguments = ["-r", "-d", "1", "-c", "AppleARMIODevice", "-a"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()

            if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] {
                for device in plist {
                    if let name = device["IORegistryEntryName"] as? String,
                       name.contains("pmgr") || name.contains("soc") {
                        // Found power manager, try to get temp
                        if let props = device["IORegistryEntryChildren"] as? [[String: Any]] {
                            for prop in props {
                                if let temp = prop["temperature"] as? Double {
                                    return temp / 100.0 // Convert to Celsius
                                }
                            }
                        }
                    }
                }
            }
        } catch {}

        return nil
    }
}

// Try multiple methods to get temperature
func getAppleSiliconTemperature() -> String {
    // Method 1: Try thermal-monitor logs
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-c", """
        /usr/bin/log show --predicate 'subsystem == "com.apple.thermalmonitor"' --last 30s --style compact 2>/dev/null | grep -i "temp\\|celsius" | tail -1 | grep -oE '[0-9]+\\.?[0-9]*' | head -1
        """]

    let pipe = Pipe()
    process.standardOutput = pipe

    do {
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let temp = Double(output), temp > 20 && temp < 120 {
            return String(format: "%.0f°C", temp)
        }
    } catch {}

    // Method 2: Check thermal state and estimate
    let state = ProcessInfo.processInfo.thermalState
    switch state {
    case .nominal: return "~35°C"
    case .fair: return "~55°C"
    case .serious: return "~75°C"
    case .critical: return "~95°C"
    @unknown default: return "~40°C"
    }
}

// Main - just print temperature for testing
print(getAppleSiliconTemperature())
