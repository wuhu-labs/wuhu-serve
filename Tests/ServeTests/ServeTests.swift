#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Fetch
import HTTPTypes
import Serve
import Testing

@Suite struct ServeTests {
  @Test func parsesContentLengthRequestAndWritesChunkedResponse() async throws {
    let connection = TestConnection(
      inboundSegments: [
        Array("POST /runner HTTP/1.1\r\n".utf8),
        Array("Host: app.wuhu.test\r\n".utf8),
        Array("Content-Length: 11\r\n".utf8),
        Array("Content-Type: text/plain\r\n".utf8),
        Array("\r\nhello ".utf8),
        Array("world".utf8),
      ]
    )

    try await Serve.serve(connection: connection) { request in
      #expect(request.method == .post)
      #expect(request.url.absoluteString == "http://app.wuhu.test/runner")
      #expect(request.body?.contentType == "text/plain")
      let requestBody = try await bodyText(request.body?.stream)
      #expect(requestBody == "hello world")

      return Response(status: .ok, body: .chunks([
        Array("hello".utf8),
        Array(" world".utf8),
      ]))
    }

    let response = connection.outputString()
    #expect(response.contains("HTTP/1.1 200 OK\r\n"))
    #expect(response.contains("transfer-encoding: chunked\r\n"))
    #expect(response.contains("connection: close\r\n"))
    #expect(response.contains("5\r\nhello\r\n"))
    #expect(response.contains("6\r\n world\r\n"))
    #expect(response.hasSuffix("0\r\n\r\n"))
  }

  @Test func parsesChunkedRequestBodies() async throws {
    let connection = TestConnection(
      inboundSegments: [
        Array("POST /events HTTP/1.1\r\n".utf8),
        Array("Host: runner.wuhu.test\r\n".utf8),
        Array("Transfer-Encoding: chunked\r\n".utf8),
        Array("\r\n".utf8),
        Array("5\r\nhello\r\n".utf8),
        Array("6\r\n world\r\n".utf8),
        Array("0\r\n\r\n".utf8),
      ]
    )

    try await Serve.serve(connection: connection) { request in
      let requestBody = try await bodyText(request.body?.stream)
      #expect(requestBody == "hello world")
      return Response(status: .accepted)
    }

    let response = connection.outputString()
    #expect(response.contains("HTTP/1.1 202 Accepted\r\n"))
  }

  @Test func returnsBadRequestForMissingHost() async {
    let connection = TestConnection(
      inboundSegments: [
        Array("GET / HTTP/1.1\r\n".utf8),
        Array("\r\n".utf8),
      ]
    )

    do {
      try await Serve.serve(connection: connection) { _ in
        Issue.record("Handler should not be invoked for invalid requests")
        return Response(status: .ok)
      }
      Issue.record("Expected missing host error")
    } catch let error as ServeError {
      #expect(error == .missingHostHeader)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    let response = connection.outputString()
    #expect(response.contains("HTTP/1.1 400 Bad Request\r\n"))
  }

  @Test func preservesExplicitContentLengthResponses() async throws {
    let connection = TestConnection(
      inboundSegments: [
        Array("GET /fixed HTTP/1.1\r\n".utf8),
        Array("Host: fixed.wuhu.test\r\n".utf8),
        Array("\r\n".utf8),
      ]
    )

    try await Serve.serve(connection: connection) { _ in
      var headers = Headers()
      headers.append(HTTPField(name: .contentLength, value: "5"))
      return Response(status: .ok, headers: headers, body: .chunk(Array("hello".utf8)))
    }

    let response = connection.outputString()
    #expect(response.contains("content-length: 5\r\n"))
    #expect(!response.contains("transfer-encoding: chunked\r\n"))
    #expect(response.hasSuffix("hello"))
  }

  @Test func doesNotReadRequestBodyUnlessHandlerConsumesIt() async throws {
    let connection = LazyBodyConnection(
      head: Array("POST /lazy HTTP/1.1\r\nHost: lazy.wuhu.test\r\nContent-Length: 11\r\n\r\n".utf8)
    )

    try await Serve.serve(connection: connection) { _ in
      Response(status: .ok, body: .chunk(Array("done".utf8)))
    }

    #expect(connection.readCount == 1)
    let response = connection.outputString()
    #expect(response.contains("HTTP/1.1 200 OK\r\n"))
    #expect(response.hasSuffix("4\r\ndone\r\n0\r\n\r\n"))
  }

  @Test func doesNotReadChunkedRequestBodyUnlessHandlerConsumesIt() async throws {
    let connection = LazyBodyConnection(
      head: Array(
        "POST /lazy-chunked HTTP/1.1\r\nHost: lazy.wuhu.test\r\nTransfer-Encoding: chunked\r\n\r\n"
          .utf8
      )
    )

    try await Serve.serve(connection: connection) { _ in
      Response(status: .ok, body: .chunk(Array("done".utf8)))
    }

    #expect(connection.readCount == 1)
    let response = connection.outputString()
    #expect(response.contains("HTTP/1.1 200 OK\r\n"))
    #expect(response.hasSuffix("4\r\ndone\r\n0\r\n\r\n"))
  }
}

private final class TestConnection: @unchecked Sendable, ServeConnection {
  private var inboundSegments: [[UInt8]]
  private var outbound: [UInt8] = []
  private(set) var isClosed = false

  init(inboundSegments: [[UInt8]]) {
    self.inboundSegments = inboundSegments
  }

  func read(into buffer: UnsafeMutableRawBufferPointer) async throws -> Int {
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

  func write(contentsOf bytes: [UInt8]) async throws {
    self.outbound.append(contentsOf: bytes)
  }

  func close() async {
    self.isClosed = true
  }

  func outputString() -> String {
    String(decoding: self.outbound, as: UTF8.self)
  }
}

private func bodyText(_ body: BodyStream?) async throws -> String? {
  guard let body else { return nil }
  return try await Response(status: .ok, body: body).text()
}

private final class LazyBodyConnection: @unchecked Sendable, ServeConnection {
  private let head: [UInt8]
  private(set) var readCount = 0
  private var outbound: [UInt8] = []

  init(head: [UInt8]) {
    self.head = head
  }

  func read(into buffer: UnsafeMutableRawBufferPointer) async throws -> Int {
    self.readCount += 1

    if self.readCount == 1 {
      let count = min(buffer.count, self.head.count)
      self.head.prefix(count).withUnsafeBytes { source in
        buffer.copyBytes(from: source)
      }
      return count
    }

    throw UnexpectedRead()
  }

  func write(contentsOf bytes: [UInt8]) async throws {
    self.outbound.append(contentsOf: bytes)
  }

  func close() async {}

  func outputString() -> String {
    String(decoding: self.outbound, as: UTF8.self)
  }

  private struct UnexpectedRead: Error {}
}
