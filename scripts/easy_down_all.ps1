$ErrorActionPreference = "Stop"

$RootDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  Write-Error "docker command not found. Install Docker Desktop first."
}

Push-Location $RootDir
try {
  docker compose -f docker-compose.all.yml down
}
finally {
  Pop-Location
}

Write-Host "[OK] All services stopped"
