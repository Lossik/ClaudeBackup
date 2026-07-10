# claude-restore.ps1  (obnova zalohy zpet na puvodni cesty)
#
# Opacny smer nez engine: cte config, spocita slugy zdroju (stejny algoritmus
# jako Get-SourceSlug v claude-backup.ps1) a kopiruje <koren zalohy>\<slug>
# zpet na cestu zdroje. Zadna inverze slugu neni potreba - mapovani se vzdy
# odvozuje z configu.
#
# Bezpecnostni semantika (obnova prepisuje ZIVA data):
#   - default je robocopy /E BEZ mazani: doplni/prepise soubory ze zalohy,
#     nic ziveho nesmaze,
#   - -Mirror = presne zrcadlo (smaze, co v zaloze neni) - ale JEN uvnitr
#     obnovovanych stromu; u glob zdroju se zrcadli kazda polozka zvlast,
#     base slozka samotna (napr. cely %USERPROFILE%) se NIKDY nezrcadli,
#   - -DryRun (robocopy /L) nic nezapisuje,
#   - bez -Yes se pred zapisem interaktivne potvrzuje (neinteraktivni beh
#     bez -Yes skonci bez zmen),
#   - .credentials.json se NIKDY neobnovuje (/XF; v zaloze ani nema byt).
#
# Rezimy:
#   claude-restore.ps1                          config z profilu, obnova z primarniho cile
#   claude-restore.ps1 -From extSSD             obnova z jineho cile z configu
#   claude-restore.ps1 -FromBackup E:\...\claude  koren zalohy zadan primo; config se
#                                               najde V ZALOZE (disaster recovery na
#                                               novem stroji - zaloha je sobestacna)
#   claude-restore.ps1 -Only USERPROFILE_Claude,2   jen vybrane zdroje (slug nebo poradi)
#
# Navratove kody: 0 ok / 1 chyba kopirovani nebo nenalezeny -Only zdroj /
#   2 koren zalohy nedostupny / 3 config chybi ci neplatny / 4 neodsouhlaseno.

