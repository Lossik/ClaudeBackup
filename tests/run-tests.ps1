# tests/run-tests.ps1 - kompletni sandbox testy (engine, editor, restore,
# watchdog, deploy -WhatIf). Nic nesaha na realny config (~/.config) ani cile;
# vse bezi v %TEMP%\cbtest (kratka cesta - slug koduje celou cestu zdroje a
# dlouhy sandbox by prehnal cil pres MAX_PATH, limit Copy-Item v PS 5.1).
#
# Spusteni:  powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1
# Pozn.: test rate-limitu toastu zobrazi JEDEN skutecny toast (overuje, ze
# druhy beh se stejnou chybou uz toast neopakuje).

$ErrorActionPreference = 'Stop'
$repo     = Split-Path -Parent $PSScriptRoot
$S        = Join-Path $env:TEMP 'cbtest'
$engine   = Join-Path $repo 'claude-backup.ps1'
$editor   = Join-Path $repo 'claude-backup-cfg.js'
$restore  = Join-Path $repo 'claude-restore.ps1'
$watchdog = Join-Path $repo 'claude-backup-watchdog.ps1'
$deploy   = Join-Path $repo 'deploy.ps1'
$node     = Join-Path $env:USERPROFILE '.local\nodejs\node.exe'
$fail = 0

