#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Fetch
import HTTPTypes
import Serve
import ServeRouting

public enum ServeFiles {
  public static func middleware(
    rootDirectory: URL,
    urlPrefix: String = "/",
    indexFile: String = "index.html"
  ) -> Middleware {
    let rootDirectory = rootDirectory.standardizedFileURL
    let prefixSegments = pathSegments(for: urlPrefix)

    return { next in
      { request in
        guard request.method == .get || request.method == .head else {
          return try await next(request)
        }

        guard let requestSegments = relativeSegments(for: request.url.path, prefixSegments: prefixSegments) else {
          return try await next(request)
        }

        guard !requestSegments.contains("..") else {
          return notFoundResponse()
        }

        guard let fileURL = resolveFileURL(
          rootDirectory: rootDirectory,
          requestSegments: requestSegments,
          indexFile: indexFile
        ) else {
          return try await next(request)
        }

        let data = try Data(contentsOf: fileURL)
        var headers = Headers()
        headers[.contentType] = contentType(for: fileURL.pathExtension)
        headers[.contentLength] = String(data.count)

        if request.method == .head {
          return Response(status: .ok, headers: headers)
        }

        return Response(
          status: .ok,
          headers: headers,
          body: .bytes(Array(data), contentType: headers[.contentType])
        )
      }
    }
  }

  public static func handler(
    rootDirectory: URL,
    urlPrefix: String = "/",
    indexFile: String = "index.html"
  ) -> Handler {
    let middleware = self.middleware(
      rootDirectory: rootDirectory,
      urlPrefix: urlPrefix,
      indexFile: indexFile
    )
    let fallback: Handler = { _ in
      notFoundResponse()
    }
    return middleware(fallback)
  }
}

private func resolveFileURL(
  rootDirectory: URL,
  requestSegments: [String],
  indexFile: String
) -> URL? {
  var candidate = rootDirectory
  for segment in requestSegments {
    candidate.appendPathComponent(segment, isDirectory: false)
  }
  candidate = candidate.standardizedFileURL

  guard isDescendant(candidate, of: rootDirectory) else { return nil }

  guard let candidateKind = fileKind(at: candidate) else {
    return nil
  }

  if candidateKind == .directory {
    candidate.appendPathComponent(indexFile, isDirectory: false)
    candidate = candidate.standardizedFileURL
    guard isDescendant(candidate, of: rootDirectory) else { return nil }
    guard fileKind(at: candidate) == .file else {
      return nil
    }
  }

  return candidate
}

private enum FileKind {
  case file
  case directory
}

private func fileKind(at url: URL) -> FileKind? {
  guard FileManager.default.fileExists(atPath: url.path) else {
    return nil
  }

  let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey])
  return resourceValues?.isDirectory == true ? .directory : .file
}

private func isDescendant(_ candidate: URL, of rootDirectory: URL) -> Bool {
  let rootPath = rootDirectory.path.hasSuffix("/") ? rootDirectory.path : rootDirectory.path + "/"
  return candidate.path == rootDirectory.path || candidate.path.hasPrefix(rootPath)
}

private func relativeSegments(
  for requestPath: String,
  prefixSegments: [String]
) -> [String]? {
  let requestSegments = pathSegments(for: requestPath)
  guard requestSegments.starts(with: prefixSegments) else { return nil }
  return Array(requestSegments.dropFirst(prefixSegments.count))
}

private func pathSegments(for path: String) -> [String] {
  path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
}

private func contentType(for pathExtension: String) -> String {
  switch pathExtension.lowercased() {
  case "css":
    return "text/css; charset=utf-8"
  case "gif":
    return "image/gif"
  case "htm", "html":
    return "text/html; charset=utf-8"
  case "jpg", "jpeg":
    return "image/jpeg"
  case "js", "mjs":
    return "text/javascript; charset=utf-8"
  case "json":
    return "application/json"
  case "md":
    return "text/markdown; charset=utf-8"
  case "png":
    return "image/png"
  case "svg":
    return "image/svg+xml"
  case "txt":
    return "text/plain; charset=utf-8"
  case "webp":
    return "image/webp"
  case "xml":
    return "application/xml"
  default:
    return "application/octet-stream"
  }
}

private func notFoundResponse() -> Response {
  let bodyText = "404 Not Found\n"
  var headers = Headers()
  headers[.contentType] = "text/plain; charset=utf-8"
  headers[.contentLength] = String(bodyText.utf8.count)
  return Response(
    status: .notFound,
    headers: headers,
    body: .string(bodyText)
  )
}
