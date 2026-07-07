# PRD: ClaudeBackup 2.0 — zálohování řízené configem

**Stav:** návrh — fáze 1–3 (engine, editor, dry-run/stav) implementovány a ověřeny; zbývá fáze 4 (nasazení)
**Datum:** 2026-07-07
**Repo:** github.com/Lossik/ClaudeBackup (private)

## 1. Motivace

Stávající zálohování (`~/.local/bin/claude-backup.ps1`, spouštěné naplánovanou
úlohou `ClaudeBackup` po přihlášení a pak každých 10 minut) funguje dobře, ale
veškeré nastavení — zdroje, výjimky i cíle — je zadrátované přímo ve scriptu.
Každá změna (přidat složku, přidat/ubrat cíl) znamená editovat kód, což je
nepohodlné a náchylné k chybám (překlep rozbije celou zálohu).

**Cíl:** oddělit nastavení od logiky. Script čte konfiguraci z config souboru
a pro jeho úpravy vznikne jednoduché, lidské rozhraní.

## 2. Současný stav (as-is)

- Engine: PowerShell + `robocopy /MIR` (zrcadlení včetně mazání).
- Spouštění: Plánovač úloh → `claude-backup-hidden.vbs` (skryté okno) → `claude-backup.ps1`.
- Zdroje: všechny `~/.claude*` + extra složky `.local\bin`, `Claude`.
- Výjimky: `.credentials.json` (tokeny — nikdy nezálohovat).
- Cíle:
  - OneDrive `Backups\claude` (primární, obsahuje i `_backup.log`),
  - externí SSD podle jmenovky svazku `KINGSTON` (volitelný, s `/FFT` kvůli exFAT).
- Návratové kódy: 0 ok / 1 chyba kopírování / 2 žádný cíl nedostupný.
- Kopie původních scriptů jsou v `legacy/` jako reference.

## 3. Cíle

1. **Config soubor** — vše, co se dnes edituje ve scriptu, se přesune do
   deklarativního configu (JSON).
2. **Engine čte config** — `claude-backup.ps1` neobsahuje žádná zadrátovaná
   nastavení; chování zůstává 1:1 se současným (žádná regrese).
3. **Konfigurační UX** — interaktivní nástroj (Node.js CLI), kterým jde
   bezpečně přidat/odebrat/upravit zdroj i cíl bez ručního psaní JSONu.
4. **Validace** — engine i editor config validují; rozbitý config nesmí
   způsobit tichou ne-zálohu (jasný exit kód + log).

## 4. Ne-cíle (zatím)

- Verzování / retence záloh (robocopy `/MIR` zůstává — poslední stav, ne historie).
- Šifrování, komprese, cloud API (S3 apod.).
- GUI aplikace / web UI — začínáme CLI, GUI případně později.
- Správa samotné naplánované úlohy (interval, trigger) — úloha zůstává, jak je.

## 5. Návrh řešení

### 5.1 Architektura

```
~/.config/claude-backup/config.json   ← jediný zdroj pravdy
        ▲                    ▲
        │ čte                │ čte + zapisuje
┌───────┴────────┐   ┌───────┴───────────┐
│ claude-backup  │   │ claude-backup-cfg │
│ .ps1 (engine)  │   │ (Node.js CLI UX)  │
└────────────────┘   └───────────────────┘
```

- **Engine zůstává PowerShell** — robocopy, Plánovač i VBS wrapper fungují,
  není důvod je přepisovat. Mění se jen: na začátku načte a zvaliduje config.
- **Editor je Node.js** (preferovaný jazyk pro pomocné scripty; portable node
  v `~/.local/nodejs`, volat absolutní cestou). Bez externích závislostí —
  stačí vestavěný `readline`.
- **Formát JSON** — nativně ho čte PowerShell (`ConvertFrom-Json`) i Node,
  žádné parsovací závislosti.

### 5.2 Umístění configu

`%USERPROFILE%\.config\claude-backup\config.json`

- Mimo repo i mimo `.local\bin` (config je data uživatele, ne kód).
- Pozn.: `~/.config` dnes není v zálohovaných zdrojích — přidat ho do
  výchozího configu, ať se záloha konfigurace veze zadarmo.

### 5.3 Schéma configu (návrh)

