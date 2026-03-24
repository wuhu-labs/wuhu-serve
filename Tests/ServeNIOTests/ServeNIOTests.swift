#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import AsyncHTTPClient
import Fetch
import FetchAsyncHTTPClient
import ServeNIO
import Testing

@Suite(.serialized)
struct ServeNIOTests {
  @Test func servesOverTCPWithFetchAsyncHTTPClient() async throws {
    let listener = try await ServeNIOListener.bind(host: "127.0.0.1", port: 0) { request in
      let body = try await bodyText(request.body) ?? ""
      return Response(
        status: .ok,
        body: .chunk(Array("\(request.method.rawValue) \(request.url.path) \(body)".utf8))
      )
    }

    do {
      let port = try #require(listener.localAddress?.port)

      try await withHTTPClient { client in
        let request = Request(
          url: try #require(URL(string: "http://127.0.0.1:\(port)/echo")),
          method: .post,
          body: .chunks(
            [
              Array("hello".utf8),
              Array(" world".utf8),
            ],
            contentType: "text/plain"
          )
        )

        let response = try await FetchClient.asyncHTTPClient(client)(request).validateStatus()
        #expect(try await response.text() == "POST /echo hello world")
      }
    } catch {
      await listener.close()
      throw error
    }

    await listener.close()
  }
}

private func withHTTPClient(
  _ operation: (HTTPClient) async throws -> Void
) async throws {
  let client = HTTPClient(eventLoopGroupProvider: .singleton)
  do {
    try await operation(client)
    try await client.shutdown()
  } catch {
    try? await client.shutdown()
    throw error
  }
}

private func bodyText(_ body: Body?) async throws -> String? {
  guard let body else { return nil }
  return try await body.text()
}
