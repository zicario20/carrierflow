[CmdletBinding()]
param(
  [string]$FlutterRoot,
  [string]$ArchivePath,
  [switch]$Download
)

$ErrorActionPreference = 'Stop'

$expectedFlutterVersion = '3.47.2'
$expectedDartVersion = '3.13.2'
$expectedArchiveSha256 = '37934f2128a55d77a38baba12fd611157ed23a47bf7d2b7d17e9e84da118409d'
$archiveUrl = 'https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_3.47.2-stable.zip'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

if ([string]::IsNullOrWhiteSpace($FlutterRoot)) {
  $FlutterRoot = Join-Path $repositoryRoot '.tooling\flutter'
}
if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
  $ArchivePath = Join-Path (Split-Path -Parent $FlutterRoot) 'flutter_windows_3.47.2-stable.zip'
}

function Assert-FlutterSdk([string]$FlutterBatchPath) {
  # The first Flutter invocation can emit bootstrap progress before its machine JSON.
  # Capture it completely, then parse only the JSON document rather than piping it line-by-line.
  $versionLines = @(& $FlutterBatchPath --version --machine 2>&1 | ForEach-Object { [string]$_ })
  if ($LASTEXITCODE -ne 0) {
    throw 'Could not read the Flutter SDK version.'
  }

  $jsonStart = -1
  for ($index = 0; $index -lt $versionLines.Count; $index++) {
    if ($versionLines[$index].TrimStart().StartsWith('{')) {
      $jsonStart = $index
      break
    }
  }
  if ($jsonStart -lt 0) {
    throw 'Flutter did not return machine-readable version data.'
  }

  try {
    $versionInfo = (($versionLines[$jsonStart..($versionLines.Count - 1)] -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    throw 'Could not parse the Flutter SDK version data.'
  }

  if ($versionInfo.frameworkVersion -ne $expectedFlutterVersion -or $versionInfo.dartSdkVersion -ne $expectedDartVersion) {
    throw "Expected Flutter $expectedFlutterVersion / Dart $expectedDartVersion; found Flutter $($versionInfo.frameworkVersion) / Dart $($versionInfo.dartSdkVersion)."
  }
}

function Assert-VerifiedFlutterArchive([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    throw "Flutter archive is missing: $Path. Re-run with -Download to fetch the official archive."
  }
  $archiveHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($archiveHash -ne $expectedArchiveSha256) {
    throw 'Flutter archive SHA-256 did not match the pinned official source.'
  }
}

$flutterBatch = Join-Path $FlutterRoot 'bin\flutter.bat'
if (Test-Path -LiteralPath $flutterBatch) {
  if (-not (Test-Path -LiteralPath $ArchivePath) -and $Download) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ArchivePath) | Out-Null
    Invoke-WebRequest -Uri $archiveUrl -OutFile $ArchivePath
  }
  Assert-VerifiedFlutterArchive $ArchivePath
  Assert-FlutterSdk $flutterBatch
  Write-Host "Flutter $expectedFlutterVersion / Dart $expectedDartVersion is already provisioned."
  return
}
if (Test-Path -LiteralPath $FlutterRoot) {
  throw "FlutterRoot exists but is not a verified SDK: $FlutterRoot"
}

if (-not (Test-Path -LiteralPath $ArchivePath)) {
  if (-not $Download) {
    throw "Flutter archive is missing: $ArchivePath. Re-run with -Download to fetch the official archive."
  }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ArchivePath) | Out-Null
  Invoke-WebRequest -Uri $archiveUrl -OutFile $ArchivePath
}
Assert-VerifiedFlutterArchive $ArchivePath

$extractRoot = Join-Path (Split-Path -Parent $FlutterRoot) ('.flutter-extract-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $extractRoot | Out-Null
Expand-Archive -LiteralPath $ArchivePath -DestinationPath $extractRoot
$extractedSdk = Join-Path $extractRoot 'flutter'
if (-not (Test-Path -LiteralPath (Join-Path $extractedSdk 'bin\flutter.bat'))) {
  throw 'The verified Flutter archive did not contain a Windows SDK.'
}

Move-Item -LiteralPath $extractedSdk -Destination $FlutterRoot
Assert-FlutterSdk (Join-Path $FlutterRoot 'bin\flutter.bat')
Write-Host "Provisioned verified Flutter $expectedFlutterVersion / Dart $expectedDartVersion."
