$ErrorActionPreference = "Stop"

$RootDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$HostDir = Join-Path $RootDir "mydj-host"
$configPath = Join-Path $HostDir "config.toml"
$configExample = Join-Path $HostDir "config.allinone.toml.example"

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  Write-Error "docker command not found. Install Docker Desktop first."
}

if (-not (Test-Path $configPath)) {
  Write-Host "[INFO] config.toml not found. Creating from all-in-one example..."
  Copy-Item $configExample $configPath
}

Push-Location $RootDir
try {
  docker compose -f docker-compose.all.yml up -d --build
}
finally {
  Pop-Location
}

Write-Host "[OK] All services started"
Write-Host "  - mydj-host:   http://localhost:8000"
Write-Host "  - fish-speech: http://localhost:8080"
Write-Host "  - ollama:      http://localhost:11434"
Write-Host "[NOTE] For first run, pull a model inside ollama container (example: llama3.2)."
