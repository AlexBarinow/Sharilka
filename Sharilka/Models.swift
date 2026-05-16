//
//  Models.swift
//  Sharilka
//
//  Core data models for server state, transfer progress, and log entries.
//

import Foundation

// MARK: - Server State

enum ServerState: String, Sendable {
    case stopped = "Stopped"
    case starting = "Starting"
    case listening = "Listening"
    case receiving = "Receiving"
    case completed = "Completed"
    case error = "Error"
}

// MARK: - Transfer Progress

struct TransferProgress: Sendable {
    var fileName: String = ""
    var expectedSize: UInt64 = 0
    var receivedBytes: UInt64 = 0
    var startTime: Date = .now
    var lastSpeedUpdateTime: Date = .now
    var lastSpeedBytes: UInt64 = 0
    var smoothedSpeed: Double = 0 // bytes per second

    var progressFraction: Double {
        guard expectedSize > 0 else { return 0 }
        return Double(receivedBytes) / Double(expectedSize)
    }

    var progressPercent: Double {
        progressFraction * 100.0
    }

    var speedMBps: Double {
        smoothedSpeed / (1024.0 * 1024.0)
    }

    var etaSeconds: Double? {
        guard smoothedSpeed > 0 else { return nil }
        let remaining = Double(expectedSize) - Double(receivedBytes)
        return remaining / smoothedSpeed
    }

    var etaFormatted: String {
        guard let eta = etaSeconds else { return "--:--" }
        if eta < 0 || eta > 360000 { return "--:--" }
        let totalSeconds = Int(eta)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var isComplete: Bool {
        expectedSize > 0 && receivedBytes >= expectedSize
    }
}

// MARK: - Completed Transfer Info

struct CompletedTransfer: Sendable {
    var fileName: String
    var fileSize: UInt64
    var duration: TimeInterval

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
    }

    var formattedDuration: String {
        if duration < 1 {
            return String(format: "%.0f ms", duration * 1000)
        } else if duration < 60 {
            return String(format: "%.1f s", duration)
        } else {
            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            return String(format: "%d:%02d", minutes, seconds)
        }
    }

    var averageSpeedMBps: Double {
        guard duration > 0 else { return 0 }
        return Double(fileSize) / duration / (1024.0 * 1024.0)
    }
}

// MARK: - Log Entry

struct LogEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let message: String
    let isError: Bool

    init(_ message: String, isError: Bool = false) {
        self.timestamp = .now
        self.message = message
        self.isError = isError
    }

    var formattedTimestamp: String {
        Self.formatter.string(from: timestamp)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

// MARK: - Protocol Constants

enum SharilkaProtocol {
    static let magic: [UInt8] = [0x53, 0x48, 0x52, 0x4B] // "SHRK"
    static let version: UInt8 = 1
    static let headerFixedSize = 4 + 1 + 8 + 8 // magic + version + filenameLen + fileSize = 21 bytes
    static let defaultPort: UInt16 = 5001
    static let saveDirectory = "/Users/alex/Exchange_Server_Data"
    static let bonjourServiceType = "_sharilka._tcp"
    static let receiveChunkSize = 1_048_576 // 1 MB
}
