$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'test-driver-windows.ps1'
$source = [IO.File]::ReadAllText($scriptPath)
$sourceMatch = [regex]::Match(
  $source,
  '\[regex\]::Match\(\$contents, ''([^'']+)''\)'
)
if (-not $sourceMatch.Success) {
  throw 'The driver test wrapper does not expose its hook-path detector.'
}

$detector = [regex]::new($sourceMatch.Groups[1].Value)
foreach ($hookPath in @(
  'X:\apps\driver\.dart_tool\hooks_runner\sqlite3\input.json',
  'X:\\apps\\driver\\.dart_tool\\hooks_runner\\sqlite3\\input.json'
)) {
  $match = $detector.Match($hookPath)
  if (-not $match.Success -or $match.Groups['drive'].Value -ne 'X') {
    throw "The hook-path detector must recognize $hookPath"
  }
}

Write-Output 'Driver test wrapper hook-path detector regression checks passed.'
