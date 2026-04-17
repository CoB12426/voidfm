$ErrorActionPreference = "Stop"

$RootDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$HostDir = Join-Path $RootDir "mydj-host"
$FishDir = Join-Path $RootDir "fish-speech"
$configPath = Join-Path $HostDir "config.toml"
$configExample = Join-Path $HostDir "config.allinone.toml.example"

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  Write-Error "docker command not found. Install Docker Desktop first."
}

if (-not (Test-Path $configPath)) {
  Write-Host "[INFO] config.toml not found. Creating from all-in-one example..."
  Copy-Item $configExample $configPath
}

if (-not (Test-Path $FishDir)) {
  if (Get-Command git -ErrorAction SilentlyContinue) {
    Write-Host "[INFO] fish-speech not found. Cloning..."
    Push-Location $RootDir
    try {
      git clone https://github.com/fishaudio/fish-speech.git fish-speech
    }
    finally {
      Pop-Location
    }
  }
  else {
    Write-Error "fish-speech directory not found and git command is unavailable. Install git or place fish-speech/ manually."
  }
}

Push-Location $RootDir
try {
  docker compose -f docker-compose.all.yml -f docker-compose.gpu.yml up -d --build
  if ($LASTEXITCODE -ne 0) {
    throw "docker compose failed with exit code $LASTEXITCODE"
  }
}
finally {
  Pop-Location
}

Write-Host "[OK] All services started"
Write-Host "  - mydj-host:   http://localhost:8000"
Write-Host "  - fish-speech: http://localhost:8080"
Write-Host "  - ollama:      http://localhost:11434"
Write-Host "[INFO] Started with GPU profile (docker-compose.gpu.yml)."
Write-Host "[NOTE] For first run, pull a model inside ollama container (example: llama3.2)."
