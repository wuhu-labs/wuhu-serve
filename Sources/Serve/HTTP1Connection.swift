#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Fetch
import HTTPTypes

struct HTTP1Connection {
  let connection: any ServeConnection
  let options: ServeOptions
  let reader: BufferedConnectionReader

  init(connection: any ServeConnection, options: ServeOptions) {
    self.connection = connection
    self.options = options
    self.reader = BufferedConnectionReader(connection: connection)
  }

  func readRequest() async throws -> Request {
    let headBytes = try await self.reader.readUntilSequence(
      [13, 10, 13, 10],
      limit: self.options.maximumHeadBytes
    )
    let headerBlock = Array(headBytes.dropLast(4))

    guard let head = String(bytes: headerBlock, encoding: .utf8) else {
      throw ServeError.invalidHeaderLine
    }

    let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
    guard let requestLine = lines.first else {
      throw ServeError.invalidRequestLine
    }
    guard requestLine.utf8.count <= self.options.maximumHeaderLineBytes else {
      throw ServeError.headerLineTooLarge(limit: self.options.maximumHeaderLineBytes)
    }

    let requestLineParts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
    guard requestLineParts.count == 3 else {
      throw ServeError.invalidRequestLine
    }

    let methodString = String(requestLineParts[0])
    let target = String(requestLineParts[1])
    let version = String(requestLineParts[2])

    guard let method = Method(rawValue: methodString) else {
      throw ServeError.invalidRequestLine
    }

    guard version == "HTTP/1.1" else {
      throw ServeError.unsupportedHTTPVersion(version)
    }

    var headers = Headers()
    var host: String?
    var contentLength: Int?
    var transferEncoding: String?
    let headerLines = Array(lines.dropFirst())

    guard headerLines.count <= self.options.maximumHeaderCount else {
      throw ServeError.tooManyHeaders(limit: self.options.maximumHeaderCount)
    }

    for line in headerLines {
      guard line.utf8.count <= self.options.maximumHeaderLineBytes else {
        throw ServeError.headerLineTooLarge(limit: self.options.maximumHeaderLineBytes)
      }
      if let first = line.first, first == " " || first == "\t" {
        throw ServeError.invalidHeaderLine
      }
      guard let separator = line.firstIndex(of: ":") else {
        throw ServeError.invalidHeaderLine
      }

      let rawName = String(line[..<separator])
      let rawValue = String(line[line.index(after: separator)...]).trimmingHTTPWhitespace()

      guard let name = HTTPField.Name(rawName) else {
        throw ServeError.invalidHeaderLine
      }

      headers.append(HTTPField(name: name, value: rawValue))

      switch rawName.lowercased() {
      case "host":
        if host != nil {
          throw ServeError.duplicateHeader("host")
        }
        host = rawValue
      case "content-length":
        if contentLength != nil {
          throw ServeError.duplicateHeader("content-length")
        }
        guard let value = Int(rawValue), value >= 0 else {
          throw ServeError.invalidContentLength
        }
        contentLength = value
      case "transfer-encoding":
        if transferEncoding != nil {
          throw ServeError.duplicateHeader("transfer-encoding")
        }
        transferEncoding = rawValue
      default:
        break
      }
    }

    guard let host else {
      throw ServeError.missingHostHeader
    }

    let url = try self.requestURL(
      for: target,
      method: method,
      host: host
    )

    let body: Body?
    if contentLength != nil, transferEncoding != nil {
      throw ServeError.conflictingBodyHeaders
    } else if let contentLength {
      guard contentLength <= self.options.maximumBodyBytes else {
        throw ServeError.requestBodyTooLarge(limit: self.options.maximumBodyBytes)
      }
      if contentLength == 0 {
        body = nil
      } else {
        let source = RequestBodySource(
          reader: self.reader,
          contentLength: contentLength,
          maximumBodyBytes: self.options.maximumBodyBytes
        )
        body = .stream(
          length: Int64(contentLength),
          contentType: firstHeaderValue(named: "content-type", in: headers),
          RequestBodySequence(source: source)
        )
      }
    } else if let transferEncoding {
      guard transferEncoding.lowercased() == "chunked" else {
        throw ServeError.unsupportedTransferEncoding(transferEncoding)
      }
      let source = RequestBodySource(
        reader: self.reader,
        maximumBodyBytes: self.options.maximumBodyBytes
      )
      body = .stream(
        contentType: firstHeaderValue(named: "content-type", in: headers),
        RequestBodySequence(source: source)
      )
    } else {
      body = nil
    }

    return Request(
      url: url,
      method: method,
      headers: headers,
      body: body
    )
  }

