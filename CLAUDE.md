# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Jazyk

Celé repo je česky — PRD, README, komentáře v kódu, logy i commit messages.
Piš česky, ať to ladí. Diakritiku v kódu (komentáře, log hlášky) drž tak, jak je
v okolí; konzolové výstupy (engine, editor) ji záměrně vynechávají (ASCII kvůli
kódování konzole/robocopy).

## Stav projektu

Hotovo a nasazeno. Naplánovaná úloha běží na config-driven enginu. Klíčové soubory:

- **`PRD.md`** — kompletní zadání a návrh (se stavem fází). **Jediný zdroj pravdy**
  pro záměr; než začneš měnit chování, přečti relevantní část.
- **`claude-backup.ps1`** (engine, `robocopy /MIR`), **`claude-backup-cfg.js`**
  (Node.js editor), **`claude-restore.ps1`** (obnova zálohy zpět, config-driven),
  **`claude-backup-watchdog.ps1`** (hlídá, že se záloha vůbec spouští),
  **`config.schema.json`** (validace), **`deploy.ps1`** (nasazení; `-CreateTask`
  vytvoří chybějící úlohy).
- `README.md`, `.gitignore`, **`tests/run-tests.ps1`** (kompletní sandbox testy —
  po každé netriviální změně je spusť; nic nesahá na reálný config ani cíle).

Původní zadrátovaná verze je v git historii. Není build ani lint.

## Cílová architektura

Oddělit **nastavení od logiky**. Jediný zdroj pravdy je config, který čte engine
a spravuje editor:

```
%USERPROFILE%\.config\claude-backup\config.json   ← data uživatele (mimo repo)
        ▲                    ▲
        │ čte                │ čte + zapisuje (atomicky, s .bak)
  claude-backup.ps1      claude-backup-cfg
  (engine, robocopy)     (Node.js interaktivní CLI)
```

- **Engine `claude-backup.ps1`** (PowerShell + `robocopy /MIR`) — zrcadlí zdroje
  na cíle. Neobsahuje žádné zadrátované nastavení; vše bere z configu.
- **Editor `claude-backup-cfg`** (Node.js) — interaktivní úprava configu.
  **Bez externích závislostí** (jen vestavěný `readline`). Node je portable
  v `~/.local/nodejs`, volej ho **absolutní cestou** (není v PATH). Nasazuje se
  jako `claude-backup-cfg.cmd` wrapper v `~/.local/bin`.
- **`config.schema.json`** (JSON Schema) — sdílená validace pro engine i editor.
- Config je záměrně **mimo repo** (`~/.config/...`) — jsou to data, ne kód.

## Kritické invarianty (nikdy neporušit)

Tyhle věci jsou důvod, proč projekt vůbec vzniká — hlídej je při každé změně:

1. **`.credentials.json` se NIKDY nezálohuje** (obsahuje tokeny). Engine ho navíc
   aktivně maže z cílů, kdyby tam zbyla stará kopie. Stejně tak `.ssh`
   (privátní klíče) do cloudu nepatří a mezi zdroje nepatří. Stejný invariant:
   **hesla DB serverů do configu NEPATŘÍ** (config se zálohuje do cloudu) —
   vlastnost `password` v `databases.servers` odmítá schéma, engine (exit 3)
   i editor; autentizace jen přes pgpass.conf / `--defaults-extra-file`.
2. **`robocopy /MIR` MAŽE.** Prázdný seznam zdrojů = smazaný obsah cíle.
   Validace **musí odmítnout prázdné `sources`/`destinations`** dřív, než se
   engine vůbec dostane k robocopy. Rozbitý config → čistý pád (exit 3),
   nikdy tichá ne-záloha ani destruktivní běh.
