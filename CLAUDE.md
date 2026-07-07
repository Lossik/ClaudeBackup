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
  (Node.js editor), **`config.schema.json`** (validace), **`deploy.ps1`** (nasazení).
- `README.md`, `.gitignore`.

Původní zadrátovaná verze je v git historii. Není build ani lint; automatizované
testy nejsou součástí repa.

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
   (privátní klíče) do cloudu nepatří a mezi zdroje nepatří.
2. **`robocopy /MIR` MAŽE.** Prázdný seznam zdrojů = smazaný obsah cíle.
   Validace **musí odmítnout prázdné `sources`/`destinations`** dřív, než se
   engine vůbec dostane k robocopy. Rozbitý config → čistý pád (exit 3),
   nikdy tichá ne-záloha ani destruktivní běh.
3. **Žádná regrese vůči původní zadrátované verzi** — záloha musí dopadnout stejně
   (stejné složky na cílech, log bez chyb). Původní verze je v git historii.

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

## Spouštění (produkce)

Zálohu spouští Plánovač úloh (úloha `ClaudeBackup`, po přihlášení + každých
10 min) přes VBS wrapper, který skryje okno konzole a propaguje návratový kód:

```
Plánovač → claude-backup-hidden.vbs → powershell -File claude-backup.ps1
```

Nasazené scripty žijí v `~/.local/bin` (ne v repu); VBS i `.cmd` wrapper generuje
`deploy.ps1`. Interval úlohy jde měnit editorem (`schedule.intervalMinutes`);
vytvoření a triggery úlohy jsou mimo deploy.

## Fáze implementace (dle PRD § 6) — hotovo

1. `config.schema.json` + engine čtoucí config (chování 1:1 s původní verzí) + výchozí `config.json`.
2. Node.js CLI editor (menu, průvodci, validace, atomický zápis + `.bak`).
3. Dry-run (`robocopy /L`) a stav poslední zálohy v editoru.
4. `deploy.ps1` — nasazení do `~/.local/bin` + ověření úlohy.

Pořadí nasazení: nejdřív vygenerovat config, pak nasadit engine, pak ověřit
ručním spuštěním úlohy (engine bez configu padá na exit 3).
