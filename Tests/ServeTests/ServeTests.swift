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
      let requestBody = try await bodyText(request.body)
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
      let requestBody = try await bodyText(request.body)
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

  @Test func requiresRequestBodyToBeResolvedBeforeSuccess() async throws {
    let connection = TestConnection(
      inboundSegments: [
        Array("POST /skip HTTP/1.1\r\n".utf8),
        Array("Host: app.wuhu.test\r\n".utf8),
        Array("Content-Length: 5\r\n".utf8),
        Array("\r\nhello".utf8),
      ]
    )

    do {
      try await Serve.serve(connection: connection) { _ in
        Response(status: .ok)
      }
      Issue.record("Expected unresolved request body error")
    } catch let error as ServeError {
      #expect(error == .unresolvedRequestBody)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    let response = connection.outputString()
    #expect(response.contains("HTTP/1.1 500 Internal Server Error\r\n"))
  }

  @Test func discardBodyAllowsIgnoringRequestBody() async throws {
    let connection = TestConnection(
      inboundSegments: [
        Array("POST /skip HTTP/1.1\r\n".utf8),
        Array("Host: app.wuhu.test\r\n".utf8),
        Array("Transfer-Encoding: chunked\r\n".utf8),
        Array("\r\n5\r\nhello\r\n0\r\n\r\n".utf8),
      ]
    )

    try await Serve.serve(connection: connection) { request in
      try await request.discardBody()
      return Response(status: .ok, body: .chunk(Array("done".utf8)))
    }

    let response = connection.outputString()
    #expect(response.contains("HTTP/1.1 200 OK\r\n"))
    #expect(response.hasSuffix("4\r\ndone\r\n0\r\n\r\n"))
  }

  @Test func requireNoBodyReturnsBadRequest() async throws {
    let connection = TestConnection(
      inboundSegments: [
        Array("POST /skip HTTP/1.1\r\n".utf8),
        Array("Host: app.wuhu.test\r\n".utf8),
        Array("Content-Length: 5\r\n".utf8),
        Array("\r\nhello".utf8),
      ]
    )

    do {
      try await Serve.serve(connection: connection) { request in
        try request.requireNoBody()
        return Response(status: .ok)
      }
      Issue.record("Expected unexpected request body error")
    } catch let error as ServeError {
      #expect(error == .unexpectedRequestBody)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    let response = connection.outputString()
    #expect(response.contains("HTTP/1.1 400 Bad Request\r\n"))
  }

  @Test func partialAsyncBytesConsumptionStillFailsHandler() async throws {
    let connection = TestConnection(
      inboundSegments: [
        Array("POST /skip HTTP/1.1\r\n".utf8),
        Array("Host: app.wuhu.test\r\n".utf8),
        Array("Transfer-Encoding: chunked\r\n".utf8),
        Array("\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".utf8),
      ]
    )

    do {
      try await Serve.serve(connection: connection) { request in
        var iterator = request.body?.asyncBytes().makeAsyncIterator()
        _ = try await iterator?.next()
        return Response(status: .ok)
      }
      Issue.record("Expected unresolved request body error")
    } catch let error as ServeError {
      #expect(error == .unresolvedRequestBody)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    let response = connection.outputString()
    #expect(response.contains("HTTP/1.1 500 Internal Server Error\r\n"))
  }

  @Test func discardingMalformedChunkedRequestReturnsBadRequest() async throws {
    let connection = TestConnection(
      inboundSegments: [
        Array("POST /skip HTTP/1.1\r\n".utf8),
        Array("Host: app.wuhu.test\r\n".utf8),
        Array("Transfer-Encoding: chunked\r\n".utf8),
        Array("\r\nzz\r\nhello\r\n0\r\n\r\n".utf8),
      ]
    )

    do {
      try await Serve.serve(connection: connection) { request in
        try await request.discardBody()
        return Response(status: .ok)
      }
      Issue.record("Expected invalid chunk size error")
    } catch let error as ServeError {
      #expect(error == .invalidChunkSize)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    let response = connection.outputString()
    #expect(response.contains("HTTP/1.1 400 Bad Request\r\n"))
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

private func bodyText(_ body: Body?) async throws -> String? {
  guard let body else { return nil }
  return try await body.text()
}
