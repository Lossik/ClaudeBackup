# claude-backup.ps1  (ClaudeBackup 2.0 - config-driven engine)
#
# Zrcadli zdroje na cile (robocopy /MIR). ZADNE zadratovane nastaveni - vse se
# cte z configu (%USERPROFILE%\.config\claude-backup\config.json), ktery odpovida
# config.schema.json. Chovani je 1:1 s legacy\claude-backup.ps1 (viz PRD, faze 1).
#
# Spousteno naplanovanou ulohou ClaudeBackup (po prihlaseni + kazdych 10 min)
# pres claude-backup-hidden.vbs (skryte okno), ktery propaguje navratovy kod.
#
# Navratove kody:
#   0 = ok (vc. preskocenych zamcenych souboru a nedostupneho volitelneho cile)
#   1 = doslo ke kopirovaci chybe
#   2 = zadny cil neni dostupny
#   3 = config chybi / nejde parsovat / nesedi schema
#       -> engine se v tomto pripade NIKDY nedostane k robocopy /MIR (nemaze!)
#
# Prepinac -DryRun: vypise co by se stalo (robocopy /L) bez jakychkoli zmen na
# disku (nevytvari cile, nekopiruje, nemaze, nezapisuje log). Pro overeni configu.
#
# Pri selhani (exit 1/2/3) engine zobrazi Windows notifikaci (NotifyIcon toast),
# pokud to config nezakazuje (notify.onError:false), neni -NoNotify ani -DryRun.

param(
    [string]$ConfigPath = (Join-Path $env:USERPROFILE '.config\claude-backup\config.json'),
    [switch]$DryRun,
    [switch]$NoNotify
)

$ErrorActionPreference = 'Stop'

# --- notifikace ------------------------------------------------------------
# Oznamit selhani do Windows (best-effort; nikdy nesmi shodit zalohu). V dry-run
# a s -NoNotify se nezobrazuje. Config to muze vypnout pres notify.onError:false.
$notifyOnError = -not $NoNotify

function Show-Notification($title, $text) {
    if ($DryRun) { return }
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
        Start-Sleep -Seconds 5   # nechat toast dorucit (balloon zije s procesem)
        $ni.Visible = $false
        $ni.Dispose()
    } catch { }
}

# --- bootstrap log ---------------------------------------------------------
# Realny log zname az z configu; chyby configu (exit 3) i nedostupnost cilu
# (exit 2) proto logujeme vedle configu, at se diagnostika neztrati.
$configDir = Split-Path -Parent $ConfigPath
$bootLog   = Join-Path $configDir '_engine.log'
try { if (-not $DryRun -and -not (Test-Path -LiteralPath $configDir)) { New-Item -ItemType Directory -Force -Path $configDir | Out-Null } } catch { }

function Write-BootLog($m) {
    $line = "$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))  $m"
    if (-not $DryRun) { try { Add-Content -Path $bootLog -Value $line -Encoding utf8 } catch { } }
    Write-Host $line
}

function Stop-BadConfig($msg) {
    Write-BootLog "CONFIG CHYBA: $msg"
    Write-BootLog "=== backup NESPUSTEN (exit 3) ==="
    if ($notifyOnError) { Show-Notification 'ClaudeBackup - chyba configu' "Zaloha nebezela: $msg" }
    exit 3
}

# --- nacteni + parse configu ----------------------------------------------
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    Stop-BadConfig "config soubor neexistuje: $ConfigPath"
}
try {
    $raw = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop
    $cfg = $raw | ConvertFrom-Json -ErrorAction Stop
} catch {
    Stop-BadConfig "config nejde precist/parsovat: $($_.Exception.Message)"
}

# notify preference z configu (jen zpresnuje default; -NoNotify/-DryRun ma prednost)
if ($cfg.notify -and ($cfg.notify.onError -eq $false)) { $notifyOnError = $false }

# --- validace --------------------------------------------------------------
# Schema tohle hlida taky, ale engine si to overi znovu: obrana pred spustenim
# destruktivniho /MIR nad rozbitym configem (PRD kriterium 4).
if ($cfg.version -ne 1) { Stop-BadConfig "nepodporovana verze configu: '$($cfg.version)' (ocekavano 1)" }

$sources = @($cfg.sources | Where-Object { $null -ne $_ })
if ($sources.Count -lt 1) { Stop-BadConfig "prazdne nebo chybejici 'sources' (robocopy /MIR by mohl mazat obsah cile)" }

