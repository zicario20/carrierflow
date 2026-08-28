[CmdletBinding()]
param(
  [string]$WorkspaceLink = (Join-Path $env:LOCALAPPDATA 'carrierflow-driver-windows'),
  [switch]$SkipAnalyze
)

$ErrorActionPreference = 'Stop'
$expectedFlutterVersion = '3.47.2'
$expectedDartVersion = '3.13.2'
$expectedArchiveSha256 = '37934f2128a55d77a38baba12fd611157ed23a47bf7d2b7d17e9e84da118409d'

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ($WorkspaceLink -match '\s') {
  throw "WorkspaceLink must not contain spaces: $WorkspaceLink"
}

if (Test-Path -LiteralPath $WorkspaceLink) {
  $link = Get-Item -LiteralPath $WorkspaceLink -Force
  if (-not ($link.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw "WorkspaceLink exists but is not a junction: $WorkspaceLink"
  }

  $linkTarget = @($link.Target)[0]
  $resolvedTarget = (Resolve-Path -LiteralPath $linkTarget).Path
  if (-not $resolvedTarget.Equals($repositoryRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "WorkspaceLink targets a different workspace: $WorkspaceLink"
  }
} else {
  New-Item -ItemType Junction -Path $WorkspaceLink -Target $repositoryRoot | Out-Null
}

$flutter = Join-Path $WorkspaceLink '.tooling\flutter\bin\flutter.bat'
$flutterArchive = Join-Path $WorkspaceLink '.tooling\flutter_windows_3.47.2-stable.zip'
$driverDirectory = Join-Path $WorkspaceLink 'apps\driver'
$temporaryCompatibilityDrive = $null
if (-not (Test-Path -LiteralPath $flutter)) {
  throw "Flutter 3.47.2 was not found at $flutter. Install it under .tooling/flutter first."
}
if (-not (Test-Path -LiteralPath $flutterArchive)) {
  throw "Verified Flutter archive is missing at $flutterArchive. Run scripts/provision-flutter-windows.ps1 first."
}
$archiveHash = (Get-FileHash -LiteralPath $flutterArchive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($archiveHash -ne $expectedArchiveSha256) {
  throw 'Flutter archive SHA-256 did not match the pinned official source.'
}

$versionInfo = (& $flutter --version --machine | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0) {
  throw 'Could not read the Flutter SDK version.'
}
if ($versionInfo.frameworkVersion -ne $expectedFlutterVersion -or $versionInfo.dartSdkVersion -ne $expectedDartVersion) {
  throw "Expected Flutter $expectedFlutterVersion / Dart $expectedDartVersion; found Flutter $($versionInfo.frameworkVersion) / Dart $($versionInfo.dartSdkVersion)."
}

# Flutter's native-assets hook cache records absolute paths. A previous run
# under a now-missing drive letter must not be trusted or silently rewritten.
# If it points at this verified junction, temporarily restore that exact drive
# mapping for the test process and always remove only the mapping we created.
$hookDirectory = Join-Path $driverDirectory '.dart_tool\hooks_runner'
if (Test-Path -LiteralPath $hookDirectory) {
  $staleDrive = Get-ChildItem -LiteralPath $hookDirectory -Recurse -File -Filter '*.json' |
    ForEach-Object {
      $contents = [IO.File]::ReadAllText($_.FullName)
      [regex]::Match($contents, '(?i)(?<drive>[a-z]):[\\]{1,2}apps[\\]{1,2}driver(?:[\\]{1,2}|/)')
    } |
    Where-Object Success |
    Select-Object -First 1
  if ($null -ne $staleDrive) {
    $driveName = $staleDrive.Groups['drive'].Value.ToUpperInvariant()
    $existingDrive = Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue
    if ($null -ne $existingDrive) {
      $existingRoot = (Resolve-Path -LiteralPath $existingDrive.Root).Path
      if (-not $existingRoot.Equals($resolvedTarget, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Native-assets cache requests $driveName`: but it is already mapped elsewhere. Refusing to replace it."
      }
    } else {
      $subst = Join-Path $env:SystemRoot 'System32\subst.exe'
      & $subst "$driveName`:" $WorkspaceLink
      if ($LASTEXITCODE -ne 0) {
        throw "Could not create the temporary $driveName`: compatibility mapping."
      }
      $temporaryCompatibilityDrive = $driveName
    }
  }
}

$pushedDriverDirectory = $false
try {
  Push-Location -LiteralPath $driverDirectory
  $pushedDriverDirectory = $true

  & $flutter pub get
  if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed.' }

  & $flutter test test/load_home_page_test.dart -r expanded
  if ($LASTEXITCODE -ne 0) { throw 'flutter test failed.' }

  & $flutter test -r expanded
  if ($LASTEXITCODE -ne 0) { throw 'full flutter test failed.' }

  if (-not $SkipAnalyze) {
    & $flutter analyze
    if ($LASTEXITCODE -ne 0) { throw 'flutter analyze failed.' }
  }
} finally {
  if ($pushedDriverDirectory) {
    Pop-Location
  }
  if ($null -ne $temporaryCompatibilityDrive) {
    $subst = Join-Path $env:SystemRoot 'System32\subst.exe'
    & $subst "$temporaryCompatibilityDrive`:" '/D'
  }
}
