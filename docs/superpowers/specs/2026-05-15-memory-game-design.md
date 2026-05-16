# Memory-Minispiel – Design

Status: freigegeben (2026-05-15)
Branch: `dev`

## Ziel

Neues zeitlich begrenztes Minispiel „Memory" analog zu Merge-Safari und Boss-Kampf:
Klassisches Paare-Aufdecken mit Tier-Emojis aus `species_costs`, als Level-/Etappen-Modell
mit 20 fest konfigurierten Leveln. Server-autoritativ (schummelsicher), eingebunden in
Startseite und Bestenliste.

## Entscheidungen

- **Spielprinzip:** Level/Etappen mit aufsteigender Schwierigkeit (wie Boss-Pfad).
- **Level-Regel:** Brett waechst pro Level, je Level ein Aufdeck-Versuch-Limit
  (`move_limit`). Alle Paare innerhalb des Limits = Level bestanden.
- **Zuglimit erreicht (Variante a):** Level fehlgeschlagen → gleiches Level wird neu
  gemischt, kein Fortschritt, kein `level++`.
- **Belohnungen:** Truhen pro Level (gewichteter Zufall aus `species_costs`),
  zusaetzlich garantiertes Tier alle 5 Level (Level 5/10/15/20). Keine Muenzen/Tickets,
  kein Boost.
- **Umfang:** 20 feste Level in DB-Config-Tabelle.
- **Integration:** Eigener `event_schedule`-Key `memory_game` (Countdown, sperrt nach
  Ablauf), Link-Karte + Quick-Action auf der Startseite, Bestenliste-Tab.
- **Architektur:** Serverautoritativ wie `merge-game` – verdecktes Layout liegt
  server-seitig, Client schickt nur den Flip-Index, Antwort enthaelt nie das verdeckte
  Layout.

## 1. Datenbank – Migration `20260515_memory_game.sql`

### `memory_level_configs` (admin-editierbar, Muster: `boss_path_stage_configs`)

| Spalte | Typ | Bemerkung |
|---|---|---|
| `level` | int pk, check > 0 | |
| `pairs` | int | Paaranzahl → Brettgroesse |
| `move_limit` | int | max. Aufdeck-Versuche (zwei Karten = 1 Versuch) |
| `chest_qty` | int | Anzahl Tiere in der Level-Truhe |
| `reward_species` | text null | nur Level 5/10/15/20 gesetzt |
| `reward_tier` | text default 'normal' | |
| `reward_qty` | int default 0 | |
| `created_at`/`updated_at` | timestamptz | Touch-Trigger wie Boss-Configs |

RLS: `select using (true)`, `admin write` via `public._admin_role() = 'admin'`.
Seed: 20 Level, `pairs` ~6 → ~18 steigend, `move_limit` eng skaliert (genug Spielraum
auf niedrigen Leveln, knapp auf hohen), `chest_qty` steigend, `reward_species` auf
Level 5/10/15/20 (z. B. zunehmend wertvolle Arten/Stufen).

### `memory_player_states` (serverautoritativ, RLS self-read)

| Spalte | Typ | Bemerkung |
|---|---|---|
| `user_id` | uuid pk → profiles | |
| `level` | int default 1 | aktuelles Level |
| `highest_level` | int default 0 | |
| `total_pairs` | bigint default 0 | kumuliert, fuer Bestenliste |
| `total_levels_cleared` | int default 0 | |
| `version` | uuid default gen_random_uuid() | Optimistic Locking |
| `board` | jsonb | verdecktes Layout `[{species,matched}]`, NIE an Client |
| `revealed` | int[] default '{}' | aktuell offene, noch nicht gematchte Indizes |
| `moves_used` | int default 0 | im aktuellen Level |
| `level_started_at` | timestamptz | |
| `created_at`/`updated_at` | timestamptz | |

Index auf `(highest_level desc, total_pairs desc)`.

### `memory_level_rewards` (offene Belohnungen, Muster: `boss_path_rewards`)

