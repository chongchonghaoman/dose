param([string]$ReleaseZip)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$version = '0.28.0'
$expected = 'b6c0b8fa96d28b42bf523e4a662607034233dd86c3f0c3034590de31ea47fcf6'
$cache = Join-Path $repoRoot '.cache'
New-Item -ItemType Directory -Force -Path $cache | Out-Null
if (-not $ReleaseZip) {
  $ReleaseZip = Join-Path $cache "dose-$version-Windows-x64.zip"
  if (-not (Test-Path -LiteralPath $ReleaseZip)) {
    Invoke-WebRequest -Uri "https://github.com/chongchonghaoman/dose/releases/download/v$version/dose-$version-Windows-x64.zip" -OutFile $ReleaseZip -UseBasicParsing
  }
}
$ReleaseZip = (Resolve-Path -LiteralPath $ReleaseZip).Path
if ((Get-FileHash -LiteralPath $ReleaseZip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) { throw 'Release checksum mismatch. No runtime files were copied.' }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($ReleaseZip)
try {
  $prefix = "dose-$version/resources/"
  $nativeRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'native'))
  $count = 0
  foreach ($entry in $archive.Entries) {
    if (-not $entry.FullName.StartsWith($prefix, [StringComparison]::Ordinal) -or -not $entry.Name) { continue }
    $relative = $entry.FullName.Substring($prefix.Length)
    if ($relative -notmatch '^(spectral|reference|reference-editor)/') { continue }
    $target = [IO.Path]::GetFullPath((Join-Path $nativeRoot $relative))
    if (-not $target.StartsWith($nativeRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe archive path' }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
    $count++
  }
  if ($count -lt 100) { throw 'Incomplete runtime archive' }
  Write-Host "Prepared $count runtime files from verified dose $version."
} finally { $archive.Dispose() }

