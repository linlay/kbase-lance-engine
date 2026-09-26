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
$versionFile = Join-Path $REPO_ROOT "VERSION"
if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) {
    throw "VERSION file not found: $versionFile"
}
$version = (Get-Content -LiteralPath $versionFile -Raw).TrimEnd("`r", "`n")
if ($version -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$') {
    throw "Invalid VERSION value: $version (expected a git tag style version such as v1.0.0)"
}

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

foreach ($command in @("cargo", "rustup", "protoc", "syft", "python")) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "$command is required to build a sidecar release artifact"
    }
}
$installed = & rustup target list --installed
if ($LASTEXITCODE -ne 0 -or $installed -notcontains $triple) {
    throw "Rust target $triple is not installed; provision it on the release runner"
}

$binaryName = if ($TargetOS -eq "windows") { "kbase-lance-engine.exe" } else { "kbase-lance-engine" }

New-Item -ItemType Directory -Path $CargoTargetDir -Force | Out-Null
& cargo rustc --bin kbase-lance-engine --manifest-path (Join-Path $REPO_ROOT "Cargo.toml") --release --locked --target $triple --target-dir $CargoTargetDir -- "--remap-path-prefix=$REPO_ROOT=/src/kbase-lance-engine"
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
    $oldSyftUpdate = $env:SYFT_CHECK_FOR_APP_UPDATE
    try {
        $env:SYFT_CHECK_FOR_APP_UPDATE = "false"
        & syft $binary -o "cyclonedx-json=$(Join-Path $stage 'sbom.cdx.json')"
        if ($LASTEXITCODE -ne 0) { throw "Syft failed" }
    } finally {
        if ($null -eq $oldSyftUpdate) { Remove-Item Env:SYFT_CHECK_FOR_APP_UPDATE -ErrorAction SilentlyContinue } else { $env:SYFT_CHECK_FOR_APP_UPDATE = $oldSyftUpdate }
    }
    Copy-Item (Join-Path $REPO_ROOT "LICENSE-APACHE-2.0") $stage
    Copy-Item (Join-Path $REPO_ROOT "NOTICE") $stage
    Copy-Item $versionFile $stage

    $artifactDir = Join-Path $OutputDir $version
    New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
    $archive = Join-Path $artifactDir "kbase-lance-engine_${version}_${TargetOS}_${TargetArch}.zip"
    Remove-Item $archive -Force -ErrorAction SilentlyContinue
    & python (Join-Path $SCRIPT_DIR "reproducible-package.py") --stage $stage --output $archive --sidecar-root $REPO_ROOT --cargo-target $CargoTargetDir
    if ($LASTEXITCODE -ne 0) { throw "Deterministic packaging failed" }
    $hash = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText("$archive.sha256", "$hash  $(Split-Path $archive -Leaf)`n", [Text.UTF8Encoding]::new($false))
    Write-Host "[kbase-lance-release] artifact: $archive"
} finally {
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
}
