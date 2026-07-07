# ClaudeBackup

Automatické zálohování `~/.claude*` profilů a pracovních složek na OneDrive
a externí SSD — řízené config souborem místo editace scriptu.

- **Zadání a návrh:** [PRD.md](PRD.md)
- **Původní (zadrátovaná) verze scriptů:** [legacy/](legacy/)

## Komponenty (plán)

| Komponenta | Jazyk | Role |
|---|---|---|
| `claude-backup.ps1` | PowerShell | backup engine (robocopy), čte config |
| `claude-backup-cfg` | Node.js | interaktivní CLI pro úpravu configu |
| `config.schema.json` | JSON Schema | sdílená validace configu |

Config žije v `%USERPROFILE%\.config\claude-backup\config.json`.