3. **Každý zdroj má v cíli vlastní slug složku** (slug z nerozvinutého kořene
   zdroje, např. `%USERPROFILE%\.local\bin` → `USERPROFILE_.local_bin`) — dva
   zdroje si nikdy nesmí sahat do stejného podstromu cíle, jinak by se jejich
   `/MIR` běhy vzájemně mazaly. Kolize slugů (různé kořeny → stejný slug) je
   chyba configu (exit 3). Slug funkce musí zůstat 1:1 mezi enginem
   (`Get-SourceSlug`) a editorem (`sourceSlug`).

### Návratové kódy enginu

`0` ok (vč. přeskočených zamčených souborů a nepřipojeného **volitelného** cíle) ·
`1` chyba kopírování **nebo nedostupný povinný (ne-`optional`) cíl** i při jinak
úspěšné záloze (navíc toast) · `2` žádný cíl nedostupný · `3` config chybí /
nejde parsovat / nesedí schéma. Plánovač je ukazuje v `LastTaskResult`.

### Cíle záloh

- `OneDrive` — primární, pevná cesta, je v něm i `_backup.log` (limit ~5 GB).
- `extSSD` — externí disk, hledá se podle **jmenovky svazku** (výchozí placeholder
  `BACKUP_SSD` — nastav na svou), písmeno disku se mění. Volitelný: nepřipojený =
  přeskoč bez chyby. exFAT má hrubá časová razítka → robocopy `/FFT`, jinak by
  kopíroval vše pořád dokola.
- **Koš** (`trash.keepDays`, per cíl): co by `/MIR` smazal, jde do
  `<cíl>\_kos\<datum>\...` a po keepDays dnech to smaže purge. Detekce mazaných
  přes pre-pass `/MIR /L` + `/UNILOG` (UTF-16 — NIKDY nečíst robocopy výstup ze
  stdout, konzolové kódování komolí diakritiku v cestách). Na OneDrive koš
  nezapínat (má vlastní + 5GB kvóta). `.credentials.json` do koše nikdy.
- **Databáze** (`databases.servers`, PRD § 5.11): logické dumpy
  (`pg_dumpall` / `mariadb-dump`) do lokálního stagingu
  (`%LOCALAPPDATA%\claude-backup\dbdumps\db_<name>`), odtud `/MIR` na cíle
  jako slug `db_<name>`. Dump až když je poslední starší než
  `intervalMinutes`; drží se `keepCount` posledních (retence dumpů — cíl
  nepotřebuje koš). Selhaný dump nepřepíše poslední dobrý (`_dump.tmp`).
  Nedostupný `optional` server se přeskočí bez chyby.

## Spouštění (produkce)

Zálohu spouští Plánovač úloh (úloha `ClaudeBackup`, po přihlášení + každých
10 min) přes VBS wrapper, který skryje okno konzole a propaguje návratový kód:

```
Plánovač → claude-backup-hidden.vbs → powershell -File claude-backup.ps1
```

Nasazené scripty žijí v `~/.local/bin` (ne v repu); VBS i `.cmd` wrapper generuje
`deploy.ps1`. Interval úlohy jde měnit editorem (`schedule.intervalMinutes`);
chybějící úlohy (`ClaudeBackup` + `ClaudeBackupWatchdog`) vytvoří
`deploy.ps1 -CreateTask`, existující úlohy deploy nemění (jen interval).
Watchdog úloha hlídá, že se záloha vůbec spouští (2× denně; toast při problému).

## Fáze implementace (dle PRD § 6) — hotovo

1. `config.schema.json` + engine čtoucí config (chování 1:1 s původní verzí) + výchozí `config.json`.
2. Node.js CLI editor (menu, průvodci, validace, atomický zápis + `.bak`).
3. Dry-run (`robocopy /L`) a stav poslední zálohy v editoru.
4. `deploy.ps1` — nasazení do `~/.local/bin` + ověření úlohy.

Pořadí nasazení: nejdřív vygenerovat config, pak nasadit engine, pak ověřit
ručním spuštěním úlohy (engine bez configu padá na exit 3).
