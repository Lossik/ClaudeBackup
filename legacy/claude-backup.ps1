# claude-backup.ps1
# Zaloha vsech ~/.claude* adresaru a souboru na OneDrive + externi SSD (zrcadleni).
# Spousteno naplanovanou ulohou ClaudeBackup (po prihlaseni + kazdych 10 min).
#
# Navratove kody:
#   0 = ok (vc. preskocenych zamcenych souboru a nepripojeneho externiho disku)
#   1 = doslo ke kopirovaci chybe
#   2 = zadny cil neni dostupny

$ErrorActionPreference = 'Stop'

# --- zdroj ---
$src = $env:USERPROFILE

# citlive soubory, ktere se NIKDY nezalohuji (obsahuji tokeny)
$excludeFiles = @('.credentials.json')

# dalsi slozky v profilu, ktere se zalohuji krome .claude*
# (nepridavat .ssh - obsahuje privatni klice, do cloudu nepatri)
$extraDirs = @('.local\bin', 'Claude')

# vetsi pracovni slozky - zalohuji se JEN na externi SSD (OneDrive ma pouze 5 GB)
$extraDirsSsdOnly = @()

# --- cile ---
# 1) OneDrive (primarni, je v nem i log)
$oneDriveRoot = if     ($env:OneDrive)         { $env:OneDrive }
                elseif ($env:OneDriveConsumer) { $env:OneDriveConsumer }
                else                           { Join-Path $env:USERPROFILE 'OneDrive' }

# 2) externi SSD Kingston XS1000 - hledame podle jmenovky svazku, pismeno se muze menit;
#    exFAT ma hrubsi casova razitka, proto /FFT (jinak by robocopy porad prekopiroval vse)
$extLetter = (Get-Volume -FileSystemLabel 'KINGSTON' -ErrorAction SilentlyContinue).DriveLetter

$destinations = @(
    @{ Name = 'OneDrive'; Path = (Join-Path $oneDriveRoot 'Backups\claude'); Opts = @() }
)
if ($extLetter) {
    $destinations += @{ Name = 'extSSD'; Path = "${extLetter}:\Backups\claude"; Opts = @('/FFT') }
}

$log = Join-Path $destinations[0].Path '_backup.log'

function Log($m) {
    $line = "$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))  $m"
    try { Add-Content -Path $log -Value $line -Encoding utf8 } catch { }
}

# --- priprava cilu; nedostupne vyradit ---
$ready = @()
foreach ($d in $destinations) {
    try {
        New-Item -ItemType Directory -Force -Path $d.Path -ErrorAction Stop | Out-Null
        $ready += ,$d
    } catch { }
}
if ($ready.Count -eq 0) { exit 2 }

# orizni log kdyz preroste 1 MB
if ((Test-Path $log) -and ((Get-Item $log).Length -gt 1MB)) {
    (Get-Content $log -Tail 300) | Set-Content $log -Encoding utf8
}

Log "=== backup start ==="
if (-not $extLetter) { Log "cil  extSSD  preskoceno (KINGSTON nepripojen)" }

$hadError = $false

function Mirror-Dir($sourcePath, $name, $destRoot, $destName, $opts) {
    $target = Join-Path $destRoot $name
    # /MIR zrcadli (vc. mazani smazanych), /XJ preskoci junctiony (sdileny obsah),
    # /XF vylouci tokeny, /R:1 /W:1 kratke retry, tichy vystup.
    # Vystup zahazujeme (mix kodovani robocopy vs PS by poskodil log) a hodnotime jen navratovy kod.
    robocopy $sourcePath $target /MIR /XJ /XF $excludeFiles /R:1 /W:1 /NP /NFL /NDL /NJH /NJS @opts | Out-Null
    $rc = $LASTEXITCODE
    if ($rc -ge 16) {
        $script:hadError = $true
        Log "dir  $name -> $destName  CHYBA (robocopy $rc)"
    } elseif ($rc -ge 8) {
        # nektere soubory nesly zkopirovat (napr. zamcene aktivni session) - dokopiruji se priste
        Log "dir  $name -> $destName  varovani: nektere soubory preskoceny (robocopy $rc)"
    } else {
        Log "dir  $name -> $destName  ok (robocopy $rc)"
    }
}

foreach ($d in $ready) {
    Get-ChildItem $src -Force -Filter '.claude*' | ForEach-Object {
        $name = $_.Name

        if ($_.PSIsContainer) {
            Mirror-Dir $_.FullName $name $d.Path $d.Name $d.Opts
        }
        elseif ($excludeFiles -contains $name) {
            # citlivy soubor primo v korenu profilu: preskocit a smazat pripadnou starou kopii
            $old = Join-Path $d.Path $name
            if (Test-Path $old) { Remove-Item $old -Force -ErrorAction SilentlyContinue }
            Log "file $name -> $($d.Name)  preskoceno (citlive)"
        }
        else {
            try {
                Copy-Item $_.FullName -Destination (Join-Path $d.Path $name) -Force -ErrorAction Stop
                Log "file $name -> $($d.Name)  ok"
            } catch {
                $hadError = $true
                Log "file $name -> $($d.Name)  CHYBA: $($_.Exception.Message)"
            }
        }
    }

    $extras = $extraDirs
    if ($d.Name -eq 'extSSD') { $extras = $extras + $extraDirsSsdOnly }

    foreach ($e in $extras) {
        $p = Join-Path $src $e
        if (Test-Path $p -PathType Container) {
            Mirror-Dir $p $e $d.Path $d.Name $d.Opts
        } else {
            Log "dir  $e -> $($d.Name)  preskoceno (neexistuje)"
        }
    }
}

if ($hadError) {
    Log "=== backup done S CHYBAMI ==="
    exit 1
}
Log "=== backup done ok ==="
exit 0
