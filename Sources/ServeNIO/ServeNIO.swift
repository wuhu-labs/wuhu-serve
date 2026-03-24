import NIOCore
import NIOPosix
import Serve

public struct ServeNIOListener: @unchecked Sendable {
  private let serverChannel: Channel

  public var localAddress: SocketAddress? {
    self.serverChannel.localAddress
  }

  public static func bind(
    host: String = "127.0.0.1",
    port: Int,
    options: ServeOptions = .init(),
    eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
    handler: @escaping Handler
  ) async throws -> Self {
    let bootstrap = self.makeBootstrap(
      eventLoopGroup: eventLoopGroup,
      options: options,
      handler: handler
    )
    let serverChannel = try await bootstrap.bind(host: host, port: port).get()
    return Self(serverChannel: serverChannel)
  }

  public static func bind(
    unixDomainSocketPath: String,
    options: ServeOptions = .init(),
    eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
    handler: @escaping Handler
  ) async throws -> Self {
    let bootstrap = self.makeBootstrap(
      eventLoopGroup: eventLoopGroup,
      options: options,
      handler: handler
    )
    let serverChannel = try await bootstrap.bind(unixDomainSocketPath: unixDomainSocketPath).get()
    return Self(serverChannel: serverChannel)
  }

  public func close() async {
    try? await self.serverChannel.close()
  }

  private static func makeBootstrap(
    eventLoopGroup: EventLoopGroup,
    options: ServeOptions,
    handler: @escaping Handler
  ) -> ServerBootstrap {
    ServerBootstrap(group: eventLoopGroup)
      .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
      .childChannelInitializer { channel in
        let connection = NIOConnection.wrap(channel: channel)
        Task {
          do {
            try await Serve.serve(connection: connection, options: options, handler: handler)
          } catch {
          }
        }
        return channel.eventLoop.makeSucceededVoidFuture()
      }
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