$destinations = @($cfg.destinations | Where-Object { $null -ne $_ })
if ($destinations.Count -lt 1) { Stop-BadConfig "prazdne nebo chybejici 'destinations'" }

$excludeFiles = @($cfg.excludeFiles | Where-Object { $_ })
if ($excludeFiles -notcontains '.credentials.json') {
    Stop-BadConfig "'.credentials.json' chybi v 'excludeFiles' (tokeny se NIKDY nesmi zalohovat)"
}

$excludeDirs = @($cfg.excludeDirs | Where-Object { $_ })   # volitelne, muze byt prazdne

foreach ($s in $sources) {
    switch ($s.type) {
        'glob' { if (-not $s.base -or -not $s.pattern) { Stop-BadConfig "zdroj typu glob nema base/pattern" } }
        'dir'  { if (-not $s.path) { Stop-BadConfig "zdroj typu dir nema path" } }
        default { Stop-BadConfig "neznamy typ zdroje: '$($s.type)'" }
    }
}

$destNames = @()
foreach ($d in $destinations) {
    if (-not $d.name) { Stop-BadConfig "cil bez 'name'" }
    switch ($d.type) {
        'path'        { if (-not $d.path) { Stop-BadConfig "cil '$($d.name)' typu path nema path" } }
        'volumeLabel' { if (-not $d.label -or -not $d.subPath) { Stop-BadConfig "cil '$($d.name)' typu volumeLabel nema label/subPath" } }
        default { Stop-BadConfig "cil '$($d.name)' ma neznamy typ: '$($d.type)'" }
    }
    $destNames += $d.name
}

# Prave jeden primarni cil - je v nem log (schema tohle vynutit neumi).
$primaries = @($destinations | Where-Object { $_.primary -eq $true })
if ($primaries.Count -ne 1) { Stop-BadConfig "musi byt prave jeden cil s 'primary': true (nalezeno: $($primaries.Count))" }
$primary = $primaries[0]

# onlyDestinations musi odkazovat na existujici cil.
foreach ($s in $sources) {
    foreach ($od in @($s.onlyDestinations | Where-Object { $_ })) {
        if ($destNames -notcontains $od) { Stop-BadConfig "zdroj odkazuje na neexistujici cil v onlyDestinations: '$od'" }
    }
}

# --- pomocne funkce --------------------------------------------------------
function Resolve-EnvPath($path, $fallbacks) {
    # Expanduje %VAR%. Kdyz zbyde nerozvinuty %VAR% (promenna neni nastavena),
    # zkusi fallback promenne v poradi, a nakonec %USERPROFILE%\<VAR>
    # (tim se %OneDrive% degraduje na %USERPROFILE%\OneDrive - shodne s legacy).
    $resolved = [Environment]::ExpandEnvironmentVariables($path)
    if ($resolved -match '%([^%]+)%') {
        $varName = $matches[1]
        $val = $null
        foreach ($fb in @($fallbacks | Where-Object { $_ })) {
            $v = [Environment]::GetEnvironmentVariable($fb)
            if ($v) { $val = $v; break }
        }
        if (-not $val) { $val = Join-Path $env:USERPROFILE $varName }
        $resolved = [Environment]::ExpandEnvironmentVariables($path.Replace("%$varName%", $val))
    }
    return $resolved
}

