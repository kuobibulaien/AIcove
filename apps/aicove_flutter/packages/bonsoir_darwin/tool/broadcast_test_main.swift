import Foundation
import Network

@main
struct BroadcastTest {
    static var old: BonsoirServiceBroadcast?
    static var next: BonsoirServiceBroadcast?
    static var ticker: DispatchSourceTimer?
    static var ticks = 0
    static var completions = 0

    static func check(_ condition: Bool, _ message: String) {
        if !condition {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func make(_ id: Int, _ name: String) -> BonsoirServiceBroadcast {
        BonsoirServiceBroadcast(id: id, printLogs: false, onDispose: {}, messenger: FlutterBinaryMessenger(), service: BonsoirService(name: name, type: "_aicove-diag._tcp", port: 49321, attributes: [:]))
    }

    static func begin(_ mode: String, _ name: String) {
        next = make(2, name)
        let before = ProcessInfo.processInfo.systemUptime
        let initialTicks = ticks
        next!.start { result in
            completions += 1
            let elapsed = ProcessInfo.processInfo.systemUptime - before
            if mode == "cancel" {
                check(((result as? FlutterError)?.details as? NSNumber)?.intValue == kDNSServiceErr_BadState, "pending stop reports cancellation")
            } else {
                check(((result as? FlutterError)?.details as? NSNumber)?.intValue == kDNSServiceErr_Timeout, "missing reply must report timeout, got \(String(describing: result))")
                check(elapsed >= 4.9 && elapsed < 6.5, "deadline bounded: \(elapsed)")
                check(ticks - initialTicks > 100, "main queue heartbeat continued")
            }
            DispatchQueue.main.async {
                check(next!.isDisposed, "timeout/stop released the action")
                next!.dispose()
                check(next!.events.filter { $0 == Generated.broadcastStopped }.count == 1, "stop is idempotent")
                check(completions == 1, "method result completed once")
                print(String(format: "PASS %@ elapsed=%.3fs main_ticks=%d completions=%d disposed=%@", mode, elapsed, ticks - initialTicks, completions, String(next!.isDisposed)))
                exit(0)
            }
        }
        let callTime = ProcessInfo.processInfo.systemUptime - before
        check(callTime < 0.25, "start() must return immediately, took \(callTime)")
        print(String(format: "start_return_ms=%.2f", callTime * 1000))
        if mode == "overlap" {
            // Same ordering/age/name/type/port as dnssd_handoff.c: the new
            // registration is submitted before the aged old registration stops.
            old!.dispose()
            old = nil
        } else if mode == "cancel" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { next!.dispose() }
        }
    }

    static func main() {
        let mode = CommandLine.arguments.dropFirst().first ?? "overlap"
        let name = "AIcove-broadcast-test-\(getpid())"
        DispatchQueue.global().asyncAfter(deadline: .now() + 25) {
            fputs("FAIL: watchdog expired (main queue blocked or result lost)\n", stderr)
            exit(1)
        }
        DispatchQueue.main.async {
            ticker = DispatchSource.makeTimerSource(queue: .main)
            ticker!.schedule(deadline: .now(), repeating: .milliseconds(10))
            ticker!.setEventHandler { ticks += 1 }
            ticker!.resume()
            if mode == "overlap" {
                old = make(1, name)
                old!.start { result in
                    check(result as? Bool == true, "old registration succeeded")
                    print("old_registered=true; aging 10s")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { begin(mode, name) }
                }
            } else {
                begin(mode, name)
            }
        }
        dispatchMain()
    }
}
