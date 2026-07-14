#Requires -Version 5.1
param(
    [ValidateSet("amd64", "arm64")]
    [string]$TargetArch,
    [string]$OutputDir,
    [string]$CargoTargetDir,
    [switch]$SkipTests
)

$ErrorActionPreference = "Stop"

if ($env:OS -ne "Windows_NT") {
    throw "scripts/build-windows.ps1 must run on Windows"
}

function Get-HostArchitecture {
    $architecture = $env:PROCESSOR_ARCHITEW6432
    if ([string]::IsNullOrWhiteSpace($architecture)) {
        $architecture = $env:PROCESSOR_ARCHITECTURE
    }

    switch ($architecture.ToUpperInvariant()) {
        "AMD64" { return "amd64" }
        "ARM64" { return "arm64" }
        default { throw "unsupported Windows host architecture: $architecture" }
    }
}

if (-not $TargetArch) {
    $TargetArch = Get-HostArchitecture
}

$triples = @{
    "amd64" = "x86_64-pc-windows-msvc"
    "arm64" = "aarch64-pc-windows-msvc"
}
$triple = $triples[$TargetArch]

foreach ($command in @("cargo", "rustup", "protoc", "syft")) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "$command is required; install it and reopen PowerShell before building"
    }
}

$installed = & rustup target list --installed
if ($LASTEXITCODE -ne 0 -or $installed -notcontains $triple) {
    throw "Rust target $triple is not installed; run: rustup target add $triple"
}

$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot
try {
    if (-not $SkipTests) {
        & cargo fmt --check
        if ($LASTEXITCODE -ne 0) { throw "cargo fmt check failed" }

        & cargo test --locked
        if ($LASTEXITCODE -ne 0) { throw "cargo test failed" }
    }

    $releaseArguments = @{
        TargetOS = "windows"
        TargetArch = $TargetArch
    }
    if ($OutputDir) {
        $releaseArguments.OutputDir = $OutputDir
    }
    if ($CargoTargetDir) {
        $releaseArguments.CargoTargetDir = $CargoTargetDir
    }

    & (Join-Path $PSScriptRoot "build-release.ps1") @releaseArguments
    if ($LASTEXITCODE -ne 0) { throw "Windows release build failed" }
} finally {
    Pop-Location
}
