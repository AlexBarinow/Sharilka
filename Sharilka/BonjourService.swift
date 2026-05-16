//
//  BonjourService.swift
//  Sharilka
//
//  Manages Bonjour advertisement using NetService with TXT record metadata.
//  Publish success and failure events are surfaced via the onEvent callback.
//

import Foundation
import Network

/// Manages Bonjour service advertisement using NetService for fine-grained TXT record control.
final class BonjourAdvertiser: @unchecked Sendable {
    private var netService: NetService?
    private let delegateHandler: BonjourDelegate

    let serviceType: String
    let serviceName: String
    let port: UInt16

    var isAdvertising: Bool {
        netService != nil
    }

    /// Callback for publish/stop/error events. Called from the NetService delegate thread.
    /// Parameters: (message: String, isError: Bool)
    var onEvent: (@Sendable (String, Bool) -> Void)?

    init(serviceType: String = SharilkaProtocol.bonjourServiceType,
         serviceName: String? = nil,
         port: UInt16 = SharilkaProtocol.defaultPort) {
        self.serviceType = serviceType
        self.serviceName = serviceName ?? "Sharilka on \(NetworkInfo.localHostName())"
        self.port = port
        self.delegateHandler = BonjourDelegate()

        // Wire up delegate events to the onEvent callback
        delegateHandler.owner = self
    }

    func startAdvertising() {
        stopAdvertising()

        let service = NetService(
            domain: "local.",
            type: serviceType,
            name: serviceName,
            port: Int32(port)
        )

        // Set TXT record with useful metadata for service discovery
        let txtData: [String: String] = [
            "protocol": "1",
            "app": "Sharilka",
            "platform": "macOS",
            "port": "\(port)"
        ]
        let txtRecord = NetService.data(fromTXTRecord: txtData.mapValues { Data($0.utf8) })
        service.setTXTRecord(txtRecord)
        service.delegate = delegateHandler
        service.publish()

        netService = service
    }

    func stopAdvertising() {
        netService?.stop()
        netService = nil
    }

    // Called by the delegate on publish success
    fileprivate func handleDidPublish(_ service: NetService) {
        onEvent?("Bonjour service published: \(service.type) as \"\(service.name)\" on port \(service.port)", false)
    }

    // Called by the delegate on publish failure
    fileprivate func handleDidNotPublish(_ service: NetService, errorDict: [String: NSNumber]) {
        let errorCode = errorDict[NetService.errorCode] ?? -1
        let errorDomain = errorDict[NetService.errorDomain] ?? -1
        onEvent?("Bonjour publish failed: error code \(errorCode), domain \(errorDomain)", true)
    }

    // Called by the delegate when service stops
    fileprivate func handleDidStop(_ service: NetService) {
        onEvent?("Bonjour service stopped: \(service.name)", false)
    }
}

private final class BonjourDelegate: NSObject, NetServiceDelegate, @unchecked Sendable {
    weak var owner: BonjourAdvertiser?

    func netServiceDidPublish(_ sender: NetService) {
        owner?.handleDidPublish(sender)
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        owner?.handleDidNotPublish(sender, errorDict: errorDict)
    }

    func netServiceDidStop(_ sender: NetService) {
        owner?.handleDidStop(sender)
    }
}
