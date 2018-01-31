import Async
import Dispatch
import Foundation

private let maxExcessSignalCount: Int = 2

/// Data stream wrapper for a dispatch socket.
public final class TLSSocketSink<Socket>: Async.InputStream where Socket: TLSSocket {
    /// See InputStream.Input
    public typealias Input = UnsafeBufferPointer<UInt8>

    /// The client stream's underlying socket.
    public var socket: Socket

    /// Data being fed into the client stream is stored here.
    private var inputBuffer: UnsafeBufferPointer<UInt8>?

    /// Stores write event source.
    private var writeSource: EventSource?

    /// A strong reference to the current eventloop
    private var eventLoop: EventLoop

    /// True if this sink has been closed
    private var isClosed: Bool

    /// Currently waiting done callback
    private var currentReadyPromise: Promise<Void>?

    /// If true, the read source has been suspended
    private var sourceIsSuspended: Bool

    /// The current number of signals received while downstream was not ready
    /// since it was last ready
    private var excessSignalCount: Int

    /// Creates a new `SocketSink`
    internal init(socket: Socket, on worker: Worker) {
        self.socket = socket
        self.eventLoop = worker.eventLoop
        self.inputBuffer = nil
        self.isClosed = false
        self.sourceIsSuspended = true
        self.excessSignalCount = 0
        let writeSource = self.eventLoop.onWritable(descriptor: socket.descriptor, writeSourceSignal)
        self.writeSource = writeSource
    }

    /// See InputStream.input
    public func input(_ event: InputEvent<UnsafeBufferPointer<UInt8>>) {
        // update variables
        switch event {
        case .next(let input, let ready):
            guard inputBuffer == nil else {
                fatalError("SocketSink upstream is illegally overproducing input buffers.")
            }
            inputBuffer = input
            guard currentReadyPromise == nil else {
                fatalError("SocketSink currentReadyPromise illegally not nil during input.")
            }
            currentReadyPromise = ready
            resumeIfSuspended()
        case .close:
            close()
        case .error(let e):
            close()
            fatalError("\(e)")
        }
    }

    /// Cancels reading
    public func close() {
        guard !isClosed else {
            return
        }
        guard let writeSource = self.writeSource else {
            fatalError("SocketSink writeSource illegally nil during close.")
        }
        writeSource.cancel()
        socket.close()
        self.writeSource = nil
        isClosed = true
    }

    /// Writes the buffered data to the socket.
    private func writeData(ready: Promise<Void>) {
        do {
            guard let buffer = self.inputBuffer else {
                fatalError("Unexpected nil SocketSink inputBuffer during writeData")
            }

            let write = try socket.write(from: buffer)
            switch write {
            case .success(let count):
                switch count {
                case buffer.count:
                    self.inputBuffer = nil
                    ready.complete()
                default:
                    inputBuffer = UnsafeBufferPointer<UInt8>(
                        start: buffer.baseAddress?.advanced(by: count),
                        count: buffer.count - count
                    )
                    writeData(ready: ready)
                }
            case .wouldBlock:
                resumeIfSuspended()
                guard currentReadyPromise == nil else {
                    fatalError("SocketSink currentReadyPromise illegally not nil during wouldBlock.")
                }
                currentReadyPromise = ready
            }
        } catch {
            self.error(error)
            ready.complete()
        }
    }

    /// Called when the write source signals.
    private func writeSourceSignal(isCancelled: Bool) {
        guard !isCancelled else {
            // source is cancelled, we will never receive signals again
            close()
            return
        }

        if !socket.handshakeIsComplete {
            try! socket.handshake()
            return
        }

        guard inputBuffer != nil else {
            // no data ready for socket yet
            excessSignalCount = excessSignalCount &+ 1
            if excessSignalCount >= maxExcessSignalCount {
                guard let writeSource = self.writeSource else {
                    fatalError("SocketSink writeSource illegally nil during signal.")
                }
                writeSource.suspend()
                sourceIsSuspended = true
            }
            return
        }

        guard let ready = currentReadyPromise else {
            fatalError("SocketSink currentReadyPromise illegaly nil during signal.")
        }
        currentReadyPromise = nil
        writeData(ready: ready)
    }

    private func resumeIfSuspended() {
        guard sourceIsSuspended else {
            return
        }

        guard let writeSource = self.writeSource else {
            fatalError("SocketSink writeSource illegally nil during resumeIfSuspended.")
        }
        sourceIsSuspended = false
        // start listening for ready notifications
        writeSource.resume()
    }
}

/// MARK: Create

extension TLSSocket {
    /// Creates a data stream for this socket on the supplied event loop.
    public func sink(on eventLoop: Worker) -> TLSSocketSink<Self> {
        return .init(socket: self, on: eventLoop)
    }
}

