//
//  FileReceiveSession.swift
//  Sharilka
//
//  Handles a single file transfer session over one NWConnection.
//  Parses the Sharilka binary protocol v2 header, validates magic/version,
//  then pipelines file data through a bounded in-memory queue:
//    - a receiver task reads chunks from the TCP connection
//    - a writer task dequeues chunks and writes them to disk via FileHandle
//  This overlaps network I/O and disk I/O for better throughput.
//
//  Protocol v2 header: magic(4) + version(1) + flags(1) + filenameLen(8) + fileSize(8) + filename
//  The benchmark flag (bit 0) causes the received file to be automatically
//  deleted after a successful transfer.
//

import Foundation
import Network

/// Represents the result of a completed (or failed) file transfer session.
struct SessionResult: Sendable {
    let fileName: String
    let fileSize: UInt64
    let receivedBytes: UInt64
    let duration: TimeInterval
    let success: Bool
    let error: String?
    let wasBenchmark: Bool
}

/// Result type for a single NWConnection.receive call.
private enum ReceiveResult: Sendable {
    case data(Data)
    case closed
    case error(String)
}

/// Handles a single incoming file transfer.
/// One instance per NWConnection. Pipelines network reads and disk writes
/// through a bounded async queue for throughput.
final class FileReceiveSession: Sendable {
    let connection: NWConnection
    private let saveDirectory: String
    private let onProgress: @Sendable (UInt64) -> Void
    private let onHeaderParsed: @Sendable (String, UInt64, Bool) -> Void
    private let onComplete: @Sendable (SessionResult) -> Void
    private let onLog: @Sendable (String, Bool) -> Void

    // Mutable state protected by lock
    private let lock = NSLock()
    private var _fileHandle: FileHandle?
    private var _filePath: String?
    private var _receivedBytes: UInt64 = 0
    private var _expectedSize: UInt64 = 0
    private var _fileName: String = ""
    private var _startTime: Date = .now
    private var _cancelled: Bool = false
    private var _headerBuffer: Data = Data()
    private var _headerParsed: Bool = false
    private var _filenameLength: UInt64 = 0
    private var _protocolVersion: UInt8 = 0
    private var _transferFlags: TransferFlags = .none
    // Pipeline tasks (set once after header is parsed)
    private var _receiverTask: Task<Void, Never>?
    private var _writerTask: Task<Void, Never>?

    private var fileHandle: FileHandle? {
        get { lock.withLock { _fileHandle } }
        set { lock.withLock { _fileHandle = newValue } }
    }

    private var filePath: String? {
        get { lock.withLock { _filePath } }
        set { lock.withLock { _filePath = newValue } }
    }

    private var receivedBytes: UInt64 {
        get { lock.withLock { _receivedBytes } }
        set { lock.withLock { _receivedBytes = newValue } }
    }

    private var expectedSize: UInt64 {
        get { lock.withLock { _expectedSize } }
        set { lock.withLock { _expectedSize = newValue } }
    }

    private var fileName: String {
        get { lock.withLock { _fileName } }
        set { lock.withLock { _fileName = newValue } }
    }

    private var isCancelled: Bool {
        get { lock.withLock { _cancelled } }
        set { lock.withLock { _cancelled = newValue } }
    }

    init(connection: NWConnection,
         saveDirectory: String,
         onProgress: @escaping @Sendable (UInt64) -> Void,
         onHeaderParsed: @escaping @Sendable (String, UInt64, Bool) -> Void,
         onComplete: @escaping @Sendable (SessionResult) -> Void,
         onLog: @escaping @Sendable (String, Bool) -> Void) {
        self.connection = connection
        self.saveDirectory = saveDirectory
        self.onProgress = onProgress
        self.onHeaderParsed = onHeaderParsed
        self.onComplete = onComplete
        self.onLog = onLog
    }

