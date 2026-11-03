#if canImport(Flutter)
    import Flutter
#endif
#if canImport(FlutterMacOS)
    import FlutterMacOS
#endif
import Foundation
import Network

/// Allows to broadcast a given service to the local network.
@available(iOS 13.0, macOS 10.15, *)
class BonsoirServiceBroadcast: BonsoirAction {
    private let service: BonsoirService
    private var sdRef: DNSServiceRef?
    private var registrationTimeout: DispatchWorkItem?
    private var startResult: FlutterResult?

    public init(id: Int, printLogs: Bool, onDispose: @escaping () -> Void, messenger: FlutterBinaryMessenger, service: BonsoirService) {
        self.service = service
        super.init(id: id, action: "broadcast", logMessages: Generated.broadcastMessages, printLogs: printLogs, onDispose: onDispose, messenger: messenger)
    }

    /// Completes only when registered, failed, cancelled or timed out. Never
    /// synchronously waits for a daemon callback on the platform/UI thread.
    public func start(result: @escaping FlutterResult) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isDisposed && sdRef == nil else {
            result(FlutterError(code: Generated.broadcastError, message: "Broadcast already started or disposed", details: kDNSServiceErr_BadState))
            return
        }
        startResult = result
        var txtRecord = TXTRecordRef()
        TXTRecordCreate(&txtRecord, 0, nil)
        defer { TXTRecordDeallocate(&txtRecord) }
        for (key, value) in service.attributes {
            guard let valueData = value.data(using: .utf8) else { continue }
            TXTRecordSetValue(&txtRecord, key, UInt8(valueData.count), [UInt8](valueData))
        }
        let error = DNSServiceRegister(&sdRef, 0, 0, service.name, service.type, "local.", service.hostAddresses.first ?? service.hostname, CFSwapInt16HostToBig(UInt16(service.port)), TXTRecordGetLength(&txtRecord), TXTRecordGetBytesPtr(&txtRecord), BonsoirServiceBroadcast.registerCallback, Unmanaged.passUnretained(self).toOpaque())
        guard error == kDNSServiceErr_NoError else {
            fail(error)
            return
        }
        log(logMessages[Generated.broadcastInitialized]!, [service])
        // DNSSD owns the socket reader. Replies, timeout and deallocation share
        // the main serial queue, as required by DNSServiceSetDispatchQueue.
        let queueError = DNSServiceSetDispatchQueue(sdRef, DispatchQueue.main)
        guard queueError == kDNSServiceErr_NoError else {
            fail(queueError)
            return
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.startResult != nil else { return }
            self.fail(DNSServiceErrorType(kDNSServiceErr_Timeout))
        }
        registrationTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
    }

    private func finishStart(_ result: Any?) {
        registrationTimeout?.cancel()
        registrationTimeout = nil
        let completion = startResult
        startResult = nil
        completion?(result)
    }

    private func fail(_ error: DNSServiceErrorType) {
        onError(parameters: [service, error], details: error)
        finishStart(FlutterError(code: Generated.broadcastError, message: "Bonjour registration failed (\(error))", details: error))
        dispose()
    }

    override public func dispose() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isDisposed else { return }
        if let ref = sdRef {
            DNSServiceRefDeallocate(ref)
            sdRef = nil
        }
        finishStart(FlutterError(code: Generated.broadcastError, message: "Broadcast stopped before registration completed", details: kDNSServiceErr_BadState))
        onSuccess(eventId: Generated.broadcastStopped, service: service)
        super.dispose()
    }

    private static let registerCallback: DNSServiceRegisterReply = { _, _, errorCode, name, _, _, context in
        guard let context else { return }
        let broadcast = Unmanaged<BonsoirServiceBroadcast>.fromOpaque(context).takeUnretainedValue()
        guard !broadcast.isDisposed else { return }
        if errorCode == kDNSServiceErr_NoError {
            let newName = name == nil ? nil : String(cString: name!)
            if let newName, broadcast.service.name != newName {
                let oldName = broadcast.service.name
                broadcast.service.name = newName
                broadcast.onSuccess(eventId: Generated.broadcastNameAlreadyExists, service: broadcast.service, parameters: [oldName])
            }
            broadcast.onSuccess(eventId: Generated.broadcastStarted, service: broadcast.service)
            broadcast.finishStart(true)
        } else {
            broadcast.fail(errorCode)
        }
    }
}