```json
{
  "$schema": "./config.schema.json",
  "version": 1,
  "sources": [
    { "type": "glob",  "base": "%USERPROFILE%", "pattern": ".claude*" },
    { "type": "dir",   "path": "%USERPROFILE%\\.local\\bin" },
    { "type": "dir",   "path": "%USERPROFILE%\\Claude" },
    { "type": "dir",   "path": "%USERPROFILE%\\.config\\claude-backup" }
  ],
  "excludeFiles": [".credentials.json"],
  "excludeDirs": [
    "node_modules", "__pycache__", ".venv", ".cache", "Cache",
    ".mypy_cache", ".pytest_cache", ".ruff_cache", ".next", ".turbo", "tmp", "temp"
  ],
  "destinations": [
    {
      "name": "OneDrive",
      "type": "path",
      "path": "%OneDrive%\\Backups\\claude",
      "envFallback": ["OneDrive", "OneDriveConsumer"],
      "primary": true,
      "robocopyOpts": []
    },
    {
      "name": "extSSD",
      "type": "volumeLabel",
      "label": "KINGSTON",
      "subPath": "Backups\\claude",
      "robocopyOpts": ["/FFT"],
      "optional": true
    }
  ],
  "log": { "file": "_backup.log", "maxSizeKB": 1024, "keepLines": 300 }
}
```

Klíčové vlastnosti:

- **`sources`** — dva typy: `glob` (dnešní `.claude*`) a `dir` (konkrétní
  složka), do budoucna snadno rozšiřitelné. Proměnné prostředí (`%...%`)
  se expandují za běhu. Podsložka v cíli se u zdroje pod profilem odvozuje
  relativně k `%USERPROFILE%` (`.local\bin` → `<cíl>\.local\bin`, 1:1 s legacy),
  jinak z názvu složky.
- **`excludeFiles`** → robocopy `/XF`; **`excludeDirs`** → robocopy `/XD`
  (přidáno jako protějšek k souborům). `.credentials.json` v `excludeFiles`
  je povinné (vynucuje schéma i engine). `excludeDirs` je volitelné, smí být
  prázdné a má výchozí sadu cache/temp/build složek; `/XD` se přidá jen když
  je pole neprázdné.
- **`destinations`** — `type: "path"` (pevná cesta; `envFallback` uvádí náhradní
  proměnné, když je hlavní `%...%` prázdná — degraduje až na `%USERPROFILE%\…`)
  vs. `type: "volumeLabel"` (najdi disk podle jmenovky — písmeno se mění).
  `optional: true` = nedostupný cíl se přeskočí bez chyby (dnešní chování SSD).
  Právě jeden cíl musí mít `primary: true` (je v něm log) — hlídá engine.
- **`onlyDestinations`** (na úrovni zdroje) — náhrada původního
  `destinationFilters` / `$extraDirsSsdOnly`: zdroj se zálohuje jen na
  vyjmenované cíle (velké složky jen na SSD, OneDrive má 5 GB limit).
  Nezadáno = na všechny cíle.
- **`version`** — pro budoucí migrace schématu.

### 5.4 Validace a chování při chybě

- Engine config **znovu validuje** (nezávisle na schématu — obrana před
  spuštěním `/MIR` nad rozbitým configem): neprázdné `sources` i `destinations`,
  přítomnost `.credentials.json` v `excludeFiles`, právě jeden `primary` cíl,
  platný `type` u zdrojů/cílů a `onlyDestinations` odkazující na existující cíl.
- Config chybí / nejde parsovat / neprojde validací → **exit 3** (nový kód).
  Diagnostika jde do `_engine.log` **vedle configu** (reálný `_backup.log`
  v cíli ještě neznáme, případně je cíl nedostupný); Plánovač chybu ukáže
  v LastTaskResult. Engine se v tomto případě **nikdy nedostane k robocopy**.
- Editor: validuje před uložením; zapisuje atomicky (temp soubor + rename)
  a před přepsáním uloží zálohu `config.json.bak`.
- Repo obsahuje **kanonický** `config.schema.json` (JSON Schema); jeho kopie
  se nasazuje **vedle configu** (`$schema: "./config.schema.json"`), aby odkaz
  fungoval a engine měl schéma lokálně. Schéma vynucuje `minItems: 1` na
  `sources`/`destinations` a `contains` `.credentials.json` v `excludeFiles`.

### 5.5 Konfigurační UX (`claude-backup-cfg`)

