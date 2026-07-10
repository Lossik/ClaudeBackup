# claude-backup.ps1  (ClaudeBackup 2.0 - config-driven engine)
#
# Zrcadli zdroje na cile (robocopy /MIR). ZADNE zadratovane nastaveni - vse se
# cte z configu (%USERPROFILE%\.config\claude-backup\config.json), ktery odpovida
# config.schema.json.
#
# Layout cile: kazdy zdroj se zalohuje do vlastni "slug" slozky v koreni cile
# (slug se odvozuje z nerozvinuteho korene zdroje, viz Get-SourceSlug), takze
# dva zdroje si nikdy nesahaji do stejneho podstromu - /MIR jednoho nemuze
# smazat data druheho. Kolizi slugu (ruzne koreny -> stejny slug) odmita
# validace jako chybu configu (exit 3).
#
# Kos (volitelny, per cil pres trash.keepDays): polozky, ktere by /MIR smazal,
# se misto toho presunou do <cil>\_kos\<datum>\<slug>\<cesta> a drzi se
# keepDays dni (pak je purge smaze). Ochrana proti "smazal jsem to omylem" -
# na OneDrive nechavej vypnuty (ma vlastni kos i verzovani, setri 5GB kvotu).
#
# Spousteno naplanovanou ulohou ClaudeBackup (po prihlaseni + kazdych 10 min)
# pres claude-backup-hidden.vbs (skryte okno), ktery propaguje navratovy kod.
#
# Navratove kody:
#   0 = ok (vc. preskocenych zamcenych souboru a nedostupneho VOLITELNEHO cile)
#   1 = kopirovaci chyba NEBO nedostupny povinny (ne-volitelny) cil, kdyz jinak zaloha probehla
#   2 = zadny cil neni dostupny
#   3 = config chybi / nejde parsovat / nesedi schema
#       -> engine se v tomto pripade NIKDY nedostane k robocopy /MIR (nemaze!)
#
# Prepinac -DryRun: vypise co by se stalo (robocopy /L) bez jakychkoli zmen na
# disku (nevytvari cile, nekopiruje, nemaze, nezapisuje log). Pro overeni configu.
#
# Pri selhani (exit 1/2/3) engine zobrazi Windows notifikaci (NotifyIcon toast),
# pokud to config nezakazuje (notify.onError:false), neni -NoNotify ani -DryRun.
# Trvajici STEJNA chyba (beh co 10 min) se opakuje az po notify.repeatMinutes
# (vychozi 360); jina chyba se oznami hned. Stav v _notify.json vedle configu,
# uspesny beh ho maze.

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

# --- rate-limit toastu -------------------------------------------------------
# Trvajici stejna chyba by jinak toastovala pri kazdem behu (co 10 min).
# Stejny 'reason' se proto oznami znovu az po $notifyRepeatMin minutach;
# jiny reason hned. Stav v _notify.json vedle configu; uspesny beh ho maze,
# takze prvni toast po zotaveni prijde vzdy okamzite.
$notifyRepeatMin = 360   # zpresni se z notify.repeatMinutes po nacteni configu
$notifyStateFile = Join-Path $configDir '_notify.json'

function Show-ErrorNotification($reason, $title, $text) {
    if ($DryRun -or -not $notifyOnError) { return }
    try {
        if (Test-Path -LiteralPath $notifyStateFile) {
            $st = Get-Content -LiteralPath $notifyStateFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if (($st.reason -eq $reason) -and $st.lastToast -and (([DateTime]::Now - [DateTime]::Parse($st.lastToast)).TotalMinutes -lt $notifyRepeatMin)) { return }
        }
    } catch { }
    Show-Notification $title $text
    try { (@{ reason = $reason; lastToast = [DateTime]::Now.ToString('o') } | ConvertTo-Json -Compress) | Set-Content -LiteralPath $notifyStateFile -Encoding utf8 } catch { }
}

