#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Fetch
import HTTPTypes
import ServeSSE
import Testing

@Suite struct ServeSSETests {
  @Test func eventSerializesFieldsAndMultilineData() {
    let event = SSEEvent.message(
      "hello\nworld",
      event: "message",
      id: "42",
      retry: 5000
    )

    #expect(
      event.serialized
        == "event: message\nid: 42\nretry: 5000\ndata: hello\ndata: world\n\n"
    )
  }

  @Test func commentSerializesAsHeartbeat() {
    let comment = SSEEvent.comment("keepalive")

    #expect(comment.serialized == ": keepalive\n\n")
  }

  @Test func responseSetsSSEHeadersAndStreamsEvents() async throws {
    let stream = AsyncStream<SSEEvent> { continuation in
      continuation.yield(SSEEvent.comment("tick"))
      continuation.yield(SSEEvent.message("payload", event: "update"))
      continuation.finish()
    }

    let response = Response.sse(stream)

    #expect(response.status == .ok)
    #expect(response.headers[HTTPField.Name.contentType] == "text/event-stream; charset=utf-8")
    #expect(response.headers[HTTPField.Name.cacheControl] == "no-cache")
    #expect(response.headers[sseXAccelBufferingHeaderName] == "no")

    let body = try await response.body.text()
    #expect(
      body
        == ": tick\n\nevent: update\ndata: payload\n\n"
    )
  }
}
