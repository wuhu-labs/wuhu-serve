#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Fetch
import HTTPTypes
import ServeFiles
import ServeRouting
import Testing

@Suite(.serialized)
struct ServeFilesTests {
  @Test func middlewareServesFileWithinPrefix() async throws {
    let root = try makeTempDirectory()
    try "body { color: red; }\n".write(
      to: root.appendingPathComponent("site.css"),
      atomically: true,
      encoding: .utf8
    )

    var router = Router()
    router.use(
      ServeFiles.middleware(
        rootDirectory: root,
        urlPrefix: "/assets"
      )
    )
    router.get("/healthz") { _, _ in
      Response(status: .ok, body: .string("ok"))
    }

    let response = try await router.handler(
      Request(url: try #require(URL(string: "http://localhost/assets/site.css")))
    )

    #expect(response.status == .ok)
    #expect(response.headers[.contentType] == "text/css; charset=utf-8")
    #expect(try await response.body.text() == "body { color: red; }\n")
  }

  @Test func middlewareFallsThroughOnMissingFile() async throws {
    let root = try makeTempDirectory()

    var router = Router()
    router.use(ServeFiles.middleware(rootDirectory: root, urlPrefix: "/assets"))
    router.get("/assets/missing.txt") { _, _ in
      Response(status: .accepted, body: .string("fallback"))
    }

    let response = try await router.handler(
      Request(url: try #require(URL(string: "http://localhost/assets/missing.txt")))
    )

    #expect(response.status == .accepted)
    #expect(try await response.body.text() == "fallback")
  }

  @Test func handlerServesDirectoryIndexAndHeadRequests() async throws {
    let root = try makeTempDirectory()
    let docs = root.appendingPathComponent("docs", isDirectory: true)
    try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    try "<h1>Docs</h1>".write(
      to: docs.appendingPathComponent("index.html"),
      atomically: true,
      encoding: .utf8
    )

    let handler = ServeFiles.handler(rootDirectory: root, urlPrefix: "/public")

    let getResponse = try await handler(
      Request(url: try #require(URL(string: "http://localhost/public/docs")))
    )
    #expect(getResponse.status == .ok)
    #expect(getResponse.headers[.contentType] == "text/html; charset=utf-8")
    #expect(try await getResponse.body.text() == "<h1>Docs</h1>")

    let headResponse = try await handler(
      Request(
        url: try #require(URL(string: "http://localhost/public/docs")),
        method: .head
      )
    )
    #expect(headResponse.status == .ok)
    #expect(headResponse.headers[.contentLength] == String("<h1>Docs</h1>".utf8.count))
    #expect(try await headResponse.body.text() == "")
  }

  @Test func traversalAttemptReturnsNotFound() async throws {
    let root = try makeTempDirectory()
    let handler = ServeFiles.handler(rootDirectory: root, urlPrefix: "/assets")

    let response = try await handler(
      Request(url: try #require(URL(string: "http://localhost/assets/../secret.txt")))
    )

    #expect(response.status == .notFound)
    #expect(try await response.body.text() == "404 Not Found\n")
  }
}

private func makeTempDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
