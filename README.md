# ClaudeBackup

Automatické zálohování `~/.claude*` profilů a pracovních složek na OneDrive
a externí SSD — řízené config souborem místo editace scriptu.

- **Zadání a návrh:** [PRD.md](PRD.md)
- **Původní (zadrátovaná) verze scriptů:** [legacy/](legacy/)

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

## Používání editoru

Config se needituje ručně — od toho je interaktivní editor. Spusť v terminálu:

```
claude-backup-cfg
```

Ukáže přehled (zdroje, cíle, výjimky, notifikace, interval) a menu příkazů:

| Klávesa | Akce |
|---|---|
| `p` / `o` | přidat / odebrat **zdroj** (`glob` nebo `dir`; zdroj lze omezit na konkrétní cíle) |
| `c` / `x` | přidat / odebrat **cíl** (pevná cesta, nebo disk podle jmenovky svazku) |
| `f` / `d` | **výjimky** souborů / složek (`+jmeno` přidá, `-jmeno` odebere, prázdné = zpět) |
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

Změnit interval zálohy na 5 minut:

```
i → 5 → aplikovat na živou úlohu? a
u
```

## Nasazení / rollback

```
deploy.ps1            # nasadí engine + editor + wrapper do ~/.local/bin, přepne úlohu
deploy.ps1 -WhatIf    # jen ukáže, co by udělal (nic nemění)
deploy.ps1 -Rollback  # obnoví předchozí (legacy) engine ze zálohy .bak
```

## Návratové kódy enginu

`0` ok (vč. přeskočených zamčených souborů a nepřipojeného **volitelného** cíle) ·
`1` chyba kopírování **nebo nedostupný povinný cíl** (když jinak záloha proběhla —
navíc přijde toast) · `2` žádný cíl dostupný · `3` config chybí / nevalidní (engine
se pak **nedostane** k `robocopy /MIR`). Plánovač je ukazuje v `LastTaskResult`.
