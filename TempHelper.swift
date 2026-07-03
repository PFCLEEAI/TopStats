import Foundation

// Temperature Helper that reads real CPU die temperature
// Uses the temp_sensor binary to get actual PMU die temperatures

let tempFile = "/tmp/cpu_temp.txt"
let sensorPath = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("temp_sensor").path
    ?? "/Applications/TopStats.app/Contents/MacOS/temp_sensor"

// Get the directory where this helper is located
let helperPath = CommandLine.arguments[0]
let helperDir = (helperPath as NSString).deletingLastPathComponent
let localSensorPath = (helperDir as NSString).appendingPathComponent("temp_sensor")

func getMaxDieTemp() -> Double? {
    let process = Process()

    // Try local path first, then app bundle path
    let sensorPaths = [localSensorPath, sensorPath, "/Applications/TopStats.app/Contents/MacOS/temp_sensor"]
    var foundPath: String? = nil

    for path in sensorPaths {
        if FileManager.default.fileExists(atPath: path) {
            foundPath = path
            break
        }
    }

    guard let execPath = foundPath else {
        return nil
    }

    process.executableURL = URL(fileURLWithPath: execPath)

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()

        // Read just enough output (2 lines: header + data)
        var headerLine = ""
        var dataLine = ""

        let fileHandle = pipe.fileHandleForReading
        var buffer = Data()
        var lineCount = 0

        while lineCount < 2 {
            guard let byte = try? fileHandle.read(upToCount: 1), !byte.isEmpty else { break }
            buffer.append(byte)

            if byte[0] == 10 { // newline
                if let line = String(data: buffer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    if lineCount == 0 {
                        headerLine = line
                    } else {
                        dataLine = line
                    }
                }
                buffer = Data()
                lineCount += 1
            }
        }

        process.terminate()

        // Parse header to find tdie sensor indices
        let headers = headerLine.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let values = dataLine.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        var maxTemp: Double = 0

        for (index, header) in headers.enumerated() {
            // Look for die temperature sensors (tdie)
            if header.lowercased().contains("tdie") && index < values.count {
                if let temp = Double(values[index]), temp > maxTemp && temp < 150 {
                    maxTemp = temp
                }
            }
        }

        return maxTemp > 0 ? maxTemp : nil

    } catch {
        return nil
    }
}

// Fallback using thermal state
func estimateTemp() -> Double {
    let state = ProcessInfo.processInfo.thermalState
    switch state {
    case .nominal: return 45
    case .fair: return 65
    case .serious: return 85
    case .critical: return 100
    @unknown default: return 50
    }
}

// Main loop
while true {
    var temp: Double

    if let realTemp = getMaxDieTemp() {
        temp = realTemp
    } else {
        temp = estimateTemp()
    }

    try? String(format: "%.0f", temp).write(toFile: tempFile, atomically: true, encoding: .utf8)
    Thread.sleep(forTimeInterval: 3.0)
}