param(
    [string]$ConfigPath = (Join-Path $env:USERPROFILE '.config\claude-backup\config.json'),
    [string]$FromBackup,
    [string]$From,
    [string[]]$Only,
    [switch]$Mirror,
    [switch]$DryRun,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'

function Say($m) { Write-Host $m }
function Fail($code, $m) { Write-Host "CHYBA: $m"; exit $code }

# --- slug (MUSI byt 1:1 s Get-SourceSlug v claude-backup.ps1) ---------------
function Get-SourceRoot($s) {
    if ($s.type -eq 'glob') { return [string]$s.base } else { return [string]$s.path }
}
function Get-SourceSlug($s) {
    $t = (Get-SourceRoot $s).Trim().TrimEnd('\', '/')
    $t = $t -replace '%', ''
    $t = $t -replace '[\\/:]+', '_'
    $t = $t -replace '[*?"<>|]', '_'
    $t = $t.Trim('_').TrimEnd('.', ' ')
    return $t
}

# --- env expanze (shodna s enginem) -----------------------------------------
function Resolve-EnvPath($path, $fallbacks) {
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
    if ($d.type -eq 'path') { return (Resolve-EnvPath $d.path $d.envFallback) }
    elseif ($d.type -eq 'volumeLabel') {
        $letter = (Get-Volume -FileSystemLabel $d.label -ErrorAction SilentlyContinue).DriveLetter
        if (-not $letter) { return $null }
        return (Join-Path "${letter}:\" $d.subPath)
    }
    return $null
}

# --- config: odkud ho vzit ---------------------------------------------------
function Read-Config($p) {
    try { return (Get-Content -LiteralPath $p -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop) }
    catch { return $null }
}

$cfg = $null
if ($PSBoundParameters.ContainsKey('ConfigPath')) {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { Fail 3 "config neexistuje: $ConfigPath" }
    $cfg = Read-Config $ConfigPath
    if (-not $cfg) { Fail 3 "config nejde precist/parsovat: $ConfigPath" }
} elseif ($FromBackup) {
    # config se hleda primo v zaloze (slug slozka se souborem config.json)
    if (-not (Test-Path -LiteralPath $FromBackup -PathType Container)) { Fail 2 "koren zalohy neexistuje: $FromBackup" }
    $found = @()
    foreach ($dir in (Get-ChildItem -LiteralPath $FromBackup -Directory)) {
        $cand = Join-Path $dir.FullName 'config.json'
        if (Test-Path -LiteralPath $cand -PathType Leaf) {
            $c = Read-Config $cand
            if ($c -and $c.version -eq 1 -and $c.sources) { $found += , @($cand, $c) }
        }
    }
    if ($found.Count -eq 0) { Fail 3 "v zaloze neni zadny pouzitelny config.json - zadej -ConfigPath" }
    if ($found.Count -gt 1) { Fail 3 "v zaloze je vic configu ($(($found | ForEach-Object { $_[0] }) -join ', ')) - zadej -ConfigPath" }
    Say "config nalezen v zaloze: $($found[0][0])"
    $cfg = $found[0][1]
} else {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { Fail 3 "config neexistuje: $ConfigPath (na novem stroji pouzij -FromBackup <koren zalohy>)" }
    $cfg = Read-Config $ConfigPath
    if (-not $cfg) { Fail 3 "config nejde precist/parsovat: $ConfigPath" }
}

if ($cfg.version -ne 1) { Fail 3 "nepodporovana verze configu: '$($cfg.version)'" }
$sources = @($cfg.sources | Where-Object { $null -ne $_ })
if ($sources.Count -lt 1) { Fail 3 "config nema zadne zdroje" }

# --- koren zalohy -------------------------------------------------------------
$backupRoot = $null
$backupName = $null
if ($FromBackup) {
    if ($From) { Say "pozn.: -From se s -FromBackup ignoruje (koren je zadan primo)" }
    $backupRoot = $FromBackup
    $backupName = "(-FromBackup)"
} else {
    $destinations = @($cfg.destinations | Where-Object { $null -ne $_ })
    if ($destinations.Count -lt 1) { Fail 3 "config nema zadne cile" }
    $d = $null
    if ($From) {
        $d = $destinations | Where-Object { $_.name -eq $From } | Select-Object -First 1
        if (-not $d) { Fail 3 "cil '$From' v configu neni (k dispozici: $(($destinations | ForEach-Object { $_.name }) -join ', '))" }
    } else {
        $d = $destinations | Where-Object { $_.primary -eq $true } | Select-Object -First 1
        if (-not $d) { $d = $destinations[0] }
    }
    $backupRoot = Resolve-DestRoot $d
    $backupName = $d.name
    if (-not $backupRoot) { Fail 2 "cil '$($d.name)' neni dostupny (nepripojeny disk?)" }
}
if (-not (Test-Path -LiteralPath $backupRoot -PathType Container)) { Fail 2 "koren zalohy neexistuje: $backupRoot" }

# --- plan obnovy ---------------------------------------------------------------
# .credentials.json se neobnovuje NIKDY (v zaloze ani nema byt - obrana do hloubky)
$xf = @($cfg.excludeFiles | Where-Object { $_ })
if ($xf -notcontains '.credentials.json') { $xf += '.credentials.json' }

$plan = @()   # polozky: Idx, Slug, Type, SlugDir, Target, Exists
for ($i = 0; $i -lt $sources.Count; $i++) {
    $s = $sources[$i]
    $slug = Get-SourceSlug $s
    $target = [Environment]::ExpandEnvironmentVariables((Get-SourceRoot $s))
    $slugDir = Join-Path $backupRoot $slug
    $plan += , ([pscustomobject]@{
        Idx = $i + 1; Slug = $slug; Type = $s.type
        SlugDir = $slugDir; Target = $target
        Exists = (Test-Path -LiteralPath $slugDir -PathType Container)
    })
}

$missingOnly = @()
if ($Only) {
    $sel = @()
    foreach ($o in $Only) {
        $hit = $null
        if ("$o" -match '^\d+$') { $hit = $plan | Where-Object { $_.Idx -eq [int]$o } }
        else { $hit = $plan | Where-Object { $_.Slug -ieq "$o" } }
        if ($hit) { $sel += $hit } else { $missingOnly += "$o" }
    }
    if ($missingOnly.Count) {
        Say "nenalezene zdroje v -Only: $($missingOnly -join ', ')"
        Say "k dispozici (poradi / slug):"
        foreach ($p in $plan) { Say "  $($p.Idx). $($p.Slug)" }
        exit 1
    }
    $plan = @($sel | Select-Object -Unique)
}

Say "=== OBNOVA ze zalohy: $backupRoot ($backupName)$(if ($DryRun) { '  [DRY-RUN]' }) ==="
Say "rezim: $(if ($Mirror) { 'MIRROR (uvnitr obnovovanych stromu maze, co v zaloze neni)' } else { 'doplneni/prepis bez mazani (/E)' })"
foreach ($p in $plan) {
    $note = if ($p.Exists) { '' } else { '  [V ZALOZE CHYBI - preskoci se]' }
    Say ("  {0}. {1,-4} {2}  ->  {3}{4}" -f $p.Idx, $p.Type, $p.Slug, $p.Target, $note)
}
$todo = @($plan | Where-Object { $_.Exists })
if ($todo.Count -eq 0) { Say "nic k obnove (zadny vybrany slug v zaloze neexistuje)"; exit 0 }

if (-not $DryRun -and -not $Yes) {
    $ans = $null
    try { $ans = Read-Host "Pokracovat a ZAPSAT na vyse uvedene cesty? [a/N]" }
    catch { Fail 4 "neinteraktivni beh bez -Yes - nic se nezmenilo (pridej -Yes nebo spust v konzoli)" }
    if ($ans -notin @('a', 'A', 'ano', 'y', 'yes')) { Say "zruseno - nic se nezmenilo"; exit 4 }
}

# --- provedeni -----------------------------------------------------------------
$hadError = $false
function Invoke-RestoreCopy($src, $dst, [bool]$mir) {
    # /XJ preskoci junctiony, /XF nikdy neobnovi citlive soubory
    $roboArgs = @($src, $dst, $(if ($mir) { '/MIR' } else { '/E' }), '/XJ', '/XF') + $xf + @('/R:1', '/W:1')
    if ($DryRun) { $roboArgs += @('/L', '/NP', '/NJH') } else { $roboArgs += @('/NP', '/NFL', '/NDL', '/NJH', '/NJS') }
    if ($DryRun) {
        $out = robocopy @roboArgs
        foreach ($ln in $out) { if ($ln -and $ln.Trim()) { Say "      $ln" } }
    } else {
        robocopy @roboArgs | Out-Null
    }
    return $LASTEXITCODE
}

foreach ($p in $todo) {
    if ($p.Type -eq 'dir' -or -not $Mirror) {
        # dir zdroj: slug slozka = cely strom zdroje. glob bez -Mirror: obsah
        # slug slozky (jen glob-matchnute polozky) se doplni do base.
        $rc = Invoke-RestoreCopy $p.SlugDir $p.Target $Mirror
        if ($rc -ge 8) { $script:hadError = $true; Say "  $($p.Slug) -> $($p.Target)  CHYBA (robocopy $rc)" }
        else           { Say "  $($p.Slug) -> $($p.Target)  ok (robocopy $rc)" }
    } else {
        # glob + -Mirror: zrcadlit KAZDOU polozku zvlast; base samotna se nikdy
        # nezrcadli (obsahuje i neglobovana ziva data, napr. cely profil)
        Get-ChildItem -LiteralPath $p.SlugDir -Force | ForEach-Object {
            $dst = Join-Path $p.Target $_.Name
            if ($_.PSIsContainer) {
                $rc = Invoke-RestoreCopy $_.FullName $dst $true
                if ($rc -ge 8) { $script:hadError = $true; Say "  $($p.Slug)\$($_.Name) -> $dst  CHYBA (robocopy $rc)" }
                else           { Say "  $($p.Slug)\$($_.Name) -> $dst  ok (robocopy $rc)" }
            } elseif ($xf -contains $_.Name) {
                Say "  $($p.Slug)\$($_.Name)  preskoceno (citlive - neobnovuje se)"
            } elseif ($DryRun) {
                Say "  $($p.Slug)\$($_.Name) -> $dst  (dry-run: zkopiroval by se)"
            } else {
                try {
                    if (-not (Test-Path -LiteralPath $p.Target)) { New-Item -ItemType Directory -Force -Path $p.Target | Out-Null }
                    Copy-Item -LiteralPath $_.FullName -Destination $dst -Force -ErrorAction Stop
                    Say "  $($p.Slug)\$($_.Name) -> $dst  ok"
                } catch {
                    $script:hadError = $true
                    Say "  $($p.Slug)\$($_.Name) -> $dst  CHYBA: $($_.Exception.Message)"
                }
            }
        }
    }
}

Say "=== obnova $(if ($DryRun) { 'dry-run ' })dokoncena$(if ($hadError) { ' S CHYBAMI' }) ==="
Say "pozn.: .credentials.json se zamerne neobnovuje - po obnove .claude se do Claude prihlas znovu."
if ($hadError) { exit 1 }
exit 0
