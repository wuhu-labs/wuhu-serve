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
import Serve
import ServeNIO
import Testing

@Suite(.serialized)
struct ServeNIOTests {
  @Test func bindsOnPortZeroExposesAssignedPortAndServesOverTCP() async throws {
    let recorder = HookRecorder()

    try await withTCPServer(hooks: recorder.hooks) { request in
      let body = try await bodyText(request.body) ?? ""
      return Response(
        status: .ok,
        body: .chunk(Array("\(request.method.rawValue) \(request.url.path) \(body)".utf8))
      )
    } operation: { server in
      let port = try #require(server.boundAddress.port)
      #expect(port > 0)
      #expect(recorder.snapshot().didBindAddresses == [String(describing: server.boundAddress)])

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
    }

    let snapshot = recorder.snapshot()
    #expect(snapshot.willShutdownAddresses.count == 1)
    #expect(snapshot.didShutdownAddresses.count == 1)
    #expect(snapshot.acceptedConnectionCount == 1)
    #expect(snapshot.startupFailures.isEmpty)
    #expect(snapshot.connectionErrors.isEmpty)
    #expect(snapshot.handlerErrors.isEmpty)
  }

  @Test func reportsStartupFailureThroughHooks() async throws {
    let firstServer = try await ServeNIOServer.bind(host: "127.0.0.1", port: 0) { _ in
      Response(status: .ok, body: .chunk(Array("ok".utf8)))
    }

    do {
      let port = try #require(firstServer.boundAddress.port)
      let recorder = HookRecorder()

      var didThrow = false
      do {
        let secondServer = try await ServeNIOServer.bind(
          host: "127.0.0.1",
          port: port,
          hooks: recorder.hooks
        ) { _ in
          Response(status: .ok, body: .chunk(Array("ok".utf8)))
        }
        await secondServer.shutdown()
      } catch {
        didThrow = true
      }

      #expect(didThrow)
      #expect(recorder.snapshot().startupFailures.count == 1)
      #expect(recorder.snapshot().didBindAddresses.isEmpty)
    } catch {
      await firstServer.shutdown()
      throw error
    }

    await firstServer.shutdown()
  }

  @Test func runUntilCancelledShutsTheServerDown() async throws {
    let recorder = HookRecorder()
    let server = try await ServeNIOServer.bind(host: "127.0.0.1", port: 0, hooks: recorder.hooks) { _ in
      Response(status: .ok, body: .chunk(Array("ok".utf8)))
    }

    let port = try #require(server.boundAddress.port)
    let task = Task {
      await server.runUntilCancelled()
    }

    await Task.yield()
    task.cancel()
    await task.value

    await expectTCPConnectionFailure(port: port)

    let snapshot = recorder.snapshot()
    #expect(snapshot.willShutdownAddresses.count == 1)
    #expect(snapshot.didShutdownAddresses.count == 1)
  }

  @Test func shutdownTerminatesActiveStreamingConnections() async throws {
    let recorder = HookRecorder()
    let controller = StreamingBodyController()
    let server = try await ServeNIOServer.bind(host: "127.0.0.1", port: 0, hooks: recorder.hooks) { _ in
      Response(
        status: .ok,
        body: .stream(contentType: "text/plain; charset=utf-8", controller.stream)
      )
    }

    let startedPromise = MultiThreadedEventLoopGroup.singleton.next().makePromise(of: String.self)
    let inactivePromise = MultiThreadedEventLoopGroup.singleton.next().makePromise(of: String.self)

    do {
      let port = try #require(server.boundAddress.port)
      let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .channelInitializer { channel in
          channel.pipeline.addHandler(
            StreamingResponseObserver(
              startedPromise: startedPromise,
              inactivePromise: inactivePromise,
              needle: "tick"
            )
          )
        }
        .connect(host: "127.0.0.1", port: port)
        .get()

      let request = rawRequest(path: "/stream")
      try await channel.writeAndFlush(channel.allocator.buffer(bytes: request))

      _ = try await withTimeout(seconds: 5) {
        try await startedPromise.futureResult.get()
      }

      async let shutdown: Void = server.shutdown()
      let finalResponse = try await withTimeout(seconds: 5) {
        try await inactivePromise.futureResult.get()
      }
      await shutdown
      controller.finish()

      #expect(finalResponse.contains("HTTP/1.1 200 OK\r\n"))
      #expect(finalResponse.contains("tick"))
    } catch {
      controller.finish()
      await server.shutdown()
      throw error
    }

    let snapshot = recorder.snapshot()
    #expect(snapshot.willShutdownAddresses.count == 1)
    #expect(snapshot.didShutdownAddresses.count == 1)
    #expect(snapshot.acceptedConnectionCount == 1)
  }

