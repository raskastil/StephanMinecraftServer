param(
  [Parameter(Position = 0)]
  [string]$Command,
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Usage {
  Write-Host "Usage:"
  Write-Host "  build server-files"
  Write-Host ""
  Write-Host "Notes:"
  Write-Host "  - Fill URLs in build/server-files.json"
  Write-Host "  - Use -Force to re-download files"
}

function Ensure-Dir([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
  }
}

function Download-File([string]$Url, [string]$OutFile, [string]$Sha256, [switch]$Force) {
  if (-not $Url) {
    Write-Host "SKIP: missing url for $OutFile" -ForegroundColor Yellow
    return
  }

  if ((Test-Path -LiteralPath $OutFile) -and (-not $Force)) {
    Write-Host "SKIP: exists $OutFile" -ForegroundColor DarkGray
    return
  }

  $outDir = Split-Path -Parent $OutFile
  if ($outDir) { Ensure-Dir $outDir }

  Write-Host "GET  $Url"
  Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing

  if ($Sha256) {
    $hash = (Get-FileHash -Algorithm SHA256 -Path $OutFile).Hash.ToLowerInvariant()
    if ($hash -ne $Sha256.ToLowerInvariant()) {
      throw "SHA256 mismatch for $OutFile"
    }
  }
}

if (-not $Command) {
  Write-Usage
  exit 1
}

if ($Command -ne "server-files") {
  Write-Usage
  exit 1
}

$manifestPath = Join-Path $PSScriptRoot "..\\build\\server-files.json"
if (-not (Test-Path -LiteralPath $manifestPath)) {
  throw "Manifest not found: $manifestPath"
}

# TLS 1.2 for older PowerShell
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
  # ignore on newer PowerShell
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

if ($manifest.server) {
  Download-File -Url $manifest.server.url -OutFile $manifest.server.output -Sha256 $manifest.server.sha256 -Force:$Force
}

if ($manifest.plugins) {
  foreach ($p in $manifest.plugins) {
    Download-File -Url $p.url -OutFile $p.output -Sha256 $p.sha256 -Force:$Force
  }
}

Write-Host "Done."
