param(
  [Parameter(Position = 0)]
  [string]$Command,
  [Parameter(Position = 1)]
  [string]$Target,
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Usage {
  Write-Host "Usage:"
  Write-Host "  build server-files"
  Write-Host "  build scan server-files"
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

function Get-RelativePathSafe([string]$Root, [string]$FullPath) {
  $full = [IO.Path]::GetFullPath($FullPath)
  $root = [IO.Path]::GetFullPath($Root)
  if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
    $rel = $full.Substring($root.Length).TrimStart("\", "/")
    return $rel -replace "\\", "/"
  }
  return $FullPath -replace "\\", "/"
}

function Load-Manifest([string]$Path) {
  if (Test-Path -LiteralPath $Path) {
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
  }
  return $null
}

function Save-Manifest([object]$Manifest, [string]$Path) {
  $json = $Manifest | ConvertTo-Json -Depth 6
  Set-Content -LiteralPath $Path -Value $json -Encoding ASCII
}

function Scan-ServerFiles {
  $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..") | Select-Object -ExpandProperty Path
  $manifestPath = Join-Path $repoRoot "build\\server-files.json"

  $existing = Load-Manifest $manifestPath
  $existingPluginsByOutput = @{}
  if ($existing -and $existing.plugins) {
    foreach ($p in $existing.plugins) {
      if ($p.output) { $existingPluginsByOutput[$p.output] = $p }
    }
  }

  $rootJars = Get-ChildItem -Path $repoRoot -Filter *.jar -File -ErrorAction SilentlyContinue
  $pluginsDir = Join-Path $repoRoot "plugins"
  $pluginJars = @()
  if (Test-Path -LiteralPath $pluginsDir) {
    $pluginJars = Get-ChildItem -Path $pluginsDir -Filter *.jar -File -ErrorAction SilentlyContinue
  }

  $serverJar = $null
  if ($rootJars) {
    $serverJar = $rootJars | Where-Object { $_.Name -ieq "Server.jar" } | Select-Object -First 1
    if (-not $serverJar) {
      $serverJar = $rootJars | Where-Object { $_.Name -match "(?i)spigot|paper|purpur|pufferfish|server" } | Select-Object -First 1
    }
    if (-not $serverJar) { $serverJar = $rootJars | Select-Object -First 1 }
  }

  $serverEntry = $null
  if ($serverJar) {
    $rel = Get-RelativePathSafe $repoRoot $serverJar.FullName
    $serverEntry = [ordered]@{
      name   = $serverJar.BaseName
      output = $rel
      url    = ""
      sha256 = ""
    }
    if ($existing -and $existing.server -and $existing.server.output -eq $rel) {
      if ($existing.server.name) { $serverEntry.name = $existing.server.name }
      if ($existing.server.url) { $serverEntry.url = $existing.server.url }
      if ($existing.server.sha256) { $serverEntry.sha256 = $existing.server.sha256 }
    }
  } elseif ($existing -and $existing.server) {
    $serverEntry = $existing.server
  } else {
    $serverEntry = [ordered]@{
      name   = "Spigot 1.21.11"
      output = "Server.jar"
      url    = ""
      sha256 = ""
    }
  }

  $plugins = @()
  foreach ($jar in ($pluginJars | Sort-Object Name)) {
    $rel = Get-RelativePathSafe $repoRoot $jar.FullName
    $entry = [ordered]@{
      name   = $jar.BaseName
      output = $rel
      url    = ""
      sha256 = ""
    }
    if ($existingPluginsByOutput.ContainsKey($rel)) {
      $old = $existingPluginsByOutput[$rel]
      if ($old.name) { $entry.name = $old.name }
      if ($old.url) { $entry.url = $old.url }
      if ($old.sha256) { $entry.sha256 = $old.sha256 }
    }
    $plugins += $entry
  }

  $newManifest = [ordered]@{
    server  = $serverEntry
    plugins = $plugins
  }

  Ensure-Dir (Split-Path -Parent $manifestPath)
  Save-Manifest $newManifest $manifestPath
  Write-Host "Updated: $manifestPath"
}

if (-not $Command) {
  Write-Usage
  exit 1
}

if ($Command -eq "scan") {
  if ($Target -and $Target -ne "server-files") {
    Write-Usage
    exit 1
  }
  Scan-ServerFiles
  exit 0
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
