# TODO

## Core hardening

- [x] Bootstrap `wuhu-serve` package and publish the repository.
- [x] Build a transport-neutral `ServeConnection` API.
- [x] Implement one-request-per-connection HTTP/1.1 parsing.
- [x] Implement streamed HTTP/1.1 response serialization.
- [x] Add wire-level tests for fragmented request input.
- [ ] Add explicit limits and tests for malformed header edge cases.
- [ ] Tighten request-target parsing and HTTP method validation.
- [ ] Decide how much chunked request trailer support we want.

## Transport adapters

- [x] Add a NIO listener target for TCP.
- [ ] Extend the NIO listener target to Unix domain sockets.
- [ ] Add an in-memory helper target for higher-level integration testing.
- [ ] Explore a lightweight adapter for `wuhu-yamux` streams.

## Framework layer

- [ ] Add middleware composition helpers.
- [ ] Add prefix mounting helpers.
- [ ] Decide whether a tiny router should live in this repo or a sibling package.

## Later

- [ ] Request body streaming instead of fully buffering request bodies.
- [ ] Keep-alive support.
- [ ] HTTP/2 story, likely via frontend proxy before native support.
