$ErrorActionPreference = "Stop"

$RootDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$HostDir = Join-Path $RootDir "mydj-host"
$ModelsDir = Join-Path $RootDir "models"

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  Write-Error "docker command not found. Install Docker Desktop first."
}

$configPath = Join-Path $HostDir "config.toml"
$configExample = Join-Path $HostDir "config.docker.toml.example"
if (-not (Test-Path $configPath)) {
  Write-Host "[INFO] config.toml not found. Creating from docker example..."
  Copy-Item $configExample $configPath
  Write-Warning "Edit $configPath to match your model files."
}

New-Item -ItemType Directory -Force -Path $ModelsDir | Out-Null

$isSubprocess = Select-String -Path $configPath -Pattern '^\s*mode\s*=\s*"subprocess"' -Quiet
if ($isSubprocess) {
  $needS2 = Join-Path $ModelsDir "s2"
  $needModel = Join-Path $ModelsDir "s2-pro-q4_k_m.gguf"
  $needTokenizer = Join-Path $ModelsDir "tokenizer.json"

  if (-not (Test-Path $needS2) -or -not (Test-Path $needModel) -or -not (Test-Path $needTokenizer)) {
    Write-Error "TTS mode is subprocess, but required files are missing in $ModelsDir`n  - s2 (Linux executable)`n  - s2-pro-q4_k_m.gguf`n  - tokenizer.json`nSet mode=http in config.toml if you do not use local s2."
  }
}
else {
  Write-Host "[INFO] TTS mode is not subprocess. Skipping local model file checks."
}

Push-Location $RootDir
try {
  docker compose -f docker-compose.easy.yml up -d --build
}
finally {
  Pop-Location
}

Write-Host "[OK] Host started: http://localhost:8000"
Write-Host "[NEXT] Install APK from GitHub Releases and set host IP in app settings."
