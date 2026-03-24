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
  var reader: BufferedConnectionReader

  init(connection: any ServeConnection, options: ServeOptions) {
    self.connection = connection
    self.options = options
    self.reader = BufferedConnectionReader(connection: connection)
  }

  mutating func readRequest() async throws -> Request {
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

    let requestLineParts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
    guard requestLineParts.count == 3 else {
      throw ServeError.invalidRequestLine
    }

    let methodString = String(requestLineParts[0])
    let target = String(requestLineParts[1])
    let version = String(requestLineParts[2])

    guard version == "HTTP/1.1" else {
      throw ServeError.unsupportedHTTPVersion(version)
    }

    var headers = Headers()
    var host: String?
    var contentLength: Int?
    var transferEncoding: String?

    for line in lines.dropFirst() {
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

    let bodyBytes: Bytes
    if contentLength != nil, transferEncoding != nil {
      throw ServeError.conflictingBodyHeaders
    } else if let contentLength {
      guard contentLength <= self.options.maximumBodyBytes else {
        throw ServeError.requestBodyTooLarge(limit: self.options.maximumBodyBytes)
      }
      bodyBytes = try await self.reader.readExact(count: contentLength)
    } else if let transferEncoding {
      guard transferEncoding.lowercased() == "chunked" else {
        throw ServeError.unsupportedTransferEncoding(transferEncoding)
      }
      bodyBytes = try await self.reader.readChunkedBody(limit: self.options.maximumBodyBytes)
    } else {
      bodyBytes = []
    }

    let urlString: String
    if target.hasPrefix("http://") || target.hasPrefix("https://") {
      urlString = target
    } else {
      urlString = "\(self.options.scheme)://\(host)\(target)"
    }

    guard let url = URL(string: urlString) else {
      throw ServeError.invalidURL(urlString)
    }

    guard let method = Method(rawValue: methodString) else {
      throw ServeError.invalidRequestLine
    }

    let body: Request.Body?
    if bodyBytes.isEmpty {
      body = nil
    } else {
      body = .stream(
        length: Int64(bodyBytes.count),
        contentType: firstHeaderValue(named: "content-type", in: headers),
        .chunk(bodyBytes)
      )
    }

    return Request(
      url: url,
      method: method,
      headers: headers,
      body: body
    )
  }

  mutating func writeResponse(_ response: Response) async throws {
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

    if explicitContentLength != nil {
      for try await chunk in response.body where !chunk.isEmpty {
        try await self.connection.write(contentsOf: chunk)
      }
      return
    }

    for try await chunk in response.body where !chunk.isEmpty {
      try await self.connection.write(contentsOf: serializeChunk(chunk))
    }
    try await self.connection.write(contentsOf: Array("0\r\n\r\n".utf8))
  }

  mutating func writeErrorResponse(status: Status) async throws {
    let body = Array("\(status.code) \(status.reasonPhrase)\n".utf8)
    var wire = "HTTP/1.1 \(status.code) \(status.reasonPhrase)\r\n"
    wire += "content-type: text/plain; charset=utf-8\r\n"
    wire += "content-length: \(body.count)\r\n"
    wire += "connection: close\r\n"
    wire += "\r\n"

    try await self.connection.write(contentsOf: Array(wire.utf8))
    try await self.connection.write(contentsOf: body)
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
