# deploy.ps1  (ClaudeBackup 2.0 - nasazeni)
#
# Nasadi novy config-driven engine + Node.js editor do ~/.local/bin a schema
# vedle configu. Prepnuti ulohy z legacy na novy engine = nahrazeni jednoho
# souboru (~/.local/bin/claude-backup.ps1); VBS wrapper i naplanovana uloha
# zustavaji. Interval opakovani se srovna dle configu (schedule.intervalMinutes).
#
# Legacy engine se pred prvnim prepisem zazalohuje (claude-backup.ps1.bak) -
# rollback: deploy.ps1 -Rollback.
#
# Pouziti:
#   deploy.ps1            ostre nasazeni
#   deploy.ps1 -WhatIf    jen ukaze, co by udelal (nic nemeni)
#   deploy.ps1 -Rollback  obnovi predchozi (legacy) engine ze zalohy
#
# Vytvoreni samotne naplanovane ulohy je mimo deploy (uloha uz existuje).

param(
    [switch]$WhatIf,
    [switch]$Rollback
)

$ErrorActionPreference = 'Stop'

# --- cesty -----------------------------------------------------------------
$binDir     = Join-Path $env:USERPROFILE '.local\bin'
$configDir  = Join-Path $env:USERPROFILE '.config\claude-backup'
$configPath = Join-Path $configDir 'config.json'
$nodeExe    = Join-Path $env:USERPROFILE '.local\nodejs\node.exe'
$repoDir    = $PSScriptRoot

$engineSrc = Join-Path $repoDir 'claude-backup.ps1'
$editorSrc = Join-Path $repoDir 'claude-backup-cfg.js'
$schemaSrc = Join-Path $repoDir 'config.schema.json'

$engineDst = Join-Path $binDir 'claude-backup.ps1'
$editorDst = Join-Path $binDir 'claude-backup-cfg.js'
$cmdDst    = Join-Path $binDir 'claude-backup-cfg.cmd'
$vbsDst    = Join-Path $binDir 'claude-backup-hidden.vbs'
$schemaDst = Join-Path $configDir 'config.schema.json'
$engineBak = "$engineDst.bak"

function Step($desc, [scriptblock]$action) {
    if ($WhatIf) { Write-Host "  [WHATIF] $desc" }
    else { Write-Host "  $desc"; & $action }
}

# --- rollback --------------------------------------------------------------
if ($Rollback) {
    if (-not (Test-Path -LiteralPath $engineBak)) { Write-Host "Neni co obnovit: $engineBak neexistuje."; exit 1 }
    Copy-Item -LiteralPath $engineBak -Destination $engineDst -Force
    Write-Host "Obnoven predchozi engine ze zalohy: $engineBak -> $engineDst"
    exit 0
}

Write-Host "=== ClaudeBackup deploy $(if ($WhatIf) { '(WHATIF - nic se nemeni)' }) ==="

# --- prerekvizity ----------------------------------------------------------
if (-not (Test-Path -LiteralPath $nodeExe)) { throw "portable node nenalezen: $nodeExe" }
foreach ($f in @($engineSrc, $editorSrc, $schemaSrc)) {
    if (-not (Test-Path -LiteralPath $f)) { throw "chybi zdrojovy soubor: $f" }
}

Step "zajisteni slozek ($binDir, $configDir)" { New-Item -ItemType Directory -Force -Path $binDir, $configDir | Out-Null }

if (-not (Test-Path -LiteralPath $configPath)) {
    Write-Host "  VAROVANI: config neexistuje ($configPath)."
    Write-Host "            Vytvor ho editorem 'claude-backup-cfg' pred ostrym behem - engine bez configu konci exit 3."
}

