//
//  FileReceiverServer.swift
//  Sharilka
//
//  TCP server using NWListener (Network.framework).
//  Accepts one connection at a time, delegates to FileReceiveSession.
//  Advertises via Bonjour using BonjourAdvertiser.
//

import Foundation
import Network

/// Callbacks from the server to the ViewModel (all called from background queues).
protocol FileReceiverServerDelegate: AnyObject, Sendable {
    func serverDidChangeState(_ state: ServerState)
    func serverDidLog(_ message: String, isError: Bool)
    func serverDidStartTransfer(fileName: String, fileSize: UInt64, isBenchmark: Bool)
    func serverDidUpdateProgress(receivedBytes: UInt64)
    func serverDidCompleteTransfer(_ result: SessionResult)
}

/// The TCP file receiver server. Manages NWListener, Bonjour, and active sessions.
final class FileReceiverServer: @unchecked Sendable {
    private var listener: NWListener?
    private var activeSession: FileReceiveSession?
    private let bonjourAdvertiser: BonjourAdvertiser

    private let port: UInt16
    private let saveDirectory: String
    private let serverQueue = DispatchQueue(label: "com.sharilka.server", qos: .userInitiated)
    private let lock = NSLock()

    weak var delegate: FileReceiverServerDelegate?

    var isRunning: Bool {
        lock.withLock { listener != nil }
    }

    var bonjourServiceType: String { bonjourAdvertiser.serviceType }
    var bonjourServiceName: String { bonjourAdvertiser.serviceName }

    init(port: UInt16 = SharilkaProtocol.defaultPort,
         saveDirectory: String = SharilkaProtocol.defaultSaveDirectory) {
        self.port = port
        self.saveDirectory = saveDirectory
        self.bonjourAdvertiser = BonjourAdvertiser(port: port)

        // Wire up Bonjour events to delegate logging
        bonjourAdvertiser.onEvent = { [weak self] message, isError in
            self?.delegate?.serverDidLog(message, isError: isError)
        }
    }

    // MARK: - Start / Stop

    func start() throws {
        // Ensure save directory exists
        let fm = FileManager.default
        if !fm.fileExists(atPath: saveDirectory) {
            try fm.createDirectory(atPath: saveDirectory, withIntermediateDirectories: true)
            delegate?.serverDidLog("Created save directory: \(saveDirectory)", isError: false)
        }

        delegate?.serverDidChangeState(.starting)

        // Create TCP listener
        let params = NWParameters.tcp
        params.acceptLocalOnly = false
        // Bind to the specified port on all IPv4 interfaces
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.any), port: NWEndpoint.Port(rawValue: port)!)

        let newListener: NWListener
        do {
            newListener = try NWListener(using: params)
        } catch {
            delegate?.serverDidLog("Failed to create listener: \(error.localizedDescription)", isError: true)
            delegate?.serverDidChangeState(.error)
            throw error
        }

        newListener.stateUpdateHandler = { [weak self] state in
            self?.handleListenerState(state)
        }

        newListener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        lock.withLock { listener = newListener }
        newListener.start(queue: serverQueue)
    }

    func stop() {
        lock.lock()
        let currentListener = listener
        let currentSession = activeSession
        listener = nil
        activeSession = nil
        lock.unlock()

        // Cancel active transfer with explicit reason
        if let session = currentSession {
            delegate?.serverDidLog("Cancelling active transfer due to server stop", isError: true)
            session.cancel(reason: "Transfer cancelled: server stopped by user")
        }

        currentListener?.cancel()
        bonjourAdvertiser.stopAdvertising()

        delegate?.serverDidLog("Server stopped", isError: false)
        delegate?.serverDidChangeState(.stopped)
    }

    // MARK: - Listener State

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            delegate?.serverDidLog("Server listening on port \(port)", isError: false)
            delegate?.serverDidChangeState(.listening)

            // Start Bonjour advertisement (success/failure reported via BonjourAdvertiser.onEvent)
            bonjourAdvertiser.startAdvertising()
            delegate?.serverDidLog("Bonjour advertising: \(bonjourAdvertiser.serviceType) as \"\(bonjourAdvertiser.serviceName)\"", isError: false)

        case .failed(let error):
            delegate?.serverDidLog("Listener failed: \(error.localizedDescription)", isError: true)
            delegate?.serverDidChangeState(.error)
            lock.withLock { listener = nil }

        case .cancelled:
            break

        case .waiting(let error):
            delegate?.serverDidLog("Listener waiting: \(error.localizedDescription)", isError: false)

        default:
            break
        }
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        let hasActiveSession = lock.withLock { activeSession != nil }

        if hasActiveSession {
            // Reject: only one transfer at a time
            delegate?.serverDidLog("Rejected connection from \(connection.endpoint): transfer already in progress", isError: true)
            connection.cancel()
            return
        }

        delegate?.serverDidLog("Incoming connection from \(connection.endpoint)", isError: false)

        // Do NOT enter .receiving yet — wait until the header is validated.
        // The session's onHeaderParsed callback will trigger the state change.

        let session = FileReceiveSession(
            connection: connection,
            saveDirectory: saveDirectory,
            onProgress: { [weak self] receivedBytes in
                self?.delegate?.serverDidUpdateProgress(receivedBytes: receivedBytes)
            },
            onHeaderParsed: { [weak self] fileName, fileSize, isBenchmark in
                // Now we have a valid header — enter .receiving state
                self?.delegate?.serverDidStartTransfer(fileName: fileName, fileSize: fileSize, isBenchmark: isBenchmark)
            },
            onComplete: { [weak self] result in
                self?.handleSessionComplete(result)
            },
            onLog: { [weak self] message, isError in
                self?.delegate?.serverDidLog(message, isError: isError)
            }
        )

        lock.withLock { activeSession = session }
        // State remains .listening until onHeaderParsed fires
        session.start()
    }

    private func handleSessionComplete(_ result: SessionResult) {
        lock.withLock { activeSession = nil }

        if result.success {
            delegate?.serverDidChangeState(.completed)
        } else {
            // On failure, return to listening if the server is still running
            let stillRunning = lock.withLock { listener != nil }
            if stillRunning {
                delegate?.serverDidChangeState(.listening)
            }
        }

        delegate?.serverDidCompleteTransfer(result)

        // Return to listening state after a brief moment for completed transfers
        if result.success {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self else { return }
                let stillRunning = self.lock.withLock { self.listener != nil && self.activeSession == nil }
                if stillRunning {
                    self.delegate?.serverDidChangeState(.listening)
                }
            }
        }
    }
}
