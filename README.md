# ClaudeBackup

Automatické zálohování `~/.claude*` profilů a pracovních složek na OneDrive
a externí SSD — řízené config souborem místo editace scriptu.

- **Zadání a návrh:** [PRD.md](PRD.md)

## Komponenty

| Komponenta | Jazyk | Role |
|---|---|---|
| `claude-backup.ps1` | PowerShell | backup engine (`robocopy /MIR`), čte config |
| `claude-backup-cfg` | Node.js | interaktivní CLI pro úpravu configu (bez závislostí) |
| `config.schema.json` | JSON Schema | sdílená validace configu (engine i editor) |
| `deploy.ps1` | PowerShell | nasazení do `~/.local/bin` + přepnutí úlohy |

Config žije v `%USERPROFILE%\.config\claude-backup\config.json` — mimo repo, jsou
to data uživatele, ne kód.

## Jak to běží

Naplánovaná úloha `ClaudeBackup` (po přihlášení + každých 10 min) →
`claude-backup-hidden.vbs` (skryté okno) → `claude-backup.ps1` (engine). Engine
načte config, zvaliduje ho a zrcadlí zdroje na cíle přes `robocopy /MIR`. Rozbitý
config = čistý pád (exit 3) bez mazání; selhání → Windows notifikace (toast).
Jeden běh trvá typicky 1–2 s (inkrementální — kopírují se jen změny).

## Prerekvizity a první nasazení

Jednorázově (např. na novém stroji):

1. **Portable Node.js** v `~/.local/nodejs\node.exe` — editor ho volá absolutní
   cestou (není v PATH).
2. **Vytvořit config** — spusť `claude-backup-cfg`; když config neexistuje,
   nabídne vygenerovat výchozí (odpovídá původnímu zadrátovanému nastavení),
   pak `u` (uložit).
3. **Nasadit** — `deploy.ps1` (zkopíruje engine + editor do `~/.local/bin`,
   schéma vedle configu).
4. **Naplánovaná úloha `ClaudeBackup`** musí existovat (spouští ji VBS wrapper).
   Její *vytvoření* je mimo deploy — deploy jen přepíná engine a srovnává interval.

Pořadí je důležité: engine bez configu končí exit 3, takže **config musí být první**.

## Používání editoru

Config se needituje ručně — od toho je interaktivní editor. Spusť v terminálu:

```
claude-backup-cfg
```

Ukáže přehled (zdroje, cíle, výjimky, notifikace, interval) a menu příkazů:

| Klávesa | Akce |
|---|---|
| `p` / `o` / `ec` | přidat / odebrat / **upravit** zdroj (`glob` nebo `dir`; lze omezit na konkrétní cíle) |
| `c` / `x` / `ep` | přidat / odebrat / **upravit** cíl (pevná cesta, nebo disk podle jmenovky svazku) |
| `f` / `d` | **výjimky** souborů / složek (`+jmeno` přidá, `-jmeno` odebere, prázdné = zpět) |
| `k` | **úklid cílů** — vypíše a po potvrzení smaže z kořene cíle vše, co nepatří žádnému zdroji (starý layout, složky po odebraných zdrojích) |
| `n` | **notifikace** při chybě zap/vyp (Windows toast) |
| `i` | **interval** úlohy — změní minuty a nabídne aplikovat rovnou na živou úlohu |
| `t` | **test (dry-run)** — `robocopy /L`, ukáže co by se zálohovalo, **nic nezapíše** |
| `s` | **stav** — konec `_backup.log` + `LastTaskResult` úlohy |
| `u` | **uložit** (validace + atomický zápis + záloha `config.json.bak`) |
| `q` | **konec** (varuje na neuložené změny) |

**Klíčové chování:**

- Změny se ukládají až přes `u`; do té doby jsou jen v paměti (nahoře svítí `* NEULOZENE ZMENY`).
- `u` nejdřív **validuje** — nevalidní config (prázdné zdroje/cíle, chybějící primární cíl…) neuloží a vypíše proč.
- `.credentials.json` **nejde** odebrat z výjimek (tokeny se nikdy nezálohují).
- Uložený config se projeví **při příští záloze automaticky** — engine ho čte při každém běhu, nic se nenasazuje znovu.
- `t` testuje **aktuální stav editoru** (i neuložený) — ideální „zkontrolovat, než uložím".

### Typické úlohy

Přidat složku k zálohování (a hned ověřit):

