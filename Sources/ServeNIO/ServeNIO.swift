import Fetch
import NIOCore
import NIOPosix
import Serve

public struct ServeNIOConnectionContext: Sendable {
  public var localAddress: SocketAddress?
  public var remoteAddress: SocketAddress?

  public init(
    localAddress: SocketAddress? = nil,
    remoteAddress: SocketAddress? = nil
  ) {
    self.localAddress = localAddress
    self.remoteAddress = remoteAddress
  }
}

public struct ServeNIOHooks: Sendable {
  public var onDidBind: @Sendable (SocketAddress) -> Void
  public var onStartupFailure: @Sendable (any Error) -> Void
  public var onWillShutdown: @Sendable (SocketAddress) -> Void
  public var onDidShutdown: @Sendable (SocketAddress) -> Void
  public var onDidAcceptConnection: @Sendable (ServeNIOConnectionContext) -> Void
  public var onConnectionError: @Sendable (ServeNIOConnectionContext, any Error) -> Void
  public var onHandlerError: @Sendable (ServeNIOConnectionContext, any Error) -> Void

  public init(
    onDidBind: @escaping @Sendable (SocketAddress) -> Void = { _ in },
    onStartupFailure: @escaping @Sendable (any Error) -> Void = { _ in },
    onWillShutdown: @escaping @Sendable (SocketAddress) -> Void = { _ in },
    onDidShutdown: @escaping @Sendable (SocketAddress) -> Void = { _ in },
    onDidAcceptConnection: @escaping @Sendable (ServeNIOConnectionContext) -> Void = { _ in },
    onConnectionError: @escaping @Sendable (ServeNIOConnectionContext, any Error) -> Void = { _, _ in },
    onHandlerError: @escaping @Sendable (ServeNIOConnectionContext, any Error) -> Void = { _, _ in }
  ) {
    self.onDidBind = onDidBind
    self.onStartupFailure = onStartupFailure
    self.onWillShutdown = onWillShutdown
    self.onDidShutdown = onDidShutdown
    self.onDidAcceptConnection = onDidAcceptConnection
    self.onConnectionError = onConnectionError
    self.onHandlerError = onHandlerError
  }
}

public final class ServeNIOServer: @unchecked Sendable {
  public let boundAddress: SocketAddress

  private let serverChannel: Channel
  private let hooks: ServeNIOHooks
  private let state: ServeNIOServerState

  public var localAddress: SocketAddress? {
    self.boundAddress
  }

  private init(
    serverChannel: Channel,
    boundAddress: SocketAddress,
    hooks: ServeNIOHooks,
    state: ServeNIOServerState
  ) {
    self.serverChannel = serverChannel
    self.boundAddress = boundAddress
    self.hooks = hooks
    self.state = state
  }

  /// Like `bind(host:port:options:hooks:eventLoopGroup:handler:)` but the handler
  /// may request a WebSocket upgrade. When the handler returns `.websocket`,
  /// the connection is handed off to `onUpgrade` instead of being closed.
  ///
  /// - Parameters:
  ///   - host: The host to bind.
  ///   - port: The port to bind.
  ///   - options: HTTP parsing / serialization limits.
  ///   - hooks: Lifecycle and error observation callbacks.
  ///   - eventLoopGroup: The NIO event loop group.
  ///   - handler: Called with the parsed request; returns either a normal HTTP
  ///     response or a WebSocket upgrade intent.
  ///   - onUpgrade: Called with the raw connection after the 101 handshake.
  ///     The caller owns the connection from that point on.
  public static func bindUpgradable(
    host: String = "127.0.0.1",
    port: Int,
    options: ServeOptions = .init(),
    hooks: ServeNIOHooks = .init(),
    eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
    handler: @escaping @Sendable (Request) async throws -> UpgradeResult,
    onUpgrade: @escaping @Sendable (any ServeConnection) async -> Void
  ) async throws -> Self {
    let state = ServeNIOServerState()
    let bootstrap = self.makeUpgradableBootstrap(
      eventLoopGroup: eventLoopGroup,
      options: options,
      hooks: hooks,
      state: state,
      handler: handler,
      onUpgrade: onUpgrade,
    )

    do {
      let serverChannel = try await bootstrap.bind(host: host, port: port).get()
      guard let boundAddress = serverChannel.localAddress else {
        try? await serverChannel.close()
        throw BindError.missingBoundAddress
      }
      let server = Self(
        serverChannel: serverChannel,
        boundAddress: boundAddress,
        hooks: hooks,
        state: state,
      )
      hooks.onDidBind(boundAddress)
      return server
    } catch {
      hooks.onStartupFailure(error)
      throw error
    }
  }