function Check($name, $cond) {
    if ($cond) { Write-Host "PASS  $name" }
    else { Write-Host "FAIL  $name"; $script:fail++ }
}
function WriteJson($path, $obj) {
    # bez BOM (PS5.1 -Encoding utf8 pise BOM a JSON.parse v Node ho odmita)
    [IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))
}
function Slug($p) {
    # ocekavany slug (stejny algoritmus jako engine/editor)
    $t = $p.Trim().TrimEnd('\', '/'); $t = $t -replace '%', ''
    $t = $t -replace '[\\/:]+', '_'; $t = $t -replace '[*?"<>|]', '_'
    return $t.Trim('_').TrimEnd('.', ' ')
}

Remove-Item -Recurse -Force $S -ErrorAction SilentlyContinue

# ============================ 0) syntaxe =====================================
foreach ($f in @($engine, $restore, $watchdog, $deploy)) {
    $errs = $null
    [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$errs) | Out-Null
    Check "0. parser bez chyb: $(Split-Path -Leaf $f)" ($errs.Count -eq 0)
}
$hasNode = Test-Path -LiteralPath $node
if ($hasNode) {
    & $node --check $editor
    Check '0. editor: syntaxe ok (node --check)' ($LASTEXITCODE -eq 0)
} else {
    Write-Host "SKIP  editor testy (portable node nenalezen: $node)"
}

# ============================ A) engine: slug layout =========================
New-Item -ItemType Directory -Force -Path "$S\globbase\.claude", "$S\srcA", "$S\dest1" | Out-Null
Set-Content "$S\globbase\.claude\settings.json" '{"a":1}'
Set-Content "$S\globbase\.claude.json" '{}'
Set-Content "$S\globbase\.credentials.json" 'SECRET'
Set-Content "$S\srcA\file.txt" 'hello'

$cfg = [ordered]@{
    version = 1
    sources = @(
        [ordered]@{ type = 'glob'; base = "$S\globbase"; pattern = '.c*' },
        [ordered]@{ type = 'dir';  path = "$S\srcA" }
    )
    excludeFiles = @('.credentials.json')
    destinations = @([ordered]@{ name = 'T1'; type = 'path'; path = "$S\dest1"; primary = $true })
}
$cfgPath = "$S\config.json"
WriteJson $cfgPath $cfg
$slugGlob = Slug "$S\globbase"
$slugDir  = Slug "$S\srcA"

$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine -ConfigPath $cfgPath -DryRun -NoNotify 2>&1 | Out-String
Check 'A1. dry-run: exit 0' ($LASTEXITCODE -eq 0)
Check 'A1. dry-run: vypis obsahuje slug globu' ($out -match [regex]::Escape("$slugGlob\.claude"))
Check 'A1. dry-run: nic se nevytvorilo v cili' (-not (Get-ChildItem "$S\dest1" -ErrorAction SilentlyContinue))

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine -ConfigPath $cfgPath -NoNotify | Out-Null
Check 'A2. beh: exit 0' ($LASTEXITCODE -eq 0)
Check 'A2. beh: glob dir ve slug slozce' (Test-Path "$S\dest1\$slugGlob\.claude\settings.json")
Check 'A2. beh: glob soubor ve slug slozce' (Test-Path "$S\dest1\$slugGlob\.claude.json")
Check 'A2. beh: dir zdroj ve slug slozce' (Test-Path "$S\dest1\$slugDir\file.txt")
Check 'A2. beh: .credentials.json NENI v cili' (-not (Get-ChildItem "$S\dest1" -Recurse -Filter '.credentials.json'))
Check 'A2. beh: _backup.log v primarnim cili' (Test-Path "$S\dest1\_backup.log")

Set-Content "$S\dest1\$slugGlob\.credentials.json" 'OLDSECRET'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine -ConfigPath $cfgPath -NoNotify | Out-Null
Check 'A3. 2. beh: exit 0 (idempotentni)' ($LASTEXITCODE -eq 0)
Check 'A3. 2. beh: stara citliva kopie smazana' (-not (Test-Path "$S\dest1\$slugGlob\.credentials.json"))

$bad = [ordered]@{
    version = 1
    sources = @(
        [ordered]@{ type = 'dir'; path = 'C:\a\b' },
        [ordered]@{ type = 'dir'; path = 'C:\a_b' }
    )
    excludeFiles = @('.credentials.json')
    destinations = @([ordered]@{ name = 'T1'; type = 'path'; path = "$S\destBad"; primary = $true })
}
$badPath = "$S\config-bad.json"
WriteJson $badPath $bad
$out4 = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine -ConfigPath $badPath -NoNotify 2>&1 | Out-String
Check 'A4. kolize slugu: exit 3' ($LASTEXITCODE -eq 3)
Check 'A4. kolize slugu: hlaska jmenuje slug' ($out4 -match "kolize slugu 'C_a_b'")
Check 'A4. kolize slugu: cil nevytvoren (zadny robocopy)' (-not (Test-Path "$S\destBad"))

# ============================ B) editor ======================================
if ($hasNode) {
    $out5 = "q`n" | & $node $editor --config $cfgPath 2>&1 | Out-String
    Check 'B1. render ukazuje slug zdroje' ($out5 -match [regex]::Escape("->  $slugDir\"))

    $out6 = "u`nq`n" | & $node $editor --config $badPath 2>&1 | Out-String
    Check 'B2. kolizni config nejde ulozit' ($out6 -match 'NELZE ULOZIT' -and $out6 -match "kolize slugu 'C_a_b'")

    New-Item -ItemType Directory -Force -Path "$S\dest1\.claude", "$S\dest1\.local\bin" | Out-Null
    Set-Content "$S\dest1\sirotek.txt" 'x'
    $out7 = "k`na`nq`n" | & $node $editor --config $cfgPath 2>&1 | Out-String
    Check 'B3. uklid: vypsal sirotky' ($out7 -match [regex]::Escape("$S\dest1\.claude") -and $out7 -match 'sirotek\.txt')
    Check 'B3. uklid: sirotci smazani' (-not (Test-Path "$S\dest1\.claude") -and -not (Test-Path "$S\dest1\sirotek.txt"))
    Check 'B3. uklid: slug slozky a log zustaly' ((Test-Path "$S\dest1\$slugGlob") -and (Test-Path "$S\dest1\_backup.log"))

    Set-Content "$S\dest1\sirotek2.txt" 'x'
    $out8 = "k`nn`nq`n" | & $node $editor --config $cfgPath 2>&1 | Out-String
    Check 'B4. uklid: bez potvrzeni ponechano' ((Test-Path "$S\dest1\sirotek2.txt") -and $out8 -match 'ponechano')
    Remove-Item "$S\dest1\sirotek2.txt" -Force

    $out9 = "t`nq`n" | & $node $editor --config $cfgPath 2>&1 | Out-String
    Check 'B5. dry-run pres editor [t]' ($out9 -match 'navratovy kod enginu: 0')
}

# ============================ C) restore =====================================
$R = "$S\restore"
New-Item -ItemType Directory -Force -Path "$R\live\globbase\.claude", "$R\live\srcA\sub", "$R\live\cfgdir", "$R\dest1" | Out-Null
Set-Content "$R\live\globbase\.claude\settings.json" 'SET1'
Set-Content "$R\live\globbase\.claude.json" 'CJ1'
Set-Content "$R\live\srcA\file.txt" 'F1'
Set-Content "$R\live\srcA\sub\deep.txt" 'D1'
$rcfg = [ordered]@{
    version = 1
    sources = @(
        [ordered]@{ type = 'glob'; base = "$R\live\globbase"; pattern = '.claude*' },
        [ordered]@{ type = 'dir';  path = "$R\live\srcA" },
        [ordered]@{ type = 'dir';  path = "$R\live\cfgdir" }
    )
    excludeFiles = @('.credentials.json')
    destinations = @([ordered]@{ name = 'T1'; type = 'path'; path = "$R\dest1"; primary = $true })
}
$rcfgPath = "$R\live\cfgdir\config.json"   # config uvnitr zdroje -> je i v zaloze
WriteJson $rcfgPath $rcfg
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine -ConfigPath $rcfgPath -NoNotify | Out-Null
Check 'C0. setup: zaloha probehla' ($LASTEXITCODE -eq 0)
$rSlugGlob = Slug "$R\live\globbase"
$rSlugA    = Slug "$R\live\srcA"

Remove-Item "$R\live\srcA\file.txt" -Force
$outC1 = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $restore -ConfigPath $rcfgPath -DryRun 2>&1 | Out-String
Check 'C1. dry-run: exit 0, nic neobnovil' (($LASTEXITCODE -eq 0) -and -not (Test-Path "$R\live\srcA\file.txt"))

& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $restore -ConfigPath $rcfgPath *> $null
Check 'C2. bez -Yes neinteraktivne: exit 4, nic nezapsal' (($LASTEXITCODE -eq 4) -and -not (Test-Path "$R\live\srcA\file.txt"))

Set-Content "$R\live\srcA\extra.txt" 'EXTRA'
Set-Content "$R\live\globbase\.claude\novy.txt" 'NEW'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $restore -ConfigPath $rcfgPath -Yes | Out-Null
Check 'C3. obnova: smazany soubor vracen, extra prezil' ((Test-Path "$R\live\srcA\file.txt") -and (Test-Path "$R\live\srcA\extra.txt") -and (Test-Path "$R\live\globbase\.claude\novy.txt"))

Remove-Item "$R\live\srcA\file.txt", "$R\live\globbase\.claude.json" -Force
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $restore -ConfigPath $rcfgPath -Yes -Only $rSlugA | Out-Null
Check 'C4. -Only: vybrany obnoven, ostatni ne' ((Test-Path "$R\live\srcA\file.txt") -and -not (Test-Path "$R\live\globbase\.claude.json"))
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $restore -ConfigPath $rcfgPath -Yes -Only 'NEEXISTUJE' *> $null
Check 'C4. -Only neznamy: exit 1' ($LASTEXITCODE -eq 1)

Set-Content "$R\live\globbase\mimo-glob.txt" 'LIVE'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $restore -ConfigPath $rcfgPath -Yes -Mirror | Out-Null
Check 'C5. mirror: maze uvnitr stromu' ((-not (Test-Path "$R\live\srcA\extra.txt")) -and -not (Test-Path "$R\live\globbase\.claude\novy.txt"))
Check 'C5. mirror: base glob zdroje NEZRCADLENA' (Test-Path "$R\live\globbase\mimo-glob.txt")
Check 'C5. mirror: obsah vracen' ((Test-Path "$R\live\globbase\.claude.json") -and (Test-Path "$R\live\srcA\file.txt"))

Set-Content "$R\dest1\$rSlugGlob\.credentials.json" 'BADTOKEN'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $restore -ConfigPath $rcfgPath -Yes -Mirror | Out-Null
Check 'C6. podvrzeny .credentials.json se neobnovi' (-not (Test-Path "$R\live\globbase\.credentials.json"))
Remove-Item "$R\dest1\$rSlugGlob\.credentials.json" -Force

Remove-Item -Recurse -Force "$R\live"
$outC7 = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $restore -FromBackup "$R\dest1" -Yes 2>&1 | Out-String
Check 'C7. -FromBackup: config ze zalohy, vse obnoveno' (($LASTEXITCODE -eq 0) -and ($outC7 -match 'config nalezen v zaloze') -and (Test-Path "$R\live\srcA\sub\deep.txt") -and (Test-Path "$R\live\cfgdir\config.json"))

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $restore -FromBackup "$R\neexistuje" -Yes *> $null
Check 'C8. nedostupna zaloha: exit 2' ($LASTEXITCODE -eq 2)

# ============================ D) rate-limit toastu ===========================
# Vlastni config dir, at _notify.json nikam nezasahuje. Prvni chybny beh
# zobrazi JEDEN skutecny toast; druhy uz musi byt potlaceny (stejny duvod).
$D = "$S\notify"
New-Item -ItemType Directory -Force -Path $D | Out-Null
$dbad = [ordered]@{ version = 1; sources = @(); excludeFiles = @('.credentials.json'); destinations = @() }
WriteJson "$D\config.json" $dbad
Write-Host '      (ted se zobrazi 1 testovaci toast "chyba configu")'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine -ConfigPath "$D\config.json" *> $null
Check 'D1. chybny beh: exit 3 + _notify.json vznikl' (($LASTEXITCODE -eq 3) -and (Test-Path "$D\_notify.json"))
$stamp1 = (Get-Content "$D\_notify.json" -Raw | ConvertFrom-Json).lastToast
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine -ConfigPath "$D\config.json" *> $null
$stamp2 = (Get-Content "$D\_notify.json" -Raw | ConvertFrom-Json).lastToast
Check 'D2. stejna chyba znovu: toast potlacen (timestamp beze zmeny)' ($stamp1 -eq $stamp2)
# uspesny beh (validni config) stav maze -> dalsi chyba by toastovala hned
New-Item -ItemType Directory -Force -Path "$D\src", "$D\dst" | Out-Null
Set-Content "$D\src\f.txt" 'x'
$dok = [ordered]@{
    version = 1
    sources = @([ordered]@{ type = 'dir'; path = "$D\src" })
    excludeFiles = @('.credentials.json')
    destinations = @([ordered]@{ name = 'T'; type = 'path'; path = "$D\dst"; primary = $true })
}
WriteJson "$D\config.json" $dok
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine -ConfigPath "$D\config.json" *> $null
Check 'D3. uspesny beh: exit 0 + _notify.json smazan' (($LASTEXITCODE -eq 0) -and -not (Test-Path "$D\_notify.json"))

# ============================ E) watchdog ====================================
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $watchdog -TaskName 'CbTestNeexistujiciUloha' -NoNotify *> $null
Check 'E1. neexistujici uloha: exit 1' ($LASTEXITCODE -eq 1)
if (Get-ScheduledTask -TaskName 'ClaudeBackup' -ErrorAction SilentlyContinue) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $watchdog -TaskName 'ClaudeBackup' -MaxAgeMinutes 525600 -NoNotify *> $null
    Check 'E2. zdrava uloha: exit 0' ($LASTEXITCODE -eq 0)
} else {
    Write-Host 'SKIP  E2. uloha ClaudeBackup na tomto stroji neexistuje'
}

# ============================ F) deploy -WhatIf ==============================
$outF = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $deploy -WhatIf -CreateTask 2>&1 | Out-String
Check 'F1. deploy -WhatIf -CreateTask: exit 0, nic nemeni' (($LASTEXITCODE -eq 0) -and ($outF -match 'WHATIF'))

# ============================ G) kos (trash.keepDays) ========================
$K = "$S\kos"
New-Item -ItemType Directory -Force -Path "$K\src\sub", "$K\dst1", "$K\dst2" | Out-Null
Set-Content "$K\src\a.txt" 'A'
Set-Content "$K\src\sub\b.txt" 'B'
# diakritika ve jmene souboru (roundtrip pres parsovani vystupu robocopy)
$diaName = 'zlu' + [char]0x0165 + 'ou' + [char]0x010D + 'k' + [char]0x00FD + '.txt'
Set-Content "$K\src\$diaName" 'DIA'
$kcfg = [ordered]@{
    version = 1
    sources = @([ordered]@{ type = 'dir'; path = "$K\src" })
    excludeFiles = @('.credentials.json')
    destinations = @(
        [ordered]@{ name = 'T1'; type = 'path'; path = "$K\dst1"; primary = $true; trash = [ordered]@{ keepDays = 5 } },
        [ordered]@{ name = 'T2'; type = 'path'; path = "$K\dst2" }
    )
}
$kcfgPath = "$K\config.json"
WriteJson $kcfgPath $kcfg
$kslug = Slug "$K\src"
$today = [DateTime]::Now.ToString('yyyy-MM-dd')

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine -ConfigPath $kcfgPath -NoNotify | Out-Null
Check 'G1. prvni beh: exit 0, zadny _kos (nic se nemazalo)' (($LASTEXITCODE -eq 0) -and -not (Test-Path "$K\dst1\_kos"))

# smazat soubor, podstrom i soubor s diakritikou -> na cili s kosem do _kos, bez kose natvrdo
Remove-Item "$K\src\a.txt", "$K\src\$diaName" -Force
Remove-Item -Recurse -Force "$K\src\sub"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine -ConfigPath $kcfgPath -NoNotify | Out-Null
Check 'G2. beh: exit 0' ($LASTEXITCODE -eq 0)
$kosBase = "$K\dst1\_kos\$today\$kslug"
Check 'G2. kos: smazany soubor presunut' ((Test-Path "$kosBase\a.txt") -and ((Get-Content "$kosBase\a.txt" -Raw) -match 'A'))
Check 'G2. kos: smazany podstrom presunut' (Test-Path "$kosBase\sub\b.txt")
Check 'G2. kos: diakritika ve jmene prezila' (Test-Path "$kosBase\$diaName")
Check 'G2. kos: polozky zmizely ze slug stromu' (-not (Test-Path "$K\dst1\$kslug\a.txt") -and -not (Test-Path "$K\dst1\$kslug\sub"))
Check 'G2. cil bez kose: smazano natvrdo, zadny _kos' ((-not (Test-Path "$K\dst2\_kos")) -and -not (Test-Path "$K\dst2\$kslug\a.txt"))

# purge: stara datovana slozka zmizi, dnesni i ne-datumove nazvy zustanou
New-Item -ItemType Directory -Force -Path "$K\dst1\_kos\2020-01-01" | Out-Null
Set-Content "$K\dst1\_kos\2020-01-01\stare.txt" 'x'
New-Item -ItemType Directory -Force -Path "$K\dst1\_kos\necum" | Out-Null
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine -ConfigPath $kcfgPath -NoNotify | Out-Null
Check 'G3. purge: stara slozka smazana' (-not (Test-Path "$K\dst1\_kos\2020-01-01"))
Check 'G3. purge: dnesni slozka a ne-datumovy nazev zustaly' ((Test-Path "$kosBase\a.txt") -and (Test-Path "$K\dst1\_kos\necum"))

# .credentials.json v cili se do kose NIKDY nedostane (/XF plati i pro pre-pass)
Set-Content "$K\dst1\$kslug\.credentials.json" 'BAD'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine -ConfigPath $kcfgPath -NoNotify | Out-Null
Check 'G4. citlivy soubor neni v kosi' (-not (Get-ChildItem "$K\dst1\_kos" -Recurse -Filter '.credentials.json'))
Remove-Item "$K\dst1\$kslug\.credentials.json" -Force

# neplatny keepDays -> exit 3
$kcfg.destinations[0].trash.keepDays = 0
WriteJson $kcfgPath $kcfg
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine -ConfigPath $kcfgPath -NoNotify *> $null
Check 'G5. neplatny keepDays: exit 3' ($LASTEXITCODE -eq 3)
$kcfg.destinations[0].trash.keepDays = 5
WriteJson $kcfgPath $kcfg

if ($hasNode) {
    # editor: uklid [k] necha _kos; [ep]->[k] nastavi kos; validace odmitne keepDays<1
    Set-Content "$K\dst1\sirotek.txt" 'x'
    $outG = "k`na`nn`nq`n" | & $node $editor --config $kcfgPath 2>&1 | Out-String
    Check 'G6. uklid: _kos neni sirotek' ((Test-Path "$K\dst1\_kos") -and -not (Test-Path "$K\dst1\sirotek.txt"))
    $outG7 = "ep`nB`nk`n30`nz`nq`na`n" | & $node $editor --config $kcfgPath 2>&1 | Out-String
    Check 'G7. editor [ep][k]: nastavi kos (render kos=30d)' ($outG7 -match 'kos: 30 dni' -and $outG7 -match 'kos=30d')
    $kbad = "$K\config-badtrash.json"
    $kcfg2 = [ordered]@{ version = 1; sources = $kcfg.sources; excludeFiles = @('.credentials.json'); destinations = @([ordered]@{ name = 'T1'; type = 'path'; path = "$K\dst1"; primary = $true; trash = [ordered]@{ keepDays = 0 } }) }
    WriteJson $kbad $kcfg2
    $outG8 = "u`nq`n" | & $node $editor --config $kbad 2>&1 | Out-String
    Check 'G8. editor: keepDays<1 nejde ulozit' ($outG8 -match 'NELZE ULOZIT' -and $outG8 -match 'keepDays')
}

# ============================ H) databaze (dumpy) ============================
# Stub dump nastroje (.cmd) misto realnych pg_dumpall/mariadb-dump - testuje se
# orchestrace enginu (cerstvost, retence, optional, chyby), ne samotne dumpy.
# Chovani stubu ridi flag soubory vedle nich (pg_down/pg_fail/maria_down).
$H = "$S\db"
New-Item -ItemType Directory -Force -Path "$H\bin", "$H\src", "$H\dst" | Out-Null
Set-Content "$H\src\f.txt" 'x'
Set-Content "$H\bin\pg_isready.cmd" "@echo off`r`nif exist `"%~dp0pg_down.flag`" exit /b 2`r`nexit /b 0"
Set-Content "$H\bin\mariadb-admin.cmd" "@echo off`r`nif exist `"%~dp0maria_down.flag`" exit /b 1`r`nexit /b 0"
Set-Content "$H\bin\pg_dumpall.cmd" "@echo off`r`nif exist `"%~dp0pg_fail.flag`" exit /b 1`r`n:loop`r`nif `"%~1`"==`"`" exit /b 1`r`nif `"%~1`"==`"-f`" (`r`necho -- PGDUMP> `"%~2`"`r`nexit /b 0`r`n)`r`nshift`r`ngoto loop"
Set-Content "$H\bin\mariadb-dump.cmd" "@echo off`r`n:loop`r`nif `"%~1`"==`"`" exit /b 1`r`nif `"%~1`"==`"-r`" (`r`necho -- MARIADUMP> `"%~2`"`r`nexit /b 0`r`n)`r`nshift`r`ngoto loop"

$hcfg = [ordered]@{
    version = 1
    sources = @([ordered]@{ type = 'dir'; path = "$H\src" })
    excludeFiles = @('.credentials.json')
    destinations = @([ordered]@{ name = 'TDB'; type = 'path'; path = "$H\dst"; primary = $true })
    databases = [ordered]@{
        stagingDir = "$H\staging"
        servers = @(
            [ordered]@{ type = 'postgres'; name = 'pg';    binDir = "$H\bin"; port = 5433; user = 'postgres'; intervalMinutes = 60; keepCount = 2 },
            [ordered]@{ type = 'mariadb';  name = 'maria'; binDir = "$H\bin"; port = 3307; intervalMinutes = 60; keepCount = 2 }
        )
    }
}
$hcfgPath = "$H\config.json"
WriteJson $hcfgPath $hcfg
function AgeDumps { Get-ChildItem "$H\staging\*\*.sql" -ErrorAction SilentlyContinue | ForEach-Object { $_.LastWriteTime = (Get-Date).AddHours(-3) } }
function DumpCount($n) { @(Get-ChildItem "$H\staging\db_$n" -Filter '*.sql' -ErrorAction SilentlyContinue).Count }

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine -ConfigPath $hcfgPath -NoNotify | Out-Null
Check 'H1. prvni beh: exit 0' ($LASTEXITCODE -eq 0)
Check 'H1. dump pg ve stagingu' ((DumpCount 'pg') -eq 1)
Check 'H1. dump maria ve stagingu' ((DumpCount 'maria') -eq 1)
Check 'H1. dumpy zrcadleny do cile' ((@(Get-ChildItem "$H\dst\db_pg" -Filter '*.sql' -ErrorAction SilentlyContinue).Count -eq 1) -and (@(Get-ChildItem "$H\dst\db_maria" -Filter '*.sql' -ErrorAction SilentlyContinue).Count -eq 1))
Check 'H1. log hlasi dump ok' ((Get-Content "$H\dst\_backup.log" -Raw) -match 'db   db_pg  dump ok')

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine -ConfigPath $hcfgPath -NoNotify | Out-Null
Check 'H2. cerstvy dump: nedumpuje se znovu (porad 1)' (($LASTEXITCODE -eq 0) -and ((DumpCount 'pg') -eq 1) -and ((DumpCount 'maria') -eq 1))

# nedostupny volitelny server -> preskocit bez chyby; ne-volitelny -> exit 1
AgeDumps
Set-Content "$H\bin\pg_down.flag" 'x'
$hcfg.databases.servers[0].optional = $true
WriteJson $hcfgPath $hcfg
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine -ConfigPath $hcfgPath -NoNotify | Out-Null
Check 'H3. volitelny nedostupny: exit 0, dump se nepridal' (($LASTEXITCODE -eq 0) -and ((DumpCount 'pg') -eq 1))
Check 'H3. druhy (dostupny) server dumpnul a retence drzi keepCount=2' ((DumpCount 'maria') -eq 2)

AgeDumps
$hcfg.databases.servers[0].optional = $false
WriteJson $hcfgPath $hcfg
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine -ConfigPath $hcfgPath -NoNotify | Out-Null
Check 'H4. povinny nedostupny: exit 1 + hlaska v logu' (($LASTEXITCODE -eq 1) -and ((Get-Content "$H\dst\_backup.log" -Raw) -match 'db_pg  CHYBA: server nedostupny'))

# selhany dump: exit 1, tmp uklizen, posledni dobry dump zustava (ve stagingu i cili)
Remove-Item "$H\bin\pg_down.flag" -Force
Set-Content "$H\bin\pg_fail.flag" 'x'
AgeDumps
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine -ConfigPath $hcfgPath -NoNotify | Out-Null
Check 'H5. selhany dump: exit 1' ($LASTEXITCODE -eq 1)
Check 'H5. tmp uklizen, stary dump prezil' ((-not (Test-Path "$H\staging\db_pg\_dump.tmp")) -and ((DumpCount 'pg') -eq 1) -and (@(Get-ChildItem "$H\dst\db_pg" -Filter '*.sql').Count -eq 1))
Remove-Item "$H\bin\pg_fail.flag" -Force

# hesla do configu NEPATRI (zalohuje se do cloudu) - engine i editor odmitaji
$hbad = "$H\config-pass.json"
$hcfg2 = [ordered]@{
    version = 1
    sources = $hcfg.sources
    excludeFiles = @('.credentials.json')
    destinations = $hcfg.destinations
    databases = [ordered]@{ servers = @([ordered]@{ type = 'mariadb'; name = 'm'; binDir = "$H\bin"; password = 'tajne' }) }
}
WriteJson $hbad $hcfg2
$outH6 = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine -ConfigPath $hbad -NoNotify 2>&1 | Out-String
Check 'H6. password v configu: exit 3' (($LASTEXITCODE -eq 3) -and ($outH6 -match 'hesla do configu NEPATRI'))

if ($hasNode) {
    $outH7 = "q`n" | & $node $editor --config $hcfgPath 2>&1 | Out-String
    Check 'H7. editor: render ukazuje db server' ($outH7 -match 'db_pg' -and $outH7 -match 'Databaze')
    $outH8 = "u`nq`n" | & $node $editor --config $hbad 2>&1 | Out-String
    Check 'H8. editor: password nejde ulozit' ($outH8 -match 'NELZE ULOZIT' -and $outH8 -match "password")
    Set-Content "$H\dst\sirotek.txt" 'x'
    New-Item -ItemType Directory -Force -Path "$H\dst\db_cizi" | Out-Null
    $outH9 = "k`na`nq`n" | & $node $editor --config $hcfgPath 2>&1 | Out-String
    Check 'H9. uklid: db slug slozky nejsou sirotci, cizi ano' ((Test-Path "$H\dst\db_pg") -and (Test-Path "$H\dst\db_maria") -and -not (Test-Path "$H\dst\db_cizi") -and -not (Test-Path "$H\dst\sirotek.txt"))
}

# ============================ vysledek =======================================
Write-Host ''
if ($fail -eq 0) {
    Write-Host '=== VSECHNY TESTY PROSLY ==='
    Remove-Item -Recurse -Force $S -ErrorAction SilentlyContinue
} else {
    Write-Host "=== SELHALO: $fail (sandbox ponechan: $S) ==="
}
exit $fail
