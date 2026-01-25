param(
  [Parameter(Position = 0)]
  [string]$Command,
  [Parameter(Position = 1)]
  [string]$Target,
  [string]$Rev,
  [string]$Output,
  [string]$BuildToolsDir,
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Usage {
  Write-Host "Usage:"
  Write-Host "  build server-files"
  Write-Host "  build resolve server-files"
  Write-Host "  build scan server-files"
  Write-Host "  build buildtools"
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

function Invoke-Json([string]$Url) {
  $headers = @{
    "User-Agent" = "StephanMinecraftServer/1.0"
  }
  return Invoke-RestMethod -Uri $Url -Headers $headers
}

function Resolve-GitHubReleaseUrl($source) {
  if (-not $source.owner -or -not $source.repo) {
    throw "github source requires owner and repo"
  }
  $tag = $source.tag
  if ($tag) {
    $api = "https://api.github.com/repos/$($source.owner)/$($source.repo)/releases/tags/$tag"
  } else {
    $api = "https://api.github.com/repos/$($source.owner)/$($source.repo)/releases/latest"
  }
  $release = Invoke-Json $api
  if (-not $release.assets) {
    throw "No assets in GitHub release for $($source.owner)/$($source.repo)"
  }

  $assets = $release.assets
  $asset = $null
  if ($source.asset) {
    $asset = $assets | Where-Object { $_.name -eq $source.asset } | Select-Object -First 1
  } elseif ($source.assetRegex) {
    $asset = $assets | Where-Object { $_.name -match $source.assetRegex } | Select-Object -First 1
  } else {
    $asset = $assets | Where-Object { $_.name -match "\\.jar$" } | Select-Object -First 1
  }

  if (-not $asset) {
    throw "No matching asset found for $($source.owner)/$($source.repo)"
  }
  return $asset.browser_download_url
}

function Resolve-ModrinthUrl($source) {
  if (-not $source.project) {
    throw "modrinth source requires project"
  }

  $api = "https://api.modrinth.com/v2/project/$($source.project)/version"
  $query = @()
  if ($source.loaders) {
    $query += "loaders=$([uri]::EscapeDataString(($source.loaders | ConvertTo-Json -Compress)))"
  }
  if ($source.gameVersions) {
    $query += "game_versions=$([uri]::EscapeDataString(($source.gameVersions | ConvertTo-Json -Compress)))"
  }
  if ($query.Count -gt 0) {
    $api = "$api?$($query -join '&')"
  }

  $versions = Invoke-Json $api
  if (-not $versions) {
    throw "No Modrinth versions found for $($source.project)"
  }

  $selected = $null
  if ($source.version -and $source.version -ne "latest") {
    $selected = $versions | Where-Object { $_.version_number -eq $source.version -or $_.id -eq $source.version } | Select-Object -First 1
  } else {
    $selected = $versions | Sort-Object { $_.date_published } -Descending | Select-Object -First 1
  }

  if (-not $selected) {
    throw "No matching Modrinth version found for $($source.project)"
  }

  $files = $selected.files
  if (-not $files) {
    throw "No files in Modrinth version for $($source.project)"
  }

  $file = $null
  if ($source.file) {
    $file = $files | Where-Object { $_.filename -eq $source.file } | Select-Object -First 1
  } elseif ($source.primary) {
    $file = $files | Where-Object { $_.primary -eq $true } | Select-Object -First 1
  } else {
    $file = $files | Where-Object { $_.filename -match "\\.jar$" } | Select-Object -First 1
  }

  if (-not $file) {
    throw "No matching Modrinth file found for $($source.project)"
  }
  return $file.url
}

function Resolve-HangarUrl($source) {
  if (-not $source.slug) {
    throw "hangar source requires slug"
  }

  $projPath = $source.slug
  if ($source.owner) {
    $projPath = "$($source.owner)/$($source.slug)"
  }

  $limit = 20
  $api = "https://hangar.papermc.io/api/v1/projects/$projPath/versions?limit=$limit&offset=0"
  $resp = Invoke-Json $api
  if (-not $resp -or -not $resp.result) {
    throw "No Hangar versions found for $projPath"
  }

  $versions = $resp.result | Sort-Object { $_.createdAt } -Descending
  if ($source.channel) {
    $versions = $versions | Where-Object { $_.channel.name -eq $source.channel }
  }
  if ($source.gameVersion -and $source.platform) {
    $gv = $source.gameVersion
    $plat = $source.platform
    $versions = $versions | Where-Object {
      $_.platformDependencies.$plat -and ($_.platformDependencies.$plat -match "(^|\\s)$gv(\\s|$)")
    }
  }

  $selected = $versions | Select-Object -First 1
  if (-not $selected) {
    throw "No matching Hangar version found for $projPath"
  }

  $platform = $source.platform
  if (-not $platform) { $platform = "PAPER" }

  $download = $selected.downloads.$platform
  if (-not $download) {
    throw "No Hangar download for platform $platform in $projPath"
  }

  if ($download.downloadUrl) {
    return $download.downloadUrl
  }
  if ($download.externalUrl) {
    return $download.externalUrl
  }

  throw "No Hangar download URL for $projPath"
}

function Resolve-EntryUrl($entry) {
  if ($entry.url) { return $entry.url }
  if (-not $entry.source) { return $null }

  switch ($entry.source.type) {
    "github" { return Resolve-GitHubReleaseUrl $entry.source }
    "github-release" { return Resolve-GitHubReleaseUrl $entry.source }
    "modrinth" { return Resolve-ModrinthUrl $entry.source }
    "hangar" { return Resolve-HangarUrl $entry.source }
    default { throw "Unknown source type: $($entry.source.type)" }
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

function Resolve-ServerFiles {
  $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..") | Select-Object -ExpandProperty Path
  $manifestPath = Join-Path $repoRoot "build\\server-files.json"
  $manifest = Load-Manifest $manifestPath
  if (-not $manifest) { throw "Manifest not found: $manifestPath" }

  $changed = $false

  if ($manifest.server) {
    $url = Resolve-EntryUrl $manifest.server
    if ($url -and $manifest.server.url -ne $url) {
      $manifest.server.url = $url
      $changed = $true
    }
  }

  if ($manifest.plugins) {
    foreach ($p in $manifest.plugins) {
      $url = Resolve-EntryUrl $p
      if ($url -and $p.url -ne $url) {
        $p.url = $url
        $changed = $true
      }
    }
  }

  if ($changed) {
    Save-Manifest $manifest $manifestPath
    Write-Host "Updated: $manifestPath"
  } else {
    Write-Host "No changes."
  }
}

function Get-JavaMajorVersion {
  $line = (& java -version 2>&1 | Select-Object -First 1)
  if (-not $line) { return $null }
  $m = [regex]::Match($line, '\"(\d+)(?:\.\d+)*\"')
  if ($m.Success) { return [int]$m.Groups[1].Value }
  $m = [regex]::Match($line, 'version\s+(\d+)')
  if ($m.Success) { return [int]$m.Groups[1].Value }
  return $null
}

function Build-Spigot {
  $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..") | Select-Object -ExpandProperty Path
  $manifestPath = Join-Path $repoRoot "build\\server-files.json"
  $manifest = Load-Manifest $manifestPath

  if (-not $Rev -or $Rev -eq "") {
    if ($manifest -and $manifest.server -and $manifest.server.name) {
      $m = [regex]::Match($manifest.server.name, '(\\d+\\.\\d+(?:\\.\\d+)?)')
      if ($m.Success) { $Rev = $m.Groups[1].Value }
    }
  }
  if (-not $Rev -or $Rev -eq "") { $Rev = "1.21.11" }

  if (-not $Output -or $Output -eq "") {
    if ($manifest -and $manifest.server -and $manifest.server.output) {
      $Output = $manifest.server.output
    } else {
      $Output = "Server.jar"
    }
  }

  $javaMajor = Get-JavaMajorVersion
  if (-not $javaMajor) {
    throw "Java not found. Install JDK 21 and ensure java is in PATH."
  }
  if ($javaMajor -lt 21) {
    throw "Java $javaMajor detected. Spigot 1.21.11 requires JDK 21."
  }

  if (-not $BuildToolsDir -or $BuildToolsDir -eq "") {
    $BuildToolsDir = Join-Path $repoRoot "build\\buildtools"
  }
  Ensure-Dir $BuildToolsDir

  $btJar = Join-Path $BuildToolsDir "BuildTools.jar"
  if (-not (Test-Path -LiteralPath $btJar) -or $Force) {
    $btUrl = "https://hub.spigotmc.org/jenkins/job/BuildTools/lastSuccessfulBuild/artifact/target/BuildTools.jar"
    Write-Host "GET  $btUrl"
    Invoke-WebRequest -Uri $btUrl -OutFile $btJar -UseBasicParsing
  }

  Push-Location $BuildToolsDir
  try {
    Write-Host "Building Spigot $Rev..."
    & java -Xmx2G -jar $btJar --rev $Rev --compile spigot
  } finally {
    Pop-Location
  }

  $builtJar = Join-Path $BuildToolsDir ("spigot-" + $Rev + ".jar")
  if (-not (Test-Path -LiteralPath $builtJar)) {
    $candidate = Get-ChildItem -Path $BuildToolsDir -Filter "spigot-*.jar" -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($candidate) { $builtJar = $candidate.FullName }
  }

  if (-not (Test-Path -LiteralPath $builtJar)) {
    throw "Built jar not found in $BuildToolsDir"
  }

  $dest = $Output
  if (-not [IO.Path]::IsPathRooted($dest)) {
    $dest = Join-Path $repoRoot $dest
  }
  $destDir = Split-Path -Parent $dest
  if ($destDir) { Ensure-Dir $destDir }
  Copy-Item -Path $builtJar -Destination $dest -Force
  Write-Host "Saved: $dest"
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

if ($Command -eq "resolve") {
  if ($Target -and $Target -ne "server-files") {
    Write-Usage
    exit 1
  }
  Resolve-ServerFiles
  exit 0
}

if ($Command -eq "buildtools") {
  Build-Spigot
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
  $url = Resolve-EntryUrl $manifest.server
  Download-File -Url $url -OutFile $manifest.server.output -Sha256 $manifest.server.sha256 -Force:$Force
}

if ($manifest.plugins) {
  foreach ($p in $manifest.plugins) {
    $url = Resolve-EntryUrl $p
    Download-File -Url $url -OutFile $p.output -Sha256 $p.sha256 -Force:$Force
  }
}

Write-Host "Done."