  /// Like `bindUpgradable(host:port:options:hooks:eventLoopGroup:handler:onUpgrade:)`
  /// but binds to a Unix domain socket.
  public static func bindUpgradable(
    unixDomainSocketPath: String,
    options: ServeOptions = .init(),
    hooks: ServeNIOHooks = .init(),
    eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
    handler: @escaping @Sendable (Request) async throws -> UpgradeResult,
    onUpgrade: @escaping @Sendable (any ServeConnection) async -> Void
  ) async throws -> Self {
    let state = ServeNIOServerState()
    let bootstrap = self.makeUpgradableBootstrap(
      eventLoopGroup: eventLoopGroup,
      options: options,
      hooks: hooks,
      state: state,
      handler: handler,
      onUpgrade: onUpgrade,
    )

    do {
      let serverChannel = try await bootstrap.bind(unixDomainSocketPath: unixDomainSocketPath).get()
      guard let boundAddress = serverChannel.localAddress else {
        try? await serverChannel.close()
        throw BindError.missingBoundAddress
      }
      let server = Self(
        serverChannel: serverChannel,
        boundAddress: boundAddress,
        hooks: hooks,
        state: state,
      )
      hooks.onDidBind(boundAddress)
      return server
    } catch {
      hooks.onStartupFailure(error)
      throw error
    }
  }

  public static func bind(
    host: String = "127.0.0.1",
    port: Int,
    options: ServeOptions = .init(),
    hooks: ServeNIOHooks = .init(),
    eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
    handler: @escaping Handler
  ) async throws -> Self {
    let state = ServeNIOServerState()
    let bootstrap = self.makeBootstrap(
      eventLoopGroup: eventLoopGroup,
      options: options,
      hooks: hooks,
      state: state,
      handler: handler
    )

    do {
      let serverChannel = try await bootstrap.bind(host: host, port: port).get()
      guard let boundAddress = serverChannel.localAddress else {
        try? await serverChannel.close()
        throw BindError.missingBoundAddress
      }
      let server = Self(
        serverChannel: serverChannel,
        boundAddress: boundAddress,
        hooks: hooks,
        state: state
      )
      hooks.onDidBind(boundAddress)
      return server
    } catch {
      hooks.onStartupFailure(error)
      throw error
    }
  }

  public static func bind(
    unixDomainSocketPath: String,
    options: ServeOptions = .init(),
    hooks: ServeNIOHooks = .init(),
    eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
    handler: @escaping Handler
  ) async throws -> Self {
    let state = ServeNIOServerState()
    let bootstrap = self.makeBootstrap(
      eventLoopGroup: eventLoopGroup,
      options: options,
      hooks: hooks,
      state: state,
      handler: handler
    )

    do {
      let serverChannel = try await bootstrap.bind(unixDomainSocketPath: unixDomainSocketPath).get()
      guard let boundAddress = serverChannel.localAddress else {
        try? await serverChannel.close()
        throw BindError.missingBoundAddress
      }
      let server = Self(
        serverChannel: serverChannel,
        boundAddress: boundAddress,
        hooks: hooks,
        state: state
      )
      hooks.onDidBind(boundAddress)
      return server
    } catch {
      hooks.onStartupFailure(error)
      throw error
    }
  }

  /// Waits until the server finishes shutting down.
  ///
  /// If the server is already shut down this returns immediately.
  public func waitUntilShutdown() async {
    await self.state.waitUntilShutdown()
  }

  /// Keeps the server alive until it is explicitly shut down or the surrounding task is cancelled.
  ///
  /// Cancelling the surrounding task triggers `shutdown()` and this method returns only after
  /// the listening channel and all active child connections have finished shutting down.
  public func runUntilCancelled() async {
    await withTaskCancellationHandler {
      await self.waitUntilShutdown()
    } onCancel: {
      Task {
        await self.shutdown()
      }
    }
  }

  /// Shuts the server down exactly once.
  ///
  /// This stops accepting new connections, closes active child channels, cancels in-flight serve
  /// tasks, and returns only after shutdown has finished.
  public func shutdown() async {
    switch self.state.beginShutdown() {
    case let .start(snapshot):
      self.hooks.onWillShutdown(self.boundAddress)
      snapshot.tasks.forEach { $0.cancel() }
      try? await self.serverChannel.close()
      await withTaskGroup(of: Void.self) { group in
        for channel in snapshot.channels {
          group.addTask {
            try? await channel.channel.close()
          }
        }
      }
      await self.state.waitForConnectionsToDrain()
      self.state.finishShutdown()
      self.hooks.onDidShutdown(self.boundAddress)
    case .inProgress, .finished:
      await self.state.waitUntilShutdown()
    }
  }

