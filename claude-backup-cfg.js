#!/usr/bin/env node
'use strict';

// claude-backup-cfg.js  (ClaudeBackup 2.0 - interaktivni editor configu, faze 2)
//
// Bezpecna uprava %USERPROFILE%\.config\claude-backup\config.json:
//   - menu + pruvodci (pridat/odebrat zdroj i cil, upravit vyjimky, uklid cilu),
//   - validace pred ulozenim (zrcadli config.schema.json - stejna pravidla jako engine),
//   - atomicky zapis (temp + rename) se zalohou config.json.bak.
//
// ZADNE externi zavislosti (jen vestaveny readline). Node je portable v
// ~/.local/nodejs, volat absolutni cestou (viz wrapper claude-backup-cfg.cmd, faze 4).
// UI je zamerne ASCII (konzolova bezpecnost, kvuli kodovani konzole).
//
// Argumenty:  --config <cesta>   (jinak vychozi cesta v profilu)
//
// [t] test (dry-run, robocopy /L) a [s] stav posledni zalohy (faze 3).

const fs = require('fs');
const os = require('os');
const path = require('path');
const readline = require('readline');
const { spawnSync } = require('child_process');

// --- cesty -----------------------------------------------------------------
function parseConfigPath() {
    const i = process.argv.indexOf('--config');
    if (i !== -1 && process.argv[i + 1]) return path.resolve(process.argv[i + 1]);
    return path.join(os.homedir(), '.config', 'claude-backup', 'config.json');
}
const CONFIG_PATH = parseConfigPath();
const CONFIG_DIR = path.dirname(CONFIG_PATH);
const SCHEMA_HINT = './config.schema.json';
// engine je vedle editoru (dev: koren repa; nasazeno: ~/.local/bin)
const ENGINE = path.join(__dirname, 'claude-backup.ps1');
const POWERSHELL = process.env.SystemRoot
    ? path.join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
    : 'powershell.exe';

// --- vychozi config (puvodni zadratovana sada zdroju a cilu) ----------------
function defaultConfig() {
    return {
        $schema: SCHEMA_HINT,
        version: 1,
        sources: [
            { type: 'glob', base: '%USERPROFILE%', pattern: '.claude*' },
            { type: 'dir', path: '%USERPROFILE%\\.local\\bin' },
            { type: 'dir', path: '%USERPROFILE%\\Claude' },
            { type: 'dir', path: '%USERPROFILE%\\.config\\claude-backup' }
        ],
        excludeFiles: ['.credentials.json'],
        excludeDirs: ['node_modules', '__pycache__', '.venv', '.cache', 'Cache',
            '.mypy_cache', '.pytest_cache', '.ruff_cache', '.next', '.turbo', 'tmp', 'temp'],
        destinations: [
            { name: 'OneDrive', type: 'path', path: '%OneDrive%\\Backups\\claude', envFallback: ['OneDrive', 'OneDriveConsumer'], primary: true, robocopyOpts: [] },
            { name: 'extSSD', type: 'volumeLabel', label: 'BACKUP_SSD', subPath: 'Backups\\claude', robocopyOpts: ['/FFT'], optional: true }
        ],
        log: { file: '_backup.log', maxSizeKB: 1024, keepLines: 300 },
        notify: { onError: true },
        schedule: { taskName: 'ClaudeBackup', intervalMinutes: 10 }
    };
}

// --- env expanze (jen pro kontrolu existence / zobrazeni) ------------------
function expandEnv(s) {
    return String(s).replace(/%([^%]+)%/g, (m, n) => (process.env[n] !== undefined ? process.env[n] : m));
}

// Rozvine cestu cile shodne s enginem (Resolve-EnvPath): %VAR% -> fallbacky -> %USERPROFILE%\<VAR>.
function resolveEnvPath(p, fallbacks) {
    let r = expandEnv(p);
    const m = r.match(/%([^%]+)%/);
    if (m) {
        const varName = m[1];
        let val = null;
        for (const fb of (Array.isArray(fallbacks) ? fallbacks : [])) { if (process.env[fb]) { val = process.env[fb]; break; } }
        if (!val) val = path.join(os.homedir(), varName);
        r = expandEnv(String(p).replace('%' + varName + '%', val));
    }
    return r;
}

// Absolutni cesta k cilove slozce, nebo null kdyz nedostupny (jako engine Resolve-DestRoot).
function resolveDestRoot(d) {
    if (!d) return null;
    if (d.type === 'path') return resolveEnvPath(d.path, d.envFallback);
    if (d.type === 'volumeLabel') {
        if (!/^[A-Za-z0-9 _.\-]+$/.test(String(d.label || ''))) return null;
        const r = spawnSync(POWERSHELL, ['-NoProfile', '-Command',
            "(Get-Volume -FileSystemLabel '" + d.label + "' -ErrorAction SilentlyContinue).DriveLetter"], { encoding: 'utf8' });
        const letter = ((r && r.stdout) || '').trim();
        if (!letter) return null;
        return letter + ':\\' + d.subPath;
    }
    return null;
}

// --- slug zdroje (zrcadli Get-SourceSlug v claude-backup.ps1) ---------------
// Koren zdroje = NEROZVINUTY retezec z configu (dir: path, glob: base).
function sourceRoot(s) { return String((s && (s.type === 'glob' ? s.base : s.path)) || ''); }

