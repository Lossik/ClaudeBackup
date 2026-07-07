#!/usr/bin/env node
'use strict';

// claude-backup-cfg.js  (ClaudeBackup 2.0 - interaktivni editor configu, faze 2)
//
// Bezpecna uprava %USERPROFILE%\.config\claude-backup\config.json:
//   - menu + pruvodci (pridat/odebrat zdroj i cil, upravit vyjimky),
//   - validace pred ulozenim (zrcadli config.schema.json - stejna pravidla jako engine),
//   - atomicky zapis (temp + rename) se zalohou config.json.bak.
//
// ZADNE externi zavislosti (jen vestaveny readline). Node je portable v
// ~/.local/nodejs, volat absolutni cestou (viz wrapper claude-backup-cfg.cmd, faze 4).
// UI je zamerne ASCII (konzolova bezpecnost, shodne s legacy scripty).
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

// --- vychozi config (1:1 s legacy + faze 1) --------------------------------
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
            { name: 'extSSD', type: 'volumeLabel', label: 'KINGSTON', subPath: 'Backups\\claude', robocopyOpts: ['/FFT'], optional: true }
        ],
        log: { file: '_backup.log', maxSizeKB: 1024, keepLines: 300 }
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
    });
    const primaries = dts.filter(d => d && d.primary === true);
    if (primaries.length !== 1) e.push(`musi byt prave jeden primarni cil (nalezeno ${primaries.length})`);

    srcs.forEach((s, i) => {
        if (s && Array.isArray(s.onlyDestinations)) {
            s.onlyDestinations.forEach(od => { if (!names.includes(od)) e.push(`sources[${i}].onlyDestinations: neznamy cil '${od}'`); });
        }
    });
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
    if (fs.existsSync(CONFIG_PATH)) fs.copyFileSync(CONFIG_PATH, bak);
    try {
        fs.renameSync(tmp, CONFIG_PATH);
    } catch (err) {
        // fallback kdyby rename pres existujici soubor selhal
        fs.rmSync(CONFIG_PATH, { force: true });
        fs.renameSync(tmp, CONFIG_PATH);
    }
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

function srcLabel(s) {
    if (s.type === 'glob') return `glob   base=${s.base}  pattern=${s.pattern}`;
    if (s.type === 'dir') return `dir    ${s.path}`;
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
    if (Array.isArray(d.robocopyOpts) && d.robocopyOpts.length) tags.push('opts=' + d.robocopyOpts.join(' '));
    return `${d.name}  ${loc}${tags.length ? '  [' + tags.join(', ') + ']' : ''}`;
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
    console.log('Vyjimky:');
    console.log('  soubory: ' + (cfg.excludeFiles || []).join(', '));
    console.log('  slozky:  ' + ((cfg.excludeDirs && cfg.excludeDirs.length) ? cfg.excludeDirs.join(', ') : '(zadne)'));
    console.log('------------------------------------------------------------');
    console.log('[p] pridat zdroj   [o] odebrat zdroj   [c] pridat cil   [x] odebrat cil');
    console.log('[f] vyjimky-soubory   [d] vyjimky-slozky');
    console.log('[t] test (dry-run)   [s] stav   [u] ulozit   [q] konec');
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
        dest.label = await askNonEmpty('  jmenovka svazku (napr. KINGSTON): ');
        dest.subPath = await askNonEmpty('  podcesta na svazku (napr. Backups\\claude): ');
    }
    const opts = csvToArr(await ask('  robocopy prepinace navic (napr. /FFT; prazdne = zadne): '));
    dest.robocopyOpts = opts;
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
            const ok = await askYesNo('Vytvorit vychozi config (odpovida legacy)?', true);
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
            else if (cmd === 'f') { if (await editExcludes(cfg, 'files')) dirty = true; }
            else if (cmd === 'd') { if (await editExcludes(cfg, 'dirs')) dirty = true; }
            else if (cmd === 't') { await testDryRun(cfg); }
            else if (cmd === 's') { await showStatus(cfg); }
            else if (cmd === 'u') {
                const errs = validateConfig(cfg);
                if (errs.length) {
                    console.log('\nNELZE ULOZIT - config neni platny:');
                    errs.forEach(x => console.log('  * ' + x));
                } else {
                    try { saveConfig(cfg); dirty = false; console.log('\nUlozeno: ' + CONFIG_PATH + '  (zaloha: config.json.bak)'); }
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