  public func close() async {
    await self.shutdown()
  }

  private static func makeBootstrap(
    eventLoopGroup: EventLoopGroup,
    options: ServeOptions,
    hooks: ServeNIOHooks,
    state: ServeNIOServerState,
    handler: @escaping Handler
  ) -> ServerBootstrap {
    Self._makeBootstrap(
      eventLoopGroup: eventLoopGroup,
      options: options,
      hooks: hooks,
      state: state,
      connectionHandler: { connection, context in
        try await Serve.serve(connection: connection, options: options) { request in
          do {
            return try await handler(request)
          } catch {
            hooks.onHandlerError(context, error)
            throw ReportedHandlerError(underlying: error)
          }
        }
      },
    )
  }

  private static func makeUpgradableBootstrap(
    eventLoopGroup: EventLoopGroup,
    options: ServeOptions,
    hooks: ServeNIOHooks,
    state: ServeNIOServerState,
    handler: @escaping @Sendable (Request) async throws -> UpgradeResult,
    onUpgrade: @escaping @Sendable (any ServeConnection) async -> Void
  ) -> ServerBootstrap {
    Self._makeBootstrap(
      eventLoopGroup: eventLoopGroup,
      options: options,
      hooks: hooks,
      state: state,
      connectionHandler: { connection, context in
        if let upgradedConnection = try await Serve.serveUpgradable(
          connection: connection,
          options: options,
          handler: { request in
            do {
              return try await handler(request)
            } catch {
              hooks.onHandlerError(context, error)
              throw ReportedHandlerError(underlying: error)
            }
          }
        ) {
          await onUpgrade(upgradedConnection)
        }
      },
    )
  }

  private static func _makeBootstrap(
    eventLoopGroup: EventLoopGroup,
    options _: ServeOptions,
    hooks: ServeNIOHooks,
    state: ServeNIOServerState,
    connectionHandler: @escaping @Sendable (any ServeConnection, ServeNIOConnectionContext) async throws -> Void
  ) -> ServerBootstrap {
    ServerBootstrap(group: eventLoopGroup)
      .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
      .childChannelInitializer { channel in
        let connectionID = state.makeConnectionID()
        guard state.registerConnection(id: connectionID, channel: channel) else {
          return channel.close()
        }

        let context = ServeNIOConnectionContext(
          localAddress: channel.localAddress,
          remoteAddress: channel.remoteAddress
        )
        hooks.onDidAcceptConnection(context)

        let connection = NIOConnection.wrap(channel: channel)
        let task = Task {
          defer {
            state.taskDidComplete(id: connectionID)
          }

          do {
            try await connectionHandler(connection, context)
          } catch is ReportedHandlerError {
          } catch is ServeError {
          } catch {
            guard !state.isShuttingDown else {
              return
            }
            hooks.onConnectionError(context, error)
          }
        }

        if state.storeTask(task, id: connectionID) {
          task.cancel()
          return channel.close()
        }

        return channel.eventLoop.makeSucceededVoidFuture()
      }
  }
}

@available(*, deprecated, renamed: "ServeNIOServer")
public typealias ServeNIOListener = ServeNIOServer

private enum BindError: Error {
  case missingBoundAddress
}

private struct ReportedHandlerError: Error {
  let underlying: any Error
}

private final class ChannelBox: @unchecked Sendable {
  let channel: Channel

  init(channel: Channel) {
    self.channel = channel
  }
}

private final class ServeNIOServerState: @unchecked Sendable {
  private enum Phase {
    case running
    case shuttingDown
    case finished
  }

  private struct ActiveConnection {
    let channel: ChannelBox
    var task: Task<Void, Never>?
    var channelClosed = false
    var taskCompleted = false
  }

  struct ShutdownSnapshot {
    let channels: [ChannelBox]
    let tasks: [Task<Void, Never>]
  }

  enum BeginShutdownResult {
    case start(ShutdownSnapshot)
    case inProgress
    case finished
  }

  private struct State {
    var nextConnectionID = 0
    var phase: Phase = .running
    var connections: [Int: ActiveConnection] = [:]
    var drainWaiters: [CheckedContinuation<Void, Never>] = []
    var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
  }