  func writeResponse(_ response: Response) async throws {
    let allowsBody = responseAllowsBody(response.status)
    let explicitContentLength = firstHeaderValue(named: "content-length", in: response.headers)

    var wire = "HTTP/1.1 \(response.status.code) \(response.status.reasonPhrase)\r\n"
    wire += serializeHeaders(
      response.headers,
      explicitContentLength: allowsBody ? explicitContentLength : nil,
      usesChunkedTransferEncoding: allowsBody && explicitContentLength == nil
    )
    wire += "\r\n"

    try await self.connection.write(contentsOf: Array(wire.utf8))

    guard allowsBody else {
      return
    }

    do {
      if explicitContentLength != nil {
        for try await chunk in response.body.asyncBytes() where !chunk.isEmpty {
          try await self.connection.write(contentsOf: chunk)
        }
        return
      }

      for try await chunk in response.body.asyncBytes() where !chunk.isEmpty {
        try await self.connection.write(contentsOf: serializeChunk(chunk))
      }
      try await self.connection.write(contentsOf: Array("0\r\n\r\n".utf8))
    } catch {
      throw ResponseBodyWriteError(underlying: error)
    }
  }

  func writeErrorResponse(status: Status) async throws {
    let body = Array("\(status.code) \(status.reasonPhrase)\n".utf8)
    var wire = "HTTP/1.1 \(status.code) \(status.reasonPhrase)\r\n"
    wire += "content-type: text/plain; charset=utf-8\r\n"
    wire += "content-length: \(body.count)\r\n"
    wire += "connection: close\r\n"
    wire += "\r\n"

    try await self.connection.write(contentsOf: Array(wire.utf8))
    try await self.connection.write(contentsOf: body)
  }

  func performWebSocketUpgrade(request: Request) async throws {
    let upgrade = firstHeaderValue(named: "upgrade", in: request.headers)
    let connectionHeader = firstHeaderValue(named: "connection", in: request.headers)
    let key = firstHeaderValue(named: "sec-websocket-key", in: request.headers)
    let version = firstHeaderValue(named: "sec-websocket-version", in: request.headers)

    guard upgrade?.lowercased() == "websocket" else {
      throw ServeError.invalidUpgrade
    }

    guard connectionHeader?.lowercased().contains("upgrade") ?? false else {
      throw ServeError.invalidUpgrade
    }

    guard version == "13" else {
      throw ServeError.invalidUpgrade
    }

    guard let key, !key.isEmpty else {
      throw ServeError.invalidWebSocketKey
    }

    let acceptKey = computeWebSocketAccept(key: key)
    var wire = "HTTP/1.1 101 Switching Protocols\r\n"
    wire += "Upgrade: websocket\r\n"
    wire += "Connection: Upgrade\r\n"
    wire += "Sec-WebSocket-Accept: \(acceptKey)\r\n"
    wire += "\r\n"

    try await self.connection.write(contentsOf: Array(wire.utf8))
  }

  private func requestURL(
    for target: String,
    method: Fetch.Method,
    host: String
  ) throws -> URL {
    guard !target.isEmpty, !target.contains("#") else {
      throw ServeError.invalidRequestTarget(target)
    }

    if target.hasPrefix("http://") || target.hasPrefix("https://") {
      guard let url = URL(string: target), url.host != nil else {
        throw ServeError.invalidURL(target)
      }
      return url
    }

    guard target.hasPrefix("/") else {
      throw ServeError.invalidRequestTarget(target)
    }

    if method == .connect {
      throw ServeError.invalidRequestTarget(target)
    }

    let urlString = "\(self.options.scheme)://\(host)\(target)"
    guard let url = URL(string: urlString) else {
      throw ServeError.invalidURL(urlString)
    }
    return url
  }
}