`id bigint pk`, `user_id uuid`, `level int`, `kind text` ('chest' | 'animal'),
`payload jsonb`, `created_at`, `consumed_at timestamptz null`.

### `event_schedule`

Insert Key `memory_game` analog `merge_game` (`starts_at` null, `ends_at` Default,
`enabled` true), `on conflict do nothing`.

### RPCs (security invoker/definer wie merge; Ausfuehrung nur `service_role` bzw.
`authenticated` analog Bestand)

- `get_memory_state()` – Spielerstand **ohne** verdecktes Layout: gematchte Karten
  (Index+Species), aktuell aufgedeckte Karten, `level`, `moves_used`, `move_limit`,
  `pairs`, `highest_level`, Level-Config-Liste, `server_now`. Legt Spielerzeile +
  Startbrett an, falls fehlend.
- `memory_flip(p_index int)` – validiert Event aktiv (`event_is_active('memory_game')`)
  und `version`; prueft Index gueltig/verdeckt/nicht gematcht. Logik:
  - Erste Karte des Versuchs: Index zu `revealed` hinzufuegen, Antwort = aufgedeckte
    Karte.
  - Zweite Karte: `moves_used + 1`. Match → beide `matched=true`, `total_pairs + 1`;
    kein Match → beide bleiben aufgedeckt in der Antwort, werden aber serverseitig
    wieder verdeckt (naechster Flip raeumt `revealed`). Antwort enthaelt Match-Flag.
  - Alle Paare gematcht → `cleared=true` in Antwort.
  - `moves_used >= move_limit` und nicht alle Paare → `failed=true`; Server mischt
    dasselbe Level neu (neues `board`, `moves_used=0`, `revealed='{}'`), **kein**
    `level++`.
  - `version` wird bei jeder Mutation neu gesetzt.
- `memory_complete_level()` – nur wenn aktuelles Brett vollstaendig gematcht: legt
  `memory_level_rewards`-Zeile(n) an (Truhe immer; `animal` falls `reward_species`
  gesetzt), `level + 1`, `highest_level = greatest(...)`,
  `total_levels_cleared + 1`, mischt naechstes Level-Brett. Gibt Reward-IDs zurueck.
- `memory_open_chest(p_reward_id bigint)` – gewichteter Zufall aus `species_costs`
  (`enabled and weight > 0`), Logik kopiert aus `open_boss_chest`; setzt
  `consumed_at`. `kind='animal'`-Rewards werden analog (garantierte Art/Stufe)
  eingeloest.
- `memory_reset_level()` – aktuelles Level neu mischen, `moves_used=0`, `revealed='{}'`,
  Event-aktiv-Check.
- `get_memory_leaderboard(p_limit int default 50)` – join `profiles`, sortiert
  `highest_level desc, total_pairs desc`, ohne gebannte Nutzer, `limit 1..100`.

Grants/Revokes und RLS-Policies strikt nach Vorbild der Merge-/Boss-Migrationen.

## 2. Edge Function `supabase/functions/memory-game/index.ts`

Spiegel von `merge-game/index.ts`: CORS-Header, `need()`, `json()`, Service-Role-Client.
Actions im Body:

- `status` → `get_memory_state`
- `flip` (payload `{ index }`) → `memory_flip`
- `complete` → `memory_complete_level`
- `open_chest` (payload `{ reward_id }`) → `memory_open_chest`
- `reset` → `memory_reset_level`

Das verdeckte Layout wird ausschliesslich serverseitig in der RPC erzeugt
(Fisher-Yates ueber zufaellige Spezies-Auswahl aus `species_costs`) und nie
zurueckgegeben. Event-Aktivitaet wird in den RPCs geprueft.

## 3. Frontend `src/views/MemoryGameView.vue`

Aufbau analog `MergeGameView.vue`:

- `I18N` mit `de`/`en`/`ru`, echte Umlaute (ä ö ü ß), `tx(key, vars)`-Helper.
- Edge-Function-Wrapper `callMemory(action, payload)`.
- Lade-/Fehler-/Event-Banner mit Countdown (`formatCountdown`), Retry.
- Statuszeile: Level, Zuege `moves_used / move_limit`, hoechstes Level.
- Karten-Grid: CSS `grid`, Spaltenzahl aus `pairs` abgeleitet; Karte mit
  3D-Flip-Animation (CSS `transform: rotateY`), Rueckseite generisch, Vorderseite
  Tier-Emoji. Gematchte Karten visuell markiert/deaktiviert.
- Aktionen: Karte klicken → `flip`; „Brett neu" → `reset` (mit Bestaetigungsdialog
  wie Merge-Reset); bei `cleared` automatisch `complete` + Truhen-/Tier-Reveal-Modal
  (Shake → Open → Reveal, Muster aus `MergeGameView` `milestoneChestReveal`); bei
  `failed` kurze Flash-Meldung „Zuglimit erreicht", Brett neu.
- PrimeVue `Button` global, scoped CSS im bestehenden Stil (CSS-Variablen `--accent`
  etc.), Mobile-Breakpoint analog Merge.
- Keine Realtime-Subscription (kein globaler Zaehler).

## 4. Integration

- **Route** `src/router.js`: `{ path: '/memory', name: 'memory',
  component: () => import('./views/MemoryGameView.vue'), meta: { auth: true } }`.
- **Game-Store** `src/stores/game.js`: Getter `memoryEndsAt`, `memoryActive`,
  `memoryShowCountdown` analog `mergeEndsAt`/`mergeActive`/`mergeShowCountdown`
  (lesen aus `eventSchedule.memory_game`).
- **Startseite** `src/views/GameView.vue`: i18n-Block `memoryLink` (de/en/ru),
  Quick-Action-Button (`/memory`), Link-Karte `memory-link` mit Countdown +
  Event-Ended-Sperre analog `merge-link`.
- **Bestenliste** `src/views/LeaderboardView.vue`: neuer Tab `memory` (Icon 🧠),
  `mode === 'memory'` → `supabase.rpc('get_memory_leaderboard', { p_limit: 50 })`,
  Zeilen-Anzeige „Level X" + „N Paare"; i18n-Strings (`byMemory`, `subtitleMemory`,
  `memoryLevel`, `memoryPairs`), Event-Countdown via Store-Getter.

## 5. Fehlerbehandlung

- Optimistic Locking ueber `version`; bei `state conflict` Frontend re-loaded
  (`callMemory('status')`) und zeigt Toast.
- Ungueltiger/bereits gematchter Index, Event beendet, kein vollstaendiges Brett bei
  `complete`, Truhe doppelt oeffnen → Exceptions in RPCs, Frontend zeigt
  `appToast.err`.
- Event abgelaufen: RPCs werfen `event ended`; Frontend zeigt Event-Ended-Banner und
  sperrt Aktionen (wie Merge).

## 6. Tests (manuell, Browser-Preview)

- Level spielen: Match, Fehlversuch (zwei verschiedene), Brett komplett → Truhe + bei
  Level 5/10/15/20 Tier-Reveal.
- Zuglimit erreicht ohne Loesung → `failed`, gleiches Level neu, kein Fortschritt.
- „Brett neu" mischt neu, kein Fortschritt.
- Event-Ende sperrt Aktionen, Banner sichtbar.
- Bestenliste-Tab zeigt hoechstes Level + Paare, eigener Eintrag markiert.
- i18n de/en/ru vollstaendig, Umlaute korrekt.
- Mobile-Layout (schmale Breite) bleibt nutzbar.
- **Anti-Cheat:** Netzwerk-Antworten (`status`, `flip`) enthalten kein verdecktes
  Layout – nur gematchte + aktuell aufgedeckte Karten.

## Nicht im Scope (YAGNI)

- Kein globaler weltweiter Zaehler / Global-Bonus (anders als Merge).
- Keine Muenzen/Tickets/Boost-Belohnungen.
- Keine Endlos-Level (fest 20).
- Keine Realtime-Subscription.
