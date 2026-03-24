#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import AsyncHTTPClient
import Fetch
import FetchAsyncHTTPClient
import NIOCore
import NIOPosix
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

  @Test func servesOverUnixDomainSocket() async throws {
    let socketPath = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("sock")
      .path

    let listener = try await ServeNIOListener.bind(unixDomainSocketPath: socketPath) { request in
      let body = try await bodyText(request.body) ?? ""
      return Response(
        status: .ok,
        body: .chunk(Array("\(request.method.rawValue) \(request.url.path) \(body)".utf8))
      )
    }

    let promise = MultiThreadedEventLoopGroup.singleton.next().makePromise(of: String.self)

    do {
      let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .channelInitializer { channel in
          channel.pipeline.addHandler(ResponseCollector(responsePromise: promise))
        }
        .connect(unixDomainSocketPath: socketPath)
        .get()

      let request = Array("""
        POST /echo HTTP/1.1\r
        Host: local\r
        Content-Length: 11\r
        \r
        hello world
        """.utf8)
      try await channel.writeAndFlush(channel.allocator.buffer(bytes: request))

      let response = try await promise.futureResult.get()
      #expect(response.contains("HTTP/1.1 200 OK\r\n"))
      #expect(response.contains("POST /echo hello world"))
    } catch {
      await listener.close()
      try? FileManager.default.removeItem(atPath: socketPath)
      throw error
    }

    await listener.close()
    try? FileManager.default.removeItem(atPath: socketPath)
  }
}

private final class ResponseCollector: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer

  private var buffer = ByteBuffer()
  private let responsePromise: EventLoopPromise<String>

  init(responsePromise: EventLoopPromise<String>) {
    self.responsePromise = responsePromise
  }

  func channelRead(context _: ChannelHandlerContext, data: NIOAny) {
    var data = self.unwrapInboundIn(data)
    self.buffer.writeBuffer(&data)
  }

  func channelInactive(context _: ChannelHandlerContext) {
    if let bytes = self.buffer.readBytes(length: self.buffer.readableBytes) {
      self.responsePromise.succeed(String(decoding: bytes, as: UTF8.self))
    } else {
      self.responsePromise.succeed("")
    }
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    self.responsePromise.fail(error)
    context.close(promise: nil)
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
