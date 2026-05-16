$openclawDir = Join-Path -Path $PSScriptRoot -ChildPath "..\.openclaw"
$configsDir = Join-Path -Path $openclawDir -ChildPath "configs"
$docsDir = Join-Path -Path $openclawDir -ChildPath "docs"

# Create directories if they do not exist
if (!(Test-Path -Path $configsDir)) {
    New-Item -ItemType Directory -Path $configsDir -Force | Out-Null
    Write-Host "Created configs directory at: $configsDir"
}

if (!(Test-Path -Path $docsDir)) {
    New-Item -ItemType Directory -Path $docsDir -Force | Out-Null
    Write-Host "Created docs directory at: $docsDir"
}

# 1. Sample Config Data (.json)
$sampleConfig = @{
    "agent_name" = "Local_Openclaw_Agent"
    "sync_interval_sec" = 300
    "log_level" = "INFO"
    "features" = @{
        "enable_metrics" = $true
        "auto_update" = $false
    }
}

$configFilePath = Join-Path -Path $configsDir -ChildPath "agent_config.json"
$sampleConfig | ConvertTo-Json -Depth 5 | Set-Content -Path $configFilePath -Encoding UTF8
Write-Host "Created sample config at: $configFilePath"

# 2. Sample Document Data (.md)
$sampleMarkdown = @"
# Local Openclaw Guide

Welcome to the local Openclaw instance!

## Commands
- `Start-Openclaw`: Starts the local daemon.
- `Stop-Openclaw`: Stops the local daemon.

*This file is synced automatically with the GIIP platform.*
"@

$docFilePath = Join-Path -Path $docsDir -ChildPath "guide.md"
$sampleMarkdown | Set-Content -Path $docFilePath -Encoding UTF8
Write-Host "Created sample markdown doc at: $docFilePath"

Write-Host "Openclaw local data insertion completed successfully."
