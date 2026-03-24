import Fetch

struct RequestBodySequence: AsyncSequence, Sendable {
  typealias Element = Bytes

  let source: RequestBodySource

  func makeAsyncIterator() -> Iterator {
    Iterator(source: self.source)
  }

  struct Iterator: AsyncIteratorProtocol {
    let source: RequestBodySource

    mutating func next() async throws -> Bytes? {
      try await self.source.nextChunk()
    }
  }
}

actor RequestBodySource {
  enum Strategy: Sendable {
    case fixedLength(remaining: Int)
    case chunked(currentChunkRemaining: Int?, sawTerminalChunk: Bool)
  }

  private let reader: BufferedConnectionReader
  private let maximumBodyBytes: Int
  private let chunkSize: Int
  private var strategy: Strategy
  private var bytesRead = 0
  private var isFinished = false

  init(
    reader: BufferedConnectionReader,
    contentLength: Int,
    maximumBodyBytes: Int,
    chunkSize: Int = 8 * 1024
  ) {
    self.reader = reader
    self.maximumBodyBytes = maximumBodyBytes
    self.chunkSize = chunkSize
    self.strategy = .fixedLength(remaining: contentLength)
  }

  init(
    reader: BufferedConnectionReader,
    maximumBodyBytes: Int,
    chunkSize: Int = 8 * 1024
  ) {
    self.reader = reader
    self.maximumBodyBytes = maximumBodyBytes
    self.chunkSize = chunkSize
    self.strategy = .chunked(currentChunkRemaining: nil, sawTerminalChunk: false)
  }

  func nextChunk() async throws -> Bytes? {
    guard !self.isFinished else { return nil }

    switch self.strategy {
    case let .fixedLength(remaining):
      guard remaining > 0 else {
        self.isFinished = true
        return nil
      }

      let count = min(remaining, self.chunkSize)
      let bytes = try await self.reader.readExact(count: count)
      self.bytesRead += bytes.count
      self.strategy = .fixedLength(remaining: remaining - bytes.count)
      if remaining == bytes.count {
        self.isFinished = true
      }
      return bytes

    case let .chunked(currentChunkRemaining, sawTerminalChunk):
      return try await self.readChunkedChunk(
        currentChunkRemaining: currentChunkRemaining,
        sawTerminalChunk: sawTerminalChunk
      )
    }
  }

  private func readChunkedChunk(
    currentChunkRemaining: Int?,
    sawTerminalChunk: Bool
  ) async throws -> Bytes? {
    if sawTerminalChunk {
      self.isFinished = true
      return nil
    }

    var remaining = currentChunkRemaining
    if remaining == nil {
      let sizeLine = try await self.reader.readLine(limit: self.maximumBodyBytes)
      let rawSize = String(decoding: sizeLine, as: UTF8.self)
        .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        .first
        .map(String.init)?
        .trimmingCharacters(in: .whitespaces)

      guard let rawSize, let size = Int(rawSize, radix: 16) else {
        throw ServeError.invalidChunkSize
      }

      if size == 0 {
        while true {
          let trailer = try await self.reader.readLine(limit: self.maximumBodyBytes)
          if trailer.isEmpty {
            self.isFinished = true
            return nil
          }
        }
      }

      remaining = size
    }

    guard let remaining else {
      throw ServeError.invalidChunkSize
    }

    let count = min(remaining, self.chunkSize)
    let bytes = try await self.reader.readExact(count: count)
    self.bytesRead += bytes.count
    if self.bytesRead > self.maximumBodyBytes {
      throw ServeError.requestBodyTooLarge(limit: self.maximumBodyBytes)
    }

    let updatedRemaining = remaining - bytes.count
    if updatedRemaining == 0 {
      let terminator = try await self.reader.readExact(count: 2)
      guard terminator == [13, 10] else {
        throw ServeError.invalidChunkTerminator
      }
      self.strategy = .chunked(currentChunkRemaining: nil, sawTerminalChunk: false)
    } else {
      self.strategy = .chunked(currentChunkRemaining: updatedRemaining, sawTerminalChunk: false)
    }

    return bytes
  }
}