# --- nasazeni --------------------------------------------------------------
# 1) zaloha stavajiciho (legacy) enginu - jen jednou, at zustane rollback bod
if ((Test-Path -LiteralPath $engineDst) -and -not (Test-Path -LiteralPath $engineBak)) {
    Step "zaloha stavajiciho enginu -> $engineBak" { Copy-Item -LiteralPath $engineDst -Destination $engineBak -Force }
}
# 2) engine (tim se uloha prepne z legacy na novy - VBS uz na tento soubor ukazuje)
Step "nasazeni enginu -> $engineDst" { Copy-Item -LiteralPath $engineSrc -Destination $engineDst -Force }
# 3) editor (.js)
Step "nasazeni editoru -> $editorDst" { Copy-Item -LiteralPath $editorSrc -Destination $editorDst -Force }
# 4) cmd wrapper (vola portable node absolutni cestou; %* propaguje argumenty)
$cmdContent = "@echo off`r`n`"$nodeExe`" `"$editorDst`" %*`r`n"
Step "zapis wrapperu -> $cmdDst" { Set-Content -LiteralPath $cmdDst -Value $cmdContent -Encoding ascii -NoNewline }
# 5) schema vedle configu (aby $schema ref sedel a engine/editor meli validaci lokalne)
Step "nasazeni schematu -> $schemaDst" { Copy-Item -LiteralPath $schemaSrc -Destination $schemaDst -Force }
# 6) VBS wrapper - zajistit ze existuje a ukazuje na engine (jinak nechat stavajici)
if (-not (Test-Path -LiteralPath $vbsDst)) {
    $vbsContent = @"
' claude-backup-hidden.vbs
' Spousti claude-backup.ps1 bez blikajiciho okna konzole; ceka a propaguje navratovy kod.
Dim sh, rc
Set sh = CreateObject("WScript.Shell")
rc = sh.Run("powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File ""$engineDst""", 0, True)
WScript.Quit rc
"@
    Step "zapis VBS wrapperu -> $vbsDst" { Set-Content -LiteralPath $vbsDst -Value $vbsContent -Encoding ascii }
} else {
    Write-Host "  VBS wrapper uz existuje (nechavam beze zmeny): $vbsDst"
}

# --- interval ulohy dle configu -------------------------------------------
if (Test-Path -LiteralPath $configPath) {
    try {
        $cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        $taskName = if ($cfg.schedule -and $cfg.schedule.taskName) { $cfg.schedule.taskName } else { 'ClaudeBackup' }
        $iv = if ($cfg.schedule) { $cfg.schedule.intervalMinutes } else { $null }
        if ($iv) {
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if ($task) {
                Step "srovnani intervalu ulohy '$taskName' -> $iv min" {
                    $t = Get-ScheduledTask -TaskName $taskName
                    $ok = $false
                    foreach ($tr in $t.Triggers) { if ($tr.Repetition -and $tr.Repetition.Interval) { $tr.Repetition.Interval = "PT${iv}M"; $ok = $true } }
                    if ($ok) { Set-ScheduledTask -TaskName $taskName -Trigger $t.Triggers | Out-Null }
                }
            } else {
                Write-Host "  uloha '$taskName' nenalezena - interval neaplikovan (vytvoreni ulohy je mimo deploy)."
            }
        }
    } catch { Write-Host "  interval neaplikovan: $($_.Exception.Message)" }
}

# --- overeni ---------------------------------------------------------------
if (-not $WhatIf) {
    Write-Host "=== overeni ==="
    if (Test-Path -LiteralPath $configPath) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engineDst -DryRun -NoNotify *> $null
        $rc = $LASTEXITCODE
        if ($rc -eq 0) { Write-Host "  dry-run nasazeneho enginu: OK (exit 0)" }
        else { Write-Host "  POZOR: dry-run enginu skoncil exit $rc - zkontroluj config!" }
    } else {
        Write-Host "  dry-run preskocen (chybi config)."
    }
    $t = Get-ScheduledTask -TaskName 'ClaudeBackup' -ErrorAction SilentlyContinue
    if ($t) {
        $act = $t.Actions | Select-Object -First 1
        Write-Host "  uloha ClaudeBackup akce: $($act.Execute) $($act.Arguments)"
        $iv = ($t.Triggers | ForEach-Object { $_.Repetition.Interval } | Where-Object { $_ } | Select-Object -First 1)
        Write-Host "  interval opakovani: $iv"
    }
    Write-Host "=== hotovo. Rollback: deploy.ps1 -Rollback ==="
} else {
    Write-Host "=== WHATIF hotovo - nic se nezmenilo ==="
}