  @Test func reportsHandlerThrownErrorsWithoutSwallowingThem() async throws {
    enum HandlerFailure: Error {
      case boom
    }

    let recorder = HookRecorder()

    try await withTCPServer(hooks: recorder.hooks) { _ in
      throw HandlerFailure.boom
    } operation: { server in
      let port = try #require(server.boundAddress.port)
      let response = try await sendRawTCPRequest(port: port, request: rawRequest(path: "/boom"))
      #expect(response.contains("HTTP/1.1 500 Internal Server Error\r\n"))
      #expect(response.contains("500 Internal Server Error\n"))
    }

    let snapshot = recorder.snapshot()
    #expect(snapshot.handlerErrors.count == 1)
    #expect(snapshot.handlerErrors[0].contains("boom"))
    #expect(snapshot.connectionErrors.isEmpty)
  }

  @Test func malformedRequestsDoNotCrashTheServer() async throws {
    let recorder = HookRecorder()

    try await withTCPServer(hooks: recorder.hooks) { _ in
      Response(status: .ok, body: .chunk(Array("ok".utf8)))
    } operation: { server in
      let port = try #require(server.boundAddress.port)
      let malformedResponse = try await sendRawTCPRequest(
        port: port,
        request: Array("GET / HTTP/1.1\r\n\r\n".utf8)
      )
      #expect(malformedResponse.contains("HTTP/1.1 400 Bad Request\r\n"))

      try await withHTTPClient { client in
        let request = Request(url: try #require(URL(string: "http://127.0.0.1:\(port)/health")))
        let response = try await FetchClient.asyncHTTPClient(client)(request).validateStatus()
        #expect(try await response.text() == "ok")
      }
    }

    let snapshot = recorder.snapshot()
    #expect(snapshot.connectionErrors.isEmpty)
    #expect(snapshot.handlerErrors.isEmpty)
  }

  @Test func unixDomainSocketLifecycleWorks() async throws {
    let socketPath = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("sock")
      .path

    let recorder = HookRecorder()

    do {
      let server = try await ServeNIOServer.bind(unixDomainSocketPath: socketPath, hooks: recorder.hooks) {
        request in
        let body = try await bodyText(request.body) ?? ""
        return Response(
          status: .ok,
          body: .chunk(Array("\(request.method.rawValue) \(request.url.path) \(body)".utf8))
        )
      }

      do {
        let response = try await sendRawUnixDomainSocketRequest(
          socketPath: socketPath,
          request: rawRequest(path: "/echo", method: .post, body: "hello world")
        )
        #expect(response.contains("HTTP/1.1 200 OK\r\n"))
        #expect(response.contains("POST /echo hello world"))
        #expect(String(describing: server.boundAddress).contains(socketPath))
      } catch {
        await server.shutdown()
        throw error
      }

      await server.shutdown()
    } catch {
      try? FileManager.default.removeItem(atPath: socketPath)
      throw error
    }

    try? FileManager.default.removeItem(atPath: socketPath)

    let snapshot = recorder.snapshot()
    #expect(snapshot.didBindAddresses.count == 1)
    #expect(snapshot.willShutdownAddresses.count == 1)
    #expect(snapshot.didShutdownAddresses.count == 1)
    #expect(snapshot.acceptedConnectionCount == 1)
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

private final class StreamingResponseObserver: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer

  private var buffer = ByteBuffer()
  private var didObserveNeedle = false
  private let startedPromise: EventLoopPromise<String>
  private let inactivePromise: EventLoopPromise<String>
  private let needle: String

  init(
    startedPromise: EventLoopPromise<String>,
    inactivePromise: EventLoopPromise<String>,
    needle: String
  ) {
    self.startedPromise = startedPromise
    self.inactivePromise = inactivePromise
    self.needle = needle
  }

  func channelRead(context _: ChannelHandlerContext, data: NIOAny) {
    var data = self.unwrapInboundIn(data)
    self.buffer.writeBuffer(&data)

    guard !self.didObserveNeedle else {
      return
    }

    if let bytes = self.buffer.getBytes(at: 0, length: self.buffer.readableBytes) {
      let response = String(decoding: bytes, as: UTF8.self)
      if response.contains(self.needle) {
        self.didObserveNeedle = true
        self.startedPromise.succeed(response)
      }
    }
  }

  func channelInactive(context _: ChannelHandlerContext) {
    if let bytes = self.buffer.readBytes(length: self.buffer.readableBytes) {
      let response = String(decoding: bytes, as: UTF8.self)
      if !self.didObserveNeedle {
        self.startedPromise.succeed(response)
      }
      self.inactivePromise.succeed(response)
    } else {
      if !self.didObserveNeedle {
        self.startedPromise.succeed("")
      }
      self.inactivePromise.succeed("")
    }
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    self.startedPromise.fail(error)
    self.inactivePromise.fail(error)
    context.close(promise: nil)
  }
}

private final class HookRecorder: @unchecked Sendable {
  struct Snapshot {
    var didBindAddresses: [String] = []
    var startupFailures: [String] = []
    var willShutdownAddresses: [String] = []
    var didShutdownAddresses: [String] = []
    var acceptedConnectionCount = 0
    var connectionErrors: [String] = []
    var handlerErrors: [String] = []
  }

  private var lock = pthread_mutex_t()
  private var storage = Snapshot()

  init() {
    pthread_mutex_init(&self.lock, nil)
  }

  deinit {
    pthread_mutex_destroy(&self.lock)
  }

  var hooks: ServeNIOHooks {
    ServeNIOHooks(
      onDidBind: { [weak self] address in
        self?.withLock {
          $0.didBindAddresses.append(String(describing: address))
        }
      },
      onStartupFailure: { [weak self] error in
        self?.withLock {
          $0.startupFailures.append(String(describing: error))
        }
      },
      onWillShutdown: { [weak self] address in
        self?.withLock {
          $0.willShutdownAddresses.append(String(describing: address))
        }
      },
      onDidShutdown: { [weak self] address in
        self?.withLock {
          $0.didShutdownAddresses.append(String(describing: address))
        }
      },
      onDidAcceptConnection: { [weak self] _ in
        self?.withLock {
          $0.acceptedConnectionCount += 1
        }
      },
      onConnectionError: { [weak self] _, error in
        self?.withLock {
          $0.connectionErrors.append(String(describing: error))
        }
      },
      onHandlerError: { [weak self] _, error in
        self?.withLock {
          $0.handlerErrors.append(String(describing: error))
        }
      }
    )
  }

  func snapshot() -> Snapshot {
    self.lockState()
    defer { self.unlockState() }
    return self.storage
  }

  private func withLock(_ update: (inout Snapshot) -> Void) {
    self.lockState()
    update(&self.storage)
    self.unlockState()
  }

  private func lockState() {
    pthread_mutex_lock(&self.lock)
  }

  private func unlockState() {
    pthread_mutex_unlock(&self.lock)
  }
}

private final class StreamingBodyController: @unchecked Sendable {
  let stream: AsyncStream<[UInt8]>

  private let continuation: AsyncStream<[UInt8]>.Continuation
  private let producerTask: Task<Void, Never>

  init(intervalNanoseconds: UInt64 = 50_000_000) {
    var capturedContinuation: AsyncStream<[UInt8]>.Continuation?
    self.stream = AsyncStream { continuation in
      capturedContinuation = continuation
    }
    let continuation = capturedContinuation!
    self.continuation = continuation

    self.producerTask = Task {
      continuation.yield(Array("tick\n".utf8))
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: intervalNanoseconds)
        guard !Task.isCancelled else {
          break
        }
        continuation.yield(Array("tick\n".utf8))
      }
      continuation.finish()
    }
  }

