# AGENTS.md

## Scope

This repository builds `kbase-lance-engine`, a Rust HTTP sidecar used by the Go
KBASE runtime. It manages generation-scoped LanceDB tables and is a local-only,
authenticated process. Treat the HTTP contract as a compatibility boundary.

## Working conventions

- Use Rust 1.91 or newer. Keep `Cargo.lock` committed and run Cargo commands
  with `--locked` unless intentionally updating dependencies.
- Before handing off code changes, run `cargo fmt --check` and
  `cargo test --locked`. Run `cargo clippy --all-targets --locked -- -D warnings`
  when the environment has the required toolchain and dependencies.
- `src/model.rs` contains the wire structs; `src/server.rs` defines routes,
  authentication, process lifecycle, and the ready handshake; `src/store.rs`
  owns LanceDB access and query behavior. Update the relevant tests and
  `README.md` whenever a public request, response, configuration variable, or
  release behavior changes.
- Keep all public JSON in camelCase. Preserve stable error envelopes and fields
  unless the caller contract is deliberately versioned.

## Safety and process invariants

- The sidecar must listen on a loopback address only. Do not weaken bearer-token
  authentication, constant-time comparison, or allowed-root validation.
- Standard output is reserved for exactly one ready-handshake JSON line. Send
  logs and diagnostics to standard error.
- A `storageDir` must be canonicalized and checked against
  `KBASE_LANCE_ALLOWED_ROOTS` before persistent data is created. Do not accept
  paths that escape an allowed root.
- Keep the parent-PID watchdog and graceful shutdown behavior intact.

## Dependencies and release

- LanceDB is pinned to the version named in `Cargo.toml` and
  `src/lib.rs`. Update both deliberately, together with `Cargo.lock`, tests,
  and documentation.
- Release scripts require `rustup`, `protoc`, and Syft, and create archives in
  `dist/`. Archives must retain the executable, metadata, CycloneDX SBOM,
  `LICENSE-APACHE-2.0`, and `NOTICE`.
- On Windows, use `scripts/build-windows.ps1` for the checked host build. It
  resolves the native `amd64` or `arm64` target and delegates packaging to
  `scripts/build-release.ps1`; cross-target runners must provide the matching
  MSVC linker and SDK.
- Do not commit `target/`, `dist/`, coverage/profiling output, `.env` files, or
  editor/operating-system metadata. `.cargo/config.toml` is an intentional,
  shareable Cargo networking configuration and should remain tracked.
