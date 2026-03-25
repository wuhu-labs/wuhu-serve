# TODO

## Core hardening

- [x] Bootstrap `wuhu-serve` package and publish the repository.
- [x] Build a transport-neutral `ServeConnection` API.
- [x] Implement one-request-per-connection HTTP/1.1 parsing.
- [x] Implement streamed HTTP/1.1 response serialization.
- [x] Add wire-level tests for fragmented request input.
- [x] Add explicit limits and tests for malformed header edge cases.
- [x] Tighten request-target parsing and HTTP method validation.
- [ ] Decide how much chunked request trailer support we want.

## Transport adapters

- [x] Add a NIO listener target for TCP.
- [x] Extend the NIO listener target to Unix domain sockets.
- [x] Add an in-memory helper target for higher-level integration testing.
- [ ] Explore a lightweight adapter for `wuhu-yamux` streams.

## Framework layer

- [ ] Add middleware composition helpers.
- [x] Add prefix mounting helpers.
- [x] Decide whether a tiny router should live in this repo or a sibling package.

## Later

- [x] Request body streaming with explicit handler-side resolution.
- [ ] Keep-alive support.
- [ ] HTTP/2 story, likely via frontend proxy before native support.