function Resolve-DestRoot($d) {
    # Vraci absolutni cestu k cilove slozce, nebo $null kdyz je cil nedostupny.
    if ($d.type -eq 'path') {
        return (Resolve-EnvPath $d.path $d.envFallback)
    }
    elseif ($d.type -eq 'volumeLabel') {
        # SSD hledame podle jmenovky svazku - pismeno se meni.
        $letter = (Get-Volume -FileSystemLabel $d.label -ErrorAction SilentlyContinue).DriveLetter
        if (-not $letter) { return $null }
        return (Join-Path "${letter}:\" $d.subPath)
    }
    return $null
}

function Get-DestSubPath($absPath) {
    # Podslozka v cili. Kdyz je zdroj pod profilem, zachovej relativni cestu
    # (.local\bin -> <cil>\.local\bin, shodne s legacy), jinak jen jmeno slozky.
    # Pozn.: dlouha vysledna cesta (>260, MAX_PATH) neni problem - mirror dela
    # robocopy, ktery je long-path-aware (overeno na 266 i 512 znacich).
    $prof = $env:USERPROFILE
    if ($absPath.StartsWith($prof, [StringComparison]::OrdinalIgnoreCase)) {
        $rel = $absPath.Substring($prof.Length).TrimStart('\', '/')
        if ($rel) { return $rel }
    }
    return (Split-Path -Path $absPath -Leaf)
}

function Invoke-Mirror($sourcePath, $name, $destRoot, $destName, $opts) {
    $target = Join-Path $destRoot $name
    # /MIR zrcadli (vc. mazani), /XJ preskoci junctiony (sdileny obsah),
    # /XF vylouci citlive soubory, /XD vylouci slozky (jen kdyz nejake jsou),
    # /R:1 /W:1 kratke retry, zbytek tichy vystup. Vystup zahazujeme (mix kodovani
    # robocopy vs PS by poskodil log) a hodnotime jen navratovy kod.
    $roboArgs = @($sourcePath, $target, '/MIR', '/XJ')
    if ($excludeFiles.Count) { $roboArgs += '/XF'; $roboArgs += $excludeFiles }
    if ($excludeDirs.Count)  { $roboArgs += '/XD'; $roboArgs += $excludeDirs }
    $roboArgs += @('/R:1', '/W:1')
    if ($DryRun) { $roboArgs += @('/L', '/NP', '/NJH') }                    # jen vypis (vc. souboru a souhrnu)
    else         { $roboArgs += @('/NP', '/NFL', '/NDL', '/NJH', '/NJS') }  # tichy vystup
    if ($opts) { $roboArgs += @($opts) }

    if ($DryRun) {
        Log "dir  $name -> $destName  (dry-run /L):"
        $out = robocopy @roboArgs
        $rc  = $LASTEXITCODE
        foreach ($ln in $out) { if ($ln -and $ln.Trim()) { Write-Host "      $ln" } }
        Log "dir  $name -> $destName  (robocopy $rc)"
        return
    }

    robocopy @roboArgs | Out-Null
    $rc = $LASTEXITCODE
    if ($rc -ge 16) {
        $script:hadError = $true
        Log "dir  $name -> $destName  CHYBA (robocopy $rc)"
    } elseif ($rc -ge 8) {
        # nektere soubory nesly zkopirovat (napr. zamcena aktivni session) - priste
        Log "dir  $name -> $destName  varovani: nektere soubory preskoceny (robocopy $rc)"
    } else {
        Log "dir  $name -> $destName  ok (robocopy $rc)"
    }
}

# --- priprava cilu; nedostupne vyradit ------------------------------------
$ready     = @()
$skipNotes = @()
foreach ($d in $destinations) {
    $root = Resolve-DestRoot $d
    if (-not $root) {
        if ($d.optional) { $skipNotes += "cil  $($d.name)  preskoceno (nedostupny)" }
        else             { $skipNotes += "cil  $($d.name)  NEDOSTUPNY" }
        continue
    }
    $opts = @($d.robocopyOpts | Where-Object { $_ })
    if ($DryRun) {
        # nic nevytvarime; dostupnost odhadneme podle existence disku
        $qualifier = try { Split-Path -Qualifier $root } catch { $null }
        if ($qualifier -and (Test-Path -LiteralPath "$qualifier\")) {
            $ready += , ([pscustomobject]@{ Name = $d.name; Path = $root; Opts = $opts })
        } elseif ($d.optional) { $skipNotes += "cil  $($d.name)  preskoceno (nedostupny disk)" }
        else                   { $skipNotes += "cil  $($d.name)  NEDOSTUPNY (disk)" }
        continue
    }
    try {
        New-Item -ItemType Directory -Force -Path $root -ErrorAction Stop | Out-Null
        $ready += , ([pscustomobject]@{ Name = $d.name; Path = $root; Opts = $opts })
    } catch {
        if ($d.optional) { $skipNotes += "cil  $($d.name)  preskoceno (nelze vytvorit: $($_.Exception.Message))" }
        else             { $skipNotes += "cil  $($d.name)  NEDOSTUPNY (nelze vytvorit: $($_.Exception.Message))" }
    }
}
if ($ready.Count -eq 0) {
    Write-BootLog "zadny cil neni dostupny (exit 2)"
    foreach ($n in $skipNotes) { Write-BootLog $n }
    if ($notifyOnError) { Show-Notification 'ClaudeBackup - zadny cil' 'Zadny cil zalohy neni dostupny (OneDrive i SSD).' }
    exit 2
}

# --- log v primarnim cili --------------------------------------------------
$logFile  = if ($cfg.log -and $cfg.log.file)      { $cfg.log.file }      else { '_backup.log' }
$logMaxKB = if ($cfg.log -and $cfg.log.maxSizeKB) { [int]$cfg.log.maxSizeKB } else { 1024 }
$logKeep  = if ($cfg.log -and $cfg.log.keepLines) { [int]$cfg.log.keepLines } else { 300 }

$primaryReady = $ready | Where-Object { $_.Name -eq $primary.name } | Select-Object -First 1
if ($primaryReady) { $script:log = Join-Path $primaryReady.Path $logFile }
else               { $script:log = $bootLog }   # primarni cil neni ready -> at se log neztrati

function Log($m) {
    $line = "$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))  $m"
    if ($DryRun) { Write-Host $line; return }
    try { Add-Content -Path $script:log -Value $line -Encoding utf8 } catch { }
}

# orizni log kdyz preroste limit
if ((-not $DryRun) -and (Test-Path -LiteralPath $script:log) -and ((Get-Item -LiteralPath $script:log).Length -gt ($logMaxKB * 1KB))) {
    (Get-Content -LiteralPath $script:log -Tail $logKeep) | Set-Content -LiteralPath $script:log -Encoding utf8
}

# --- zaloha ----------------------------------------------------------------
Log "=== backup start$(if ($DryRun) { ' [DRY-RUN: nic se nezapisuje, jen vypis]' }) ==="
foreach ($n in $skipNotes) { Log $n }

$hadError = $false

foreach ($d in $ready) {
    foreach ($s in $sources) {
        # zdroj se zalohuje jen na cile v onlyDestinations (nezadano = na vsechny)
        $only = @($s.onlyDestinations | Where-Object { $_ })
        if ($only.Count -and ($only -notcontains $d.Name)) { continue }

        if ($s.type -eq 'glob') {
            $base = [Environment]::ExpandEnvironmentVariables($s.base)
            if (-not (Test-Path -LiteralPath $base)) {
                Log "glob $($s.pattern) v $base  preskoceno (base neexistuje)"
                continue
            }
            Get-ChildItem -LiteralPath $base -Force -Filter $s.pattern | ForEach-Object {
                $name = $_.Name
                if ($_.PSIsContainer) {
                    Invoke-Mirror $_.FullName $name $d.Path $d.Name $d.Opts
                }
                elseif ($excludeFiles -contains $name) {
                    # citlivy soubor primo v korenu: preskocit a smazat starou kopii v cili
                    $old = Join-Path $d.Path $name
                    if ($DryRun) {
                        $note = if (Test-Path -LiteralPath $old) { '; stara kopie by se smazala' } else { '' }
                        Log "file $name -> $($d.Name)  preskoceno (citlive)$note"
                    } else {
                        if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue }
                        Log "file $name -> $($d.Name)  preskoceno (citlive)"
                    }
                }
                else {
                    if ($DryRun) {
                        Log "file $name -> $($d.Name)  (dry-run: zkopiroval by se)"
                    } else {
                        try {
                            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $d.Path $name) -Force -ErrorAction Stop
                            Log "file $name -> $($d.Name)  ok"
                        } catch {
                            $hadError = $true
                            Log "file $name -> $($d.Name)  CHYBA: $($_.Exception.Message)"
                        }
                    }
                }
            }
        }
        elseif ($s.type -eq 'dir') {
            $p   = [Environment]::ExpandEnvironmentVariables($s.path)
            $sub = Get-DestSubPath $p
            if (Test-Path -LiteralPath $p -PathType Container) {
                Invoke-Mirror $p $sub $d.Path $d.Name $d.Opts
            } else {
                Log "dir  $sub -> $($d.Name)  preskoceno (neexistuje)"
            }
        }
    }
}

if ($hadError) {
    Log "=== backup done S CHYBAMI ==="
    if ($notifyOnError) { Show-Notification 'ClaudeBackup - chyba' 'Zaloha skoncila s chybou kopirovani. Viz _backup.log.' }
    exit 1
}
Log "=== backup done ok ==="
exit 0
