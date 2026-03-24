# wuhu-serve

`wuhu-serve` is a small transport-neutral HTTP/1.1 server core for Swift.

The current scope is intentionally narrow:

- one request per connection
- `Request -> Response` handler model
- transport-neutral byte-stream connections
- HTTP/1.1 request parsing and response serialization
- `Connection: close` on every response

It is not trying to be a full web framework yet.

## Design

The public surface is centered around a single handler shape:

```swift
import Fetch
import Serve

let handler: Handler = { request in
  Response(status: .ok, body: .chunk(Array("hello".utf8)))
}
```

And a transport-neutral connection:

```swift
public protocol ServeConnection: Sendable {
  func read(into buffer: UnsafeMutableRawBufferPointer) async throws -> Int
  func write(contentsOf bytes: [UInt8]) async throws
  func close() async
}
```

That lets the same HTTP engine run over:

- TCP listeners
- Unix domain sockets
- yamux streams
- in-memory test transports

## Status

This repository currently contains the HTTP/1.1 core plus wire-level tests.

Planned follow-up work lives in [`TODO.md`](./TODO.md).
