# Auto-Freilassen & Button-Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tiere unter einer einstellbaren Stufen-Schwelle werden app-weit automatisch freigelassen, und die beiden Release-Buttons stehen kompakt nebeneinander.

**Architecture:** Reine Auswahl-/Gruppierungslogik in einem dependency-freien Modul `src/autoRelease.js` (node-testbar). Der Pinia-Store ruft diese Logik in einer neuen Action `autoReleaseSweep()` auf, die am Ende von `load()` getriggert wird (app-weit, da alle Akquise-Pfade `load()` aufrufen). Persistenz der Schwelle via `localStorage` pro User-ID. UI-Auswahl in `TicketsView.vue`.

**Tech Stack:** Vue 3 (`<script setup>`), Pinia (options store), PrimeVue Button, Supabase RPC `release_animals`, `node --test` für Unit-Tests.

---

## File Structure

- **Create** `src/autoRelease.js` — reine Funktion `groupAnimalsForAutoRelease(animals, thresholdTier, now)` → Liste `{ species, tier, ids[] }`. Keine Imports (eigene Tier-Order-Map + Upgrade-Check), damit unter `node --test` lauffähig.
- **Create** `src/autoRelease.test.js` — Unit-Tests (Muster wie `src/tradePublicWanted.test.js`).
- **Modify** `src/stores/game.js` — State `autoReleaseTier`/`_autoReleasing`, Lesen in `load()`, Hook am Ende von `load()`, Actions `autoReleaseSweep()` + `setAutoReleaseTier()`.
- **Modify** `src/views/TicketsView.vue` — i18n-Keys, Auto-Freilassen-Auswahl in der Release-Karte, `.release-actions` Layout-Umstellung, gekürzte Button-Labels.

---

## Task 1: Reine Auswahl-Logik `groupAnimalsForAutoRelease`

**Files:**
- Create: `src/autoRelease.js`
- Test: `src/autoRelease.test.js`

- [ ] **Step 1: Write the failing test**

`src/autoRelease.test.js`:

```javascript
import test from 'node:test'
import assert from 'node:assert/strict'
import { groupAnimalsForAutoRelease } from './autoRelease.js'

const NOW = 1_000_000

test('returns empty when threshold is off/empty', () => {
  const animals = [{ id: 'a', species: 'chicken', tier: 'normal' }]
  assert.deepEqual(groupAnimalsForAutoRelease(animals, '', NOW), [])
  assert.deepEqual(groupAnimalsForAutoRelease(animals, null, NOW), [])
})

test('groups only animals strictly below the threshold tier', () => {
  const animals = [
    { id: 'a', species: 'chicken', tier: 'normal' },
    { id: 'b', species: 'chicken', tier: 'normal' },
    { id: 'c', species: 'cow', tier: 'gold' },
    { id: 'd', species: 'cow', tier: 'diamond' }
  ]
  const groups = groupAnimalsForAutoRelease(animals, 'gold', NOW)
  assert.deepEqual(groups, [{ species: 'chicken', tier: 'normal', ids: ['a', 'b'] }])

  const groups2 = groupAnimalsForAutoRelease(animals, 'diamond', NOW)
  assert.deepEqual(
    groups2.sort((x, y) => x.species.localeCompare(y.species)),
    [
      { species: 'chicken', tier: 'normal', ids: ['a', 'b'] },
      { species: 'cow', tier: 'gold', ids: ['c'] }
    ]
  )
})

test('excludes animals that are still upgrading', () => {
  const animals = [
    { id: 'a', species: 'chicken', tier: 'normal' },
    { id: 'b', species: 'chicken', tier: 'normal', upgrade_ready_at: new Date(NOW + 60_000).toISOString() }
  ]
  const groups = groupAnimalsForAutoRelease(animals, 'gold', NOW)
  assert.deepEqual(groups, [{ species: 'chicken', tier: 'normal', ids: ['a'] }])
})

test('treats missing tier as normal and includes finished upgrades', () => {
  const animals = [
    { id: 'a', species: 'chicken' },
    { id: 'b', species: 'chicken', tier: 'normal', upgrade_ready_at: new Date(NOW - 1).toISOString() }
  ]
  const groups = groupAnimalsForAutoRelease(animals, 'gold', NOW)
  assert.deepEqual(groups, [{ species: 'chicken', tier: 'normal', ids: ['a', 'b'] }])
})

test('unknown threshold value yields no groups', () => {
  const animals = [{ id: 'a', species: 'chicken', tier: 'normal' }]
  assert.deepEqual(groupAnimalsForAutoRelease(animals, 'bogus', NOW), [])
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test`
Expected: FAIL — `Cannot find module './autoRelease.js'` / `groupAnimalsForAutoRelease is not a function`.