    func start() {
        lock.withLock {
            _startTime = .now
            _headerBuffer = Data()
            _headerParsed = false
        }

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onLog("Connection ready from \(self.connection.endpoint)", false)
                self.readNextChunk()
            case .failed(let error):
                self.onLog("Connection failed: \(error.localizedDescription)", true)
                self.handleFailure("Connection failed: \(error.localizedDescription)")
            case .cancelled:
                // Only handle cleanup if we haven't already completed
                break
            default:
                break
            }
        }

        connection.start(queue: .global(qos: .userInitiated))
    }

    /// Cancel the session externally (e.g. server stop). Logs the reason and cleans up.
    func cancel(reason: String = "Session cancelled") {
        let wasAlreadyCancelled = lock.withLock { () -> Bool in
            let was = _cancelled
            _cancelled = true
            return was
        }
        if !wasAlreadyCancelled {
            // Cancel pipeline tasks if running
            lock.withLock {
                _receiverTask?.cancel()
                _writerTask?.cancel()
            }

            onLog(reason, true)
            connection.cancel()

            lock.withLock {
                _fileHandle?.closeFile()
                _fileHandle = nil
            }
            cleanupPartialFile()

            let (name, expected, received, start, flags) = lock.withLock {
                (_fileName, _expectedSize, _receivedBytes, _startTime, _transferFlags)
            }

            onComplete(SessionResult(
                fileName: name,
                fileSize: expected,
                receivedBytes: received,
                duration: Date().timeIntervalSince(start),
                success: false,
                error: reason,
                wasBenchmark: flags.isBenchmark
            ))
        }
    }

    // MARK: - Header Reading

    private func readNextChunk() {
        guard !isCancelled else { return }
        let isHeaderPhase = lock.withLock { !_headerParsed }
        guard isHeaderPhase else { return }
        readHeaderData()
    }

    private func readHeaderData() {
        // Read up to 64 KB during header phase — enough for the 22-byte fixed header
        // plus any reasonable filename, with room for overflow into file data.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self, !self.isCancelled else { return }

            if let error {
                self.handleFailure("Read error during header: \(error.localizedDescription)")
                return
            }

            if let data = content, !data.isEmpty {
                let result = self.lock.withLock { () -> HeaderParseResult in
                    self._headerBuffer.append(data)
                    return self.tryParseHeader()
                }

                switch result {
                case .needMoreData:
                    if isComplete {
                        self.handleFailure("Connection closed before header was complete")
                    } else {
                        self.readNextChunk()
                    }
                case .invalid(let reason):
                    self.handleFailure(reason)
                case .parsed(let overflow):
                    // Header parsed — hand off to the pipeline for file data
                    self.startPipeline(overflow: overflow)
                }
            } else if isComplete {
                self.handleFailure("Connection closed before any data received")
            }
        }
    }

    // MARK: - Header Parsing

    private enum HeaderParseResult {
        case needMoreData
        case invalid(String)
        case parsed(Data) // overflow data that belongs to file content
    }

    /// Reads a little-endian UInt64 from 8 bytes of Data at the given offset.
    /// Safe regardless of memory alignment — assembles the value byte-by-byte.
    private static func readLittleEndianUInt64(from data: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(data[data.startIndex + offset + i]) << (i * 8)
        }
        return value
    }

    /// Must be called while holding the lock.
    /// Only protocol v2 is supported. Any other version is rejected.
    private func tryParseHeader() -> HeaderParseResult {
        let buffer = _headerBuffer
        let fixedSize = SharilkaProtocol.headerFixedSize // 22

        // Need at least 5 bytes to read magic + version
        guard buffer.count >= 5 else {
            return .needMoreData
        }

        // Validate magic bytes "SHRK"
        let magic = [buffer[buffer.startIndex],
                     buffer[buffer.startIndex + 1],
                     buffer[buffer.startIndex + 2],
                     buffer[buffer.startIndex + 3]]
        guard magic == SharilkaProtocol.magic else {
            return .invalid("Invalid protocol magic: expected SHRK, got \(magic.map { String(format: "%02X", $0) }.joined())")
        }

        // Read and validate version — only v2 is supported
        let version = buffer[buffer.startIndex + 4]
        _protocolVersion = version

        guard version == SharilkaProtocol.version else {
            return .invalid("Unsupported protocol version: \(version), only v\(SharilkaProtocol.version) is supported")
        }

        guard buffer.count >= fixedSize else {
            return .needMoreData
        }

        // Read flags byte (byte 5)
        let flagsByte = buffer[buffer.startIndex + 5]
        _transferFlags = TransferFlags(rawValue: flagsByte)

        // Read filename length as little-endian UInt64 (bytes 6..13)
        let filenameLength = Self.readLittleEndianUInt64(from: buffer, at: 6)
        _filenameLength = filenameLength

        // Sanity check filename length
        guard filenameLength > 0 && filenameLength < 10000 else {
            return .invalid("Invalid filename length: \(filenameLength)")
        }

        // Read file size as little-endian UInt64 (bytes 14..21)
        let fileSize = Self.readLittleEndianUInt64(from: buffer, at: 14)
        _expectedSize = fileSize

        // Check if we have the full filename
        let totalHeaderSize = fixedSize + Int(filenameLength)
        guard buffer.count >= totalHeaderSize else {
            return .needMoreData
        }

        // Read filename (UTF-8)
        let filenameStart = buffer.startIndex + fixedSize
        let filenameEnd = filenameStart + Int(filenameLength)
        let filenameData = buffer[filenameStart..<filenameEnd]
        guard let filename = String(data: filenameData, encoding: .utf8) else {
            return .invalid("Invalid UTF-8 filename")
        }

        return finalizeHeader(filename: filename, fileSize: fileSize, totalHeaderSize: totalHeaderSize, buffer: buffer)
    }

    /// Finalizes the parsed v2 header: sanitizes the filename, prepares the destination file, and returns any overflow data.
    private func finalizeHeader(filename: String, fileSize: UInt64, totalHeaderSize: Int, buffer: Data) -> HeaderParseResult {
        // Sanitize filename: remove path components to prevent directory traversal
        let sanitizedName = (filename as NSString).lastPathComponent
        guard !sanitizedName.isEmpty else {
            return .invalid("Empty filename after sanitization")
        }

        _fileName = sanitizedName
        _headerParsed = true

        let flags = _transferFlags
        let flagsDesc = flags.isBenchmark ? " [benchmark]" : ""

        // Notify about the parsed header (triggers state change to .receiving)
        onHeaderParsed(sanitizedName, fileSize, flags.isBenchmark)

        // Prepare the destination file
        let path = (saveDirectory as NSString).appendingPathComponent(sanitizedName)
        _filePath = path

        // Create or overwrite the file
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            try? fm.removeItem(atPath: path)
        }
        fm.createFile(atPath: path, contents: nil)

        guard let handle = FileHandle(forWritingAtPath: path) else {
            return .invalid("Failed to create file handle for: \(path)")
        }
        _fileHandle = handle

        onLog("Transfer started (v2\(flagsDesc)): \"\(sanitizedName)\" (\(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)))", false)

        // Return any overflow data (bytes beyond the header that are file content)
        let overflowStart = buffer.startIndex + totalHeaderSize
        let overflow = buffer[overflowStart...]
        return .parsed(Data(overflow))
    }

    // MARK: - Receive/Write Pipeline

    /// Starts the producer-consumer pipeline after the header has been parsed.
    /// - Parameter overflow: any file data bytes that arrived with the header read.
    private func startPipeline(overflow: Data) {
        let queue = BoundedChunkQueue(capacity: kChunkQueueCapacity)
        let expected = lock.withLock { _expectedSize }

        let writerTask = Task.detached { [self] in
            await self.writerLoop(queue: queue, expectedSize: expected)
        }

        let receiverTask = Task.detached { [self] in
            await self.receiverLoop(queue: queue, overflow: overflow, expectedSize: expected)
        }

        lock.withLock {
            _receiverTask = receiverTask
            _writerTask = writerTask
        }
    }

    // MARK: Receiver Task

    /// Reads file data from the TCP connection and enqueues chunks into the bounded queue.
    /// Stops after the declared file size has been received, or on error/cancellation.
    nonisolated private func receiverLoop(queue: BoundedChunkQueue, overflow: Data, expectedSize: UInt64) async {
        var networkBytesReceived: UInt64 = 0

        // Process any overflow bytes from header parsing
        if !overflow.isEmpty {
            let remaining = expectedSize - networkBytesReceived
            let toEnqueue: Data
            if UInt64(overflow.count) > remaining {
                toEnqueue = overflow.prefix(Int(remaining))
            } else {
                toEnqueue = overflow
            }
            await queue.enqueue(FileChunk(data: toEnqueue, byteCount: toEnqueue.count))
            networkBytesReceived += UInt64(toEnqueue.count)

            if networkBytesReceived >= expectedSize {
                await queue.finish()
                return
            }
        }

        // Main receive loop
        while !Task.isCancelled && networkBytesReceived < expectedSize {
            let result = await receiveOneChunk()

            switch result {
            case .data(let data):
                let remaining = expectedSize - networkBytesReceived
                let toEnqueue: Data
                if UInt64(data.count) > remaining {
                    toEnqueue = data.prefix(Int(remaining))
                } else {
                    toEnqueue = data
                }
                await queue.enqueue(FileChunk(data: toEnqueue, byteCount: toEnqueue.count))
                networkBytesReceived += UInt64(toEnqueue.count)

            case .closed:
                if networkBytesReceived < expectedSize {
                    let msg = "Connection closed prematurely: received \(networkBytesReceived)/\(expectedSize) bytes"
                    await queue.fail(PipelineError(message: msg))
                }
                return

            case .error(let message):
                await queue.fail(PipelineError(message: "Read error: \(message)"))
                return
            }
        }

        if networkBytesReceived >= expectedSize {
            await queue.finish()
        }
    }

    /// Wraps a single NWConnection.receive call as an async operation.
    nonisolated private func receiveOneChunk() async -> ReceiveResult {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: SharilkaProtocol.receiveChunkSize) { content, _, isComplete, error in
                if let data = content, !data.isEmpty {
                    continuation.resume(returning: .data(data))
                } else if let error {
                    continuation.resume(returning: .error(error.localizedDescription))
                } else if isComplete {
                    continuation.resume(returning: .closed)
                } else {
                    // Should not happen with minimumIncompleteLength: 1
                    continuation.resume(returning: .closed)
                }
            }
        }
    }

    // MARK: Writer Task

    /// Dequeues chunks from the bounded queue and writes them sequentially to disk.
    /// Determines the final transfer outcome (success or failure).
    nonisolated private func writerLoop(queue: BoundedChunkQueue, expectedSize: UInt64) async {
        var bytesWritten: UInt64 = 0

        while let chunk = await queue.dequeue() {
            if Task.isCancelled { break }

            let handle = lock.withLock { _fileHandle }
            guard let handle else { break }

            do {
                try handle.write(contentsOf: chunk.data)
            } catch {
                // Disk write failed — cancel receiver, report failure
                lock.withLock { _receiverTask?.cancel() }
                await queue.fail(error)
                completePipeline(
                    success: false,
                    bytesWritten: bytesWritten,
                    error: "Disk write error: \(error.localizedDescription)"
                )
                return
            }

            bytesWritten += UInt64(chunk.byteCount)
            lock.withLock { _receivedBytes = bytesWritten }
            onProgress(bytesWritten)
        }

        // If externally cancelled, cancel() already handled cleanup
        let alreadyCancelled = lock.withLock { _cancelled }
        if alreadyCancelled || Task.isCancelled { return }

        // Check for receiver-side errors
        if let queueErr = await queue.currentError() {
            completePipeline(
                success: false,
                bytesWritten: bytesWritten,
                error: queueErr.localizedDescription
            )
            return
        }

        // Verify all bytes written
        if bytesWritten >= expectedSize {
            completePipeline(success: true, bytesWritten: bytesWritten, error: nil)
        } else {
            completePipeline(
                success: false,
                bytesWritten: bytesWritten,
                error: "Incomplete transfer: wrote \(bytesWritten)/\(expectedSize) bytes"
            )
        }
    }

    // MARK: - Pipeline Completion

    /// Called by the writer task to finalize the transfer after the pipeline drains.
    /// Ensures success is only reported after all bytes are safely written to disk.
    nonisolated private func completePipeline(success: Bool, bytesWritten: UInt64, error: String?) {
        // Ensure we only complete once
        let wasAlreadyCancelled = lock.withLock { () -> Bool in
            let was = _cancelled
            _cancelled = true
            return was
        }
        guard !wasAlreadyCancelled else { return }

        let flags = lock.withLock { _transferFlags }

        if success {
            // Close file handle — all data is safely on disk
            lock.withLock {
                _fileHandle?.closeFile()
                _fileHandle = nil
            }

            let (name, expected, start, path) = lock.withLock {
                (_fileName, _expectedSize, _startTime, _filePath)
            }
            let duration = Date().timeIntervalSince(start)

            // Auto-delete benchmark files after successful transfer
            if flags.isBenchmark, let benchmarkPath = path {
                let fm = FileManager.default
                if fm.fileExists(atPath: benchmarkPath) {
                    do {
                        try fm.removeItem(atPath: benchmarkPath)
                        onLog("Benchmark file auto-deleted: \(benchmarkPath)", false)
                    } catch {
                        onLog("Failed to auto-delete benchmark file: \(error.localizedDescription)", true)
                    }
                }
            }

            onLog("Transfer completed: \"\(name)\" in \(String(format: "%.1f", duration))s", false)
            connection.cancel()

            onComplete(SessionResult(
                fileName: name,
                fileSize: expected,
                receivedBytes: bytesWritten,
                duration: duration,
                success: true,
                error: nil,
                wasBenchmark: flags.isBenchmark
            ))
        } else {
            let reason = error ?? "Unknown error"
            onLog(reason, true)

            lock.withLock {
                _fileHandle?.closeFile()
                _fileHandle = nil
            }
            connection.cancel()
            cleanupPartialFile()

            let (name, expected, received, start) = lock.withLock {
                (_fileName, _expectedSize, _receivedBytes, _startTime)
            }

            onComplete(SessionResult(
                fileName: name,
                fileSize: expected,
                receivedBytes: received,
                duration: Date().timeIntervalSince(start),
                success: false,
                error: reason,
                wasBenchmark: flags.isBenchmark
            ))
        }
    }

    // MARK: - Error Handling

    /// Handles failures during the header phase or connection-level events.
    /// Also cancels any running pipeline tasks.
    private func handleFailure(_ reason: String) {
        guard !isCancelled else { return }
        isCancelled = true

        // Cancel pipeline tasks if they exist
        lock.withLock {
            _receiverTask?.cancel()
            _writerTask?.cancel()
        }

        onLog(reason, true)

        lock.withLock {
            _fileHandle?.closeFile()
            _fileHandle = nil
        }

        connection.cancel()
        cleanupPartialFile()

        let (name, expected, received, start, flags) = lock.withLock {
            (_fileName, _expectedSize, _receivedBytes, _startTime, _transferFlags)
        }

        onComplete(SessionResult(
            fileName: name,
            fileSize: expected,
            receivedBytes: received,
            duration: Date().timeIntervalSince(start),
            success: false,
            error: reason,
            wasBenchmark: flags.isBenchmark
        ))
    }

    private func cleanupPartialFile() {
        guard let path = filePath else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            try? fm.removeItem(atPath: path)
            onLog("Partial file deleted: \(path)", false)
        }
    }
}

// MARK: - Pipeline Error

/// Simple error type for pipeline failures, carrying a description.
private struct PipelineError: Error, LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}