// Slug = jmeno slozky zdroje v cili: %USERPROFILE%\.local\bin -> USERPROFILE_.local_bin.
// Kazdy zdroj ma v cili vlastni strom; kolize (ruzne koreny -> stejny slug) blokuje validace.
function sourceSlug(s) {
    let t = sourceRoot(s).trim().replace(/[\\\/]+$/, '');
    t = t.replace(/%/g, '');
    t = t.replace(/[\\\/:]+/g, '_');
    t = t.replace(/[*?"<>|]/g, '_');
    t = t.replace(/^_+/, '').replace(/_+$/, '').replace(/[. ]+$/, '');
    return t;
}

// --- validace (zrcadli config.schema.json + engine) ------------------------
function validateConfig(cfg) {
    const e = [];
    if (!cfg || typeof cfg !== 'object' || Array.isArray(cfg)) return ['config neni objekt'];
    if (cfg.version !== 1) e.push("version musi byt 1");

    const srcs = Array.isArray(cfg.sources) ? cfg.sources : [];
    if (srcs.length < 1) e.push("sources: musi mit aspon 1 polozku (prazdne = /MIR by mazal obsah cile)");
    srcs.forEach((s, i) => {
        if (!s || typeof s !== 'object') { e.push(`sources[${i}]: neni objekt`); return; }
        if (s.type === 'glob') {
            if (!s.base) e.push(`sources[${i}] (glob): chybi base`);
            if (!s.pattern) e.push(`sources[${i}] (glob): chybi pattern`);
        } else if (s.type === 'dir') {
            if (!s.path) e.push(`sources[${i}] (dir): chybi path`);
        } else e.push(`sources[${i}]: neznamy type '${s.type}'`);
    });

    const ef = Array.isArray(cfg.excludeFiles) ? cfg.excludeFiles : [];
    if (ef.length < 1) e.push("excludeFiles: musi mit aspon 1 polozku");
    if (!ef.includes('.credentials.json')) e.push("excludeFiles: musi obsahovat '.credentials.json' (tokeny se nesmi zalohovat)");

    if (cfg.excludeDirs !== undefined && !Array.isArray(cfg.excludeDirs)) e.push("excludeDirs: musi byt pole");

    if (cfg.notify !== undefined) {
        if (typeof cfg.notify !== 'object' || Array.isArray(cfg.notify)) e.push("notify: musi byt objekt");
        else {
            if (cfg.notify.onError !== undefined && typeof cfg.notify.onError !== 'boolean') e.push("notify.onError: musi byt boolean");
            if (cfg.notify.repeatMinutes !== undefined && (!Number.isInteger(cfg.notify.repeatMinutes) || cfg.notify.repeatMinutes < 1)) e.push("notify.repeatMinutes: musi byt cele cislo >= 1");
        }
    }

    if (cfg.schedule !== undefined) {
        if (typeof cfg.schedule !== 'object' || Array.isArray(cfg.schedule)) e.push("schedule: musi byt objekt");
        else {
            if (cfg.schedule.taskName !== undefined && (typeof cfg.schedule.taskName !== 'string' || !cfg.schedule.taskName)) e.push("schedule.taskName: musi byt neprazdny retezec");
            if (cfg.schedule.intervalMinutes !== undefined && (!Number.isInteger(cfg.schedule.intervalMinutes) || cfg.schedule.intervalMinutes < 1)) e.push("schedule.intervalMinutes: musi byt cele cislo >= 1");
        }
    }

    const dts = Array.isArray(cfg.destinations) ? cfg.destinations : [];
    if (dts.length < 1) e.push("destinations: musi mit aspon 1 polozku");
    const names = [];
    dts.forEach((d, i) => {
        if (!d || typeof d !== 'object') { e.push(`destinations[${i}]: neni objekt`); return; }
        if (!d.name) e.push(`destinations[${i}]: chybi name`); else names.push(d.name);
        if (d.type === 'path') {
            if (!d.path) e.push(`destinations[${i}] (path): chybi path`);
        } else if (d.type === 'volumeLabel') {
            if (!d.label) e.push(`destinations[${i}] (volumeLabel): chybi label`);
            if (!d.subPath) e.push(`destinations[${i}] (volumeLabel): chybi subPath`);
        } else e.push(`destinations[${i}]: neznamy type '${d.type}'`);
        if (d.trash !== undefined) {
            if (!d.trash || typeof d.trash !== 'object' || Array.isArray(d.trash)) e.push(`destinations[${i}]: trash musi byt objekt`);
            else if (!Number.isInteger(d.trash.keepDays) || d.trash.keepDays < 1) e.push(`destinations[${i}]: trash.keepDays musi byt cele cislo >= 1`);
        }
    });
    const primaries = dts.filter(d => d && d.primary === true);
    if (primaries.length !== 1) e.push(`musi byt prave jeden primarni cil (nalezeno ${primaries.length})`);

    srcs.forEach((s, i) => {
        if (s && Array.isArray(s.onlyDestinations)) {
            s.onlyDestinations.forEach(od => { if (!names.includes(od)) e.push(`sources[${i}].onlyDestinations: neznamy cil '${od}'`); });
        }
    });

    // Kolize slugu: ruzne koreny nesmi dat stejny slug (zapisovaly by do stejne
    // slozky cile a /MIR by data prubezne mazal). Stejny koren smi slug sdilet.
    const slugRoots = {};   // slug (lowercase) -> { root, i }
    srcs.forEach((s, i) => {
        if (!s || typeof s !== 'object') return;
        const root = sourceRoot(s);
        if (!root) return;   // chybejici base/path uz je nahlaseno vyse
        const slug = sourceSlug(s);
        if (!slug) { e.push(`sources[${i}]: koren '${root}' dava prazdny slug (nelze odvodit slozku v cili)`); return; }
        const key = slug.toLowerCase();
        const norm = root.trim().replace(/[\\\/]+$/, '').toLowerCase();
        const seen = slugRoots[key];
        if (seen && seen.root !== norm) e.push(`sources[${i}]: kolize slugu '${slug}' se sources[${seen.i}] (ruzne koreny by zapisovaly do stejne slozky cile)`);
        else if (!seen) slugRoots[key] = { root: norm, i };
    });

    // databases (volitelny blok): dumpy DB serveru, slug 'db_<name>' zije ve
    // stejnem prostoru cile jako slugy zdroju. HESLA DO CONFIGU NEPATRI
    // (config se zalohuje do cloudu) - vlastnost password validace odmita.
    if (cfg.databases !== undefined) {
        const db = cfg.databases;
        if (!db || typeof db !== 'object' || Array.isArray(db)) e.push('databases: musi byt objekt');
        else {
            if (db.stagingDir !== undefined && (typeof db.stagingDir !== 'string' || !db.stagingDir)) e.push('databases.stagingDir: musi byt neprazdny retezec');
            const servers = Array.isArray(db.servers) ? db.servers : [];
            if (servers.length < 1) e.push('databases.servers: musi mit aspon 1 polozku (jinak blok smaz)');
            const seenNames = {};
            servers.forEach((s, i) => {
                if (!s || typeof s !== 'object') { e.push(`databases.servers[${i}]: neni objekt`); return; }
                if (!['postgres', 'mariadb'].includes(s.type)) e.push(`databases.servers[${i}]: neznamy type '${s.type}' (cekam postgres/mariadb)`);
                if (typeof s.name !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(s.name)) e.push(`databases.servers[${i}]: chybi platne name (povolene A-Za-z0-9_.-, urcuje slozku v cili)`);
                else {
                    const nk = s.name.toLowerCase();
                    if (seenNames[nk] !== undefined) e.push(`databases.servers[${i}]: duplicitni name '${s.name}'`);
                    seenNames[nk] = i;
                    const sk = ('db_' + nk);
                    const seen = slugRoots[sk];
                    if (seen && seen.root !== 'db:' + nk) e.push(`databases.servers[${i}]: slug 'db_${s.name}' koliduje se slozkou zdroje v cili`);
                    else if (!seen) slugRoots[sk] = { root: 'db:' + nk, i };
                }
                if (typeof s.binDir !== 'string' || !s.binDir) e.push(`databases.servers[${i}]: chybi binDir (slozka s dump nastroji)`);
                if ('password' in s) e.push(`databases.servers[${i}]: 'password' do configu NEPATRI (config se zalohuje do cloudu; pouzij pgpass.conf / --defaults-extra-file)`);
                if (s.host !== undefined && (typeof s.host !== 'string' || !s.host)) e.push(`databases.servers[${i}]: host musi byt neprazdny retezec`);
                if (s.user !== undefined && (typeof s.user !== 'string' || !s.user)) e.push(`databases.servers[${i}]: user musi byt neprazdny retezec`);
                if (s.port !== undefined && (!Number.isInteger(s.port) || s.port < 1 || s.port > 65535)) e.push(`databases.servers[${i}]: port musi byt cele cislo 1-65535`);
                ['intervalMinutes', 'keepCount'].forEach(k => {
                    if (s[k] !== undefined && (!Number.isInteger(s[k]) || s[k] < 1)) e.push(`databases.servers[${i}]: ${k} musi byt cele cislo >= 1`);
                });
                if (s.extraArgs !== undefined && !Array.isArray(s.extraArgs)) e.push(`databases.servers[${i}]: extraArgs musi byt pole`);
                if (s.onlyDestinations !== undefined) {
                    if (!Array.isArray(s.onlyDestinations)) e.push(`databases.servers[${i}]: onlyDestinations musi byt pole`);
                    else s.onlyDestinations.forEach(od => { if (!names.includes(od)) e.push(`databases.servers[${i}].onlyDestinations: neznamy cil '${od}'`); });
                }
            });
        }
    }
    return e;
}

// --- IO --------------------------------------------------------------------
function loadConfig() {
    if (!fs.existsSync(CONFIG_PATH)) return { status: 'missing' };
    let raw;
    try { raw = fs.readFileSync(CONFIG_PATH, 'utf8'); }
    catch (err) { return { status: 'error', message: 'nelze cist: ' + err.message }; }
    try { return { status: 'ok', cfg: JSON.parse(raw) }; }
    catch (err) { return { status: 'error', message: 'neplatny JSON: ' + err.message }; }
}

function saveConfig(cfg) {
    // atomicky: zapis do .tmp, zaloha stavajiciho do .bak, pak rename pres original
    const tmp = CONFIG_PATH + '.tmp';
    const bak = CONFIG_PATH + '.bak';
    if (!fs.existsSync(CONFIG_DIR)) fs.mkdirSync(CONFIG_DIR, { recursive: true });
    fs.writeFileSync(tmp, JSON.stringify(cfg, null, 2) + '\n', 'utf8');
    const madeBackup = fs.existsSync(CONFIG_PATH);
    if (madeBackup) fs.copyFileSync(CONFIG_PATH, bak);
    try {
        fs.renameSync(tmp, CONFIG_PATH);
    } catch (err) {
        // fallback kdyby rename pres existujici soubor selhal
        fs.rmSync(CONFIG_PATH, { force: true });
        fs.renameSync(tmp, CONFIG_PATH);
    }
    return madeBackup;   // true = puvodni config existoval a byl zazalohovan do .bak
}

// --- readline (vlastni radkova fronta - odolne vuci davkovemu stdin) --------
let rl;
const EOF = Symbol('eof');
const _lineQueue = [];
let _lineWaiter = null;
let _inputEnded = false;
function ask(q) {
    process.stdout.write(q);
    return new Promise((resolve, reject) => {
        if (_lineQueue.length) return resolve(_lineQueue.shift());
        if (_inputEnded) return reject(EOF);
        _lineWaiter = { resolve, reject };
    });
}
async function askNonEmpty(q) {
    for (;;) { const a = (await ask(q)).trim(); if (a) return a; console.log('  (prazdne neni platne)'); }
}
async function askYesNo(q, def) {
    const suffix = def === true ? ' [A/n]: ' : def === false ? ' [a/N]: ' : ' [a/n]: ';
    for (;;) {
        const a = (await ask(q + suffix)).trim().toLowerCase();
        if (!a && def !== undefined) return def;
        if (['a', 'ano', 'y', 'yes'].includes(a)) return true;
        if (['n', 'ne', 'no'].includes(a)) return false;
    }
}
function csvToArr(s) { return String(s).split(',').map(x => x.trim()).filter(Boolean); }

// --- render ----------------------------------------------------------------
function letter(i) { return String.fromCharCode(65 + i); }
function notifyEnabled(cfg) { return !(cfg.notify && cfg.notify.onError === false); }
function scheduleTaskName(cfg) { return (cfg.schedule && cfg.schedule.taskName) ? cfg.schedule.taskName : 'ClaudeBackup'; }
function scheduleInterval(cfg) { return (cfg.schedule && cfg.schedule.intervalMinutes) ? cfg.schedule.intervalMinutes : null; }

// Precte interval opakovani (v minutach) ze zive naplanovane ulohy, nebo null.
function getTaskIntervalMinutes(taskName) {
    if (/'/.test(taskName)) return null;
    const r = spawnSync(POWERSHELL, ['-NoProfile', '-Command',
        "$ErrorActionPreference='SilentlyContinue'; $t = Get-ScheduledTask -TaskName '" + taskName + "'; if ($t) { $iv = $t.Triggers | ForEach-Object { $_.Repetition.Interval } | Where-Object { $_ } | Select-Object -First 1; if ($iv) { [int][System.Xml.XmlConvert]::ToTimeSpan($iv).TotalMinutes } }"],
        { encoding: 'utf8' });
    const n = parseInt(((r && r.stdout) || '').trim(), 10);
    return Number.isInteger(n) ? n : null;
}

// Nastavi interval opakovani zive ulohy (zachova oba triggery). Vraci {ok, msg}.
function setTaskIntervalMinutes(taskName, minutes) {
    if (/'/.test(taskName)) return { ok: false, msg: 'nazev ulohy obsahuje apostrof' };
    const r = spawnSync(POWERSHELL, ['-NoProfile', '-Command',
        "$ErrorActionPreference='Stop'; $name='" + taskName + "'; try { $t = Get-ScheduledTask -TaskName $name; $ok=$false; foreach ($tr in $t.Triggers) { if ($tr.Repetition -and $tr.Repetition.Interval) { $tr.Repetition.Interval='PT" + minutes + "M'; $ok=$true } }; if (-not $ok) { throw 'uloha nema opakovaci trigger' }; Set-ScheduledTask -TaskName $name -Trigger $t.Triggers | Out-Null; 'OK' } catch { 'ERR: '+$_.Exception.Message }"],
        { encoding: 'utf8' });
    if (r.error) return { ok: false, msg: r.error.message };
    const out = ((r && r.stdout) || '').trim();
    if (out.endsWith('OK')) return { ok: true };
    return { ok: false, msg: out.replace(/^ERR:\s*/, '') || 'neznama chyba' };
}

function srcLabel(s) {
    if (s.type === 'glob') return `glob   base=${s.base}  pattern=${s.pattern}  ->  ${sourceSlug(s)}\\`;
    if (s.type === 'dir') return `dir    ${s.path}  ->  ${sourceSlug(s)}\\`;
    return `?      ${JSON.stringify(s)}`;
}
function destLabel(d) {
    let loc;
    if (d.type === 'path') loc = `path        ${d.path}`;
    else if (d.type === 'volumeLabel') loc = `volumeLabel ${d.label}:\\${d.subPath}`;
    else loc = JSON.stringify(d);
    const tags = [];
    if (d.primary) tags.push('primarni');
    if (d.optional) tags.push('volitelny');
    if (d.trash && d.trash.keepDays) tags.push('kos=' + d.trash.keepDays + 'd');
    if (Array.isArray(d.robocopyOpts) && d.robocopyOpts.length) tags.push('opts=' + d.robocopyOpts.join(' '));
    return `${d.name}  ${loc}${tags.length ? '  [' + tags.join(', ') + ']' : ''}`;
}

function dbServers(cfg) { return (cfg.databases && Array.isArray(cfg.databases.servers)) ? cfg.databases.servers : []; }
function dbLabel(s) {
    const host = s.host || 'localhost';
    const port = s.port || (s.type === 'postgres' ? 5432 : 3306);
    const user = s.user || (s.type === 'postgres' ? 'postgres' : 'root');
    const tags = [];
    tags.push('co ' + (s.intervalMinutes || 360) + ' min');
    tags.push('drzet ' + (s.keepCount || 7));
    if (s.optional) tags.push('volitelny');
    const only = Array.isArray(s.onlyDestinations) && s.onlyDestinations.length ? '   -> jen: ' + s.onlyDestinations.join(', ') : '';
    return `${s.type}  ${s.name}  ${host}:${port}  user=${user}  ->  db_${s.name}\\  [${tags.join(', ')}]${only}`;
}

function render(cfg, dirty) {
    console.log('\n============================================================');
    console.log('  ClaudeBackup - konfigurace' + (dirty ? '   * NEULOZENE ZMENY' : ''));
    console.log('  ' + CONFIG_PATH);
    console.log('============================================================');
    console.log('Zdroje:');
    (cfg.sources || []).forEach((s, i) => {
        const only = Array.isArray(s.onlyDestinations) && s.onlyDestinations.length ? '   -> jen: ' + s.onlyDestinations.join(', ') : '';
        console.log(`  ${i + 1}. ${srcLabel(s)}${only}`);
    });
    console.log('Cile:');
    (cfg.destinations || []).forEach((d, i) => console.log(`  ${letter(i)}. ${destLabel(d)}`));
    if (dbServers(cfg).length) {
        console.log('Databaze (dumpy):');
        dbServers(cfg).forEach((s, i) => console.log(`  ${i + 1}. ${dbLabel(s)}`));
    }
    console.log('Vyjimky:');
    console.log('  soubory: ' + (cfg.excludeFiles || []).join(', '));
    console.log('  slozky:  ' + ((cfg.excludeDirs && cfg.excludeDirs.length) ? cfg.excludeDirs.join(', ') : '(zadne)'));
    console.log('Notifikace pri chybe: ' + (notifyEnabled(cfg) ? 'ZAP (Windows toast)' : 'vyp'));
    console.log('Interval ulohy: ' + (scheduleInterval(cfg) !== null ? scheduleInterval(cfg) + ' min' : '(nenastaveno)') + '   (uloha ' + scheduleTaskName(cfg) + ')');
    console.log('------------------------------------------------------------');
    console.log('[p] pridat zdroj   [o] odebrat zdroj   [ec] upravit zdroj');
    console.log('[c] pridat cil     [x] odebrat cil     [ep] upravit cil   [k] uklid cilu');
    console.log('[f] vyjimky-soubory   [d] vyjimky-slozky   [n] notifikace zap/vyp   [b] databaze');
    console.log('[i] interval ulohy   [t] test (dry-run)   [s] stav   [u] ulozit   [q] konec');
}

// --- pruvodci --------------------------------------------------------------
async function addSource(cfg) {
    const t = (await ask('typ zdroje [glob/dir] (prazdne=zpet): ')).trim().toLowerCase();
    if (!t) return false;
    if (t !== 'glob' && t !== 'dir') { console.log('  neznamy typ.'); return false; }
    let src;
    if (t === 'glob') {
        let base = (await ask('  base (prazdne = %USERPROFILE%): ')).trim() || '%USERPROFILE%';
        const pattern = await askNonEmpty('  pattern (napr. .claude*): ');
        src = { type: 'glob', base, pattern };
    } else {
        const p = await askNonEmpty('  cesta (lze pouzit %VAR%): ');
        const exp = expandEnv(p);
        if (!fs.existsSync(exp)) console.log(`  pozn.: cesta ted neexistuje (${exp}) - pridavam presto.`);
        src = { type: 'dir', path: p };
    }
    const only = csvToArr(await ask('  omezit na cile - jmena oddelena carkou (prazdne = vsechny): '));
    if (only.length) src.onlyDestinations = only;
    cfg.sources.push(src);
    console.log('  + zdroj pridan.');
    return true;
}

async function removeSource(cfg) {
    if (!cfg.sources.length) { console.log('  zadne zdroje.'); return false; }
    const a = (await ask('cislo zdroje k odebrani (prazdne=zpet): ')).trim();
    if (!a) return false;
    const idx = parseInt(a, 10) - 1;
    if (isNaN(idx) || idx < 0 || idx >= cfg.sources.length) { console.log('  neplatne cislo.'); return false; }
    if (cfg.sources.length === 1) {
        const ok = await askYesNo('  je to POSLEDNI zdroj (prazdny seznam se neda ulozit). Presto odebrat?', false);
        if (!ok) return false;
    }
    const [rm] = cfg.sources.splice(idx, 1);
    console.log('  - odebran: ' + srcLabel(rm));
    return true;
}

async function addDestination(cfg) {
    const t = (await ask('typ cile [path/volumeLabel] (prazdne=zpet): ')).trim();
    if (!t) return false;
    if (t !== 'path' && t !== 'volumeLabel') { console.log('  neznamy typ.'); return false; }
    const name = await askNonEmpty('  nazev (jmeno cile, napr. OneDrive): ');
    if (cfg.destinations.some(d => d.name === name)) { console.log('  cil s timto jmenem uz existuje.'); return false; }
    const dest = { name, type: t };
    if (t === 'path') {
        dest.path = await askNonEmpty('  cesta (lze %VAR%, napr. %OneDrive%\\Backups\\claude): ');
        const fb = csvToArr(await ask('  envFallback - nahradni promenne (prazdne = zadne): '));
        if (fb.length) dest.envFallback = fb;
    } else {
        dest.label = await askNonEmpty('  jmenovka svazku (napr. BACKUP_SSD): ');
        dest.subPath = await askNonEmpty('  podcesta na svazku (napr. Backups\\claude): ');
    }
    const opts = csvToArr(await ask('  robocopy prepinace navic (napr. /FFT; prazdne = zadne): '));
    dest.robocopyOpts = opts;
    const kosDny = (await ask('  kos - dny drzeni smazanych polozek (prazdne = bez kose): ')).trim();
    if (kosDny) {
        const m = parseInt(kosDny, 10);
        if (Number.isInteger(m) && m >= 1 && String(m) === kosDny) dest.trash = { keepDays: m };
        else console.log('  neplatne cislo - kos zustava vypnuty.');
    }
    dest.optional = await askYesNo('  volitelny (nedostupny cil se preskoci bez chyby)?', t === 'volumeLabel');
    const makePrimary = await askYesNo('  primarni (je v nem log)?', cfg.destinations.every(d => !d.primary));
    if (makePrimary) { cfg.destinations.forEach(d => { d.primary = false; }); dest.primary = true; }
    cfg.destinations.push(dest);
    console.log('  + cil pridan.');
    return true;
}

async function removeDestination(cfg) {
    if (!cfg.destinations.length) { console.log('  zadne cile.'); return false; }
    if (cfg.destinations.length === 1) { console.log('  nelze odebrat posledni cil (musi zustat aspon jeden).'); return false; }
    const a = (await ask('pismeno cile k odebrani (prazdne=zpet): ')).trim().toUpperCase();
    if (!a) return false;
    const idx = a.charCodeAt(0) - 65;
    if (idx < 0 || idx >= cfg.destinations.length) { console.log('  neplatne pismeno.'); return false; }
    const [rm] = cfg.destinations.splice(idx, 1);
    console.log('  - odebran cil: ' + rm.name);
    if (rm.primary && cfg.destinations.length && !cfg.destinations.some(d => d.primary)) {
        cfg.destinations[0].primary = true;
        console.log('  (primarni prepnut na: ' + cfg.destinations[0].name + ')');
    }
    return true;
}

async function editExcludes(cfg, kind) {
    const key = kind === 'files' ? 'excludeFiles' : 'excludeDirs';
    if (!Array.isArray(cfg[key])) cfg[key] = [];
    let changed = false;
    for (;;) {
        console.log(`\n  vyjimky-${kind === 'files' ? 'soubory' : 'slozky'}: ` + (cfg[key].length ? cfg[key].join(', ') : '(zadne)'));
        const a = (await ask("  '+jmeno' pridat, '-jmeno' odebrat, prazdne = zpet: ")).trim();
        if (!a) return changed;
        const op = a[0], val = a.slice(1).trim();
        if (!val) { console.log('  chybi jmeno.'); continue; }
        if (op === '+') {
            if (!cfg[key].includes(val)) { cfg[key].push(val); changed = true; console.log('  + ' + val); }
            else console.log('  uz tam je.');
        } else if (op === '-') {
            if (kind === 'files' && val === '.credentials.json') { console.log('  .credentials.json nelze odebrat (kriticky invariant).'); continue; }
            const i = cfg[key].indexOf(val);
            if (i !== -1) { cfg[key].splice(i, 1); changed = true; console.log('  - ' + val); }
            else console.log('  nenalezeno.');
        } else console.log("  zacni znakem '+' nebo '-'.");
    }
}

// Upravit existujici cil (nazev, primarni, volitelny, cesta, robocopyOpts).
async function editDestination(cfg) {
    if (!cfg.destinations || !cfg.destinations.length) { console.log('  zadne cile.'); return false; }
    const a = (await ask('pismeno cile k uprave (prazdne=zpet): ')).trim().toUpperCase();
    if (!a) return false;
    const idx = a.charCodeAt(0) - 65;
    if (idx < 0 || idx >= cfg.destinations.length) { console.log('  neplatne pismeno.'); return false; }
    const d = cfg.destinations[idx];
    let changed = false;
    for (;;) {
        console.log('\n  cil ' + letter(idx) + ': ' + destLabel(d));
        console.log('  [m] nazev   [p] primarni   [o] volitelny   [c] cesta   [r] robocopyOpts   [k] kos   [z] zpet');
        const c = (await ask('  co upravit? ')).trim().toLowerCase();
        if (!c || c === 'z') return changed;
        if (c === 'm') {
            const nn = (await ask('    novy nazev (prazdne=nechat): ')).trim();
            if (nn && nn !== d.name) {
                if (cfg.destinations.some((x, i) => i !== idx && x.name === nn)) { console.log('    jmeno uz existuje.'); }
                else {
                    const old = d.name; d.name = nn; changed = true;
                    (cfg.sources || []).forEach(s => { if (Array.isArray(s.onlyDestinations)) s.onlyDestinations = s.onlyDestinations.map(x => x === old ? nn : x); });
                    console.log('    nazev zmenen na ' + nn + ' (opraveno i v onlyDestinations).');
                }
            }
        } else if (c === 'p') {
            if (d.primary === true) { console.log('    uz je primarni.'); }
            else {
                cfg.destinations.forEach(x => { x.primary = false; });
                d.primary = true; changed = true;
                console.log('    nastaven jako primarni (u ostatnich zruseno).');
                if (d.optional) console.log('    pozn.: cil je volitelny - primarni by mel byt vzdy dostupny (jinak log padne do slozky configu).');
            }
        } else if (c === 'o') {
            d.optional = !(d.optional === true); changed = true;
            console.log('    volitelny: ' + (d.optional ? 'ANO' : 'ne'));
            if (d.optional && d.primary) console.log('    pozn.: primarni cil delas volitelnym.');
        } else if (c === 'c') {
            if (d.type === 'path') {
                const np = (await ask('    nova cesta (lze %VAR%, prazdne=nechat): ')).trim();
                if (np) { d.path = np; changed = true; console.log('    cesta zmenena.'); }
            } else if (d.type === 'volumeLabel') {
                const nl = (await ask('    nova jmenovka svazku (prazdne=nechat "' + d.label + '"): ')).trim();
                if (nl) { d.label = nl; changed = true; }
                const ns = (await ask('    nova podcesta (prazdne=nechat "' + d.subPath + '"): ')).trim();
                if (ns) { d.subPath = ns; changed = true; }
                if (nl || ns) console.log('    cesta zmenena.');
            }
        } else if (c === 'r') {
            const nr = (await ask('    robocopy prepinace (carkou; "-" = zadne; prazdne=nechat): ')).trim();
            if (nr === '-') { d.robocopyOpts = []; changed = true; console.log('    prepinace vymazany.'); }
            else if (nr) { d.robocopyOpts = csvToArr(nr); changed = true; console.log('    prepinace nastaveny.'); }
        } else if (c === 'k') {
            const cur = (d.trash && d.trash.keepDays) ? d.trash.keepDays : null;
            console.log('    kos: ' + (cur ? cur + ' dni' : 'vypnuty') + '   (smazane polozky se drzi v <cil>\\_kos\\<datum>)');
            if (d.name === 'OneDrive') console.log('    pozn.: OneDrive ma vlastni kos i verzovani - kos tu obvykle neni potreba.');
            const a = (await ask("    dny drzeni ('-' = vypnout; prazdne = nechat): ")).trim();
            if (a === '-') { delete d.trash; changed = true; console.log('    kos vypnut.'); }
            else if (a) {
                const m = parseInt(a, 10);
                if (!Number.isInteger(m) || m < 1 || String(m) !== a) console.log('    neplatne cislo (cekam cele cislo >= 1).');
                else { d.trash = { keepDays: m }; changed = true; console.log('    kos: ' + m + ' dni.'); }
            }
        } else console.log('    neznamy prikaz.');
    }
}

// Upravit existujici zdroj (dle typu: glob base/pattern, dir cesta; onlyDestinations).
async function editSource(cfg) {
    if (!cfg.sources || !cfg.sources.length) { console.log('  zadne zdroje.'); return false; }
    const a = (await ask('cislo zdroje k uprave (prazdne=zpet): ')).trim();
    if (!a) return false;
    const idx = parseInt(a, 10) - 1;
    if (isNaN(idx) || idx < 0 || idx >= cfg.sources.length) { console.log('  neplatne cislo.'); return false; }
    const s = cfg.sources[idx];
    let changed = false;
    for (;;) {
        const only = (Array.isArray(s.onlyDestinations) && s.onlyDestinations.length) ? s.onlyDestinations.join(', ') : '(vsechny cile)';
        console.log('\n  zdroj ' + (idx + 1) + ': ' + srcLabel(s));
        console.log('  omezeni na cile: ' + only);
        if (s.type === 'glob') console.log('  [b] base   [p] pattern   [l] omezeni-cile   [z] zpet');
        else console.log('  [c] cesta   [l] omezeni-cile   [z] zpet');
        const c = (await ask('  co upravit? ')).trim().toLowerCase();
        if (!c || c === 'z') return changed;
        if (s.type === 'glob' && c === 'b') {
            const nb = (await ask('    nova base (prazdne=nechat): ')).trim();
            if (nb) { s.base = nb; changed = true; console.log('    base zmenena.'); }
        } else if (s.type === 'glob' && c === 'p') {
            const np = (await ask('    novy pattern (prazdne=nechat): ')).trim();
            if (np) { s.pattern = np; changed = true; console.log('    pattern zmenen.'); }
        } else if (s.type === 'dir' && c === 'c') {
            const np = (await ask('    nova cesta (lze %VAR%, prazdne=nechat): ')).trim();
            if (np) { const exp = expandEnv(np); if (!fs.existsSync(exp)) console.log('    pozn.: cesta ted neexistuje (' + exp + ').'); s.path = np; changed = true; console.log('    cesta zmenena.'); }
        } else if (c === 'l') {
            const names = (cfg.destinations || []).map(x => x.name);
            const nv = (await ask('    cile carkou ("-" = na vsechny; prazdne=nechat) [' + names.join(', ') + ']: ')).trim();
            if (nv === '-') { delete s.onlyDestinations; changed = true; console.log('    -> na vsechny cile'); }
            else if (nv) {
                const arr = csvToArr(nv);
                const bad = arr.filter(x => !names.includes(x));
                if (bad.length) console.log('    neexistujici cile: ' + bad.join(', '));
                else { s.onlyDestinations = arr; changed = true; console.log('    -> jen: ' + arr.join(', ')); }
            }
        } else console.log('    neznamy prikaz.');
    }
}

// --- databaze (dumpy DB serveru) --------------------------------------------
// Sprava bloku databases: pridat/odebrat/upravit server. Hesla se NIKDY
// neukladaji do configu (zalohuje se do cloudu) - pruvodce je ani nenabizi.
async function editDatabases(cfg) {
    let changed = false;
    for (;;) {
        const servers = dbServers(cfg);
        console.log('\n  Databaze (dumpy pg_dumpall / mariadb-dump do stagingu, odtud na cile):');
        if (!servers.length) console.log('    (zadne)');
        servers.forEach((s, i) => console.log(`    ${i + 1}. ${dbLabel(s)}`));
        console.log('  [p] pridat   [o] odebrat   [e] upravit   [z] zpet');
        const c = (await ask('  co udelat? ')).trim().toLowerCase();
        if (!c || c === 'z') return changed;
        if (c === 'p') {
            const t = (await ask('    typ [postgres/mariadb] (prazdne=zpet): ')).trim().toLowerCase();
            if (!t) continue;
            if (t !== 'postgres' && t !== 'mariadb') { console.log('    neznamy typ.'); continue; }
            const name = (await askNonEmpty('    name (jmeno serveru, slozka v cili bude db_<name>): ')).trim();
            if (!/^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(name)) { console.log('    neplatne jmeno (povolene A-Za-z0-9_.-).'); continue; }
            if (servers.some(s => s && String(s.name).toLowerCase() === name.toLowerCase())) { console.log('    server s timto jmenem uz existuje.'); continue; }
            const srv = { type: t, name };
            const binDir = await askNonEmpty('    binDir (slozka s ' + (t === 'postgres' ? 'pg_dumpall/pg_isready' : 'mariadb-dump/mariadb-admin') + ', lze %VAR%): ');
            if (!fs.existsSync(expandEnv(binDir))) console.log('    pozn.: slozka ted neexistuje (' + expandEnv(binDir) + ') - pridavam presto.');
            srv.binDir = binDir;
            const host = (await ask('    host (prazdne = localhost): ')).trim();
            if (host) srv.host = host;
            const defPort = t === 'postgres' ? 5432 : 3306;
            const port = (await ask('    port (prazdne = ' + defPort + '): ')).trim();
            if (port) {
                const p = parseInt(port, 10);
                if (!Number.isInteger(p) || p < 1 || p > 65535 || String(p) !== port) { console.log('    neplatny port.'); continue; }
                srv.port = p;
            }
            const defUser = t === 'postgres' ? 'postgres' : 'root';
            const user = (await ask('    user (prazdne = ' + defUser + '; heslo do configu NEPATRI - pgpass/extraArgs): ')).trim();
            if (user) srv.user = user;
            const iv = (await ask('    dumpovat kdyz je posledni starsi nez minut (prazdne = 360): ')).trim();
            if (iv) {
                const m = parseInt(iv, 10);
                if (!Number.isInteger(m) || m < 1 || String(m) !== iv) { console.log('    neplatne cislo.'); continue; }
                srv.intervalMinutes = m;
            }
            const kc = (await ask('    kolik poslednich dumpu drzet (prazdne = 7): ')).trim();
            if (kc) {
                const m = parseInt(kc, 10);
                if (!Number.isInteger(m) || m < 1 || String(m) !== kc) { console.log('    neplatne cislo.'); continue; }
                srv.keepCount = m;
            }
            srv.optional = await askYesNo('    volitelny (nebezici server se preskoci bez chyby)?', false);
            if (!srv.optional) delete srv.optional;
            const only = csvToArr(await ask('    omezit na cile - jmena carkou (prazdne = vsechny) [' + (cfg.destinations || []).map(x => x.name).join(', ') + ']: '));
            if (only.length) srv.onlyDestinations = only;
            if (!cfg.databases || typeof cfg.databases !== 'object') cfg.databases = { servers: [] };
            if (!Array.isArray(cfg.databases.servers)) cfg.databases.servers = [];
            cfg.databases.servers.push(srv);
            changed = true;
            console.log('    + server pridan.');
        } else if (c === 'o') {
            if (!servers.length) { console.log('    zadne servery.'); continue; }
            const a = (await ask('    cislo serveru k odebrani (prazdne=zpet): ')).trim();
            if (!a) continue;
            const idx = parseInt(a, 10) - 1;
            if (isNaN(idx) || idx < 0 || idx >= servers.length) { console.log('    neplatne cislo.'); continue; }
            const [rm] = cfg.databases.servers.splice(idx, 1);
            if (!cfg.databases.servers.length) delete cfg.databases;   // prazdny blok nejde ulozit
            changed = true;
            console.log('    - odebran: ' + rm.name + '  (dumpy ve stagingu a cilech zustavaji - pripadne je smaz rucne / uklidem [k])');
        } else if (c === 'e') {
            if (!servers.length) { console.log('    zadne servery.'); continue; }
            const a = (await ask('    cislo serveru k uprave (prazdne=zpet): ')).trim();
            if (!a) continue;
            const idx = parseInt(a, 10) - 1;
            if (isNaN(idx) || idx < 0 || idx >= servers.length) { console.log('    neplatne cislo.'); continue; }
            const s = servers[idx];
            for (;;) {
                console.log('\n    server ' + (idx + 1) + ': ' + dbLabel(s));
                console.log('    [i] interval   [k] keepCount   [o] volitelny   [l] omezeni-cile   [c] binDir   [h] host:port   [u] user   [z] zpet');
                const cc = (await ask('    co upravit? ')).trim().toLowerCase();
                if (!cc || cc === 'z') break;
                if (cc === 'i') {
                    const v = (await ask('      dumpovat kdyz je posledni starsi nez minut (ted ' + (s.intervalMinutes || 360) + '): ')).trim();
                    if (v) { const m = parseInt(v, 10); if (Number.isInteger(m) && m >= 1 && String(m) === v) { s.intervalMinutes = m; changed = true; } else console.log('      neplatne cislo.'); }
                } else if (cc === 'k') {
                    const v = (await ask('      kolik poslednich dumpu drzet (ted ' + (s.keepCount || 7) + '): ')).trim();
                    if (v) { const m = parseInt(v, 10); if (Number.isInteger(m) && m >= 1 && String(m) === v) { s.keepCount = m; changed = true; } else console.log('      neplatne cislo.'); }
                } else if (cc === 'o') {
                    if (s.optional) delete s.optional; else s.optional = true;
                    changed = true;
                    console.log('      volitelny: ' + (s.optional ? 'ANO' : 'ne'));
                } else if (cc === 'l') {
                    const names = (cfg.destinations || []).map(x => x.name);
                    const nv = (await ask('      cile carkou ("-" = na vsechny; prazdne=nechat) [' + names.join(', ') + ']: ')).trim();
                    if (nv === '-') { delete s.onlyDestinations; changed = true; console.log('      -> na vsechny cile'); }
                    else if (nv) {
                        const arr = csvToArr(nv);
                        const bad = arr.filter(x => !names.includes(x));
                        if (bad.length) console.log('      neexistujici cile: ' + bad.join(', '));
                        else { s.onlyDestinations = arr; changed = true; console.log('      -> jen: ' + arr.join(', ')); }
                    }
                } else if (cc === 'c') {
                    const v = (await ask('      novy binDir (prazdne=nechat): ')).trim();
                    if (v) { if (!fs.existsSync(expandEnv(v))) console.log('      pozn.: slozka ted neexistuje (' + expandEnv(v) + ').'); s.binDir = v; changed = true; }
                } else if (cc === 'h') {
                    const nh = (await ask('      host (prazdne=nechat "' + (s.host || 'localhost') + '"): ')).trim();
                    if (nh) { s.host = nh; changed = true; }
                    const np = (await ask('      port (prazdne=nechat ' + (s.port || (s.type === 'postgres' ? 5432 : 3306)) + '): ')).trim();
                    if (np) { const p = parseInt(np, 10); if (Number.isInteger(p) && p >= 1 && p <= 65535 && String(p) === np) { s.port = p; changed = true; } else console.log('      neplatny port.'); }
                } else if (cc === 'u') {
                    const v = (await ask('      user (prazdne=nechat; heslo do configu NEPATRI): ')).trim();
                    if (v) { s.user = v; changed = true; }
                } else console.log('      neznamy prikaz.');
            }
        } else console.log('    neznamy prikaz.');
    }
}

// --- test (dry-run) a stav (faze 3) ----------------------------------------
async function testDryRun(cfg) {
    const errs = validateConfig(cfg);
    if (errs.length) {
        console.log('\nNELZE TESTOVAT - config neni platny:');
        errs.forEach(x => console.log('  * ' + x));
        return;
    }
    if (!fs.existsSync(ENGINE)) { console.log('\nEngine nenalezen: ' + ENGINE); return; }
    // testujeme AKTUALNI stav editoru (i neulozeny) -> zapis do docasneho configu
    const tmp = path.join(os.tmpdir(), 'cbcfg-dryrun-' + process.pid + '.json');
    fs.writeFileSync(tmp, JSON.stringify(cfg, null, 2) + '\n', 'utf8');
    console.log('\n----- DRY-RUN (robocopy /L; aktualni stav editoru, nic se nezapisuje) -----');
    const r = spawnSync(POWERSHELL, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ENGINE, '-DryRun', '-ConfigPath', tmp],
        { stdio: ['ignore', 'inherit', 'inherit'] });
    try { fs.rmSync(tmp, { force: true }); } catch (e) { /* ignore */ }
    console.log('----- konec dry-run -----');
    if (r.error) { console.log('  chyba spusteni enginu: ' + r.error.message); return; }
    const meaning = { 0: 'ok', 1: 'chyba kopirovani', 2: 'zadny cil dostupny', 3: 'config neplatny' }[r.status] || '?';
    console.log('  navratovy kod enginu: ' + r.status + ' (' + meaning + ')');
}

async function showStatus(cfg) {
    const rc = { 0: 'ok', 1: 'chyba kopirovani', 2: 'zadny cil dostupny', 3: 'config neplatny' };
    // 1) posledni radky _backup.log v primarnim cili
    const primary = (cfg.destinations || []).find(d => d && d.primary === true);
    const logFile = (cfg.log && cfg.log.file) ? cfg.log.file : '_backup.log';
    console.log('\n----- STAV: posledni radky ' + logFile + ' -----');
    if (!primary) {
        console.log('  neni primarni cil.');
    } else {
        const root = resolveDestRoot(primary);
        if (!root) {
            console.log('  primarni cil (' + primary.name + ') neni dostupny.');
        } else {
            const lp = path.join(root, logFile);
            if (!fs.existsSync(lp)) console.log('  log zatim neexistuje: ' + lp);
            else fs.readFileSync(lp, 'utf8').split(/\r?\n/).filter(Boolean).slice(-25).forEach(l => console.log('  ' + l));
        }
    }
    // 2) LastTaskResult naplanovane ulohy
    console.log('----- STAV: naplanovana uloha ClaudeBackup -----');
    const r = spawnSync(POWERSHELL, ['-NoProfile', '-Command',
        "$ErrorActionPreference='SilentlyContinue'; $i = Get-ScheduledTaskInfo -TaskName 'ClaudeBackup'; if ($i) { [pscustomobject]@{ LastRunTime = (''+$i.LastRunTime); LastTaskResult = $i.LastTaskResult; NextRunTime = (''+$i.NextRunTime) } | ConvertTo-Json -Compress }"],
        { encoding: 'utf8' });
    const out = ((r && r.stdout) || '').trim();
    if (!out) { console.log('  uloha nenalezena nebo bez informaci.'); return; }
    try {
        const info = JSON.parse(out);
        const m = rc[info.LastTaskResult];
        console.log('  LastRunTime:    ' + info.LastRunTime);
        console.log('  LastTaskResult: ' + info.LastTaskResult + (m ? ' (' + m + ')' : ''));
        console.log('  NextRunTime:    ' + info.NextRunTime);
    } catch (e) { console.log('  ' + out); }
}

// --- uklid cilu (jednorazova migrace na slug layout) ------------------------
// V koreni kazdeho cile smi byt jen slug slozky zdroju a log soubor. Vse
// ostatni (typicky stary layout pred slug schematem) vypise a po potvrzeni
// smaze. Jedina destruktivni akce editoru - vzdy interaktivni, s vypisem predem.
async function cleanupDestinations(cfg) {
    const errs = validateConfig(cfg);
    if (errs.length) {
        console.log('\nNELZE UKLIDIT - config neni platny:');
        errs.forEach(x => console.log('  * ' + x));
        return;
    }
    console.log('\n----- UKLID CILU: v koreni cile smi byt jen slug slozky zdroju a log -----');
    for (const d of cfg.destinations) {
        console.log('\n  cil ' + d.name + ':');
        const root = resolveDestRoot(d);
        if (!root) { console.log('    nedostupny - preskoceno.'); continue; }
        if (!fs.existsSync(root)) { console.log('    slozka neexistuje (' + root + ') - preskoceno.'); continue; }
        const expected = new Set();
        (cfg.sources || []).forEach(s => {
            const only = Array.isArray(s.onlyDestinations) ? s.onlyDestinations.filter(Boolean) : [];
            if (only.length && !only.includes(d.name)) return;
            const slug = sourceSlug(s);
            if (slug) expected.add(slug.toLowerCase());
        });
        dbServers(cfg).forEach(s => {
            const only = Array.isArray(s.onlyDestinations) ? s.onlyDestinations.filter(Boolean) : [];
            if (only.length && !only.includes(d.name)) return;
            if (s && s.name) expected.add(('db_' + s.name).toLowerCase());
        });
        const logFile = (cfg.log && cfg.log.file) ? cfg.log.file : '_backup.log';
        expected.add(logFile.toLowerCase());
        expected.add('_kos');   // kos enginu (trash.keepDays) neni sirotek
        let entries;
        try { entries = fs.readdirSync(root); }
        catch (err) { console.log('    nelze cist (' + err.message + ') - preskoceno.'); continue; }
        const orphans = entries.filter(n => !expected.has(n.toLowerCase()));
        if (!orphans.length) { console.log('    cil je cisty (' + root + ').'); continue; }
        console.log('    polozky nepatrici zadnemu zdroji:');
        orphans.forEach(n => console.log('      ' + path.join(root, n)));
        const ok = await askYesNo('    SMAZAT vypsanych ' + orphans.length + ' polozek?', false);
        if (!ok) { console.log('    ponechano beze zmeny.'); continue; }
        for (const n of orphans) {
            try { fs.rmSync(path.join(root, n), { recursive: true, force: true }); console.log('      - smazano: ' + n); }
            catch (err) { console.log('      CHYBA mazani ' + n + ': ' + err.message); }
        }
    }
    console.log('\n----- konec uklidu -----');
}

// --- hlavni smycka ---------------------------------------------------------
async function main() {
    rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    rl.on('line', l => { if (_lineWaiter) { const w = _lineWaiter; _lineWaiter = null; w.resolve(l); } else _lineQueue.push(l); });
    rl.on('close', () => { _inputEnded = true; if (_lineWaiter) { const w = _lineWaiter; _lineWaiter = null; w.reject(EOF); } });

    const loaded = loadConfig();
    if (loaded.status === 'error') {
        console.log('CHYBA: ' + loaded.message);
        console.log('Config je poskozeny - oprav rucne nebo smaz, editor ho nechce prepsat naslepo.');
        rl.close();
        process.exitCode = 2;
        return;
    }
    let cfg, dirty = false;

    try {
        if (loaded.status === 'missing') {
            console.log('Config neexistuje: ' + CONFIG_PATH);
            const ok = await askYesNo('Vytvorit vychozi config (vychozi sada zdroju a cilu)?', true);
            if (!ok) { rl.close(); return; }
            cfg = defaultConfig();
            dirty = true;
        } else {
            cfg = loaded.cfg;
        }

        for (;;) {
            render(cfg, dirty);
            const cmd = (await ask('> ')).trim().toLowerCase();
            if (cmd === 'p') { if (await addSource(cfg)) dirty = true; }
            else if (cmd === 'o') { if (await removeSource(cfg)) dirty = true; }
            else if (cmd === 'c') { if (await addDestination(cfg)) dirty = true; }
            else if (cmd === 'x') { if (await removeDestination(cfg)) dirty = true; }
            else if (cmd === 'ep') { if (await editDestination(cfg)) dirty = true; }
            else if (cmd === 'ec') { if (await editSource(cfg)) dirty = true; }
            else if (cmd === 'b') { if (await editDatabases(cfg)) dirty = true; }
            else if (cmd === 'f') { if (await editExcludes(cfg, 'files')) dirty = true; }
            else if (cmd === 'd') { if (await editExcludes(cfg, 'dirs')) dirty = true; }
            else if (cmd === 'k') { await cleanupDestinations(cfg); }
            else if (cmd === 't') { await testDryRun(cfg); }
            else if (cmd === 's') { await showStatus(cfg); }
            else if (cmd === 'i') {
                const name = scheduleTaskName(cfg);
                const cur = scheduleInterval(cfg);
                const live = getTaskIntervalMinutes(name);
                console.log('\n  uloha: ' + name);
                console.log('  interval v configu:  ' + (cur !== null ? cur + ' min' : '(nenastaveno)'));
                console.log('  interval zive ulohy: ' + (live !== null ? live + ' min' : '(uloha nenalezena / bez repetice)'));
                const a = (await ask('  novy interval v minutach (prazdne = zpet): ')).trim();
                if (a) {
                    const m = parseInt(a, 10);
                    if (!Number.isInteger(m) || m < 1 || String(m) !== a) {
                        console.log('  neplatne cislo (cekam cele cislo >= 1).');
                    } else {
                        if (!cfg.schedule) cfg.schedule = {};
                        cfg.schedule.taskName = name;
                        cfg.schedule.intervalMinutes = m;
                        dirty = true;
                        console.log('  + interval v configu nastaven na ' + m + ' min (uloz [u]).');
                        const ap = await askYesNo('  aplikovat hned na zivou ulohu ' + name + '?', true);
                        if (ap) {
                            const res = setTaskIntervalMinutes(name, m);
                            if (res.ok) console.log('  ZIVA ULOHA zmenena na ' + m + ' min.');
                            else console.log('  aplikace selhala: ' + res.msg + '\n  (interval zustava v configu; aplikuje se pri deploy / muze vyzadovat admina).');
                        }
                    }
                }
            }
            else if (cmd === 'n') {
                if (!cfg.notify) cfg.notify = {};
                cfg.notify.onError = !notifyEnabled(cfg);
                dirty = true;
                console.log('  notifikace pri chybe: ' + (cfg.notify.onError ? 'ZAP' : 'vyp'));
                if (cfg.notify.onError) {
                    const cur = cfg.notify.repeatMinutes || 360;
                    const a = (await ask('  opakovat toast pri TRVAJICI stejne chybe po minutach (prazdne=' + cur + '): ')).trim();
                    if (a) {
                        const m = parseInt(a, 10);
                        if (!Number.isInteger(m) || m < 1 || String(m) !== a) console.log('  neplatne cislo - nechavam ' + cur + '.');
                        else { cfg.notify.repeatMinutes = m; console.log('  opakovani toastu: po ' + m + ' min.'); }
                    }
                }
            }
            else if (cmd === 'u') {
                const errs = validateConfig(cfg);
                if (errs.length) {
                    console.log('\nNELZE ULOZIT - config neni platny:');
                    errs.forEach(x => console.log('  * ' + x));
                } else {
                    try {
                        const madeBackup = saveConfig(cfg);
                        dirty = false;
                        console.log('\nUlozeno: ' + CONFIG_PATH + (madeBackup ? '  (zaloha: config.json.bak)' : '  (prvni ulozeni - bez zalohy)'));
                    }
                    catch (err) { console.log('\nCHYBA pri ukladani: ' + err.message); }
                }
            }
            else if (cmd === 'q') {
                if (dirty) { const ok = await askYesNo('Mas neulozene zmeny. Opravdu skoncit bez ulozeni?', false); if (!ok) continue; }
                break;
            }
            else if (cmd) console.log('  neznamy prikaz.');
        }
    } catch (e) {
        if (e !== EOF) { rl.close(); throw e; }
        // EOF (konec vstupu / Ctrl+Z) -> tichy konec bez ulozeni
    }
    rl.close();
}

main().catch(err => { console.error('Neocekavana chyba: ' + (err && err.stack || err)); process.exitCode = 1; });
