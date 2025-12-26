# ============================================================================
# Test-PowerShellSyntax.ps1
# Purpose: Validate PowerShell syntax across all .ps1 files
# Usage: .\Test-PowerShellSyntax.ps1
# ============================================================================

$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Path (Split-Path -Path $MyInvocation.MyCommand.Path -Parent) -Parent

Write-Host "=== PowerShell Syntax Validation ===" -ForegroundColor Cyan
Write-Host "Scanning directory: $ScriptRoot" -ForegroundColor Gray
Write-Host ""

$allFiles = Get-ChildItem -Path $ScriptRoot -Filter "*.ps1" -Recurse -ErrorAction SilentlyContinue
$totalFiles = $allFiles.Count
$errorFiles = @()
$checkedCount = 0

foreach ($file in $allFiles) {
    $checkedCount++
    $relativePath = $file.FullName.Replace($ScriptRoot, ".").Replace("\", "/")
    
    Write-Host "[$checkedCount/$totalFiles] Checking: $relativePath" -NoNewline
    
    try {
        $content = Get-Content -Path $file.FullName -Raw -ErrorAction Stop
        $errors = $null
        $null = [System.Management.Automation.PSParser]::Tokenize($content, [ref]$errors)
        
        if ($errors -and $errors.Count -gt 0) {
            Write-Host " ❌ FAILED" -ForegroundColor Red
            $errorFiles += @{
                File = $relativePath
                Errors = $errors
            }
            foreach ($err in $errors) {
                Write-Host "  Line $($err.Token.StartLine), Col $($err.Token.StartColumn): $($err.Message)" -ForegroundColor Red
            }
        }
        else {
            Write-Host " ✓" -ForegroundColor Green
        }
    }
    catch {
        Write-Host " ⚠️ WARNING" -ForegroundColor Yellow
        Write-Host "  Could not parse file: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host "Total files checked: $totalFiles" -ForegroundColor Gray
Write-Host "Files with errors: $($errorFiles.Count)" -ForegroundColor $(if ($errorFiles.Count -eq 0) { "Green" } else { "Red" })

if ($errorFiles.Count -gt 0) {
    Write-Host ""
    Write-Host "Files with syntax errors:" -ForegroundColor Red
    foreach ($item in $errorFiles) {
        Write-Host "  - $($item.File)" -ForegroundColor Red
    }
    exit 1
}
else {
    Write-Host ""
    Write-Host "✓ All PowerShell files have valid syntax!" -ForegroundColor Green
    exit 0
}