function Stop-BadConfig($msg) {
    Write-BootLog "CONFIG CHYBA: $msg"
    Write-BootLog "=== backup NESPUSTEN (exit 3) ==="
    Show-ErrorNotification 'exit3' 'ClaudeBackup - chyba configu' "Zaloha nebezela: $msg"
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
if ($cfg.notify -and $cfg.notify.repeatMinutes) { $notifyRepeatMin = [int]$cfg.notify.repeatMinutes }

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
    if ($d.trash) {
        $kd = 0
        if (-not [int]::TryParse("$($d.trash.keepDays)", [ref]$kd) -or $kd -lt 1) {
            Stop-BadConfig "cil '$($d.name)' ma neplatny trash.keepDays (cekam cele cislo >= 1)"
        }
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

function Get-SourceRoot($s) {
    # Koren zdroje = NEROZVINUTY retezec z configu (dir: path, glob: base).
    if ($s.type -eq 'glob') { return [string]$s.base } else { return [string]$s.path }
}

function Get-SourceSlug($s) {
    # Slug = jmeno slozky zdroje v cili, odvozene z nerozvinuteho korene zdroje
    # (stabilni, citelne, nezavisle na stroji): %USERPROFILE%\.local\bin
    # -> USERPROFILE_.local_bin, C:\PHP\current -> C_PHP_current.
    # Kazdy zdroj tak ma v cili vlastni strom a /MIR jednoho zdroje nikdy
    # nemaze data jineho. MUSI byt 1:1 se sourceSlug() v claude-backup-cfg.js.
    $t = (Get-SourceRoot $s).Trim().TrimEnd('\', '/')
    $t = $t -replace '%', ''
    $t = $t -replace '[\\/:]+', '_'
    $t = $t -replace '[*?"<>|]', '_'
    $t = $t.Trim('_').TrimEnd('.', ' ')
    return $t
}

# Kolize slugu: ruzne koreny nesmi dat stejny slug (zapisovaly by do stejne
# slozky cile a /MIR by data prubezne mazal). Stejny koren smi slug sdilet -
# zapisy ze stejneho mista na disku jsou idempotentni.
$slugRoots = @{}
foreach ($s in $sources) {
    $slug = Get-SourceSlug $s
    if (-not $slug) { Stop-BadConfig "koren zdroje '$(Get-SourceRoot $s)' dava prazdny slug (nelze odvodit slozku v cili)" }
    $key  = $slug.ToLowerInvariant()
    $root = (Get-SourceRoot $s).Trim().TrimEnd('\', '/').ToLowerInvariant()
    if ($slugRoots.ContainsKey($key)) {
        if ($slugRoots[$key] -ne $root) { Stop-BadConfig "kolize slugu '$slug': koreny '$($slugRoots[$key])' a '$root' by zapisovaly do stejne slozky cile" }
    } else { $slugRoots[$key] = $root }
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

# Datum behu pro kos - jeden beh = jedna datova slozka v _kos.
$trashDate = [DateTime]::Now.ToString('yyyy-MM-dd')

function Move-ExtrasToTrash($baseArgs, $target, $destRoot, $name, $destName) {
    # Pre-pass /MIR /L se STEJNYMI argumenty jako ostry mirror: co by /MIR
    # smazal, hlasi radky '*EXTRA File/Dir' (tagy jsou anglicke i na ceskych
    # Windows; /FP = plne cesty). Tyto polozky se PRESUNOU do
    # <cil>\_kos\<datum>\<name>\<relativni cesta> (move na stejnem svazku =
    # rename, zadne kopirovani), takze nasledny ostry /MIR uz nemaze nic.
    # Stejne jmeno smazane vickrat za den -> v kosi zustava posledni verze.
    # Vypis se cte pres /UNILOG (UTF-16 soubor), NE ze zachyceneho stdout -
    # konzolove kodovani by zkomolilo diakritiku v cestach a polozka by kos
    # minula (Test-Path na spatnou cestu selze a /MIR by ji smazal).
    $listLog = Join-Path $env:TEMP "claude-backup-kos-$PID.log"
    robocopy @($baseArgs + @('/L', '/NP', '/NJH', '/NJS', '/FP', "/UNILOG:$listLog")) | Out-Null
    $listOut = @()
    try { if (Test-Path -LiteralPath $listLog) { $listOut = Get-Content -LiteralPath $listLog -Encoding Unicode } } catch { }
    try { Remove-Item -LiteralPath $listLog -Force -ErrorAction SilentlyContinue } catch { }
    $moved = 0
    foreach ($ln in $listOut) {
        if ($ln -notmatch '\*EXTRA (File|Dir)') { continue }
        $p = ($ln -split "`t")[-1].Trim().TrimEnd('\')
        if (-not $p) { continue }
        # bezpecnost: nikdy nesahat mimo cilovy strom mirroru
        if (-not $p.StartsWith($target, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if (-not (Test-Path -LiteralPath $p)) { continue }   # uz presunuto s nadrazenou slozkou
        $rel  = $p.Substring($target.Length).TrimStart('\')
        $dest = Join-Path $destRoot (Join-Path '_kos' (Join-Path $trashDate (Join-Path $name $rel)))
        try {
            $parent = Split-Path -Parent $dest
            if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent -ErrorAction Stop | Out-Null }
            if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue }
            Move-Item -LiteralPath $p -Destination $dest -Force -ErrorAction Stop
            $moved++
        } catch {
            # nepresunutou polozku smaze nasledny /MIR - zaloha bezi dal, jen
            # tahle polozka kos mine (typicky zamceny soubor)
            Log "kos  $name -> $destName  varovani: nepresunuto '$rel' ($($_.Exception.Message))"
        }
    }
    if ($moved) { Log "kos  $name -> $destName  do kose presunuto polozek: $moved" }
}

function Invoke-Mirror($sourcePath, $name, $destRoot, $destName, $opts, $trashDays) {
    # Pozn.: dlouha vysledna cesta (>260, MAX_PATH) neni problem - mirror dela
    # robocopy, ktery je long-path-aware (overeno na 266 i 512 znacich).
    $target = Join-Path $destRoot $name
    # /MIR zrcadli (vc. mazani), /XJ preskoci junctiony (sdileny obsah),
    # /XF vylouci citlive soubory, /XD vylouci slozky (jen kdyz nejake jsou),
    # /R:1 /W:1 kratke retry. Vystup ostreho behu zahazujeme (mix kodovani
    # robocopy vs PS by poskodil log) a hodnotime jen navratovy kod.
    $baseArgs = @($sourcePath, $target, '/MIR', '/XJ')
    if ($excludeFiles.Count) { $baseArgs += '/XF'; $baseArgs += $excludeFiles }
    if ($excludeDirs.Count)  { $baseArgs += '/XD'; $baseArgs += $excludeDirs }
    $baseArgs += @('/R:1', '/W:1')
    if ($opts) { $baseArgs += @($opts) }

    if ($DryRun) {
        Log "dir  $name -> $destName  (dry-run /L):"
        $out = robocopy @($baseArgs + @('/L', '/NP', '/NJH'))   # jen vypis (vc. souboru a souhrnu)
        $rc  = $LASTEXITCODE
        foreach ($ln in $out) { if ($ln -and $ln.Trim()) { Write-Host "      $ln" } }
        if ($trashDays -ge 1) { Log "dir  $name -> $destName  (cil ma kos ${trashDays} dni: *EXTRA polozky by se presunuly do _kos, ne smazaly)" }
        Log "dir  $name -> $destName  (robocopy $rc)"
        return
    }

    # kos: polozky, ktere by /MIR smazal, nejdriv presunout do _kos
    if ($trashDays -ge 1) { Move-ExtrasToTrash $baseArgs $target $destRoot $name $destName }

    robocopy @($baseArgs + @('/NP', '/NFL', '/NDL', '/NJH', '/NJS')) | Out-Null
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
$ready           = @()
$skipNotes       = @()
$missingRequired = @()   # ne-volitelne (povinne) cile, ktere nejsou dostupne
foreach ($d in $destinations) {
    $root = Resolve-DestRoot $d
    if (-not $root) {
        if ($d.optional) { $skipNotes += "cil  $($d.name)  preskoceno (nedostupny)" }
        else             { $skipNotes += "cil  $($d.name)  NEDOSTUPNY"; $missingRequired += $d.name }
        continue
    }
    $opts = @($d.robocopyOpts | Where-Object { $_ })
    $trashDays = 0
    if ($d.trash -and $d.trash.keepDays) { $trashDays = [int]$d.trash.keepDays }
    if ($DryRun) {
        # nic nevytvarime; dostupnost odhadneme podle existence disku
        $qualifier = try { Split-Path -Qualifier $root } catch { $null }
        if ($qualifier -and (Test-Path -LiteralPath "$qualifier\")) {
            $ready += , ([pscustomobject]@{ Name = $d.name; Path = $root; Opts = $opts; TrashDays = $trashDays })
        } elseif ($d.optional) { $skipNotes += "cil  $($d.name)  preskoceno (nedostupny disk)" }
        else                   { $skipNotes += "cil  $($d.name)  NEDOSTUPNY (disk)"; $missingRequired += $d.name }
        continue
    }
    try {
        New-Item -ItemType Directory -Force -Path $root -ErrorAction Stop | Out-Null
        $ready += , ([pscustomobject]@{ Name = $d.name; Path = $root; Opts = $opts; TrashDays = $trashDays })
    } catch {
        if ($d.optional) { $skipNotes += "cil  $($d.name)  preskoceno (nelze vytvorit: $($_.Exception.Message))" }
        else             { $skipNotes += "cil  $($d.name)  NEDOSTUPNY (nelze vytvorit: $($_.Exception.Message))"; $missingRequired += $d.name }
    }
}
if ($ready.Count -eq 0) {
    Write-BootLog "zadny cil neni dostupny (exit 2)"
    foreach ($n in $skipNotes) { Write-BootLog $n }
    Show-ErrorNotification 'exit2' 'ClaudeBackup - zadny cil' 'Zadny cil zalohy neni dostupny (OneDrive i SSD).'
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
            $slug = Get-SourceSlug $s
            $base = [Environment]::ExpandEnvironmentVariables($s.base)
            if (-not (Test-Path -LiteralPath $base)) {
                Log "glob $($s.pattern) v $base  preskoceno (base neexistuje)"
                continue
            }
            Get-ChildItem -LiteralPath $base -Force -Filter $s.pattern | ForEach-Object {
                $name = $_.Name
                $rel  = Join-Path $slug $name
                if ($_.PSIsContainer) {
                    Invoke-Mirror $_.FullName $rel $d.Path $d.Name $d.Opts $d.TrashDays
                }
                elseif ($excludeFiles -contains $name) {
                    # citlivy soubor primo v korenu: preskocit a smazat starou kopii v cili
                    $old = Join-Path $d.Path $rel
                    if ($DryRun) {
                        $note = if (Test-Path -LiteralPath $old) { '; stara kopie by se smazala' } else { '' }
                        Log "file $rel -> $($d.Name)  preskoceno (citlive)$note"
                    } else {
                        if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue }
                        Log "file $rel -> $($d.Name)  preskoceno (citlive)"
                    }
                }
                else {
                    if ($DryRun) {
                        Log "file $rel -> $($d.Name)  (dry-run: zkopiroval by se)"
                    } else {
                        try {
                            $slugDir = Join-Path $d.Path $slug
                            if (-not (Test-Path -LiteralPath $slugDir)) { New-Item -ItemType Directory -Force -Path $slugDir -ErrorAction Stop | Out-Null }
                            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $d.Path $rel) -Force -ErrorAction Stop
                            Log "file $rel -> $($d.Name)  ok"
                        } catch {
                            $hadError = $true
                            Log "file $rel -> $($d.Name)  CHYBA: $($_.Exception.Message)"
                        }
                    }
                }
            }
        }
        elseif ($s.type -eq 'dir') {
            $p   = [Environment]::ExpandEnvironmentVariables($s.path)
            $sub = Get-SourceSlug $s
            if (Test-Path -LiteralPath $p -PathType Container) {
                Invoke-Mirror $p $sub $d.Path $d.Name $d.Opts $d.TrashDays
            } else {
                Log "dir  $sub -> $($d.Name)  preskoceno (neexistuje)"
            }
        }
    }
}

# --- kos: purge starych datovych slozek -------------------------------------
# Jedine mazani mimo /MIR - striktne jen <cil>\_kos\<yyyy-MM-dd> starsi nez
# keepDays daneho cile. Slozky s jinym nazvem se nechavaji byt.
if (-not $DryRun) {
    foreach ($d in $ready) {
        if ($d.TrashDays -lt 1) { continue }
        $kos = Join-Path $d.Path '_kos'
        if (-not (Test-Path -LiteralPath $kos)) { continue }
        $limit = [DateTime]::Today.AddDays(-$d.TrashDays)
        foreach ($sub in @(Get-ChildItem -LiteralPath $kos -Directory -ErrorAction SilentlyContinue)) {
            $dt = [DateTime]::MinValue
            if ([DateTime]::TryParseExact($sub.Name, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$dt) -and ($dt -lt $limit)) {
                try {
                    Remove-Item -LiteralPath $sub.FullName -Recurse -Force -ErrorAction Stop
                    Log "kos  $($d.Name)  smazana stara slozka kose: $($sub.Name)"
                } catch {
                    Log "kos  $($d.Name)  varovani: nejde smazat $($sub.Name) ($($_.Exception.Message))"
                }
            }
        }
    }
}

if ($hadError -or $missingRequired.Count) {
    $reasons = @()
    if ($missingRequired.Count) { $reasons += "nedostupny povinny cil: $($missingRequired -join ', ')" }
    if ($hadError)              { $reasons += "chyba kopirovani (viz _backup.log)" }
    $why = $reasons -join '; '
    Log "=== backup done S CHYBAMI ($why) ==="
    Show-ErrorNotification 'exit1' 'ClaudeBackup - chyba' "$why."
    exit 1
}
Log "=== backup done ok ==="
# uspech resetuje rate-limit toastu - dalsi (nova) chyba se oznami hned
if (-not $DryRun) { try { Remove-Item -LiteralPath $notifyStateFile -Force -ErrorAction SilentlyContinue } catch { } }
exit 0
