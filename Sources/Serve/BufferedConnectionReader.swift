import Fetch

struct BufferedConnectionReader {
  let connection: any ServeConnection
  var buffer: Bytes = []
  var reachedEnd = false

  mutating func readUntilSequence(_ sequence: Bytes, limit: Int) async throws -> Bytes {
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

  mutating func readLine(limit: Int) async throws -> Bytes {
    let bytes = try await self.readUntilSequence([13, 10], limit: limit)
    return Array(bytes.dropLast(2))
  }

  mutating func readExact(count: Int) async throws -> Bytes {
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

  mutating func readChunkedBody(limit: Int) async throws -> Bytes {
    var body: Bytes = []

    while true {
      let sizeLine = try await self.readLine(limit: limit)
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
          let trailer = try await self.readLine(limit: limit)
          if trailer.isEmpty {
            return body
          }
        }
      }

      let chunk = try await self.readExact(count: size)
      let terminator = try await self.readExact(count: 2)
      guard terminator == [13, 10] else {
        throw ServeError.invalidChunkTerminator
      }

      body.append(contentsOf: chunk)
      if body.count > limit {
        throw ServeError.requestBodyTooLarge(limit: limit)
      }
    }
  }

  private mutating func readMore() async throws {
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
