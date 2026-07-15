import Foundation

private var failures = 0

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() {
        print("PASS: \(message)")
    } else {
        failures += 1
        print("FAIL: \(message)")
    }
}

private let capturedNetworkQualityFixture = #"""
{
  "base_rtt": 16.719575881958008,
  "dl_throughput": 354043904,
  "interface_name": "en0",
  "responsiveness": 631.94012451171875,
  "ul_throughput": 148441824
}
"""#

do {
    let completedAt = Date(timeIntervalSince1970: 1_750_000_000)
    let result = try NetworkSpeedTester.parse(
        data: Data(capturedNetworkQualityFixture.utf8),
        completedAt: completedAt
    )
    check(result.downloadBitsPerSecond == 354_043_904, "parses download throughput as bits per second")
    check(result.uploadBitsPerSecond == 148_441_824, "parses upload throughput as bits per second")
    check(abs(result.idleLatencyMilliseconds - 16.719575881958008) < 0.0001, "parses idle latency")
    check(abs(result.responsivenessRPM - 631.94012451171875) < 0.0001, "parses responsiveness")
    check(result.interfaceName == "en0", "parses interface name")
    check(result.completedAt == completedAt, "uses the supplied completion time")
    check(formatNetworkSpeed(result.downloadBitsPerSecond) == "354 Mbps", "formats captured download speed without an erroneous byte-to-bit conversion")
} catch {
    failures += 1
    print("FAIL: valid captured fixture threw \(error)")
}

for invalid in [
    Data("not json".utf8),
    Data(#"{"dl_throughput": 100}"#.utf8),
    Data(#"{"base_rtt": -1, "dl_throughput": 1, "ul_throughput": 1, "responsiveness": 1, "interface_name": "en0"}"#.utf8)
] {
    do {
        _ = try NetworkSpeedTester.parse(data: invalid)
        failures += 1
        print("FAIL: invalid fixture was accepted")
    } catch {
        print("PASS: invalid fixture is rejected")
    }
}

check(formatNetworkSpeed(999_000) == "999 Kbps", "formats Kbps")
check(formatNetworkSpeed(25_500_000) == "25.5 Mbps", "formats Mbps")
check(formatNetworkSpeed(1_200_000_000) == "1.2 Gbps", "formats Gbps")

if let rates = NetworkSpeedTester.transferRates(
    previousIncoming: 1_000,
    previousOutgoing: 2_000,
    currentIncoming: 2_000,
    currentOutgoing: 2_500,
    elapsed: 0.5
) {
    check(rates.download == 16_000, "calculates live download bits per second")
    check(rates.upload == 8_000, "calculates live upload bits per second")
} else {
    failures += 1
    print("FAIL: valid live transfer counters were rejected")
}
check(NetworkSpeedTester.transferRates(
    previousIncoming: 2_000,
    previousOutgoing: 2_000,
    currentIncoming: 1_000,
    currentOutgoing: 2_500,
    elapsed: 0.5
) == nil, "rejects reset or wrapped interface counters")
check(NetworkSpeedTester.transferRates(
    previousIncoming: 1,
    previousOutgoing: 1,
    currentIncoming: 2,
    currentOutgoing: 2,
    elapsed: 0
) == nil, "rejects a zero sampling interval")

if CommandLine.arguments.contains("--integration") {
    let tester = NetworkSpeedTester()
    tester.start()
    let deadline = Date().addingTimeInterval(40)
    var peakLiveDownload = 0.0
    var peakLiveUpload = 0.0
    while tester.phase == .testing && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        peakLiveDownload = max(peakLiveDownload, tester.liveDownloadBitsPerSecond)
        peakLiveUpload = max(peakLiveUpload, tester.liveUploadBitsPerSecond)
    }
    if case .completed = tester.phase, let result = tester.result {
        check(peakLiveDownload > 0, "publishes changing live download speed during the test")
        check(peakLiveUpload > 0, "publishes changing live upload speed during the test")
        check(result.downloadBitsPerSecond > 0, "live test returns download capacity")
        check(result.uploadBitsPerSecond > 0, "live test returns upload capacity")
        check(result.idleLatencyMilliseconds > 0, "live test returns idle latency")
        check(result.responsivenessRPM > 0, "live test returns responsiveness")
        print("LIVE PEAKS: down=\(formatNetworkSpeed(peakLiveDownload)) up=\(formatNetworkSpeed(peakLiveUpload))")
        print("FINAL RESULT: down=\(formatNetworkSpeed(result.downloadBitsPerSecond)) up=\(formatNetworkSpeed(result.uploadBitsPerSecond)) latency=\(String(format: "%.0f ms", result.idleLatencyMilliseconds)) responsiveness=\(String(format: "%.0f RPM", result.responsivenessRPM)) interface=\(result.interfaceName)")
    } else {
        failures += 1
        print("FAIL: live test did not complete: \(tester.phase)")
        tester.cancel()
    }
}

if failures > 0 {
    exit(1)
}
print("All network speed tests passed.")
