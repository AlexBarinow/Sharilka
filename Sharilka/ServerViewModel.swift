//
//  ServerViewModel.swift
//  Sharilka
//
//  ViewModel bridging the FileReceiverServer with SwiftUI.
//  All published properties update on the main actor.
//

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class ServerViewModel: FileReceiverServerDelegate {
    // MARK: - Published State

    var serverState: ServerState = .stopped
    var currentPort: UInt16 = SharilkaProtocol.defaultPort
    var saveDirectory: String

    // Bonjour info
    var bonjourServiceType: String = SharilkaProtocol.bonjourServiceType
    var bonjourServiceName: String = ""

    // Network info
    var localAddresses: [String] = []

    // Transfer progress
    var transferProgress: TransferProgress = TransferProgress()

    // Last completed transfer
    var lastCompletedTransfer: CompletedTransfer?

    // Log entries
    var logEntries: [LogEntry] = []

    // MARK: - Private

    private var server: FileReceiverServer?
    private var speedTimer: Timer?

    // MARK: - Init

    init() {
        // Load persisted save directory or use default
        if let persisted = UserDefaults.standard.string(forKey: SharilkaProtocol.saveDirectoryKey),
           !persisted.isEmpty {
            self.saveDirectory = persisted
        } else {
            self.saveDirectory = SharilkaProtocol.defaultSaveDirectory
        }
    }

    // MARK: - Computed Properties

    var isServerRunning: Bool {
        serverState != .stopped && serverState != .error
    }

    var canStart: Bool {
        serverState == .stopped || serverState == .error || serverState == .completed
    }

    var canStop: Bool {
        serverState == .listening || serverState == .receiving || serverState == .starting || serverState == .completed
    }

    var stateColor: String {
        switch serverState {
        case .stopped: return "gray"
        case .starting: return "orange"
        case .listening: return "green"
        case .receiving: return "blue"
        case .completed: return "green"
        case .error: return "red"
        }
    }

    // MARK: - Actions

    func startServer() {
        guard canStart else { return }

        let newServer = FileReceiverServer(port: currentPort, saveDirectory: saveDirectory)
        newServer.delegate = self
        server = newServer

        bonjourServiceName = newServer.bonjourServiceName
        bonjourServiceType = newServer.bonjourServiceType
        localAddresses = NetworkInfo.localIPv4Addresses()

        do {
            try newServer.start()
        } catch {
            addLog("Failed to start server: \(error.localizedDescription)", isError: true)
            serverState = .error
        }
    }

    func stopServer() {
        stopSpeedTimer()
        resetTransferProgress()
        server?.stop()
        server = nil
    }

    func clearStatus() {
        logEntries.removeAll()
        lastCompletedTransfer = nil
        transferProgress = TransferProgress()
        if serverState == .completed || serverState == .error {
            serverState = server != nil ? .listening : .stopped
        }
    }

    /// Opens an NSOpenPanel for directory selection and persists the result.
    func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Select the folder where received files will be saved"

        if panel.runModal() == .OK, let url = panel.url {
            let newPath = url.path
            saveDirectory = newPath
            UserDefaults.standard.set(newPath, forKey: SharilkaProtocol.saveDirectoryKey)
            addLog("Save folder changed to: \(newPath)", isError: false)

            // If server is running, restart it with the new save directory
            if server != nil {
                stopServer()
                startServer()
                addLog("Server restarted with new save folder", isError: false)
            }
        }
    }

    /// Reveals the current save folder in Finder.
    func revealInFinder() {
        let url = URL(fileURLWithPath: saveDirectory, isDirectory: true)
        // Ensure directory exists before trying to reveal it
        let fm = FileManager.default
        if !fm.fileExists(atPath: saveDirectory) {
            try? fm.createDirectory(atPath: saveDirectory, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - FileReceiverServerDelegate

    nonisolated func serverDidChangeState(_ state: ServerState) {
        Task { @MainActor [weak self] in
            self?.serverState = state
            if state == .listening {
                self?.localAddresses = NetworkInfo.localIPv4Addresses()
            }
            // Reset progress display when returning to listening or stopped
            if state == .listening || state == .stopped {
                self?.resetTransferProgress()
            }
        }
    }

    nonisolated func serverDidLog(_ message: String, isError: Bool) {
        Task { @MainActor [weak self] in
            self?.addLog(message, isError: isError)
        }
    }

    nonisolated func serverDidStartTransfer(fileName: String, fileSize: UInt64, isBenchmark: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.transferProgress = TransferProgress(
                fileName: fileName,
                expectedSize: fileSize,
                receivedBytes: 0,
                startTime: .now,
                lastSpeedUpdateTime: .now,
                lastSpeedBytes: 0,
                smoothedSpeed: 0,
                isBenchmark: isBenchmark
            )
            self.serverState = .receiving
            self.startSpeedTimer()
        }
    }

    nonisolated func serverDidUpdateProgress(receivedBytes: UInt64) {
        Task { @MainActor [weak self] in
            self?.transferProgress.receivedBytes = receivedBytes
        }
    }

    nonisolated func serverDidCompleteTransfer(_ result: SessionResult) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.stopSpeedTimer()

            if result.success {
                let benchmarkLabel = result.wasBenchmark ? " [benchmark — file auto-deleted]" : ""
                self.lastCompletedTransfer = CompletedTransfer(
                    fileName: result.fileName,
                    fileSize: result.fileSize,
                    duration: result.duration,
                    wasBenchmark: result.wasBenchmark
                )
                self.addLog("✅ Transfer completed\(benchmarkLabel): \"\(result.fileName)\" — \(ByteCountFormatter.string(fromByteCount: Int64(result.fileSize), countStyle: .file)) in \(String(format: "%.1f", result.duration))s (\(String(format: "%.1f", Double(result.fileSize) / result.duration / 1_048_576)) MB/s)", isError: false)
            } else {
                self.addLog("❌ Transfer failed: \(result.error ?? "unknown")", isError: true)
                if !result.fileName.isEmpty {
                    self.addLog("Partial file deleted for: \"\(result.fileName)\"", isError: false)
                }
                // Reset progress on failure so the UI doesn't show stale data
                self.resetTransferProgress()
            }
        }
    }

    // MARK: - Speed Tracking

    private func startSpeedTimer() {
        stopSpeedTimer()
        speedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateSpeed()
            }
        }
    }

    private func stopSpeedTimer() {
        speedTimer?.invalidate()
        speedTimer = nil
    }

    private func updateSpeed() {
        let now = Date()
        let elapsed = now.timeIntervalSince(transferProgress.lastSpeedUpdateTime)

        guard elapsed > 0.1 else { return }

        let bytesDelta = transferProgress.receivedBytes - transferProgress.lastSpeedBytes
        let instantSpeed = Double(bytesDelta) / elapsed

        // Exponential moving average for smoothing
        let alpha: Double = 0.3
        if transferProgress.smoothedSpeed == 0 {
            transferProgress.smoothedSpeed = instantSpeed
        } else {
            transferProgress.smoothedSpeed = alpha * instantSpeed + (1 - alpha) * transferProgress.smoothedSpeed
        }

        transferProgress.lastSpeedUpdateTime = now
        transferProgress.lastSpeedBytes = transferProgress.receivedBytes
    }

    // MARK: - Helpers

    /// Resets transfer progress to a clean default state.
    private func resetTransferProgress() {
        transferProgress = TransferProgress()
    }

    // MARK: - Logging

    private func addLog(_ message: String, isError: Bool) {
        let entry = LogEntry(message, isError: isError)
        logEntries.append(entry)

        // Keep log from growing unbounded
        if logEntries.count > 500 {
            logEntries.removeFirst(logEntries.count - 500)
        }
    }
}
