# claude-backup-watchdog.ps1  (hlidani, ze zaloha VUBEC bezi)
#
# Engine oznami selhani sveho behu (exit 1/2/3 + toast), ale nikdy situaci,
# kdy se vubec nespousti - zakazana ci smazana uloha, rozbity trigger.
# Watchdog proto bezi jako DRUHA naplanovana uloha (ClaudeBackupWatchdog:
# po prihlaseni +30 min, pak kazdych 12 h; vytvari deploy.ps1 -CreateTask)
# a kontroluje jen "nebezi":
#   1. uloha zalohy existuje,
#   2. neni zakazana (Disabled),
#   3. bezela nedavno (LastRunTime ne starsi nez -MaxAgeMinutes; zaloha bezi
#      kazdych ~10 min a watchdog startuje az 30 min po prihlaseni, takze
#      cerstvy LastRunTime je zaruceny, kdyz je vse zdrave).
#
# Vysledky SELHANI behu zalohy (LastTaskResult != 0) watchdog neresi - ty uz
# toastuje engine sam (vcetne rate-limitu).
#
# Problem -> toast + radek do _engine.log vedle configu, exit 1. Jinak exit 0.

param(
    [string]$ConfigPath = (Join-Path $env:USERPROFILE '.config\claude-backup\config.json'),
    [string]$TaskName,
    [int]$MaxAgeMinutes = 60,
    [switch]$NoNotify
)

$ErrorActionPreference = 'Stop'

# jmeno ulohy: parametr > config (schedule.taskName) > 'ClaudeBackup'
if (-not $TaskName) {
    $TaskName = 'ClaudeBackup'
    try {
        $cfg = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($cfg.schedule -and $cfg.schedule.taskName) { $TaskName = $cfg.schedule.taskName }
    } catch { }
}

$configDir = Split-Path -Parent $ConfigPath
$bootLog   = Join-Path $configDir '_engine.log'

function Write-WdLog($m) {
    $line = "$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))  WATCHDOG: $m"
    try { Add-Content -Path $bootLog -Value $line -Encoding utf8 } catch { }
    Write-Host $line
}

function Show-Notification($title, $text) {
    if ($NoNotify) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ni.Icon = [System.Drawing.SystemIcons]::Warning
        $ni.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Error
        $ni.BalloonTipTitle = $title
        $ni.BalloonTipText = $text
        $ni.Visible = $true
        $ni.ShowBalloonTip(10000)
        Start-Sleep -Seconds 5
        $ni.Visible = $false
        $ni.Dispose()
    } catch { }
}

function Stop-Problem($msg) {
    Write-WdLog "PROBLEM: $msg (exit 1)"
    Show-Notification 'ClaudeBackup - zaloha NEBEZI' $msg
    exit 1
}

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $task) { Stop-Problem "naplanovana uloha '$TaskName' neexistuje - zaloha se nespousti" }
if ($task.State -eq 'Disabled') { Stop-Problem "naplanovana uloha '$TaskName' je zakazana - zaloha se nespousti" }

$info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $info -or -not $info.LastRunTime -or $info.LastRunTime.Year -lt 2000) {
    Stop-Problem "uloha '$TaskName' jeste nikdy nebezela"
}
$ageMin = [int]([DateTime]::Now - $info.LastRunTime).TotalMinutes
if ($ageMin -gt $MaxAgeMinutes) {
    Stop-Problem "uloha '$TaskName' nebezela uz $ageMin min (limit $MaxAgeMinutes) - posledni beh $($info.LastRunTime)"
}

# ok jen na konzoli (do _engine.log ne - bez rotace by rostl donekonecna)
Write-Host "$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))  WATCHDOG: ok - uloha '$TaskName' bezi (posledni beh pred $ageMin min)"
exit 0
