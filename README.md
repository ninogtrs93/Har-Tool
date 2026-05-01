# Teams Web Log Capture (no-build Windows tool)

Dit project is direct bruikbaar als map op Windows, zonder build, zonder npm, zonder installer.

## Bestanden

- `START-HIER.cmd` – dubbelklik startbestand
- `Teams-Web-Log-Capture.ps1` – hoofdscript
- `config.json` – instellingen
- `README.md` – uitleg

## Gebruik

1. Kopieer de map naar een Windows-machine met Microsoft Edge.
2. Dubbelklik op `START-HIER.cmd`.
3. Edge opent met Teams Web.
4. Log in en open Roger365.
5. De recorder draait direct vanaf browserstart.
6. Typ in het consolevenster:
   - `status` voor actuele status
   - `opslaan` om capturebestanden op te slaan
   - `annuleren` om te stoppen zonder output

## Output

Bij `opslaan` schrijft de tool naar:

`%USERPROFILE%\Downloads\Teams-Web-Log-Capture\session-<timestamp>\`

Met minimaal:

- `capture.ndjson`
- `summary.json`
- `samenvatting.txt`
- `targets.json`
- `hosts-by-target.json`

## Wat deze v1 doet

- Start Edge met tijdelijk profiel en CDP remote debugging
- Start passieve capture direct vanaf browserstart
- Observeert netwerk-events, requests en websocket-signalen
- Markeert de vereiste Roger/SignalR hosts en pad-markers
- Blijft actief tot de gebruiker handmatig opslaat/annuleert of timeout bereikt is

## Config aanpassen

Pas `config.json` aan voor hosts, markers, polling/status interval, outputlocatie en timeout.