  private var state = State()
  private var lock = pthread_mutex_t()

  init() {
    pthread_mutex_init(&self.lock, nil)
  }

  deinit {
    pthread_mutex_destroy(&self.lock)
  }

  var isShuttingDown: Bool {
    self.lockState()
    let result = self.state.phase != .running
    self.unlockState()
    return result
  }

  func makeConnectionID() -> Int {
    self.lockState()
    let connectionID = self.state.nextConnectionID
    self.state.nextConnectionID += 1
    self.unlockState()
    return connectionID
  }

  func registerConnection(id: Int, channel: Channel) -> Bool {
    self.lockState()
    guard self.state.phase == .running else {
      self.unlockState()
      return false
    }
    self.state.connections[id] = ActiveConnection(channel: ChannelBox(channel: channel))
    self.unlockState()

    channel.closeFuture.whenComplete { _ in
      self.channelDidClose(id: id)
    }
    return true
  }

  /// Returns true when the caller should immediately cancel the task because shutdown has begun.
  func storeTask(_ task: Task<Void, Never>, id: Int) -> Bool {
    self.lockState()
    guard var connection = self.state.connections[id] else {
      self.unlockState()
      return true
    }
    connection.task = task
    self.state.connections[id] = connection
    let shouldCancel = self.state.phase != .running
    self.unlockState()
    return shouldCancel
  }

  func taskDidComplete(id: Int) {
    let drainWaiters = self.withLock {
      guard var connection = $0.connections[id] else {
        return [CheckedContinuation<Void, Never>]()
      }
      connection.taskCompleted = true
      if connection.channelClosed {
        $0.connections.removeValue(forKey: id)
      } else {
        $0.connections[id] = connection
      }
      return self.takeDrainWaitersIfNeeded(state: &$0)
    }
    self.resume(drainWaiters)
  }

  func beginShutdown() -> BeginShutdownResult {
    self.lockState()
    switch self.state.phase {
    case .running:
      self.state.phase = .shuttingDown
      let snapshot = ShutdownSnapshot(
        channels: self.state.connections.values.map(\.channel),
        tasks: self.state.connections.values.compactMap(\.task)
      )
      self.unlockState()
      return .start(snapshot)
    case .shuttingDown:
      self.unlockState()
      return .inProgress
    case .finished:
      self.unlockState()
      return .finished
    }
  }

  func waitForConnectionsToDrain() async {
    await withCheckedContinuation { continuation in
      self.lockState()
      if self.state.connections.isEmpty {
        self.unlockState()
        continuation.resume()
        return
      }
      self.state.drainWaiters.append(continuation)
      self.unlockState()
    }
  }

  func finishShutdown() {
    let shutdownWaiters = self.withLock {
      $0.phase = .finished
      let waiters = $0.shutdownWaiters
      $0.shutdownWaiters = []
      return waiters
    }
    self.resume(shutdownWaiters)
  }

  func waitUntilShutdown() async {
    await withCheckedContinuation { continuation in
      self.lockState()
      if self.state.phase == .finished {
        self.unlockState()
        continuation.resume()
        return
      }
      self.state.shutdownWaiters.append(continuation)
      self.unlockState()
    }
  }

  private func channelDidClose(id: Int) {
    let drainWaiters = self.withLock {
      guard var connection = $0.connections[id] else {
        return [CheckedContinuation<Void, Never>]()
      }
      connection.channelClosed = true
      if connection.taskCompleted {
        $0.connections.removeValue(forKey: id)
      } else {
        $0.connections[id] = connection
      }
      return self.takeDrainWaitersIfNeeded(state: &$0)
    }
    self.resume(drainWaiters)
  }

  private func takeDrainWaitersIfNeeded(state: inout State) -> [CheckedContinuation<Void, Never>] {
    guard state.phase == .shuttingDown, state.connections.isEmpty else {
      return []
    }
    let waiters = state.drainWaiters
    state.drainWaiters = []
    return waiters
  }

  private func resume(_ waiters: [CheckedContinuation<Void, Never>]) {
    waiters.forEach { $0.resume() }
  }

  private func withLock<T>(_ body: (inout State) -> T) -> T {
    self.lockState()
    let result = body(&self.state)
    self.unlockState()
    return result
  }

  private func lockState() {
    pthread_mutex_lock(&self.lock)
  }

  private func unlockState() {
    pthread_mutex_unlock(&self.lock)
  }
}

private final class NIOConnection: ServeConnection, @unchecked Sendable {
  private let channel: Channel
  private let readState: ReadState

