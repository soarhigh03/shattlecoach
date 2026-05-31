# V4-EB3. One-command start: env setup + adb reverse + score server.
#
# Usage:
#   cd C:\dev\shattlecock
#   .\scripts\start_score_server.ps1
#   .\scripts\start_score_server.ps1 -Port 9000
#   .\scripts\start_score_server.ps1 -GroqApiKey "gsk_xxx"   # enable v1 LLM
#
# Press Ctrl+C to stop the server. ADB reverse rule is removed on exit.

param(
    [int]$Port = 8765,
    [string]$GroqApiKey = ""
)

$ErrorActionPreference = 'Stop'
$REPO = "C:\dev\shattlecock"
$VENV_PY = "$REPO\.venv\Scripts\python.exe"
$ADB = "C:\Users\ehdgn\AppData\Local\Android\Sdk\platform-tools\adb.exe"

Write-Host "ShattleCoach score server" -ForegroundColor Cyan
Write-Host "  Port: $Port" -ForegroundColor Cyan

if ($GroqApiKey -ne "") {
    $env:GROQ_API_KEY = $GroqApiKey
    Write-Host "  GROQ_API_KEY: set (v1 LLM enabled)" -ForegroundColor Green
} elseif ($env:GROQ_API_KEY -ne $null -and $env:GROQ_API_KEY -ne "") {
    Write-Host "  GROQ_API_KEY: already set in env (v1 LLM enabled)" -ForegroundColor Green
} else {
    Write-Host "  GROQ_API_KEY: not set (v1 LLM will be skipped, v0 rule-based only)" -ForegroundColor Yellow
}

# adb reverse
$adb_set = $false
if (Test-Path $ADB) {
    $devices = & $ADB devices 2>$null | Select-String "device$"
    if ($devices.Count -gt 0) {
        Write-Host ""
        Write-Host "ADB devices:" -ForegroundColor Cyan
        & $ADB devices
        Write-Host ""
        Write-Host "Setting adb reverse tcp:${Port} tcp:${Port}..." -ForegroundColor Cyan
        & $ADB reverse "tcp:$Port" "tcp:$Port"
        $adb_set = $true
        Write-Host "  -> phone's localhost:$Port now maps to PC's localhost:$Port" -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "WARNING: no ADB device detected." -ForegroundColor Yellow
        Write-Host "  Server will still start, but phone won't be able to reach localhost." -ForegroundColor Yellow
        Write-Host "  Connect phone via USB + enable USB debugging, then re-run this script." -ForegroundColor Yellow
    }
} else {
    Write-Host "WARNING: adb not found at $ADB; skipping reverse setup." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Starting Flask server (Ctrl+C to stop)..." -ForegroundColor Cyan

try {
    & $VENV_PY "$REPO\scripts\score_server.py" --port $Port
} finally {
    if ($adb_set) {
        Write-Host ""
        Write-Host "Removing adb reverse rule..." -ForegroundColor Cyan
        & $ADB reverse --remove "tcp:$Port" 2>$null
    }
}
