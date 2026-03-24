import Fetch

actor BufferedConnectionReader {
  let connection: any ServeConnection
  private var buffer: Bytes = []
  private var reachedEnd = false

  init(connection: any ServeConnection) {
    self.connection = connection
  }

  func readUntilSequence(_ sequence: Bytes, limit: Int) async throws -> Bytes {
    while true {
      if let index = self.buffer.firstIndex(ofSequence: sequence) {
        let end = index + sequence.count
        let bytes = Array(self.buffer[..<end])
        self.buffer.removeFirst(end)
        return bytes
      }

      if self.buffer.count > limit {
        throw ServeError.headersTooLarge(limit: limit)
      }

      try await self.readMore()
      if self.reachedEnd {
        throw ServeError.unexpectedEndOfStream
      }
    }
  }

  func readLine(limit: Int) async throws -> Bytes {
    let bytes = try await self.readUntilSequence([13, 10], limit: limit)
    return Array(bytes.dropLast(2))
  }

  func readExact(count: Int) async throws -> Bytes {
    while self.buffer.count < count {
      try await self.readMore()
      if self.reachedEnd {
        throw ServeError.unexpectedEndOfStream
      }
    }

    let bytes = Array(self.buffer.prefix(count))
    self.buffer.removeFirst(count)
    return bytes
  }

  private func readMore() async throws {
    guard !self.reachedEnd else { return }

    let chunk = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096, alignment: 1)
    defer { chunk.deallocate() }

    let count = try await self.connection.read(into: chunk)

    if count == 0 {
      self.reachedEnd = true
      return
    }

    self.buffer.append(contentsOf: chunk.prefix(count))
  }
}

private extension Array where Element: Equatable {
  func firstIndex(ofSequence sequence: [Element]) -> Int? {
    guard !sequence.isEmpty, sequence.count <= self.count else {
      return nil
    }

    for index in 0...(self.count - sequence.count) {
      if Array(self[index..<(index + sequence.count)]) == sequence {
        return index
      }
    }

    return nil
  }
}
