#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Fetch

public typealias Handler = @Sendable (Request) async throws -> Response

public protocol ServeConnection: Sendable {
  func read(into buffer: UnsafeMutableRawBufferPointer) async throws -> Int
  func write(contentsOf bytes: [UInt8]) async throws
  func close() async
}

public struct ServeOptions: Sendable {
  public var scheme: String
  public var defaultHost: String
  public var maximumHeadBytes: Int
  public var maximumHeaderLineBytes: Int
  public var maximumHeaderCount: Int
  public var maximumBodyBytes: Int

  public init(
    scheme: String = "http",
    defaultHost: String = "localhost",
    maximumHeadBytes: Int = 16 * 1024,
    maximumHeaderLineBytes: Int = 8 * 1024,
    maximumHeaderCount: Int = 100,
    maximumBodyBytes: Int = 8 * 1024 * 1024
  ) {
    self.scheme = scheme
    self.defaultHost = defaultHost
    self.maximumHeadBytes = maximumHeadBytes
    self.maximumHeaderLineBytes = maximumHeaderLineBytes
    self.maximumHeaderCount = maximumHeaderCount
    self.maximumBodyBytes = maximumBodyBytes
  }
}

public enum ServeError: Error, Equatable, Sendable {
  case conflictingBodyHeaders
  case duplicateHeader(String)
  case headerLineTooLarge(limit: Int)
  case headersTooLarge(limit: Int)
  case invalidChunkSize
  case invalidChunkTerminator
  case invalidContentLength
  case invalidHeaderLine
  case invalidRequestLine
  case invalidRequestTarget(String)
  case invalidURL(String)
  case missingHostHeader
  case requestBodyTooLarge(limit: Int)
  case tooManyHeaders(limit: Int)
  case unresolvedRequestBody
  case unexpectedRequestBody
  case unsupportedHTTPVersion(String)
  case unsupportedTransferEncoding(String)
  case unexpectedEndOfStream
}

public enum Serve {
  public static func serve(
    connection: any ServeConnection,
    options: ServeOptions = .init(),
    handler: @escaping Handler
  ) async throws {
    let http = HTTP1Connection(connection: connection, options: options)

    do {
      let request = try await http.readRequest()
      let response = try await handler(request)
      try await ensureResolved(request.body)
      try await http.writeResponse(response)
    } catch let error as ResponseBodyWriteError {
      await connection.close()
      throw error.underlying
    } catch let error as ServeError {
      try? await http.writeErrorResponse(status: error.responseStatus)
      await connection.close()
      throw error
    } catch {
      try? await http.writeErrorResponse(status: .internalServerError)
      await connection.close()
      throw error
    }

    await connection.close()
  }
}

extension Request {
  public func discardBody() async throws {
    try await self.body?.discard()
  }

  public func requireNoBody() throws {
    guard self.body == nil else {
      throw ServeError.unexpectedRequestBody
    }
  }
}

extension ServeError {
  var responseStatus: Status {
    switch self {
    case .headerLineTooLarge, .headersTooLarge, .tooManyHeaders:
      return .requestHeaderFieldsTooLarge
    case .requestBodyTooLarge:
      return .contentTooLarge
    case .unresolvedRequestBody:
      return .internalServerError
    case let .unsupportedHTTPVersion(version):
      return Status(code: 505, reasonPhrase: "Unsupported HTTP Version (\(version))")
    default:
      return .badRequest
    }
  }
}

private func ensureResolved(_ body: Body?) async throws {
  guard let body else { return }
  guard await body.isResolved else {
    throw ServeError.unresolvedRequestBody
  }
}
