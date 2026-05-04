# Teams Web HAR Capture (no-build)

Dit is een directe Windows-tool zonder buildstap.

## Gebruik
1. Dubbelklik `START-HIER.cmd`.
2. Edge + DevTools openen automatisch.
3. Log in bij Teams en open Roger365.
4. Reproduceer het probleem.
5. Druk `1` om HAR op te slaan.

## Menu
- `1` HAR opslaan
- `2` Status
- `3` Annuleren

## Bestanden
- `START-HIER.cmd`
- `Teams-Web-HAR-Capture.ps1`
- `config.json`
- `extension/manifest.json`
- `extension/devtools.html`
- `extension/devtools.js`
- `extension/panel.html`
- `extension/panel.js`

## Output
`%USERPROFILE%\Downloads\Teams-Web-HAR-Capture\session-<timestamp>\`
- `TeamsWeb-HAR-*.har`
- `summary.json`
- `samenvatting.txt`
- `README-VOOR-SUPPORT.txt`
- `extension-status.log` (optioneel)

## Hoe dit een echte DevTools HAR maakt
De extensie draait als DevTools-extension en gebruikt `chrome.devtools.network.getHAR()` bij export. Daardoor komt de HAR uit de DevTools Network log.

## Privacy
Let op: HAR kan gevoelige data bevatten (tokens/cookies/headers/URL's). Deel alleen met vertrouwde support.
