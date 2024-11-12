# 管理者権限のチェック
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "This script needs to be run as Administrator. Please restart PowerShell as Administrator and try again."
    exit
}

# タスクの基本情報
$taskName = "GIIP Agent Task"
$taskDescription = "Executes the giipAgent.wsf file every 1 minute starting at midnight daily."

# PowerShellが実行されているフォルダを取得し、`giipAgent.wsf`ファイルが存在するか確認
$scriptDir = Get-Location
$wsfFilePath = Join-Path -Path $scriptDir -ChildPath "giipAgent.wsf"

# `giipAgent.wsf`ファイルが存在するか確認
if (!(Test-Path -Path $wsfFilePath -PathType Leaf)) {
    Write-Host "giipAgent.wsf file not found in the current directory ($scriptDir). Please check and try again."
    exit
}

# タスクスケジューラの設定内容を定義
$action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$wsfFilePath`""

# 0時0分に開始し、1分間隔で1日（24時間）繰り返すトリガーを設定
$trigger = New-ScheduledTaskTrigger -Once -At "00:00" -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 1)

# タスクの実行アカウントと権限を指定
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

# タスクの設定
$taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
$task = New-ScheduledTask -Action $action -Trigger $trigger -Settings $taskSettings -Principal $principal -Description $taskDescription

# タスクをタスクスケジューラに登録
Register-ScheduledTask -TaskName $taskName -InputObject $task

Write-Host "Task '$taskName' has been successfully registered to execute every 1 minute starting daily at midnight."
