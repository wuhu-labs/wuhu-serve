import Foundation

import Fetch
import Serve

public final class InMemoryConnection: ServeConnection, @unchecked Sendable {
  private let lock = NSLock()
  private var inboundSegments: [Bytes]
  private var outbound: Bytes = []
  private var didClose = false

  public init(inboundSegments: [Bytes] = []) {
    self.inboundSegments = inboundSegments
  }

  public convenience init(inbound: Bytes) {
    self.init(inboundSegments: [inbound])
  }

  public func appendInboundSegment(_ bytes: Bytes) {
    self.lock.withLock {
      self.inboundSegments.append(bytes)
    }
  }

  public func read(into buffer: UnsafeMutableRawBufferPointer) async throws -> Int {
    self.lock.withLock {
      guard !self.inboundSegments.isEmpty else { return 0 }

      let segment = self.inboundSegments.removeFirst()
      let count = min(buffer.count, segment.count)
      segment.prefix(count).withUnsafeBytes { source in
        buffer.copyBytes(from: source)
      }

      if count < segment.count {
        self.inboundSegments.insert(Array(segment.dropFirst(count)), at: 0)
      }

      return count
    }
  }

  public func write(contentsOf bytes: Bytes) async throws {
    self.lock.withLock {
      self.outbound.append(contentsOf: bytes)
    }
  }

  public func close() async {
    self.lock.withLock {
      self.didClose = true
    }
  }

  public var isClosed: Bool {
    self.lock.withLock {
      self.didClose
    }
  }

  public func outputBytes() -> Bytes {
    self.lock.withLock {
      self.outbound
    }
  }

  public func outputString() -> String {
    self.lock.withLock {
      String(decoding: self.outbound, as: UTF8.self)
    }
  }
}
