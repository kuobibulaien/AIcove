// Minimal Flutter channel shell. Tests compile the production broadcast source
// unchanged; only channel delivery is replaced with in-process observations.
import Foundation
import Network

typealias FlutterResult = (Any?) -> Void
struct FlutterBinaryMessenger {}
struct FlutterError: Error {
    let code: String
    let message: String?
    let details: Any?
}
class BonsoirAction {
    let logMessages: [String: String]
    private let onDispose: () -> Void
    private(set) var isDisposed = false
    var events: [String] = []
    var errors: [Int32] = []
    init(id: Int, action: String, logMessages: [String: String], printLogs: Bool, onDispose: @escaping () -> Void, messenger: FlutterBinaryMessenger) {
        self.logMessages = logMessages
        self.onDispose = onDispose
    }
    func log(_ message: String, _ parameters: [Any] = []) {}
    func onSuccess(eventId: String, service: BonsoirService? = nil, parameters: [Any] = []) {
        events.append(eventId)
    }
    func onError(parameters: [Any] = [], details: Any? = nil) {
        errors.append(details as! Int32)
    }
    func dispose() {
        isDisposed = true
        onDispose()
    }
}

#if SUPPRESS_BONJOUR_CALLBACKS
// Fault injection: submit a real registration, but deliberately never install
// its callback reader. This deterministically models a daemon that never replies.
func DNSServiceSetDispatchQueue(_ ref: DNSServiceRef?, _ queue: DispatchQueue) -> DNSServiceErrorType {
    return DNSServiceErrorType(kDNSServiceErr_NoError)
}
#endif
