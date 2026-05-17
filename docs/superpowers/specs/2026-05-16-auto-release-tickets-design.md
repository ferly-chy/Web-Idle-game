# Auto-Freilassen & Button-Redesign (Tickets) — Design

Datum: 2026-05-16
Betroffene Dateien: `src/stores/game.js`, `src/views/TicketsView.vue`, `src/autoRelease.js`

## Revision 2026-05-17 (maßgeblich — ersetzt globale Schwelle)

Nach Live-Test verworfen: globale „alles unter Stufe X"-Schwelle. **Neues Modell:**
Pro Spezies eine **inklusive Maximal-Stufe**. Konfiguration ist eine Map
`autoReleaseMap = { [species]: maxTier }` (z.B. `{ chicken: "gold" }` → Normal- und
Gold-Küken werden automatisch freigelassen, Diamant/Epic/Rainbow bleiben). Nicht
gelistete Spezies = kein Auto-Freilassen.

- **Semantik:** Tier wird freigelassen, wenn `species in map` UND
  `tierRank(animal.tier) <= tierRank(map[species])` UND nicht upgradend.
- **Persistenz:** `localStorage`-Key `autoReleaseMap:<uid>`, JSON-serialisiert.
  Der alte Key `autoReleaseTier:<uid>` und State `autoReleaseTier` entfallen
  ersatzlos (Feature war unreleased, keine Migration nötig).
- **Pure Helper-Signatur:** `groupAnimalsForAutoRelease(animals, autoReleaseMap, now)`.
- **Store:** State `autoReleaseMap: {}`; `setAutoReleaseSpecies(species, maxTierOrNull)`
  (null/leer → Spezies aus Map entfernen), persistiert JSON + Sweep.
- **UI:** Die globale Aus/Gold/…-Zeile entfällt. Stattdessen erscheint bei
  ausgewählter Spezies eine Zeile „🤖 Auto bis [Aus/Normal/Gold/Diamant/Epic/Rainbow]"
  für genau diese Spezies. Spezies-Buttons mit aktivem Auto erhalten ein 🤖-Badge.
- Re-Entrancy-Guard, app-weiter `load()`-Hook, Button-Redesign: unverändert wie unten.

Die folgenden Abschnitte beschreiben das ursprüngliche (überholte) Schwellen-Modell
und gelten nur noch für die unveränderten Teile (Guard, Hook, Button-Layout, i18n-Muster).

## Ziel

Zwei Änderungen an der Tickets-Seite:

1. **Button-Design:** „Freilassen ×N" und „Alle freilassen" kompakter nebeneinander statt untereinander.
2. **Auto Verkauf:** Tiere unterhalb einer einstellbaren Stufen-Schwelle werden app-weit automatisch freigelassen.

## 1. Button-Redesign

`.release-actions` von `flex-direction: column` auf eine Reihe umstellen:

- `flex-direction: row`, `flex-wrap: wrap`, `gap: 6px`
- Beide Buttons `flex: 1` mit sinnvoller `min-width`, damit sie auf schmalen Screens umbrechen statt zu quetschen.
- „Alle freilassen" behält das Warn-Rot (`.release-all`), da die Aktion unwiderruflich ist, steht aber gleichwertig neben dem normalen Release-Button.
- Labels leicht kürzen, damit sie nebeneinander passen: `release` → „🏞️ ×{qty}", `releaseAll` → „🏞️ Alle ({count})" (de/en/ru). Bedeutung bleibt durch Kontext (Mengenzeile darüber) klar.

## 2. Auto-Freilassen (app-weit)

### Schwellen-Semantik

Tier-Rang: `normal=0, gold=1, diamond=2, epic=3, rainbow=4`.

Einstellung `autoReleaseTier`:
- `''` → Aus (Default)
- `gold` → alle Tiere mit Rang < 1 (nur Normal) werden freigelassen
- `diamond` → Rang < 2 (Normal + Gold)
- `epic` → Rang < 3 (Normal + Gold + Diamant)
- `rainbow` → Rang < 4 (alles außer Rainbow)

Upgradende Tiere (`isUpgrading`) werden nie automatisch freigelassen.

### Store (`src/stores/game.js`)

- **State:** `autoReleaseTier: ''`, internes Flag `_autoReleasing: false` (nicht im reaktiven State nötig — als einfache Instanzvariable bzw. State-Feld ohne UI-Bindung).
- **In `load()`:** vor `this.lastLoadedAt = Date.now()` aus `localStorage` lesen:
  `localStorage.getItem('autoReleaseTier:' + auth.user.id)` → in `this.autoReleaseTier` (Whitelist-validiert gegen `['', 'gold','diamond','epic','rainbow']`, sonst `''`).
  Danach `this.autoReleaseSweep()` (fire-and-forget, Fehler verschluckt) aufrufen.