  func finish() {
    self.producerTask.cancel()
    self.continuation.finish()
  }

  deinit {
    self.finish()
  }
}

private enum TimeoutError: Error {
  case timedOut(seconds: Double)
}

private func withTCPServer<T>(
  host: String = "127.0.0.1",
  port: Int = 0,
  hooks: ServeNIOHooks = .init(),
  handler: @escaping Handler,
  operation: (ServeNIOServer) async throws -> T
) async throws -> T {
  let server = try await ServeNIOServer.bind(
    host: host,
    port: port,
    hooks: hooks,
    handler: handler
  )

  do {
    let value = try await operation(server)
    await server.shutdown()
    return value
  } catch {
    await server.shutdown()
    throw error
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

private func sendRawTCPRequest(port: Int, request: [UInt8]) async throws -> String {
  let promise = MultiThreadedEventLoopGroup.singleton.next().makePromise(of: String.self)
  let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
    .channelInitializer { channel in
      channel.pipeline.addHandler(ResponseCollector(responsePromise: promise))
    }
    .connect(host: "127.0.0.1", port: port)
    .get()

  try await channel.writeAndFlush(channel.allocator.buffer(bytes: request))
  return try await withTimeout(seconds: 5) {
    try await promise.futureResult.get()
  }
}

private func sendRawUnixDomainSocketRequest(
  socketPath: String,
  request: [UInt8]
) async throws -> String {
  let promise = MultiThreadedEventLoopGroup.singleton.next().makePromise(of: String.self)
  let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
    .channelInitializer { channel in
      channel.pipeline.addHandler(ResponseCollector(responsePromise: promise))
    }
    .connect(unixDomainSocketPath: socketPath)
    .get()

  try await channel.writeAndFlush(channel.allocator.buffer(bytes: request))
  return try await withTimeout(seconds: 5) {
    try await promise.futureResult.get()
  }
}

private func rawRequest(
  path: String,
  method: Fetch.Method = .get,
  host: String = "local",
  body: String? = nil
) -> [UInt8] {
  let body = body.map { Array($0.utf8) } ?? []
  var request = "\(method.rawValue) \(path) HTTP/1.1\r\n"
  request += "Host: \(host)\r\n"
  if !body.isEmpty {
    request += "Content-Length: \(body.count)\r\n"
  }
  request += "\r\n"
  return Array(request.utf8) + body
}

private func expectTCPConnectionFailure(port: Int) async {
  var didFail = false

  do {
    let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .connect(host: "127.0.0.1", port: port)
      .get()
    try? await channel.close()
  } catch {
    didFail = true
  }

  #expect(didFail)
}

private func withTimeout<T: Sendable>(
  seconds: Double,
  operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask {
      try await operation()
    }
    group.addTask {
      try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      throw TimeoutError.timedOut(seconds: seconds)
    }

    let value = try await group.next()
    group.cancelAll()
    return try #require(value)
  }
}
