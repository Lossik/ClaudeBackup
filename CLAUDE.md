# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Jazyk

Celé repo je česky — PRD, README, komentáře v kódu, logy i commit messages
(viz commit "Zalozeni projektu…"). Piš česky, ať to ladí. Diakritiku v kódu
(komentáře, log hlášky) drž tak, jak je v okolí; legacy scripty ji záměrně
vynechávají (ASCII kvůli kódování konzole/robocopy).

## Stav projektu

Fáze návrhu. Reálně existuje jen:

- **`PRD.md`** — kompletní zadání a návrh. **Jediný zdroj pravdy** pro to, co se
  staví; než začneš cokoli implementovat, přečti ho celý.
- **`legacy/`** — původní funkční verze s natvrdo zadrátovaným nastavením.
  **Reference, needituj ji** — je to výchozí chování, se kterým musí být nová
  verze 1:1 (žádná regrese). Nová implementace patří do kořene repa.
- `README.md`, `.gitignore`.

Nic z cílové architektury (engine čtoucí config, Node.js editor, schéma) zatím
neexistuje. Není build, ani lint, ani testy, ani `package.json`.

## Cílová architektura (dle PRD)

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
  na cíle. Po přepisu nesmí obsahovat žádné zadrátované nastavení; vše bere
  z configu.
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
   (privátní klíče) do cloudu nepatří a mezi zdroje nepatří.
2. **`robocopy /MIR` MAŽE.** Prázdný seznam zdrojů = smazaný obsah cíle.
   Validace **musí odmítnout prázdné `sources`/`destinations`** dřív, než se
   engine vůbec dostane k robocopy. Rozbitý config → čistý pád (exit 3),
   nikdy tichá ne-záloha ani destruktivní běh.
3. **Chování 1:1 s `legacy/`** — po fázi 1 musí záloha dopadnout stejně jako dnes
   (stejné složky na obou cílech, log bez chyb).

### Návratové kódy enginu

`0` ok (vč. přeskočených zamčených souborů a nepřipojeného SSD) · `1` chyba
kopírování · `2` žádný cíl nedostupný · `3` (nový) config chybí / nejde
parsovat / nesedí schéma. Plánovač je ukazuje v `LastTaskResult`.

### Cíle záloh

- `OneDrive` — primární, pevná cesta, je v něm i `_backup.log` (limit ~5 GB).
- `extSSD` (Kingston) — hledá se podle **jmenovky svazku** (`KINGSTON`), písmeno
  disku se mění. Volitelný: nepřipojený = přeskoč bez chyby. exFAT má hrubá
  časová razítka → robocopy `/FFT`, jinak by kopíroval vše pořád dokola.

## Spouštění (produkce)

Zálohu spouští Plánovač úloh (úloha `ClaudeBackup`, po přihlášení + každých
10 min) přes VBS wrapper, který skryje okno konzole a propaguje návratový kód:

```
Plánovač → claude-backup-hidden.vbs → powershell -File claude-backup.ps1
```

Nasazené scripty žijí v `~/.local/bin` (ne v repu). Správa intervalu/triggeru
úlohy je zatím ne-cíl — úloha zůstává, jak je.

## Fáze implementace (dle PRD § 6)

1. `config.schema.json` + engine čtoucí config (chování 1:1 s legacy) + výchozí `config.json`.
2. Node.js CLI editor (menu, průvodci, validace, atomický zápis + `.bak`).
3. Dry-run (`robocopy /L`) a stav poslední zálohy v editoru.
4. `deploy.ps1` — nasazení do `~/.local/bin` + ověření úlohy.

Pořadí nasazení: nejdřív vygenerovat config, pak nasadit engine, pak ověřit
ručním spuštěním úlohy (engine bez configu padá na exit 3).
