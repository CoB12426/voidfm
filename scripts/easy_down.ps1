$ErrorActionPreference = "Stop"

$RootDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$FishDir = Join-Path $RootDir "fish-speech"

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  Write-Error "docker command not found. Install Docker Desktop first."
}

Push-Location $RootDir
try {
  docker compose -f docker-compose.easy.yml down
}
finally {
  Pop-Location
}

if (Test-Path $FishDir) {
  Push-Location $FishDir
  try {
    docker compose -f compose.yml --profile server down
  }
  finally {
    Pop-Location
  }
}

Write-Host "[OK] Host stopped"