```
p → dir → C:\Users\...\Projekty → (omezit na cíle? Enter = na všechny)
t   # dry-run: zkontroluj, co přibude
u   # ulož
```

Velkou složku jen na SSD (OneDrive má ~5 GB limit) — u „omezit na cíle" zadej `extSSD`.

Přehodit primární cíl / změnit cestu / (ne)volitelnost existujícího cíle:

```
ep → (písmeno cíle) → p=primární · o=volitelný · c=cesta · r=robocopyOpts → z
u
```

Změnit interval zálohy na 5 minut:

```
i → 5 → aplikovat na živou úlohu? a
u
```

## Volitelné vs povinné cíle

Každý cíl je buď **volitelný** (`optional: true`), nebo **povinný** (bez `optional`):

- **Volitelný** — nedostupný cíl (typicky odpojený externí SSD) engine **tiše
  přeskočí** (exit 0). Pro disk, který nebývá připojený pořád.
- **Povinný** — nedostupný cíl → engine **pošle toast a skončí exit 1** (i když
  ostatní cíle vyšly), a to při **každém běhu** (co 10 min), dokud cíl chybí.
  Pro cíl, který má být vždy dostupný — dozvíš se, když vypadne.

Když jsou nedostupné **všechny** cíle, engine skončí exit 2.

Pozn.: zdroj s `onlyDestinations` (např. velká složka jen na SSD) se při
odpojeném disku **nezálohuje nikam** — má kopii jen na tom jednom cíli.

## Nasazení / rollback

```
deploy.ps1            # nasadí engine + editor + wrapper do ~/.local/bin, přepne úlohu
deploy.ps1 -WhatIf    # jen ukáže, co by udělal (nic nemění)
deploy.ps1 -Rollback  # obnoví předchozí engine ze zálohy .bak
```

Přepnutí úlohy na nový engine = nahrazení `~/.local/bin/claude-backup.ps1` (VBS
wrapper i úloha zůstávají). Interval se srovná dle `schedule.intervalMinutes`.

### Migrace na slug layout (jednorázově)

Starší verze enginu ukládaly zálohy přímo do kořene cíle (`.claude`, `.local\…`).
Slug schéma mění cesty všech záloh, takže po nasazení:

1. `deploy.ps1` — nasadí nový engine.
2. Nech proběhnout zálohu (nebo spusť úlohu ručně) — vzniknou slug složky.
3. `claude-backup-cfg` → `k` — smaže staré složky (vypíše je a zeptá se).

Do kroku 3 existují v cíli stará i nová kopie zároveň — když je OneDrive kvóta
(~5 GB) těsná, spusť `k` už před krokem 2 (za cenu chvíle bez hotové zálohy).

## Obnova (kde jsou data)

Záloha je **zrcadlo posledního stavu** (`robocopy /MIR`), ne historie verzí.
Data najdeš přímo v cíli:

- **OneDrive:** `%OneDrive%\Backups\claude\` (je tu i log `_backup.log`)
- **externí SSD:** `<disk>:\Backups\claude\` (písmeno se mění — hledá se podle jmenovky svazku; výchozí placeholder `BACKUP_SSD`)

Každý zdroj má v cíli **vlastní složku** pojmenovanou „slugem" z jeho cesty
v configu: `%USERPROFILE%\.local\bin` → `USERPROFILE_.local_bin`, položky glob
zdroje (`.claude*`) leží v `USERPROFILE\.claude…`. Díky tomu si dva zdroje
nikdy nesahají do stejné složky cíle (`/MIR` jednoho nemůže mazat data druhého).

Obnova = zkopírovat obsah slug složky zpět na cestu, ze které slug vznikl
(např. `…\Backups\claude\USERPROFILE\.claude` zpět do `%USERPROFILE%\.claude`).

⚠️ `/MIR` je **zrcadlo, ne archiv** — když v profilu soubor smažeš, při dalším
běhu zmizí i ze zálohy. Není to ochrana proti „smazal jsem to omylem minulý týden".

## Návratové kódy enginu

`0` ok (vč. přeskočených zamčených souborů a nepřipojeného **volitelného** cíle) ·
`1` chyba kopírování **nebo nedostupný povinný cíl** (když jinak záloha proběhla —
navíc přijde toast) · `2` žádný cíl dostupný · `3` config chybí / nevalidní (engine
se pak **nedostane** k `robocopy /MIR`). Plánovač je ukazuje v `LastTaskResult`.
