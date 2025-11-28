# GIIP Agent for Windows

![GIIP Logo](https://giipasp.azurewebsites.net/logo.png)

## 🌟 Overview

GIIP Agent is an intelligent monitoring and management agent for Windows that:
- **Executes remote commands** via CQE (Command Queue Execution) system
- **Auto-discovers infrastructure** (OS, hardware, software, services, network)
- **Provides operational advice** based on collected data
- **Reports heartbeat** every 5 minutes to central management

For Linux/UNIX version: https://github.com/LowyShin/giipAgentLinux  
For UiPath Agent: https://github.com/LowyShin/giipAgentUIP

> **⚠️ Security Note (2025-03-11)**  
> WSF (Windows Script File) version may be restricted by latest security tools.  
> If restricted, use the AHK v1.1 agent (included). Note: AHK v1 agent is NOT compatible with AHK v2.

> **🔒 SECURITY WARNING**
> 
> **NEVER commit `giipAgent.cfg` with real credentials!**
> 
> The `giipAgent.cfg` file in this repository is a **TEMPLATE ONLY**.
> - Keep your actual configuration file **OUTSIDE** of the git repository
> - The `.gitignore` file is configured to prevent accidental commits
> - Always verify before `git push` that no secrets are included
> 
> **Safe practice:**
> ```powershell
> # Keep your config in parent directory
> Copy-Item giipAgent.cfg ..\giipAgent.cfg.myserver
> notepad ..\giipAgent.cfg.myserver  # Edit with real secrets
> New-Item -ItemType SymbolicLink -Path "giipAgent.cfg" -Target "..\giipAgent.cfg.myserver"
> ```

---

## 📋 Prerequisites

### System Requirements
- Windows Server 2012 R2 or later / Windows 10 or later
- PowerShell 5.1 or later
- Git for Windows
- Administrator privileges
- Internet connectivity

### Supported Versions
- **PowerShell Agent** (Recommended): `giipAgentWin.ps1`
- **WSF Agent**: `giipAgent.wsf` (may be blocked by security tools)
- **AHK Agent**: `giipAgent.ahk` (requires AutoHotkey v1.1)

---

## 🚀 Quick Installation

### Step 1: Download Agent

```powershell
# Open PowerShell as Administrator
# Choose installation directory (e.g., C:\, D:\, or any preferred location)
cd C:\

# Clone the repository
git clone https://github.com/LowyShin/giipAgentWin.git
cd giipAgentWin
```

### Step 2: Configure Agent

Edit the configuration file:
```powershell
notepad giipAgent.cfg
```

**Configuration parameters:**
```ini
# Your Secret Key from GIIP portal (https://giipasp.azurewebsites.net)
sk="your-secret-key-here"

# Logical Server Serial Number
# Use "0" for first-time installation (will be auto-assigned)
lssn="0"

# Agent execution interval (seconds)
giipagentdelay="60"

# API server address
apiaddr="https://giipasp.azurewebsites.net"
```

### Step 3: Set PowerShell Execution Policy

```powershell
# Check current policy
Get-ExecutionPolicy

# Set policy (if needed)
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### Step 4: Install Agent

Run the installation script:
```powershell
# Ensure you're running PowerShell as Administrator
.\TaskSchdReg.ps1
```

**What happens during installation:**
1. Checks for administrator privileges
2. Detects existing GIIP installations
3. Prompts for removal if found (Y/N)
4. Registers 2 Windows Scheduled Tasks:
   - **GIIP Agent Task**: Runs every 1 minute
   - **GIIP Auto-Discovery Task**: Runs every 5 minutes
5. Configures tasks to run as SYSTEM account
6. Sets tasks to run on batteries and when locked

---

## ✅ Verify Installation

### Check Task Scheduler Registration
```powershell
# List all GIIP tasks
Get-ScheduledTask -TaskName "GIIP*"

# Expected output:
# TaskName                      State
# --------                      -----
# GIIP Agent Task               Ready
# GIIP Auto-Discovery Task      Ready
```

### Check Task Details
```powershell
# View task information
Get-ScheduledTask -TaskName "GIIP Auto-Discovery Task" | Get-ScheduledTaskInfo

# View task trigger (schedule)
(Get-ScheduledTask -TaskName "GIIP Auto-Discovery Task").Triggers

# View last run result
Get-ScheduledTask -TaskName "GIIP Auto-Discovery Task" | Get-ScheduledTaskInfo | Select-Object LastRunTime, LastTaskResult
```

### Check Logs
```powershell
# Find log directory
$LogDir = Join-Path (Split-Path $PWD) "giipLogs"
Write-Host "Log directory: $LogDir"

# View agent log
Get-Content "$LogDir\giipAgent_$(Get-Date -Format 'yyyyMMdd').log" -Tail 20

# View auto-discovery log
Get-Content "$LogDir\giip-auto-discover_$(Get-Date -Format 'yyyyMMdd').log" -Tail 20

# Monitor logs in real-time
Get-Content "$LogDir\giip-auto-discover_$(Get-Date -Format 'yyyyMMdd').log" -Wait
```

### Manual Test

Test auto-discovery script:
```powershell
# Test discovery collection (JSON output)
.\giipscripts\auto-discover-win.ps1

# Test full auto-discovery with API call
.\giip-auto-discover.ps1
```

---

## 📊 Auto-Discovery Features

The agent automatically collects:

### System Information
- OS name, version, architecture (`Win32_OperatingSystem`)
- CPU model, cores, logical processors (`Win32_Processor`)
- Total memory size in GB
- Computer name

### Network Configuration
- Network adapter names
- IPv4/IPv6 addresses (`Get-NetIPAddress`)
- MAC addresses (`Get-NetAdapter`)
- Excludes loopback and disabled adapters

### Software Inventory
- Installed programs from Windows Registry:
  - `HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall`
  - `HKLM:\Software\Wow6432Node\...\Uninstall` (32-bit on 64-bit)
- Software name, version, publisher
- Installation date, path, size
- Up to 100 packages collected

### Service Status
- Windows Services (`Get-Service`)
- Service name, display name, status
- Start type (Auto/Manual/Disabled)
- Port numbers for common services (IIS, SQL Server, etc.)
- CPU and memory usage (if running)
- Up to 50 services collected (prioritizes important services)

### Operational Advice
Automatically generated based on:
- Hardware capacity (CPU cores, memory)
- OS end-of-life status (Windows Server 2008/2012, etc.)
- Missing security software (antivirus, firewall)
- Missing backup solutions
- Critical service failures (SQL Server, IIS, etc.)
- Web server SSL configuration
- Database monitoring tools
- Service/software bloat detection

### Database Performance Monitoring (DPA)

The agent includes database performance monitoring scripts:

| Script | Purpose | Configuration |
|--------|---------|---------------|
| `dpa-put-mssql.ps1` | MS SQL Server session/query monitoring | Reads from `giipAgent.cfg` |
| `dpa-put-mysql.ps1` | MySQL/MariaDB monitoring | Reads from `giipAgent.cfg` |

**Important Configuration Mapping:**

```ini
# giipAgent.cfg - Database Monitoring Section
sk="your-secret-key"           # → USER_TOKEN (API authentication)
lssn="12345"                   # → K_KEY (server identifier)
apiaddrv2="https://..."        # → KVS_ENDPOINT
apiaddrcode="function-code"    # → FUNCTION_CODE
```

**Key Points:**
- ⚠️ **kKey = lssn** (서버 식별자는 항상 lssn 값을 사용)
- ⚠️ **K_TYPE = "lssn"** (기본값, 변경하지 말 것)
- These scripts collect active sessions, CPU usage, slow queries
- Data is uploaded to KVS (Key-Value Storage) every 5 minutes
- Failed uploads are logged to ErrorLogs table

**Schedule:**
```powershell
# Task Scheduler - Every 5 minutes
*/5 * * * * pwsh -File "C:\giipAgent\giipscripts\dpa-put-mssql.ps1"
```

---

## 🔧 Configuration Details

### File Structure
```
giipAgentWin/
├── giipAgentWin.ps1           # Main agent (CQE executor) - PowerShell
├── giipAgent.wsf              # Main agent - WSF (legacy)
├── giipAgent.ahk              # Main agent - AutoHotkey v1.1
├── giipAgent.cfg              # Configuration file
├── TaskSchdReg.ps1            # Installation script
├── giip-auto-discover.ps1     # Auto-discovery wrapper
├── giipscripts/
│   ├── auto-discover-win.ps1      # Discovery data collector
│   ├── dpa-put-mssql.ps1
│   ├── dpa-put-mysql.ps1
│   ├── net-put-win.ps1
│   └── sqlnet_put.bat
├── gitsync.ps1                # Git sync helper
└── README.md
```

### Task Scheduler Configuration
| Task | Trigger | Action | Account |
|------|---------|--------|---------|
| GIIP Agent Task | Every 1 minute (repeating) | Run `giipAgentWin.ps1` | SYSTEM |
| GIIP Auto-Discovery Task | Every 5 minutes (repeating) | Run `giip-auto-discover.ps1` | SYSTEM |

**Task Settings:**
- ✅ Run whether user is logged on or not
- ✅ Run with highest privileges
- ✅ Allow start on batteries
- ✅ Don't stop if going on batteries
- ✅ Start when available

---

## 🔍 Troubleshooting

### Installation Issues

**Problem: "Script needs to be run as Administrator"**
```powershell
# Solution: Right-click PowerShell and select "Run as Administrator"
# Or from PowerShell:
Start-Process powershell -Verb RunAs -ArgumentList "-File .\TaskSchdReg.ps1"
```

**Problem: "Execution policy" error**
```powershell
# Check current policy
Get-ExecutionPolicy

# Set policy for current user
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# Or bypass for single execution
powershell.exe -ExecutionPolicy Bypass -File .\TaskSchdReg.ps1
```

**Problem: Task created but not running**
```powershell
# Check task status
Get-ScheduledTask -TaskName "GIIP Auto-Discovery Task" | Format-List *

# Check last run result (0 = success)
(Get-ScheduledTask -TaskName "GIIP Auto-Discovery Task" | Get-ScheduledTaskInfo).LastTaskResult

# Common error codes:
# 0x0        = Success
# 0x1        = Incorrect function
# 0x41301    = Task is currently running
# 0x41303    = Task has not yet run
# 0x800710E0 = The operator or administrator has refused the request
```

### Discovery Issues

**Problem: JSON parsing error**
```powershell
# Test JSON output validity
$json = .\giipscripts\auto-discover-win.ps1
$json | ConvertFrom-Json

# If error, check PowerShell version
$PSVersionTable.PSVersion
# Should be 5.1 or higher
```

**Problem: API call fails**
```powershell
# Test network connectivity
Test-NetConnection -ComputerName giipasp.azurewebsites.net -Port 443

# Test TLS 1.2 support
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri "https://giipasp.azurewebsites.net" -UseBasicParsing

# Check proxy settings
netsh winhttp show proxy

# If using proxy, configure PowerShell
$proxy = New-Object System.Net.WebProxy("http://proxy:8080")
$webSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
$webSession.Proxy = $proxy
```

**Problem: WMI/CIM errors**
```powershell
# Rebuild WMI repository (requires restart)
winmgmt /salvagerepository
winmgmt /resetrepository

# Restart WMI service
Restart-Service Winmgmt -Force
```

**Problem: No data in GIIP portal**
```powershell
# Verify configuration
Get-Content .\giipAgent.cfg

# Check if LSSN was assigned
# Should change from "0" to a number after first run

# Manual API test
$secretKey = "your-secret-key"
$uri = "https://giipasp.azurewebsites.net/api/giipApi?cmd=AgentAutoRegister"
$body = @{
    at = $secretKey
    jsondata = @{}
} | ConvertTo-Json

Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType "application/json" -Headers @{
    "Authorization" = "Bearer $secretKey"
}
```

---

## 🔄 Reinstallation

### Update Existing Installation

```powershell
cd C:\giipAgentWin

# Pull latest version
git pull

# Reinstall (will prompt to remove old tasks)
.\TaskSchdReg.ps1
# Answer 'Y' when prompted to remove old tasks
```

### Clean Reinstall

```powershell
# Remove tasks manually
Unregister-ScheduledTask -TaskName "GIIP Agent Task" -Confirm:$false
Unregister-ScheduledTask -TaskName "GIIP Auto-Discovery Task" -Confirm:$false

# Verify removal
Get-ScheduledTask -TaskName "GIIP*"

# Reinstall
cd C:\giipAgentWin
.\TaskSchdReg.ps1
```

---

## 🗑️ Uninstallation

```powershell
# Remove scheduled tasks
Unregister-ScheduledTask -TaskName "GIIP Agent Task" -Confirm:$false
Unregister-ScheduledTask -TaskName "GIIP Auto-Discovery Task" -Confirm:$false

# Remove agent directory
Remove-Item -Path "C:\giipAgentWin" -Recurse -Force

# Remove logs (optional)
Remove-Item -Path "C:\giipLogs" -Recurse -Force
```

---

## 📚 Additional Resources

- **GIIP Portal**: https://giipasp.azurewebsites.net
- **Documentation**: [AGENT_INSTALLATION_GUIDE](../giipdb/docs/AGENT_INSTALLATION_GUIDE.md)
- **Architecture**: [GIIP_ARCHITECTURE](../giipdb/docs/GIIP_ARCHITECTURE.md)
- **Auto-Discovery Design**: [AUTO_DISCOVERY_DESIGN](../giipdb/docs/AUTO_DISCOVERY_DESIGN.md)
- **Linux Agent**: https://github.com/LowyShin/giipAgentLinux
- **UiPath Agent**: https://github.com/LowyShin/giipAgentUIP

### GIIP Token Information
- **Token Exchange**: https://tokenjar.io/GIIP
- **Trading Manual**: https://www.slideshare.net/LowyShin/giipentokenjario-giip-token-trade-manual-20190416-141149519
- **Etherscan**: https://etherscan.io/token/0x33be026eff080859eb9dfff6029232b094732c52

### Documentation in Other Languages
- [English](https://github.com/LowyShin/giip/wiki)
- [日本語](https://github.com/LowyShin/giip-ja/wiki)
- [한국어](https://github.com/LowyShin/giip-ko/wiki)

---

## 🤝 Support

- **Issues**: https://github.com/LowyShin/giipAgentWin/issues
- **Email**: support@giip.io
- **Web**: https://giipasp.azurewebsites.net
- **Contact**: https://github.com/LowyShin/giip/wiki/Contact-Us

---

## 📝 Version History

- **2025-10-27**: Added PowerShell-based auto-discovery system
- **2020-03-09**: Fixed lssn=0 handling, command reading improvements
- **2020-03-06**: Added UiPath agent support

---

## 📄 License

Free to use for infrastructure management and monitoring.