private func serializeHeaders(
  _ headers: Headers,
  explicitContentLength: String?,
  usesChunkedTransferEncoding: Bool
) -> String {
  var wire = ""

  for field in headers {
    let rawName = field.name.rawName.lowercased()

    if rawName == "connection" || rawName == "content-length" || rawName == "transfer-encoding" {
      continue
    }

    wire += "\(field.name.rawName): \(field.value)\r\n"
  }

  if let explicitContentLength {
    wire += "content-length: \(explicitContentLength)\r\n"
  } else if usesChunkedTransferEncoding {
    wire += "transfer-encoding: chunked\r\n"
  }

  wire += "connection: close\r\n"
  return wire
}

private func serializeChunk(_ bytes: Bytes) -> Bytes {
  Array(String(bytes.count, radix: 16).utf8) + [13, 10] + bytes + [13, 10]
}

struct ResponseBodyWriteError: Error {
  let underlying: any Error
}

private func responseAllowsBody(_ status: Status) -> Bool {
  !(100..<200).contains(status.code) && status.code != 204 && status.code != 304
}

private func firstHeaderValue(named rawName: String, in headers: Headers) -> String? {
  for field in headers where field.name.rawName.caseInsensitiveCompare(rawName) == .orderedSame {
    return field.value
  }
  return nil
}

private extension String {
  func trimmingHTTPWhitespace() -> String {
    self.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

#if canImport(CryptoKit)
import CryptoKit
#endif

private func computeWebSocketAccept(key: String) -> String {
  let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  let combined = key + magic
  #if canImport(CryptoKit)
  let hash = Insecure.SHA1.hash(data: Data(combined.utf8))
  return Data(hash).base64EncodedString()
  #else
  let bytes = Array(combined.utf8)
  let digest = sha1(bytes)
  return Data(digest).base64EncodedString()
  #endif
}

#if !canImport(CryptoKit)
private func sha1(_ message: [UInt8]) -> [UInt8] {
  var ml = message.count
  var h0: UInt32 = 0x67452301
  var h1: UInt32 = 0xEFCDAB89
  var h2: UInt32 = 0x98BADCFE
  var h3: UInt32 = 0x10325476
  var h4: UInt32 = 0xC3D2E1F0

  var padded = message
  padded.append(0x80)

  let targetLength = ((ml + 9 + 63) / 64) * 64
  while padded.count < targetLength - 8 {
    padded.append(0)
  }

  ml *= 8
  for i in stride(from: 56, through: 0, by: -8) {
    padded.append(UInt8((ml >> i) & 0xFF))
  }

  for chunkStart in stride(from: 0, to: padded.count, by: 64) {
    var w = [UInt32](repeating: 0, count: 80)
    for i in 0..<16 {
      let base = chunkStart + i * 4
      w[i] = (UInt32(padded[base]) << 24)
           | (UInt32(padded[base + 1]) << 16)
           | (UInt32(padded[base + 2]) << 8)
           | UInt32(padded[base + 3])
    }
    for i in 16..<80 {
      w[i] = leftRotate(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], by: 1)
    }

    var a = h0, b = h1, c = h2, d = h3, e = h4

    for i in 0..<80 {
      let f: UInt32, k: UInt32
      if i < 20 {
        f = (b & c) | ((~b) & d)
        k = 0x5A827999
      } else if i < 40 {
        f = b ^ c ^ d
        k = 0x6ED9EBA1
      } else if i < 60 {
        f = (b & c) | (b & d) | (c & d)
        k = 0x8F1BBCDC
      } else {
        f = b ^ c ^ d
        k = 0xCA62C1D6
      }

      let temp = leftRotate(a, by: 5) &+ f &+ e &+ k &+ w[i]
      e = d
      d = c
      c = leftRotate(b, by: 30)
      b = a
      a = temp
    }

    h0 = h0 &+ a
    h1 = h1 &+ b
    h2 = h2 &+ c
    h3 = h3 &+ d
    h4 = h4 &+ e
  }

  var digest = [UInt8]()
  for h in [h0, h1, h2, h3, h4] {
    digest.append(UInt8((h >> 24) & 0xFF))
    digest.append(UInt8((h >> 16) & 0xFF))
    digest.append(UInt8((h >> 8) & 0xFF))
    digest.append(UInt8(h & 0xFF))
  }
  return digest
}

private func leftRotate(_ value: UInt32, by count: UInt32) -> UInt32 {
  (value << count) | (value >> (32 - count))
}
#endif
