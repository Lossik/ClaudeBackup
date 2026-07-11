# ClaudeBackup

Automatické zálohování `~/.claude*` profilů a pracovních složek na OneDrive
a externí SSD — řízené config souborem místo editace scriptu.

- **Zadání a návrh:** [PRD.md](PRD.md)

## Komponenty

| Komponenta | Jazyk | Role |
|---|---|---|
| `claude-backup.ps1` | PowerShell | backup engine (`robocopy /MIR`), čte config |
| `claude-backup-cfg` | Node.js | interaktivní CLI pro úpravu configu (bez závislostí) |
| `claude-restore.ps1` | PowerShell | obnova zálohy zpět na původní cesty (config-driven) |
| `claude-backup-watchdog.ps1` | PowerShell | hlídá, že se záloha vůbec spouští (druhá úloha) |
| `config.schema.json` | JSON Schema | sdílená validace configu (engine i editor) |
| `deploy.ps1` | PowerShell | nasazení do `~/.local/bin`, `-CreateTask` vytvoří úlohy |
| `tests/run-tests.ps1` | PowerShell | kompletní sandbox testy (nic nesahá na reálný config/cíle) |

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
3. **Nasadit** — `deploy.ps1 -CreateTask` (zkopíruje scripty do `~/.local/bin`,
   schéma vedle configu a vytvoří chybějící naplánované úlohy: `ClaudeBackup`
   po přihlášení + každých 10 min a `ClaudeBackupWatchdog` po přihlášení
   +30 min, pak co 12 h). Bez `-CreateTask` deploy existující úlohy jen
   aktualizuje (engine, interval) a nové nevytváří.

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
| `c` / `x` / `ep` | přidat / odebrat / **upravit** cíl (pevná cesta / jmenovka svazku; v `ep` i **koš** — dny držení smazaných) |
| `f` / `d` | **výjimky** souborů / složek (`+jmeno` přidá, `-jmeno` odebere, prázdné = zpět) |
| `b` | **databáze** — přidat / odebrat / upravit dumpované DB servery (viz níže) |
| `k` | **úklid cílů** — vypíše a po potvrzení smaže z kořene cíle vše, co nepatří žádnému zdroji (starý layout, složky po odebraných zdrojích) |
| `n` | **notifikace** při chybě zap/vyp (Windows toast) + interval opakování toastu při trvající chybě |
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
  ostatní cíle vyšly). Exit 1 se opakuje při každém běhu, dokud cíl chybí;
  **toast** se ale při trvající stejné chybě opakuje až po `notify.repeatMinutes`
  (výchozí 360, tj. 6 h — jiná chyba přijde hned, úspěšný běh počítadlo resetuje).
  Pro cíl, který má být vždy dostupný — dozvíš se, když vypadne.

Když jsou nedostupné **všechny** cíle, engine skončí exit 2.

Pozn.: zdroj s `onlyDestinations` (např. velká složka jen na SSD) se při
odpojeném disku **nezálohuje nikam** — má kopii jen na tom jednom cíli.

## Hlídání, že záloha vůbec běží (watchdog)

Engine ohlásí **selhání svého běhu**, ale ne situaci, kdy se **vůbec nespouští**
(zakázaná/smazaná úloha, rozbitý trigger). Od toho je druhá úloha
`ClaudeBackupWatchdog` (`claude-backup-watchdog.ps1`, vytvoří ji
`deploy.ps1 -CreateTask`): po přihlášení +30 min a pak každých 12 h zkontroluje,
že úloha zálohy existuje, není zakázaná a běžela nedávno (výchozí limit 60 min).
Problém → toast + řádek do `_engine.log` vedle configu. Výsledky *selhání* běhů
neřeší — ty toastuje engine sám.

## Testy

```
powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1
```

Kompletní sandbox suita (engine, editor, restore, watchdog, deploy `-WhatIf`) —
běží v `%TEMP%\cbtest`, na reálný config ani cíle nesahá. Jediný viditelný
vedlejší efekt: jeden testovací toast (ověření rate-limitu notifikací).

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

### Obnova scriptem (`claude-restore.ps1`)

Restore čte config, spočítá slugy stejně jako engine a kopíruje slug složky
zpět na původní cesty — nemusíš nic mapovat ručně:

```
claude-restore.ps1 -DryRun               # jen ukáže co→kam, nic nezapíše
claude-restore.ps1                       # obnova všeho z primárního cíle (ptá se před zápisem)
claude-restore.ps1 -From extSSD          # obnova z jiného cíle z configu
claude-restore.ps1 -Only USERPROFILE_Claude,2   # jen vybrané zdroje (slug nebo pořadí)
claude-restore.ps1 -FromBackup "E:\Backups\claude"   # nový stroj: koren zálohy přímo,
                                         # config si najde v záloze (je soběstačná)
```

