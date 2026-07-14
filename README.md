# kbase-lance-engine

`kbase-lance-engine` is a local [LanceDB](https://lancedb.com/) sidecar for
the Go KBASE runtime. It provides generation-scoped vector and full-text
search over a small authenticated HTTP API.

The process is deliberately private: it binds to a loopback address only,
writes one JSON readiness handshake to standard output, and writes operational
logs to standard error. It is not intended to be exposed as a network service.

## Requirements

Building from source requires:

- Rust 1.91 or later
- `protoc` on `PATH`, or `PROTOC` and `PROTOC_INCLUDE` configured for
  `prost-build`

The packaged sidecar has no Rust or `protoc` runtime dependency. The repository
pins its dependency graph in `Cargo.lock`; use `--locked` for local verification
and release builds.

```bash
cargo fmt --check
cargo test --locked
cargo build --locked
```

## Run locally

Create an existing storage directory, provide a token of at least 32
characters, and choose a loopback port:

```bash
export KBASE_LANCE_TOKEN="$(openssl rand -hex 32)"
export KBASE_LANCE_ALLOWED_ROOTS="$(mktemp -d)"
export KBASE_LANCE_LISTEN_ADDR="127.0.0.1:8282"

cargo run --locked
```

The first line written to standard output is the ready handshake. The actual
address is useful when the default ephemeral port is used:

```json
{"protocolVersion":1,"engineVersion":"1.0.0","lancedbVersion":"0.30.0","listenAddress":"127.0.0.1:54321"}
```

In a second terminal, verify the process with the same token:

```bash
curl --fail \
  -H "Authorization: Bearer $KBASE_LANCE_TOKEN" \
  http://127.0.0.1:8282/v1/health
```

## Configuration

| Variable | Required | Description |
| --- | --- | --- |
| `KBASE_LANCE_TOKEN` | Yes | Per-process bearer token; must contain at least 32 characters. |
| `KBASE_LANCE_ALLOWED_ROOTS` | No | Platform path-list restricting accepted `storageDir` values. When set, a storage directory must already exist and fall beneath one of these roots. |
| `KBASE_LANCE_LISTEN_ADDR` | No | Loopback listen address; defaults to `127.0.0.1:0`. |
| `KBASE_LANCE_LISTEN` | No | Compatibility alias used only if `KBASE_LANCE_LISTEN_ADDR` is unset. |
| `KBASE_LANCE_PARENT_PID` | No | Go supervisor PID. The sidecar shuts down when this process disappears. |
| `RUST_LOG` | No | Standard tracing filter, for example `debug`. |

For production use, set `KBASE_LANCE_ALLOWED_ROOTS` explicitly. The engine
rejects non-absolute, missing, and non-directory `storageDir` values.

## HTTP contract

Every request requires `Authorization: Bearer <token>`. JSON field names use
camelCase; request bodies are limited to 64 MiB. Errors use this stable shape:

```json
{"error":{"code":"invalid_request","message":"missing or invalid bearer token"}}
```

Most generation-scoped requests include `requestId`, `agentKey`, and
`generationId`. Generation IDs contain 1–128 ASCII letters, digits, hyphens,
or underscores.

| Area | Endpoints |
| --- | --- |
| Health | `GET /v1/health` |
| Generation lifecycle | `POST /v1/generations/create`, `/release`, `/import`, `/validate` |
| Chunks | `POST /v1/chunks/replace-file`, `/delete-file` |
| Search and reads | `POST /v1/search`, `/read/chunk`, `/read/path` |
| Maintenance | `POST /v1/indexes/build`, `/stats`, `/optimize`, `/shutdown` |

`/v1/generations/import` and `/v1/chunks/replace-file` accept JSON by default.
They also accept Arrow IPC streams with
`Content-Type: application/vnd.apache.arrow.stream` (or `application/x-arrow`).
For an Arrow request, send the generation metadata in
`x-kbase-request-id`, `x-kbase-agent-key`, and `x-kbase-generation-id`; replace
also requires `x-kbase-file-id`.

Generation validation returns `chunkIdDigest` and `fileIdDigest`. Each is
SHA-256 over sorted, unique UTF-8 IDs; every value is encoded as its unsigned
64-bit big-endian byte length followed by its raw bytes. `fileIdDigest` covers
only file IDs represented by at least one chunk in the Lance table.

LanceDB 0.30.0 does not expose an ICU FTS tokenizer. For the KBASE `icu`
contract, the sidecar uses ICU4X to segment indexed text and queries, then
stores those tokens in a LanceDB whitespace-tokenized FTS index.

The Rust request and response structs in [`src/model.rs`](src/model.rs) are
the authoritative schema for callers.

## Release artifacts

Release builds run on a runner that already has the requested Rust target,
linker or SDK, `protoc`, and [Syft](https://github.com/anchore/syft). The scripts
do not install toolchains or cross-compilation dependencies.

```bash
scripts/build-release.sh --os darwin --arch arm64
```

Windows release runners use the matching PowerShell entrypoint:

```powershell
scripts/build-release.ps1 -TargetOS windows -TargetArch amd64
```

On Windows, the more convenient checked build entrypoint detects the host
architecture, verifies formatting and tests, then invokes the release script:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-windows.ps1
```

It requires `cargo`, `rustup`, `protoc`, and `syft` on `PATH`. The requested
Rust target must be installed first; for a standard 64-bit Windows machine:

```powershell
rustup target add x86_64-pc-windows-msvc
```

Use `-TargetArch arm64` to build an ARM64 archive from a correctly provisioned
runner, and `-SkipTests` only when the caller has already run the checks. Pass
`-OutputDir` or `-CargoTargetDir` to select artifact and reusable Cargo-cache
locations.

Each command writes a versioned archive to `dist/v<version>/`. Archives contain
the executable, `cargo-metadata.json`, `sbom.cdx.json`, `LICENSE-APACHE-2.0`,
and `NOTICE`, followed by a SHA-256 checksum file. The optional
`--cargo-target-dir <dir>` or `-CargoTargetDir <dir>` setting selects a reusable
Cargo compilation cache; it is never a release artifact and must not be
committed.

## License

Licensed under the [Apache License 2.0](LICENSE-APACHE-2.0). See [NOTICE](NOTICE)
for release attribution information.
