#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Fetch
import HTTPTypes
import Serve

public typealias RouteHandler = @Sendable (_ request: Request, _ parameters: RouteParameters) async throws -> Response
public typealias Middleware = @Sendable (_ next: @escaping Handler) -> Handler

public struct RouteParameters: Sendable, Equatable {
  private let storage: [String: String]

  public init(_ storage: [String: String] = [:]) {
    self.storage = storage
  }

  public var isEmpty: Bool {
    self.storage.isEmpty
  }

  public subscript(_ name: String) -> String? {
    self.storage[name]
  }

  public var values: [String: String] {
    self.storage
  }
}

public struct Router: Sendable {
  private var routes: [Route] = []
  private var middlewares: [Middleware] = []

  public init() {}

  public mutating func on(
    _ method: Fetch.Method,
    _ path: String,
    use handler: @escaping RouteHandler
  ) {
    self.routes.append(
      Route(
        method: method,
        path: PathPattern(path),
        handler: handler
      )
    )
  }

  public mutating func get(_ path: String, use handler: @escaping RouteHandler) {
    self.on(Fetch.Method.get, path, use: handler)
  }

  public mutating func post(_ path: String, use handler: @escaping RouteHandler) {
    self.on(Fetch.Method.post, path, use: handler)
  }

  public mutating func put(_ path: String, use handler: @escaping RouteHandler) {
    self.on(Fetch.Method.put, path, use: handler)
  }

  public mutating func patch(_ path: String, use handler: @escaping RouteHandler) {
    self.on(Fetch.Method.patch, path, use: handler)
  }

  public mutating func delete(_ path: String, use handler: @escaping RouteHandler) {
    self.on(Fetch.Method.delete, path, use: handler)
  }

  public mutating func mount(_ prefix: String, _ router: Router) {
    let prefixPattern = PathPattern(prefix)
    self.routes.append(
      contentsOf: router.routes.map { route in
        Route(
          method: route.method,
          path: route.path.prefixed(by: prefixPattern),
          handler: applyingMiddlewares(router.middlewares, to: route.handler)
        )
      }
    )
  }

  public mutating func use(_ middleware: @escaping Middleware) {
    self.middlewares.append(middleware)
  }

  public var handler: Handler {
    let dispatch = self.dispatchHandler
    return applyMiddlewares(self.middlewares, to: dispatch)
  }

  private var dispatchHandler: Handler {
    let routes = self.routes
    return { request in
      let pathSegments = PathPattern.segments(for: request.url.path)

      var pathMatches: [(route: Route, parameters: RouteParameters)] = []
      var bestMethodMatch: (route: Route, parameters: RouteParameters)?

      for route in routes {
        guard let parameters = route.path.match(pathSegments) else { continue }
        pathMatches.append((route, parameters))

        guard route.method == request.method else { continue }

        if let current = bestMethodMatch {
          if route.path.isMoreSpecific(than: current.route.path) {
            bestMethodMatch = (route, parameters)
          }
        } else {
          bestMethodMatch = (route, parameters)
        }
      }

      if let bestMethodMatch {
        return try await bestMethodMatch.route.handler(request, bestMethodMatch.parameters)
      }

      if !pathMatches.isEmpty {
        var headers = Headers()
        let allow = pathMatches
          .map(\.route.method.rawValue)
          .sorted()
          .joined(separator: ", ")
        headers[.allow] = allow
        return plainTextResponse(status: .methodNotAllowed, headers: headers)
      }

      return plainTextResponse(status: .notFound)
    }
  }
}

public func applyMiddlewares(
  _ middlewares: [Middleware],
  to handler: @escaping Handler
) -> Handler {
  middlewares.reversed().reduce(handler) { next, middleware in
    middleware(next)
  }
}

private struct Route: Sendable {
  let method: Fetch.Method
  let path: PathPattern
  let handler: RouteHandler
}

private func applyingMiddlewares(
  _ middlewares: [Middleware],
  to handler: @escaping RouteHandler
) -> RouteHandler {
  guard !middlewares.isEmpty else { return handler }

  return { request, parameters in
    let endpoint: Handler = { request in
      try await handler(request, parameters)
    }
    return try await applyMiddlewares(middlewares, to: endpoint)(request)
  }
}

private struct PathPattern: Sendable, Equatable {
  let segments: [Segment]

  init(_ rawPath: String) {
    precondition(rawPath.hasPrefix("/"), "Route paths must start with '/'")
    self.segments = Self.segments(for: rawPath).map(Segment.init)

    for segment in self.segments {
      if case let .parameter(name) = segment {
        precondition(!name.isEmpty, "Route parameter names must not be empty")
      }
    }
  }

  init(segments: [Segment]) {
    self.segments = segments
  }

  func prefixed(by prefix: PathPattern) -> Self {
    Self(segments: prefix.segments + self.segments)
  }

  func match(_ pathSegments: [String]) -> RouteParameters? {
    guard pathSegments.count == self.segments.count else { return nil }

    var parameters: [String: String] = [:]

    for (segment, pathSegment) in zip(self.segments, pathSegments) {
      switch segment {
      case let .literal(literal):
        guard literal == pathSegment else { return nil }
      case let .parameter(name):
        parameters[name] = pathSegment
      }
    }

    return RouteParameters(parameters)
  }

  func isMoreSpecific(than other: PathPattern) -> Bool {
    if self.literalCount != other.literalCount {
      return self.literalCount > other.literalCount
    }
    return self.segments.count > other.segments.count
  }

  var literalCount: Int {
    self.segments.reduce(into: 0) { count, segment in
      if case .literal = segment {
        count += 1
      }
    }
  }

  static func segments(for rawPath: String) -> [String] {
    rawPath
      .split(separator: "/", omittingEmptySubsequences: true)
      .map(String.init)
  }

  enum Segment: Sendable, Equatable {
    case literal(String)
    case parameter(String)

    init(_ rawValue: String) {
      if rawValue.hasPrefix(":") {
        self = .parameter(String(rawValue.dropFirst()))
      } else {
        self = .literal(rawValue)
      }
    }
  }
}

private func plainTextResponse(
  status: Status,
  headers: Headers = Headers()
) -> Response {
  var responseHeaders = headers
  responseHeaders[.contentType] = "text/plain; charset=utf-8"
  let bodyText = "\(status.code) \(status.reasonPhrase)\n"
  let body = Body.string(bodyText)
  responseHeaders[.contentLength] = String(bodyText.utf8.count)
  return Response(status: status, headers: responseHeaders, body: body)
}
