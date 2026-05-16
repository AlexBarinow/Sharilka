//
//  BoundedChunkQueue.swift
//  Sharilka
//
//  A bounded, actor-isolated async queue for pipelining received network
//  chunks to a disk-writer task.  The queue suspends the producer when full
//  and the consumer when empty, providing natural back-pressure.
//

import Foundation

/// Default number of chunks the queue can hold before the producer suspends.
nonisolated let kChunkQueueCapacity = 4

/// A single chunk of file data flowing through the pipeline.
struct FileChunk: Sendable {
    let data: Data
    let byteCount: Int
}

/// Actor-based bounded async queue.
///
/// - **enqueue(_:)** suspends if the queue is at capacity.
/// - **dequeue()** suspends if the queue is empty.
/// - **finish()** signals that no more chunks will be enqueued.
/// - **fail(_:)** signals an error from the producer side.
///
/// Both sides observe cancellation via `Task.isCancelled`.
actor BoundedChunkQueue {
    private let capacity: Int
    private var buffer: [FileChunk] = []
    private var finished = false
    private var error: Error?

    // Continuations for suspended producer / consumer
    private var enqueueContinuation: CheckedContinuation<Void, Never>?
    private var dequeueContinuation: CheckedContinuation<FileChunk?, Never>?

    init(capacity: Int = kChunkQueueCapacity) {
        self.capacity = capacity
        buffer.reserveCapacity(capacity)
    }

    // MARK: - Producer API

    /// Enqueue a chunk.  Suspends if the buffer is at capacity.
    func enqueue(_ chunk: FileChunk) async {
        // If we already failed or finished, drop silently.
        if finished || error != nil { return }

        if buffer.count >= capacity {
            // Suspend producer until space is available.
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                enqueueContinuation = cont
            }
            // After resuming, check if we were cancelled / failed while waiting.
            if finished || error != nil { return }
        }

        buffer.append(chunk)

        // If a consumer is waiting, wake it with the chunk we just added.
        if let waiter = dequeueContinuation {
            dequeueContinuation = nil
            let item = buffer.removeFirst()
            waiter.resume(returning: item)
        }
    }

    /// Signal that all chunks have been produced.
    func finish() {
        finished = true
        // Wake a waiting consumer so it sees the end-of-stream.
        if let waiter = dequeueContinuation {
            dequeueContinuation = nil
            if buffer.isEmpty {
                waiter.resume(returning: nil)
            } else {
                let item = buffer.removeFirst()
                waiter.resume(returning: item)
            }
        }
        // Wake a waiting producer so it can exit.
        if let waiter = enqueueContinuation {
            enqueueContinuation = nil
            waiter.resume()
        }
    }

    /// Signal a producer-side error.  Drains the queue and wakes waiters.
    func fail(_ err: Error) {
        error = err
        finished = true
        buffer.removeAll()

        if let waiter = dequeueContinuation {
            dequeueContinuation = nil
            waiter.resume(returning: nil)
        }
        if let waiter = enqueueContinuation {
            enqueueContinuation = nil
            waiter.resume()
        }
    }

    // MARK: - Consumer API

    /// Dequeue the next chunk.  Returns `nil` when the stream is finished
    /// and the buffer is empty, or when a failure has been signaled.
    func dequeue() async -> FileChunk? {
        if let err = error { _ = err; return nil }

        if buffer.isEmpty {
            if finished { return nil }

            // Suspend consumer until a chunk is available (or stream ends).
            return await withCheckedContinuation { (cont: CheckedContinuation<FileChunk?, Never>) in
                dequeueContinuation = cont
            }
        }

        let item = buffer.removeFirst()

        // If a producer is waiting for space, wake it.
        if let waiter = enqueueContinuation {
            enqueueContinuation = nil
            waiter.resume()
        }

        return item
    }

    /// Returns the current error, if any.
    func currentError() -> Error? { error }

    /// Returns whether the queue has been marked as finished.
    func isFinished() -> Bool { finished }
}
