#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Fetch
import HTTPTypes
import Serve
import ServeTesting
import Testing

@Suite struct ServeTests {
  @Test func parsesContentLengthRequestAndWritesChunkedResponse() async throws {
    let connection = InMemoryConnection(
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
    let connection = InMemoryConnection(
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
    let connection = InMemoryConnection(
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
    let connection = InMemoryConnection(
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
    let connection = InMemoryConnection(
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
    let connection = InMemoryConnection(
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
    let connection = InMemoryConnection(
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
    let connection = InMemoryConnection(
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
    let connection = InMemoryConnection(
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

  @Test func streamedResponseFailureAfterHeadersDoesNotWriteSecondResponse() async throws {
    enum StreamFailure: Error {
      case boom
    }

    let connection = InMemoryConnection(
      inboundSegments: [
        Array("GET /stream HTTP/1.1\r\n".utf8),
        Array("Host: app.wuhu.test\r\n".utf8),
        Array("\r\n".utf8),
      ]
    )

    do {
      try await Serve.serve(connection: connection) { _ in
        Response(
          status: .ok,
          body: .stream(
            contentType: "text/plain; charset=utf-8",
            AsyncThrowingStream { continuation in
              continuation.yield(Array("hello".utf8))
              continuation.finish(throwing: StreamFailure.boom)
            }
          )
        )
      }
      Issue.record("Expected streamed response failure")
    } catch let error as StreamFailure {
      #expect(error == .boom)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    let response = connection.outputString()
    #expect(response.contains("HTTP/1.1 200 OK\r\n"))
    #expect(response.contains("transfer-encoding: chunked\r\n"))
    #expect(response.contains("5\r\nhello\r\n"))
    #expect(!response.contains("HTTP/1.1 500 Internal Server Error\r\n"))
    #expect(!response.contains("500 Internal Server Error\n"))
    #expect(!response.hasSuffix("0\r\n\r\n"))
  }

  @Test func rejectsTooManyHeaders() async throws {
    let options = ServeOptions(maximumHeaderCount: 1)
    let connection = InMemoryConnection(
      inboundSegments: [
        Array("GET / HTTP/1.1\r\n".utf8),
        Array("Host: app.wuhu.test\r\n".utf8),
        Array("X-Extra: value\r\n".utf8),
        Array("\r\n".utf8),
      ]
    )

    do {
      try await Serve.serve(connection: connection, options: options) { _ in
        Issue.record("Handler should not be invoked for invalid requests")
        return Response(status: .ok)
      }
      Issue.record("Expected too many headers error")
    } catch let error as ServeError {
      #expect(error == .tooManyHeaders(limit: 1))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    let response = connection.outputString()
    #expect(response.contains("HTTP/1.1 431 Request Header Fields Too Large\r\n"))
  }

  @Test func rejectsOverlongHeaderLines() async throws {
    let options = ServeOptions(maximumHeaderLineBytes: 16)
    let connection = InMemoryConnection(
      inboundSegments: [
        Array("GET / HTTP/1.1\r\n".utf8),
        Array("Host: app.wuhu.test\r\n".utf8),
        Array("\r\n".utf8),
      ]
    )

    do {
      try await Serve.serve(connection: connection, options: options) { _ in
        Issue.record("Handler should not be invoked for invalid requests")
        return Response(status: .ok)
      }
      Issue.record("Expected header line too large error")
    } catch let error as ServeError {
      #expect(error == .headerLineTooLarge(limit: 16))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    let response = connection.outputString()
    #expect(response.contains("HTTP/1.1 431 Request Header Fields Too Large\r\n"))
  }

  @Test func rejectsFoldedHeaderLines() async throws {
    let connection = InMemoryConnection(
      inboundSegments: [
        Array("GET / HTTP/1.1\r\n".utf8),
        Array("Host: app.wuhu.test\r\n".utf8),
        Array(" X-Extra: value\r\n".utf8),
        Array("\r\n".utf8),
      ]
    )

    do {
      try await Serve.serve(connection: connection) { _ in
        Issue.record("Handler should not be invoked for invalid requests")
        return Response(status: .ok)
      }
      Issue.record("Expected invalid header line error")
    } catch let error as ServeError {
      #expect(error == .invalidHeaderLine)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    let response = connection.outputString()
    #expect(response.contains("HTTP/1.1 400 Bad Request\r\n"))
  }

  @Test func rejectsOriginFormTargetsWithoutLeadingSlash() async throws {
    let connection = InMemoryConnection(
      inboundSegments: [
        Array("GET hello HTTP/1.1\r\n".utf8),
        Array("Host: app.wuhu.test\r\n".utf8),
        Array("\r\n".utf8),
      ]
    )

    do {
      try await Serve.serve(connection: connection) { _ in
        Issue.record("Handler should not be invoked for invalid requests")
        return Response(status: .ok)
      }
      Issue.record("Expected invalid request target error")
    } catch let error as ServeError {
      #expect(error == .invalidRequestTarget("hello"))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    let response = connection.outputString()
    #expect(response.contains("HTTP/1.1 400 Bad Request\r\n"))
  }

  @Test func rejectsTargetsWithFragments() async throws {
    let connection = InMemoryConnection(
      inboundSegments: [
        Array("GET /runner#frag HTTP/1.1\r\n".utf8),
        Array("Host: app.wuhu.test\r\n".utf8),
        Array("\r\n".utf8),
      ]
    )

    do {
      try await Serve.serve(connection: connection) { _ in
        Issue.record("Handler should not be invoked for invalid requests")
        return Response(status: .ok)
      }
      Issue.record("Expected invalid request target error")
    } catch let error as ServeError {
      #expect(error == .invalidRequestTarget("/runner#frag"))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    let response = connection.outputString()
    #expect(response.contains("HTTP/1.1 400 Bad Request\r\n"))
  }

  @Test func rejectsInvalidHTTPMethodTokens() async throws {
    let connection = InMemoryConnection(
      inboundSegments: [
        Array("GE(T / HTTP/1.1\r\n".utf8),
        Array("Host: app.wuhu.test\r\n".utf8),
        Array("\r\n".utf8),
      ]
    )

    do {
      try await Serve.serve(connection: connection) { _ in
        Issue.record("Handler should not be invoked for invalid requests")
        return Response(status: .ok)
      }
      Issue.record("Expected invalid request line error")
    } catch let error as ServeError {
      #expect(error == .invalidRequestLine)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    let response = connection.outputString()
    #expect(response.contains("HTTP/1.1 400 Bad Request\r\n"))
  }
}

private func bodyText(_ body: Body?) async throws -> String? {
  guard let body else { return nil }
  return try await body.text()
}