**Bezpečnostní sémantika:** default **nemaže** — jen doplní/přepíše soubory ze
zálohy (`robocopy /E`). `-Mirror` udělá přesné zrcadlo (smaže, co v záloze
není), ale jen **uvnitř obnovovaných stromů** — u glob zdrojů se zrcadlí každá
položka zvlášť, base složka (typicky celý `%USERPROFILE%`) se nikdy nezrcadlí.
Bez `-Yes` se před zápisem ptá; `.credentials.json` se **nikdy neobnovuje**
(po obnově `.claude` se do Claude přihlas znovu).

**Nový stroj (disaster recovery):** záloha obsahuje i config a scripty
(`USERPROFILE_.config_claude-backup`, `USERPROFILE_.local_bin` — je v ní
i `claude-restore.ps1`). Postup: spusť restore přímo ze zálohy s `-FromBackup`,
pak `deploy.ps1` z obnoveného repa/`.local\bin` a ručně vytvoř naplánovanou
úlohu (její vytvoření je mimo deploy).

Ruční obnova bez scriptu = zkopírovat obsah slug složky zpět na cestu, ze
které slug vznikl (např. `…\Backups\claude\USERPROFILE\.claude` zpět do
`%USERPROFILE%\.claude`).

⚠️ `/MIR` je **zrcadlo, ne archiv** — když v profilu soubor smažeš, při dalším
běhu zmizí i ze zálohy. Proti „smazal jsem to omylem minulý týden" chrání **koš**
(viz níže), pokud ho má cíl zapnutý.

## Koš — ochrana proti omylem smazaným souborům

Cíl se zapnutým košem (`trash.keepDays`, nastavíš přes `ep` → `k`) **nemaže
natvrdo**: položky, které by `/MIR` smazal, se přesunou do
`<cíl>\_kos\<datum>\<slug>\<cesta>` a drží se tam `keepDays` dní (pak je
purge při běžné záloze odstraní). Přesun je rename na stejném svazku — nic se
nekopíruje, funguje i na exFAT.

- **SSD cíle: zapni** (doporučeno ~30 dní) — smazané soubory jinak nekryje nic.
- **OneDrive: nech vypnutý** — má vlastní koš (30 dní) i verzování souborů
  a `_kos` by ukusoval z ~5GB kvóty.
- **Obnova z koše:** struktura je lidsky čitelná — najdi
  `_kos\<datum>\<slug>\…` a zkopíruj zpět (ručně, nebo po obnově slug složky
  scriptem `claude-restore.ps1`).
- Koš chrání jen **smazané** soubory, ne přepsané (verzování obsahu koš
  nedělá — na OneDrive ho řeší OneDrive sám).
- `.credentials.json` se do koše nikdy nedostane (výjimky platí i pro koš).

## Zálohování databází (dumpy)

Živý datadir PostgreSQL/MariaDB nejde bezpečně kopírovat — blok `databases`
v configu (spravuje editor přes `b`) proto zálohuje **logické dumpy**:

1. Engine dumpne server do lokálního stagingu
   (`%LOCALAPPDATA%\claude-backup\dbdumps\db_<name>`): `pg_dumpall` (všechny
   DB včetně rolí) resp. `mariadb-dump --all-databases`. Nový dump vzniká, až
   když je poslední starší než `intervalMinutes` (výchozí 360 = 6 h); drží se
   `keepCount` posledních (výchozí 7), starší se mažou.
2. Staging se na cíle zrcadlí jako složka `db_<name>` — typicky na vyhrazený
   cíl (`onlyDestinations`), např. `Backups\databases` na SSD, **bez koše**
   (retenci řeší `keepCount`).

**Hesla do configu nepatří** (config se zálohuje do cloudu) — schéma, engine
i editor vlastnost `password` odmítají. Postgres se autentizuje přes
`pgpass.conf`/trust, MariaDB přes `--defaults-extra-file=...` v `extraArgs`.

Server s `optional: true` (např. Postgres spouštěný jen ručně) se při
nedostupnosti přeskočí bez chyby; nedostupný povinný server = exit 1 + toast.
Selhaný dump nikdy nepřepíše poslední dobrý (dump jde přes `_dump.tmp`).

**Obnova dumpu** (ručně): PostgreSQL `psql -p <port> -U postgres -f <dump>.sql
postgres`, MariaDB `mariadb -P <port> -u root < <dump>.sql`.

## Návratové kódy enginu

`0` ok (vč. přeskočených zamčených souborů a nepřipojeného **volitelného** cíle) ·
`1` chyba kopírování **nebo nedostupný povinný cíl** (když jinak záloha proběhla —
navíc přijde toast) · `2` žádný cíl dostupný · `3` config chybí / nevalidní (engine
se pak **nedostane** k `robocopy /MIR`). Plánovač je ukazuje v `LastTaskResult`.