Interaktivní menu v terminálu (Node.js, bez závislostí):

```
ClaudeBackup — konfigurace
──────────────────────────
Zdroje:                        Cíle:
  1. ~\.claude*  (glob)          A. OneDrive  ~\OneDrive\Backups\claude  [primární]
  2. ~\.local\bin                B. extSSD    KINGSTON:\Backups\claude   [volitelný]
  3. ~\Claude
Výjimky: soubory: .credentials.json  |  složky: node_modules, tmp, …

[p] přidat zdroj   [o] odebrat zdroj   [c] přidat cíl   [x] odebrat cíl
[v] výjimky        [t] test (dry-run)  [s] stav poslední zálohy   [q] konec
```

- **Přidání zdroje/cíle** = průvodce (cesta s validací existence, u cíle
  volba pevná cesta × jmenovka svazku).
- **Test (dry-run)** — spustí engine s `robocopy /L` (nic nekopíruje),
  ukáže, co by se zálohovalo. Klíčové pro důvěru po změně configu.
- **Stav** — přečte konec `_backup.log` + LastTaskResult úlohy.
- Spouštění: `claude-backup-cfg.cmd` v `~/.local/bin` (wrapper volající
  portable node absolutní cestou).

### 5.6 První spuštění / migrace

Při prvním běhu editoru (config neexistuje) se vygeneruje výchozí config
odpovídající dnešnímu zadrátovanému nastavení. Engine bez configu spadne
s exit 3 — nasazení tedy proběhne v pořadí: (1) vygenerovat config,
(2) nasadit nový engine, (3) ověřit ručním spuštěním úlohy.

## 6. Fáze

| Fáze | Obsah | Výstup | Stav |
|------|-------|--------|------|
| 1 | Config schéma + engine čte config (chování 1:1 s dneškem) | `config.schema.json`, nový `claude-backup.ps1`, výchozí `config.json` | ✅ implementováno, ověřeno v sandboxu i naostro (OneDrive + KINGSTON) |
| 2 | Node.js CLI editor (menu, průvodci, validace, atomický zápis) | `claude-backup-cfg.js` | ✅ implementováno, ověřeno (27 testů); UI ASCII, bez závislostí |
| 3 | Dry-run + stav poslední zálohy v editoru | rozšíření CLI (`[t]`/`[s]`) | ✅ implementováno, ověřeno (36 testů) + reálný smoke |
| 4 | Nasazení: deploy script do `~/.local/bin`, ověření úlohy | `deploy.ps1` | — |

## 7. Akceptační kritéria

1. Po nasazení fáze 1 proběhne záloha se stejným výsledkem jako dnes
   (stejné složky na obou cílech, log bez chyb).
2. Přidání nového zdroje přes CLI se projeví v příští záloze bez editace kódu.
3. Odpojený volitelný cíl (SSD) zálohu neshodí (exit 0, poznámka v logu).
4. Poškozený config → exit 3, srozumitelná hláška v logu, žádné mazání
   v cílech (engine se nesmí dostat k robocopy `/MIR` s prázdným seznamem).
5. `.credentials.json` se nikdy neobjeví v žádném cíli.

## 8. Rizika a otevřené otázky

- **Rozbitý config + `/MIR`**: `/MIR` maže — prázdný seznam zdrojů by mohl
  smazat obsah cíle. Mitigace: validace (schéma i engine) odmítne prázdné
  `sources`/`destinations` → exit 3 před robocopy. **Implementováno a ověřeno**
  v sandboxu (kritérium 4).
- **Délka cílové cesty (MAX_PATH)**: podsložka v cíli se odvozuje relativně
  k profilu, takže hluboko zanořený `dir` zdroj může cílovou cestu přetáhnout
  přes 260 znaků. Produkční zdroje jsou mělké (`.local\bin`, `Claude`,
  `.config\claude-backup`) → dnes bez dopadu; hlídat při přidávání zdrojů.
- **Souběh editoru a běžící zálohy**: úloha běží každých 10 min; atomický
  zápis configu stačí (engine čte config jednou na začátku).
- **Otevřená otázka:** má editor umět měnit i interval úlohy v Plánovači?
  (Zatím ne-cíl, ale schéma na to nechává prostor.)
- **Otevřená otázka:** notifikace při opakovaném selhání zálohy (toast)?
