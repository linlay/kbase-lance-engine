#Requires -Version 5.1
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("darwin", "linux", "windows")]
    [string]$TargetOS,
    [Parameter(Mandatory = $true)]
    [ValidateSet("amd64", "arm64")]
    [string]$TargetArch,
    [string]$OutputDir,
    [string]$CargoTargetDir
)

$ErrorActionPreference = "Stop"
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$REPO_ROOT = Split-Path -Parent $SCRIPT_DIR
if (-not $OutputDir) { $OutputDir = Join-Path $REPO_ROOT "dist" }
if (-not $CargoTargetDir) { $CargoTargetDir = Join-Path $REPO_ROOT "target" }

$triples = @{
    "darwin/amd64" = "x86_64-apple-darwin"
    "darwin/arm64" = "aarch64-apple-darwin"
    "linux/amd64" = "x86_64-unknown-linux-gnu"
    "linux/arm64" = "aarch64-unknown-linux-gnu"
    "windows/amd64" = "x86_64-pc-windows-msvc"
    "windows/arm64" = "aarch64-pc-windows-msvc"
}
$triple = $triples["$TargetOS/$TargetArch"]
if (-not $triple) { throw "Unsupported target $TargetOS/$TargetArch" }

foreach ($command in @("cargo", "rustup", "protoc", "syft")) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "$command is required to build a sidecar release artifact"
    }
}
$installed = & rustup target list --installed
if ($LASTEXITCODE -ne 0 -or $installed -notcontains $triple) {
    throw "Rust target $triple is not installed; provision it on the release runner"
}

$version = (Select-String -Path (Join-Path $REPO_ROOT "Cargo.toml") -Pattern '^version = "([^"]+)"' | Select-Object -First 1).Matches[0].Groups[1].Value
if (-not $version) { throw "Package version is missing from Cargo.toml" }
$binaryName = if ($TargetOS -eq "windows") { "kbase-lance-engine.exe" } else { "kbase-lance-engine" }

New-Item -ItemType Directory -Path $CargoTargetDir -Force | Out-Null
& cargo build --manifest-path (Join-Path $REPO_ROOT "Cargo.toml") --release --locked --target $triple --target-dir $CargoTargetDir
if ($LASTEXITCODE -ne 0) { throw "cargo build failed for $TargetOS/$TargetArch" }
$binary = Join-Path $CargoTargetDir "$triple/release/$binaryName"
if (-not (Test-Path $binary -PathType Leaf)) { throw "Cargo completed but binary is missing: $binary" }

$stage = Join-Path ([IO.Path]::GetTempPath()) "kbase-lance-release.$([Guid]::NewGuid().ToString('N'))"
try {
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    Copy-Item $binary (Join-Path $stage $binaryName)
    $metadata = & cargo metadata --manifest-path (Join-Path $REPO_ROOT "Cargo.toml") --locked --format-version 1
    if ($LASTEXITCODE -ne 0) { throw "cargo metadata failed" }
    [IO.File]::WriteAllText((Join-Path $stage "cargo-metadata.json"), ($metadata -join "`n"), [Text.UTF8Encoding]::new($false))
    & syft $binary -o "cyclonedx-json=$(Join-Path $stage 'sbom.cdx.json')"
    if ($LASTEXITCODE -ne 0) { throw "Syft failed" }
    Copy-Item (Join-Path $REPO_ROOT "LICENSE-APACHE-2.0") $stage
    Copy-Item (Join-Path $REPO_ROOT "NOTICE") $stage

    $artifactDir = Join-Path $OutputDir "v$version"
    New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
    $archive = Join-Path $artifactDir "kbase-lance-engine_v${version}_${TargetOS}_${TargetArch}.zip"
    Remove-Item $archive -Force -ErrorAction SilentlyContinue
    Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $archive -CompressionLevel Optimal
    $hash = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText("$archive.sha256", "$hash  $(Split-Path $archive -Leaf)`n", [Text.UTF8Encoding]::new($false))
    Write-Host "[kbase-lance-release] artifact: $archive"
} finally {
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
}