  init(channel: Channel, readState: ReadState) {
    self.channel = channel
    self.readState = readState
  }

  func read(into buffer: UnsafeMutableRawBufferPointer) async throws -> Int {
    try await self.readState.read(into: buffer)
  }

  func write(contentsOf bytes: [UInt8]) async throws {
    let buffer = self.channel.allocator.buffer(bytes: bytes)
    try await self.channel.writeAndFlush(buffer)
  }

  func close() async {
    try? await self.channel.close()
  }

  static func wrap(channel: Channel) -> NIOConnection {
    let state = ReadState()
    let handler = NIOConnectionHandler(readState: state)
    channel.pipeline.addHandler(handler).whenFailure { error in
      state.receiveError(error)
    }
    return NIOConnection(channel: channel, readState: state)
  }
}

private final class ReadState: @unchecked Sendable {
  private var buffer: ByteBuffer = .init()
  private var eof = false
  private var error: (any Error)?
  private var waiter: CheckedContinuation<Int, any Error>?
  private var waiterBuffer: UnsafeMutableRawBufferPointer?
  private var lock = pthread_mutex_t()

  init() {
    pthread_mutex_init(&self.lock, nil)
  }

  deinit {
    pthread_mutex_destroy(&self.lock)
  }

  func read(into target: UnsafeMutableRawBufferPointer) async throws -> Int {
    self.lockState()
    if self.buffer.readableBytes > 0 {
      let count = min(self.buffer.readableBytes, target.count)
      self.buffer.readWithUnsafeReadableBytes { source in
        target.copyBytes(from: UnsafeRawBufferPointer(rebasing: source.prefix(count)))
        return count
      }
      self.unlockState()
      return count
    }
    if let error = self.error {
      self.unlockState()
      throw error
    }
    if self.eof {
      self.unlockState()
      return 0
    }
    self.unlockState()

    return try await withCheckedThrowingContinuation { continuation in
      self.lockState()
      if self.buffer.readableBytes > 0 {
        let count = min(self.buffer.readableBytes, target.count)
        self.buffer.readWithUnsafeReadableBytes { source in
          target.copyBytes(from: UnsafeRawBufferPointer(rebasing: source.prefix(count)))
          return count
        }
        self.unlockState()
        continuation.resume(returning: count)
        return
      }
      if let error = self.error {
        self.unlockState()
        continuation.resume(throwing: error)
        return
      }
      if self.eof {
        self.unlockState()
        continuation.resume(returning: 0)
        return
      }
      self.waiter = continuation
      self.waiterBuffer = target
      self.unlockState()
    }
  }

  func receive(_ data: ByteBuffer) {
    self.lockState()
    if let waiter = self.waiter, let waiterBuffer = self.waiterBuffer {
      self.waiter = nil
      self.waiterBuffer = nil
      var copy = data
      let count = min(copy.readableBytes, waiterBuffer.count)
      copy.readWithUnsafeReadableBytes { source in
        waiterBuffer.copyBytes(from: UnsafeRawBufferPointer(rebasing: source.prefix(count)))
        return count
      }
      if copy.readableBytes > 0 {
        self.buffer.writeBuffer(&copy)
      }
      self.unlockState()
      waiter.resume(returning: count)
    } else {
      var copy = data
      self.buffer.writeBuffer(&copy)
      self.unlockState()
    }
  }

  func receiveEOF() {
    self.lockState()
    self.eof = true
    if let waiter = self.waiter {
      self.waiter = nil
      self.waiterBuffer = nil
      self.unlockState()
      waiter.resume(returning: 0)
    } else {
      self.unlockState()
    }
  }

  func receiveError(_ error: any Error) {
    self.lockState()
    self.error = error
    if let waiter = self.waiter {
      self.waiter = nil
      self.waiterBuffer = nil
      self.unlockState()
      waiter.resume(throwing: error)
    } else {
      self.unlockState()
    }
  }

  private func lockState() {
    pthread_mutex_lock(&self.lock)
  }

  private func unlockState() {
    pthread_mutex_unlock(&self.lock)
  }
}

private final class NIOConnectionHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer

  let readState: ReadState

  init(readState: ReadState) {
    self.readState = readState
  }

  func channelRead(context _: ChannelHandlerContext, data: NIOAny) {
    self.readState.receive(self.unwrapInboundIn(data))
  }

  func channelInactive(context _: ChannelHandlerContext) {
    self.readState.receiveEOF()
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    self.readState.receiveError(error)
    context.close(promise: nil)
  }
}