- [ ] **Step 3: Write minimal implementation**

`src/autoRelease.js`:

```javascript
const TIER_ORDER = { normal: 0, gold: 1, diamond: 2, epic: 3, rainbow: 4 }

function isUpgrading(a, now) {
  if (!a || !a.upgrade_ready_at) return false
  return new Date(a.upgrade_ready_at).getTime() > now
}

export function groupAnimalsForAutoRelease(animals, thresholdTier, now = Date.now()) {
  const threshold = TIER_ORDER[thresholdTier]
  if (threshold == null || threshold <= 0) return []
  const map = new Map()
  for (const a of animals || []) {
    if (isUpgrading(a, now)) continue
    const tier = a.tier || 'normal'
    const rank = TIER_ORDER[tier]
    if (rank == null || rank >= threshold) continue
    const key = `${a.species}|${tier}`
    if (!map.has(key)) map.set(key, { species: a.species, tier, ids: [] })
    map.get(key).ids.push(a.id)
  }
  return [...map.values()]
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test`
Expected: PASS (all `autoRelease` tests green; existing `tradePublicWanted` tests remain green).

- [ ] **Step 5: Commit**

```bash
git add src/autoRelease.js src/autoRelease.test.js
git commit -m "feat(tickets): reine Auswahl-Logik fuer Auto-Freilassen"
```

---

## Task 2: Store-Integration (State, Sweep, Setter, load-Hook)

**Files:**
- Modify: `src/stores/game.js` (State-Block ~`src/stores/game.js:44`, `load()` Ende ~`src/stores/game.js:273`, neue Actions nach `releaseAnimalsBulk` ~`src/stores/game.js:699`)

- [ ] **Step 1: Import der Auswahl-Logik ergänzen**

In `src/stores/game.js` die bestehende Import-Zeile für `../animals` unverändert lassen und darunter ergänzen:

```javascript
import { groupAnimalsForAutoRelease } from '../autoRelease'
```

- [ ] **Step 2: State-Felder ergänzen**

In `state: () => ({ ... })` (letztes Feld ist aktuell `craftJob: null` bei `src/stores/game.js:44`) nach `craftJob: null` ergänzen (Komma nicht vergessen):

```javascript
    craftJob: null,
    autoReleaseTier: '',
    _autoReleasing: false
```

- [ ] **Step 3: Schwelle in `load()` aus localStorage lesen + Sweep triggern**

In `load()` direkt vor `this.lastLoadedAt = Date.now()` (aktuell `src/stores/game.js:273`) einfügen:

```javascript
      try {
        const v = localStorage.getItem('autoReleaseTier:' + auth.user.id) || ''
        this.autoReleaseTier = ['', 'gold', 'diamond', 'epic', 'rainbow'].includes(v) ? v : ''
      } catch { this.autoReleaseTier = '' }
      this.autoReleaseSweep().catch(() => {})
```

- [ ] **Step 4: Actions `autoReleaseSweep` + `setAutoReleaseTier` ergänzen**

Direkt nach der bestehenden Action `releaseAnimalsBulk` (endet mit `return data` + `},` bei `src/stores/game.js:699`) einfügen:

```javascript
    async autoReleaseSweep() {
      const auth = useAuthStore()
      if (!auth.user || !this.autoReleaseTier || this._autoReleasing) return
      const groups = groupAnimalsForAutoRelease(this.animals, this.autoReleaseTier, Date.now())
      if (groups.length === 0) return
      this._autoReleasing = true
      try {
        for (const g of groups) {
          try {
            const { data, error } = await supabase.rpc('release_animals', {
              p_species: g.species,
              p_tier: g.tier || 'normal',
              p_qty: g.ids.length
            })
            if (error) continue
            if (data?.tickets != null) this.tickets = Number(data.tickets)
            const drop = new Set(g.ids)
            this.animals = this.animals.filter(a => !drop.has(a.id))
            if (drop.has(this.favoriteAnimalId)) {
              const next = this.animals.find(a => a.equipped) || this.animals[0]
              this.favoriteAnimalId = next ? next.id : null
            }
          } catch { /* einzelne Gruppe ueberspringen */ }
        }
      } finally {
        this._autoReleasing = false
      }
    },
    setAutoReleaseTier(v) {
      const auth = useAuthStore()
      const next = ['', 'gold', 'diamond', 'epic', 'rainbow'].includes(v) ? v : ''
      this.autoReleaseTier = next
      try {
        if (auth.user) localStorage.setItem('autoReleaseTier:' + auth.user.id, next)
      } catch { /* localStorage nicht verfuegbar */ }
      this.autoReleaseSweep().catch(() => {})
    },
```

- [ ] **Step 5: Verifizieren, dass nichts bricht (Lint/Build)**

Run: `npm run build`
Expected: Build erfolgreich, keine Syntaxfehler in `src/stores/game.js`.

- [ ] **Step 6: Commit**

```bash
git add src/stores/game.js
git commit -m "feat(tickets): app-weiter Auto-Freilassen-Sweep im Store"
```

---

## Task 3: UI — Auto-Freilassen-Auswahl + Button-Layout in `TicketsView.vue`

**Files:**
- Modify: `src/views/TicketsView.vue` (i18n-Objekt `I18N`, Release-Karten-Template ~`src/views/TicketsView.vue:441-517`, Style `.release-actions` ~`src/views/TicketsView.vue:779-787`)

- [ ] **Step 1: i18n-Keys ergänzen (de/en/ru)**

Im `I18N`-Objekt jeweils im `de`-, `en`- und `ru`-Block diese Keys hinzufügen (z. B. direkt nach `releaseBusy`). Echte Umlaute verwenden.

`de`:

```javascript
    autoTitle: "🤖 Auto-Freilassen",
    autoHint: "Tiere unter der gewählten Stufe werden automatisch freigelassen (app-weit).",
    autoOff: "Aus",
    tierGold: "Gold",
    tierDiamond: "Diamant",
    tierEpic: "Epic",
    tierRainbow: "Rainbow",
```

`en`:

```javascript
    autoTitle: "🤖 Auto-release",
    autoHint: "Animals below the chosen tier are released automatically (app-wide).",
    autoOff: "Off",
    tierGold: "Gold",
    tierDiamond: "Diamond",
    tierEpic: "Epic",
    tierRainbow: "Rainbow",
```

`ru`:

```javascript
    autoTitle: "🤖 Авто-освобождение",
    autoHint: "Животные ниже выбранного тира освобождаются автоматически (по всему приложению).",
    autoOff: "Выкл",
    tierGold: "Голд",
    tierDiamond: "Алмаз",
    tierEpic: "Эпик",
    tierRainbow: "Радуга",
```

- [ ] **Step 2: Auto-Freilassen-Auswahl ins Release-Karten-Template einfügen**

In `src/views/TicketsView.vue` innerhalb von `<div class="fm-controls">`, direkt **vor** `<div class="release-actions">` (aktuell `src/views/TicketsView.vue:501`) einfügen:

```html
          <div class="fm-row auto-rel">
            <label class="hint" style="margin:0">{{ tx("autoTitle") }}</label>
            <div class="fusion-tiers">
              <Button
                class="fusion-sp"
                :class="{ active: game.autoReleaseTier === '' }"
                @click="game.setAutoReleaseTier('')"
              >{{ tx("autoOff") }}</Button>
              <Button
                v-for="opt in ['gold','diamond','epic','rainbow']"
                :key="opt"
                class="fusion-sp"
                :class="{ active: game.autoReleaseTier === opt }"
                @click="game.setAutoReleaseTier(opt)"
              >{{ tx(opt === 'gold' ? 'tierGold' : opt === 'diamond' ? 'tierDiamond' : opt === 'epic' ? 'tierEpic' : 'tierRainbow') }}</Button>
            </div>
            <p class="hint" style="margin:2px 0 0">{{ tx("autoHint") }}</p>
          </div>
```

- [ ] **Step 3: Button-Labels kürzen (Nebeneinander)**

Im `I18N`-Objekt die bestehenden Werte ändern:

- `de`: `release: "🏞️ ×{qty}"`, `releaseAll: "🏞️ Alle ({count})"`
- `en`: `release: "🏞️ ×{qty}"`, `releaseAll: "🏞️ All ({count})"`
- `ru`: `release: "🏞️ ×{qty}"`, `releaseAll: "🏞️ Все ({count})"`

- [ ] **Step 4: `.release-actions` auf Reihe umstellen**

In `<style scoped>` den Block `.release-actions` (aktuell `src/views/TicketsView.vue:779-783`) ersetzen durch:

```css
.release-actions {
  display: flex;
  flex-direction: row;
  flex-wrap: wrap;
  gap: 6px;
}
.release-actions .btn {
  flex: 1 1 140px;
}
```

- [ ] **Step 5: Im Browser verifizieren**

- Dev-Server starten (`preview_start`), zur Tickets-Seite navigieren.
- Prüfen: „Freilassen ×N" und „Alle freilassen" stehen nebeneinander, brechen auf schmaler Breite sauber um (`preview_resize` schmal).
- Auto-Freilassen auf „Gold" setzen → ein Normal-Tier-Tier (ggf. via Truhe/Shop erzeugen) wird nach Reload automatisch freigelassen, Tickets-Zähler steigt, kein Endlos-Loop (`preview_console_logs` ohne Fehler/Spam, `preview_network` zeigt endlich viele `release_animals`-Calls).
- Auf „Aus" setzen → keine automatische Freilassung mehr.
- `preview_screenshot` als Nachweis.

- [ ] **Step 6: Commit**

```bash
git add src/views/TicketsView.vue
git commit -m "feat(tickets): Auto-Freilassen-Auswahl + kompaktes Button-Layout"
```

---

## Self-Review

**Spec coverage:**
- Button kompakt/nebeneinander → Task 3 Steps 3-4. ✓
- Auto-Freilassen unter Schwelle, Semantik „strikt unter" → Task 1 + Task 3 Step 2. ✓
- localStorage-Persistenz `autoReleaseTier:<uid>` → Task 2 Steps 3-4. ✓
- App-weit via `load()`-Hook → Task 2 Step 3. ✓
- Re-Entrancy-Guard `_autoReleasing`, kein `load()` im Sweep → Task 2 Steps 2,4. ✓
- Upgradende Tiere ausgeschlossen → Task 1 Test + Impl. ✓
- Favoriten-Nachführung beim lokalen Entfernen (Konsistenz mit `releaseAnimal`) → Task 2 Step 4. ✓
- Fehler pro Gruppe verschluckt → Task 2 Step 4. ✓
- i18n de/en/ru → Task 3 Step 1. ✓
- Manuelle Browser-Verifikation → Task 3 Step 5. ✓

**Placeholder scan:** Keine TBD/TODO; alle Code-Schritte vollständig. ✓

**Type consistency:** `groupAnimalsForAutoRelease(animals, thresholdTier, now)` Signatur identisch in Task 1 (Definition), Task 2 Step 4 (Aufruf). Rückgabeform `{ species, tier, ids[] }` konsistent verwendet. localStorage-Key `autoReleaseTier:<uid>` und Whitelist `['', 'gold','diamond','epic','rainbow']` identisch in Lesen (Task 2 Step 3) und Setter (Task 2 Step 4). ✓