- **Action `setAutoReleaseTier(v)`:** validieren, `this.autoReleaseTier = v`, in `localStorage` schreiben (`autoReleaseTier:<uid>`), danach `this.autoReleaseSweep()`.
- **Action `autoReleaseSweep()`:**
  - Frühausstieg wenn `!this.autoReleaseTier`, `this._autoReleasing`, oder kein `auth.user`.
  - Schwellen-Rang aus Map bestimmen.
  - Tiere gruppieren nach `species|tier`, nur nicht-upgradende mit `tierRank < schwelle`.
  - `this._autoReleasing = true`; pro Gruppe `supabase.rpc('release_animals', { p_species, p_tier, p_qty })`; bei Erfolg `this.tickets` aktualisieren und genau die `qty` betroffenen Tier-Objekte dieser Gruppe lokal aus `this.animals` entfernen (deterministische Auswahl aus aktuellem State, identisch zur Gruppierungsbasis).
  - `finally`: `this._autoReleasing = false`. **Kein `this.load()`** innerhalb des Sweeps → keine Rekursion.
  - Fehler einzelner Gruppen werden geloggt/verschluckt, Sweep läuft für restliche Gruppen weiter.

### Re-Entrancy / Rekursionsschutz

- Sweep ruft niemals `load()`.
- `_autoReleasing`-Flag verhindert Überschneidung paralleler Sweeps.
- Da `load()` den Sweep auslöst, der Sweep aber selbst kein `load()` aufruft, entsteht keine Schleife. Nach einem Sweep gibt es keine Tiere unter Schwelle mehr → Konvergenz.

### Scope (app-weit)

Hook am Ende von `load()`. Alle Akquise-Pfade (Shop-Kauf, Truhe, Fusion, Boss-Belohnung, App-Start, Return-Refresh) rufen letztlich `load()` auf → neu erhaltene Billig-Tiere werden zeitnah app-weit automatisch verwertet, ohne dass die Tickets-Seite offen sein muss.

### UI (`src/views/TicketsView.vue`)

In der Release-Karte (oberhalb der Release-Actions) eine Zeile „🤖 Auto-Freilassen":

- PrimeVue-Auswahl (Button-Gruppe im bestehenden `.fusion-tiers`/`.fusion-sp`-Stil, konsistent mit Spezies/Stufen-Auswahl): Optionen `Aus`, `Gold`, `Diamant`, `Epic`, `Rainbow`.
- Gebunden an `game.autoReleaseTier`, Klick ruft `game.setAutoReleaseTier(v)`.
- Kurzer Hint-Text: „Tiere unter der gewählten Stufe werden automatisch freigelassen."
- i18n-Keys de/en/ru: `autoTitle`, `autoHint`, `autoOff` + Wiederverwendung vorhandener Stufen-Bezeichnungen falls vorhanden, sonst eigene Labels.

## Fehlerbehandlung

- Sweep-RPC-Fehler pro Gruppe: verschluckt/geloggt, kein UI-Bruch (läuft im Hintergrund).
- `localStorage` nicht verfügbar: `try/catch`, Feature degradiert auf „Aus" / nicht-persistent.
- Ungültiger gespeicherter Wert: auf `''` zurückfallen.

## Bewusst NICHT enthalten (YAGNI)

- Kein Sonder-Schutz für Favoriten/equipped über die bestehende `release_animals`-RPC-Semantik hinaus (identisch zum manuellen „Alle freilassen").
- Kein serverseitiges Settings-Feld — clientseitiges `localStorage` reicht (Muster wie `bonusTaps`/`tutorialStep2`).
- Keine zeitgesteuerten Hintergrund-Timer — `load()`-Hook deckt alle Akquise-Fälle ab.
- Keine Pro-Spezies-Ausnahmen / Whitelist.

## Test / Verifikation

- Manuell im Browser-Preview: Schwelle setzen, Normal-Tier-Tier erhalten (Truhe/Shop) → wird nach Refresh automatisch freigelassen, Tickets steigen.
- Toggle „Aus" → keine automatische Freilassung.
- Kein Endlos-Loop / kein Doppel-Release (State-Konvergenz prüfen).
- Button-Layout auf schmaler Viewport-Breite (Umbruch korrekt).
