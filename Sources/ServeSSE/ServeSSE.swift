#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Fetch
import HTTPTypes
import Serve

public struct SSEEvent: Sendable, Equatable {
  public var event: String?
  public var id: String?
  public var retry: Int?
  public var data: [String]
  public var comment: [String]

  public init(
    event: String? = nil,
    id: String? = nil,
    retry: Int? = nil,
    data: [String] = [],
    comment: [String] = []
  ) {
    self.event = event
    self.id = id
    self.retry = retry
    self.data = data
    self.comment = comment
  }

  public static func message(
    _ string: String,
    event: String? = nil,
    id: String? = nil,
    retry: Int? = nil
  ) -> Self {
    Self(
      event: event,
      id: id,
      retry: retry,
      data: sseLines(for: string)
    )
  }

  public static func comment(_ string: String = "") -> Self {
    Self(comment: sseLines(for: string))
  }

  public var bytes: Bytes {
    Array(self.serialized.utf8)
  }

  public var serialized: String {
    var lines: [String] = []

    for comment in self.comment {
      lines.append(comment.isEmpty ? ":" : ": \(comment)")
    }

    if let event = self.event {
      lines.append("event: \(event)")
    }

    if let id = self.id {
      lines.append("id: \(id)")
    }

    if let retry = self.retry {
      lines.append("retry: \(retry)")
    }

    for dataLine in self.data {
      lines.append("data: \(dataLine)")
    }

    return lines.joined(separator: "\n") + "\n\n"
  }
}

extension Response {
  public static func sse<S: AsyncSequence & Sendable>(
    _ events: S,
    status: Status = .ok,
    headers: Headers = Headers()
  ) -> Self where S.Element == SSEEvent {
    var responseHeaders = headers
    if responseHeaders[.contentType] == nil {
      responseHeaders[.contentType] = "text/event-stream; charset=utf-8"
    }
    if responseHeaders[.cacheControl] == nil {
      responseHeaders[.cacheControl] = "no-cache"
    }
    if responseHeaders[sseXAccelBufferingHeaderName] == nil {
      responseHeaders[sseXAccelBufferingHeaderName] = "no"
    }

    return Self(
      status: status,
      headers: responseHeaders,
      body: .stream(
        contentType: responseHeaders[.contentType],
        SSEBodySequence(base: events)
      )
    )
  }
}

public let sseXAccelBufferingHeaderName = HTTPField.Name("x-accel-buffering")!

private struct SSEBodySequence<Base: AsyncSequence & Sendable>: AsyncSequence, Sendable
where Base.Element == SSEEvent {
  typealias Element = Bytes

  let base: Base

  func makeAsyncIterator() -> Iterator {
    Iterator(base: self.base.makeAsyncIterator())
  }

  struct Iterator: AsyncIteratorProtocol {
    var base: Base.AsyncIterator

    mutating func next() async throws -> Bytes? {
      guard let event = try await self.base.next() else {
        return nil
      }
      return event.bytes
    }
  }
}

private func sseLines(for string: String) -> [String] {
  string.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
}
