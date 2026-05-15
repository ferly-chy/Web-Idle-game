# Memory-Minispiel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ein zeitlich begrenztes, serverautoritatives Memory-Minispiel (20 Level, Truhen + Tier-Belohnungen) analog zu Merge-Safari/Boss-Kampf, integriert in Startseite und Bestenliste.

**Architecture:** Serverautoritativ wie `merge-game`: verdecktes Karten-Layout liegt in `memory_player_states.board` (Postgres), wird nie an den Client gesendet. Der Client schickt nur Flip-Indizes an die Edge Function `memory-game`, die die SQL-RPCs aufruft. Belohnungen laufen ueber eine `memory_level_rewards`-Warteschlange wie beim Boss-Pfad.

**Tech Stack:** Supabase Postgres (Migration + plpgsql RPCs), Supabase Edge Function (Deno/TypeScript), Vue 3 + Pinia + PrimeVue 4, vue-router (hash). Supabase-Projekt-ID: `rkskpvbismdlsevaqoer`.

**Test-Konvention dieses Projekts:** Es gibt kein JS-Unit-Framework. DB-Logik wird via `execute_sql` gegen das Supabase-Projekt verifiziert, Frontend via Browser-Preview manuell. Jeder DB-Task enthaelt eine SQL-Verifikation als „Test".

---

## File Structure

| Datei | Verantwortung | Aktion |
|---|---|---|
| `supabase/migrations/20260515_memory_game.sql` | Alle Tabellen, Level-Config-Seed, RLS/Grants, RPCs, `event_schedule`-Key | Create |
| `supabase/functions/memory-game/index.ts` | Edge Function: Actions `status/flip/complete/open_chest/reset` → RPCs | Create |
| `src/views/MemoryGameView.vue` | Spiel-UI: Karten-Grid, Flip-Animation, Truhen-/Tier-Reveal, i18n de/en/ru | Create |
| `src/router.js` | Route `/memory` | Modify |
| `src/stores/game.js` | Getter `memoryEndsAt/memoryActive/memoryShowCountdown` | Modify |
| `src/views/GameView.vue` | Startseiten-Link-Karte + Quick-Action + i18n | Modify |
| `src/views/LeaderboardView.vue` | Bestenliste-Tab `memory` + i18n | Modify |

Die gesamte DB-Logik liegt in **einer** Migrationsdatei (Projektkonvention). Tasks 1–7 bauen diese Datei inkrementell auf; jeder Task fuegt seinen Block an und verifiziert ihn isoliert per `execute_sql`. Task 8 wendet die fertige Migration final via `apply_migration` an.

---

## Task 1: Migration-Geruest – Tabellen + Event-Key

**Files:**
- Create: `supabase/migrations/20260515_memory_game.sql`

- [ ] **Step 1: Migrationsdatei mit Tabellen und Event-Key anlegen**

Datei `supabase/migrations/20260515_memory_game.sql` mit folgendem Inhalt erstellen:

```sql
-- Memory-Minispiel: serverautoritatives Level-Spiel mit Tier-Emojis aus species_costs.
-- Verdecktes Layout liegt in memory_player_states.board und wird nie an den Client gesendet.

create table if not exists public.memory_level_configs (
  level int primary key check (level > 0),
  pairs int not null check (pairs >= 2),
  move_limit int not null check (move_limit > 0),
  chest_qty int not null default 1 check (chest_qty > 0),
  reward_species text references public.species_costs(species) on update cascade on delete set null,
  reward_tier text not null default 'normal',
  reward_qty int not null default 0 check (reward_qty >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.memory_level_configs is
  'Konfiguration der Memory-Level: Paaranzahl, Zuglimit, Truhen- und Tier-Belohnung.';

create table if not exists public.memory_player_states (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  level int not null default 1 check (level > 0),
  highest_level int not null default 0 check (highest_level >= 0),
  total_pairs bigint not null default 0 check (total_pairs >= 0),
  total_levels_cleared int not null default 0 check (total_levels_cleared >= 0),
  version uuid not null default gen_random_uuid(),
  board jsonb not null default '[]'::jsonb,
  revealed int[] not null default '{}',
  moves_used int not null default 0 check (moves_used >= 0),
  level_started_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.memory_player_states is
  'Serverautoritativer Spielstand des Memory-Minispiels. board ist privat.';

create index if not exists memory_player_states_lb_idx
  on public.memory_player_states(highest_level desc, total_pairs desc);

create table if not exists public.memory_level_rewards (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  level int not null,
  kind text not null check (kind in ('chest','animal')),
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  consumed_at timestamptz
);

comment on table public.memory_level_rewards is
  'Offene Memory-Belohnungen (Truhen/Tiere) pro Spieler, Muster wie boss_path_rewards.';

create index if not exists memory_level_rewards_open_idx
  on public.memory_level_rewards(user_id) where consumed_at is null;

insert into public.event_schedule (key, starts_at, ends_at, enabled)
values ('memory_game', null, '2026-06-30 23:59:59+00', true)
on conflict (key) do nothing;
```

- [ ] **Step 2: Block isoliert anwenden und verifizieren**

Den SQL-Inhalt aus Step 1 via `execute_sql` (Projekt `rkskpvbismdlsevaqoer`) ausfuehren, dann verifizieren:

```sql
select count(*) as tables from information_schema.tables
 where table_schema='public'
   and table_name in ('memory_level_configs','memory_player_states','memory_level_rewards');
select key from public.event_schedule where key='memory_game';
```

Expected: `tables = 3`, eine Zeile mit `key = memory_game`.

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/20260515_memory_game.sql
git commit -m "feat(memory): DB-Geruest Tabellen + Event-Key"
```

---

## Task 2: RLS, Grants und Level-Config-Seed

**Files:**
- Modify: `supabase/migrations/20260515_memory_game.sql` (anhaengen)

- [ ] **Step 1: RLS/Grants und Seed an die Migration anhaengen**

Folgendes ans Ende von `supabase/migrations/20260515_memory_game.sql` anhaengen:

```sql
alter table public.memory_level_configs enable row level security;
alter table public.memory_player_states enable row level security;
alter table public.memory_level_rewards enable row level security;

drop policy if exists "memory_level_configs read" on public.memory_level_configs;
create policy "memory_level_configs read" on public.memory_level_configs
  for select using (true);

drop policy if exists "memory_level_configs admin write" on public.memory_level_configs;
create policy "memory_level_configs admin write" on public.memory_level_configs
  for all using (public._admin_role() = 'admin')
  with check (public._admin_role() = 'admin');

drop policy if exists "memory_player_states self read" on public.memory_player_states;
create policy "memory_player_states self read" on public.memory_player_states
  for select using ((select auth.uid()) = user_id);

drop policy if exists "memory_level_rewards self read" on public.memory_level_rewards;
create policy "memory_level_rewards self read" on public.memory_level_rewards
  for select using ((select auth.uid()) = user_id);

revoke all on table public.memory_level_configs from anon;
revoke all on table public.memory_player_states from anon;
revoke all on table public.memory_level_rewards from anon;

grant select on table public.memory_level_configs to authenticated;
grant select on table public.memory_player_states to authenticated;
grant select on table public.memory_level_rewards to authenticated;

grant select, insert, update, delete on table public.memory_level_configs to service_role;
grant select, insert, update, delete on table public.memory_player_states to service_role;
grant select, insert, update, delete on table public.memory_level_rewards to service_role;

create or replace function public.touch_memory_level_configs_updated_at()
returns trigger language plpgsql set search_path = public as $$
begin
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists memory_level_configs_touch on public.memory_level_configs;
create trigger memory_level_configs_touch
  before update on public.memory_level_configs
  for each row execute function public.touch_memory_level_configs_updated_at();

insert into public.memory_level_configs
  (level, pairs, move_limit, chest_qty, reward_species, reward_tier, reward_qty)
values
  (1,  6,  10, 1, null,      'normal', 0),
  (2,  6,  9,  1, null,      'normal', 0),
  (3,  7,  11, 1, null,      'normal', 0),
  (4,  7,  10, 1, null,      'normal', 0),
  (5,  8,  12, 2, 'rabbit',  'normal', 1),
  (6,  8,  11, 2, null,      'normal', 0),
  (7,  9,  13, 2, null,      'normal', 0),
  (8,  9,  12, 2, null,      'normal', 0),
  (9,  10, 14, 2, null,      'normal', 0),
  (10, 10, 13, 3, 'panda',   'gold',   1),
  (11, 11, 15, 3, null,      'normal', 0),
  (12, 11, 14, 3, null,      'normal', 0),
  (13, 12, 16, 3, null,      'normal', 0),
  (14, 12, 15, 3, null,      'normal', 0),
  (15, 13, 17, 4, 'tiger',   'gold',   1),
  (16, 13, 16, 4, null,      'normal', 0),
  (17, 14, 18, 4, null,      'normal', 0),
  (18, 14, 17, 4, null,      'normal', 0),
  (19, 15, 19, 5, null,      'normal', 0),
  (20, 15, 18, 5, 'dragon',  'gold',   1)
on conflict (level) do update
  set pairs = excluded.pairs,
      move_limit = excluded.move_limit,
      chest_qty = excluded.chest_qty,
      reward_species = excluded.reward_species,
      reward_tier = excluded.reward_tier,
      reward_qty = excluded.reward_qty;
```

- [ ] **Step 2: Block anwenden und verifizieren**

Den SQL-Block aus Step 1 via `execute_sql` ausfuehren, dann:

```sql
select count(*) as levels, min(level) as lo, max(level) as hi from public.memory_level_configs;
select level, pairs, move_limit, chest_qty, reward_species from public.memory_level_configs
 where reward_qty > 0 order by level;
```

Expected: `levels = 20, lo = 1, hi = 20`; vier Zeilen mit `reward_species` (Level 5/10/15/20).

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/20260515_memory_game.sql
git commit -m "feat(memory): RLS, Grants und 20-Level-Seed"
```

---

## Task 3: RPC `memory_build_board` + `get_memory_state`

**Files:**
- Modify: `supabase/migrations/20260515_memory_game.sql` (anhaengen)

- [ ] **Step 1: Board-Builder und State-RPC anhaengen**

Folgendes ans Ende der Migration anhaengen:

```sql
-- Erzeugt ein verdecktes Layout fuer p_pairs Paare aus zufaelligen,
-- gewichteten Arten. board = jsonb-Array [{species, matched}], gemischt.
create or replace function public.memory_build_board(p_pairs int)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_species text[];
  v_board jsonb := '[]'::jsonb;
  v_s text;
begin
  if p_pairs < 2 then raise exception 'invalid pairs'; end if;

  select array_agg(species) into v_species
  from (
    select species from public.species_costs
     where enabled and weight > 0
     order by random()
     limit p_pairs
  ) s;

  if v_species is null or array_length(v_species, 1) < p_pairs then
    -- Fallback: Arten duerfen sich wiederholen, wenn zu wenige verfuegbar.
    select array_agg(species) into v_species
    from (
      select species from public.species_costs
       where enabled
       order by random()
       limit p_pairs
    ) s2;
  end if;
  if v_species is null or array_length(v_species, 1) < 1 then
    raise exception 'no species available';
  end if;

  for i in 1..p_pairs loop
    v_s := v_species[1 + ((i - 1) % array_length(v_species, 1))];
    v_board := v_board
      || jsonb_build_object('species', v_s, 'matched', false)
      || jsonb_build_object('species', v_s, 'matched', false);
  end loop;

  -- Fisher-Yates ueber jsonb-Array.
  return (
    select coalesce(jsonb_agg(elem order by random()), '[]'::jsonb)
    from jsonb_array_elements(v_board) elem
  );
end $$;

revoke all on function public.memory_build_board(int) from public, anon, authenticated;
grant execute on function public.memory_build_board(int) to service_role;

-- Liefert den Spielstand OHNE verdecktes Layout: nur gematchte + aktuell
-- aufgedeckte Karten (mit Species/Emoji), Level-Configs und server_now.
create or replace function public.get_memory_state(p_user_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_st public.memory_player_states%rowtype;
  v_cfg public.memory_level_configs%rowtype;
  v_cards jsonb := '[]'::jsonb;
  v_configs jsonb;
  v_idx int;
  v_cell jsonb;
  v_species text;
  v_meta record;
begin
  if p_user_id is null then raise exception 'missing user'; end if;

  select * into v_st from public.memory_player_states where user_id = p_user_id;
  if not found then
    select * into v_cfg from public.memory_level_configs where level = 1;
    if not found then raise exception 'no level config'; end if;
    insert into public.memory_player_states(user_id, level, board, level_started_at)
    values (p_user_id, 1, public.memory_build_board(v_cfg.pairs), now())
    returning * into v_st;
  end if;

  select * into v_cfg from public.memory_level_configs where level = v_st.level;
  if not found then
    select * into v_cfg from public.memory_level_configs
     order by level desc limit 1;
  end if;

  -- Sichtbare Karten = matched ODER Index in revealed.
  for v_idx in 0 .. (jsonb_array_length(v_st.board) - 1) loop
    v_cell := v_st.board -> v_idx;
    if (v_cell->>'matched')::boolean = true
       or v_idx = any(v_st.revealed) then
      v_species := v_cell->>'species';
      select name, emoji into v_meta
        from public.species_costs where species = v_species;
      v_cards := v_cards || jsonb_build_object(
        'index', v_idx,
        'species', v_species,
        'name', coalesce(v_meta.name, v_species),
        'emoji', coalesce(v_meta.emoji, '🐾'),
        'matched', (v_cell->>'matched')::boolean
      );
    end if;
  end loop;

  select coalesce(jsonb_agg(jsonb_build_object(
    'level', level, 'pairs', pairs, 'move_limit', move_limit,
    'chest_qty', chest_qty, 'reward_species', reward_species,
    'reward_tier', reward_tier, 'reward_qty', reward_qty
  ) order by level), '[]'::jsonb) into v_configs
  from public.memory_level_configs;

  return jsonb_build_object(
    'level', v_st.level,
    'highest_level', v_st.highest_level,
    'total_pairs', v_st.total_pairs,
    'total_levels_cleared', v_st.total_levels_cleared,
    'version', v_st.version,
    'moves_used', v_st.moves_used,
    'pairs', v_cfg.pairs,
    'move_limit', v_cfg.move_limit,
    'card_count', jsonb_array_length(v_st.board),
    'visible_cards', v_cards,
    'configs', v_configs,
    'event_active', public.event_is_active('memory_game'),
    'server_now', now()
  );
end $$;

revoke all on function public.get_memory_state(uuid) from public, anon, authenticated;
grant execute on function public.get_memory_state(uuid) to service_role;
```

- [ ] **Step 2: Anwenden und verifizieren (Anti-Cheat-Check)**

SQL aus Step 1 via `execute_sql` ausfuehren. Dann mit einem realen Profil testen:

```sql
-- Ersten existierenden Profil-User holen und State erzeugen:
select public.get_memory_state((select id from public.profiles limit 1));
```

Expected: JSON mit `level=1`, `card_count=12` (Level 1 = 6 Paare), `visible_cards=[]` (nichts aufgedeckt), `configs` enthaelt 20 Eintraege. **Wichtig:** Antwort enthaelt KEIN Feld mit dem vollstaendigen `board`/verdeckten Layout.

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/20260515_memory_game.sql
git commit -m "feat(memory): board-builder + get_memory_state RPC"
```

---

## Task 4: RPC `memory_flip`

**Files:**
- Modify: `supabase/migrations/20260515_memory_game.sql` (anhaengen)

- [ ] **Step 1: Flip-RPC anhaengen**

Folgendes ans Ende der Migration anhaengen:

```sql
-- Deckt Karte p_index auf. Erste Karte des Versuchs -> nur aufdecken.
-- Zweite Karte -> Versuch zaehlen, Match pruefen. Bei Zuglimit ohne
-- Loesung: gleiches Level neu mischen (kein Fortschritt).
create or replace function public.memory_flip(
  p_user_id uuid,
  p_seen_version uuid,
  p_index int
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_st public.memory_player_states%rowtype;
  v_cfg public.memory_level_configs%rowtype;
  v_board jsonb;
  v_a int;
  v_b int;
  v_sa text;
  v_sb text;
  v_matched boolean := false;
  v_cleared boolean := false;
  v_failed boolean := false;
  v_total_pairs int;
  v_matched_count int;
begin
  if p_user_id is null then raise exception 'missing user'; end if;
  if not public.event_is_active('memory_game') then
    raise exception 'event ended';
  end if;

  select * into v_st from public.memory_player_states
   where user_id = p_user_id and version = p_seen_version
   for update;
  if not found then raise exception 'state conflict'; end if;

  select * into v_cfg from public.memory_level_configs where level = v_st.level;
  if not found then raise exception 'no level config'; end if;

  v_board := v_st.board;
  if p_index < 0 or p_index >= jsonb_array_length(v_board) then
    raise exception 'invalid index';
  end if;
  if (v_board -> p_index ->> 'matched')::boolean = true then
    raise exception 'already matched';
  end if;
  if p_index = any(v_st.revealed) then
    raise exception 'already revealed';
  end if;
  if array_length(v_st.revealed, 1) >= 2 then
    -- Vorheriger Fehlversuch noch sichtbar -> erst raeumen.
    v_st.revealed := '{}';
  end if;

  if coalesce(array_length(v_st.revealed, 1), 0) = 0 then
    -- Erste Karte des Versuchs.
    update public.memory_player_states
       set revealed = array[p_index],
           version = gen_random_uuid(),
           updated_at = now()
     where user_id = p_user_id
     returning * into v_st;
  else
    -- Zweite Karte: Versuch werten.
    v_a := v_st.revealed[1];
    v_b := p_index;
    v_sa := v_board -> v_a ->> 'species';
    v_sb := v_board -> v_b ->> 'species';

    if v_sa = v_sb then
      v_matched := true;
      v_board := jsonb_set(v_board, array[v_a::text, 'matched'], 'true'::jsonb);
      v_board := jsonb_set(v_board, array[v_b::text, 'matched'], 'true'::jsonb);
    end if;

    select count(*) into v_matched_count
      from jsonb_array_elements(v_board) e
     where (e->>'matched')::boolean = true;
    v_total_pairs := jsonb_array_length(v_board) / 2;
    v_cleared := (v_matched_count = jsonb_array_length(v_board));

    if not v_cleared
       and (v_st.moves_used + 1) >= v_cfg.move_limit then
      v_failed := true;
    end if;

    if v_failed then
      -- Level fehlgeschlagen: gleiches Level neu mischen, kein Fortschritt.
      update public.memory_player_states
         set board = public.memory_build_board(v_cfg.pairs),
             revealed = '{}',
             moves_used = 0,
             level_started_at = now(),
             version = gen_random_uuid(),
             updated_at = now()
       where user_id = p_user_id
       returning * into v_st;
    else
      update public.memory_player_states
         set board = v_board,
             revealed = case when v_matched then '{}'::int[] else array[v_a, v_b] end,
             moves_used = v_st.moves_used + 1,
             total_pairs = total_pairs + case when v_matched then 1 else 0 end,
             version = gen_random_uuid(),
             updated_at = now()
       where user_id = p_user_id
       returning * into v_st;
    end if;
  end if;

  return jsonb_build_object(
    'turn', jsonb_build_object(
      'matched', v_matched,
      'cleared', v_cleared,
      'failed', v_failed,
      'flipped_index', p_index
    ),
    'state', public.get_memory_state(p_user_id)
  );
end $$;

revoke all on function public.memory_flip(uuid, uuid, int) from public, anon, authenticated;
grant execute on function public.memory_flip(uuid, uuid, int) to service_role;
```

- [ ] **Step 2: Anwenden und verifizieren**

SQL aus Step 1 via `execute_sql` ausfuehren. Funktionalen Smoke-Test:

```sql
do $$
declare
  uid uuid := (select id from public.profiles limit 1);
  st jsonb;
  v uuid;
  r jsonb;
begin
  -- State zuruecksetzen fuer reproduzierbaren Test.
  delete from public.memory_player_states where user_id = uid;
  st := public.get_memory_state(uid);
  v := (st->>'version')::uuid;
  r := public.memory_flip(uid, v, 0);
  raise notice 'flip1 turn: %', r->'turn';
  raise notice 'visible after flip1: %', jsonb_array_length(r->'state'->'visible_cards');
end $$;
```

Expected: `flip1 turn` zeigt `matched=false, cleared=false, failed=false`; `visible after flip1 = 1` (eine Karte aufgedeckt). Kein Fehler.

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/20260515_memory_game.sql
git commit -m "feat(memory): memory_flip RPC mit Zuglimit-Fail"
```

---

## Task 5: RPCs `memory_complete_level` + `memory_reset_level`

**Files:**
- Modify: `supabase/migrations/20260515_memory_game.sql` (anhaengen)

- [ ] **Step 1: Complete- und Reset-RPC anhaengen**

Folgendes ans Ende der Migration anhaengen:

```sql
-- Schliesst ein vollstaendig geloestes Level ab: Truhen-Reward (immer) +
-- Tier-Reward (falls reward_species gesetzt) in memory_level_rewards,
-- level + 1, naechstes Brett mischen.
create or replace function public.memory_complete_level(p_user_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_st public.memory_player_states%rowtype;
  v_cfg public.memory_level_configs%rowtype;
  v_next_cfg public.memory_level_configs%rowtype;
  v_matched_count int;
  v_chest_id bigint;
  v_animal_id bigint;
  v_next_level int;
  v_max_level int;
begin
  if p_user_id is null then raise exception 'missing user'; end if;
  if not public.event_is_active('memory_game') then
    raise exception 'event ended';
  end if;

  select * into v_st from public.memory_player_states
   where user_id = p_user_id for update;
  if not found then raise exception 'no state'; end if;

  select * into v_cfg from public.memory_level_configs where level = v_st.level;
  if not found then raise exception 'no level config'; end if;

  select count(*) into v_matched_count
    from jsonb_array_elements(v_st.board) e
   where (e->>'matched')::boolean = true;
  if v_matched_count <> jsonb_array_length(v_st.board)
     or jsonb_array_length(v_st.board) = 0 then
    raise exception 'level not cleared';
  end if;

  insert into public.memory_level_rewards(user_id, level, kind, payload)
  values (p_user_id, v_st.level, 'chest',
          jsonb_build_object('chest_qty', v_cfg.chest_qty))
  returning id into v_chest_id;

  if v_cfg.reward_species is not null and v_cfg.reward_qty > 0 then
    insert into public.memory_level_rewards(user_id, level, kind, payload)
    values (p_user_id, v_st.level, 'animal',
            jsonb_build_object(
              'species', v_cfg.reward_species,
              'tier', v_cfg.reward_tier,
              'qty', v_cfg.reward_qty))
    returning id into v_animal_id;
  end if;

  select coalesce(max(level), 0) into v_max_level
    from public.memory_level_configs;
  v_next_level := least(v_st.level + 1, v_max_level);

  select * into v_next_cfg from public.memory_level_configs
   where level = v_next_level;

  update public.memory_player_states
     set level = v_next_level,
         highest_level = greatest(highest_level, v_st.level),
         total_levels_cleared = total_levels_cleared + 1,
         board = public.memory_build_board(v_next_cfg.pairs),
         revealed = '{}',
         moves_used = 0,
         level_started_at = now(),
         version = gen_random_uuid(),
         updated_at = now()
   where user_id = p_user_id
   returning * into v_st;

  return jsonb_build_object(
    'completed_level', v_cfg.level,
    'chest_reward_id', v_chest_id,
    'animal_reward_id', v_animal_id,
    'state', public.get_memory_state(p_user_id)
  );
end $$;

revoke all on function public.memory_complete_level(uuid) from public, anon, authenticated;
grant execute on function public.memory_complete_level(uuid) to service_role;

-- Aktuelles Level neu mischen (kein Fortschritt).
create or replace function public.memory_reset_level(p_user_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_st public.memory_player_states%rowtype;
  v_cfg public.memory_level_configs%rowtype;
begin
  if p_user_id is null then raise exception 'missing user'; end if;
  if not public.event_is_active('memory_game') then
    raise exception 'event ended';
  end if;

  select * into v_st from public.memory_player_states
   where user_id = p_user_id for update;
  if not found then raise exception 'no state'; end if;

  select * into v_cfg from public.memory_level_configs where level = v_st.level;
  if not found then raise exception 'no level config'; end if;

  update public.memory_player_states
     set board = public.memory_build_board(v_cfg.pairs),
         revealed = '{}',
         moves_used = 0,
         level_started_at = now(),
         version = gen_random_uuid(),
         updated_at = now()
   where user_id = p_user_id;

  return jsonb_build_object('state', public.get_memory_state(p_user_id));
end $$;

revoke all on function public.memory_reset_level(uuid) from public, anon, authenticated;
grant execute on function public.memory_reset_level(uuid) to service_role;
```

- [ ] **Step 2: Anwenden und verifizieren**

SQL aus Step 1 via `execute_sql` ausfuehren. Test (Level kuenstlich loesen):

```sql
do $$
declare
  uid uuid := (select id from public.profiles limit 1);
  st jsonb;
  bsize int;
  newboard jsonb := '[]'::jsonb;
  i int;
begin
  delete from public.memory_player_states where user_id = uid;
  st := public.get_memory_state(uid);
  bsize := (st->>'card_count')::int;
  -- Brett kuenstlich komplett auf matched setzen.
  for i in 1..bsize loop
    newboard := newboard || jsonb_build_object('species','rabbit','matched',true);
  end loop;
  update public.memory_player_states set board = newboard where user_id = uid;
  st := public.memory_complete_level(uid);
  raise notice 'completed: %, new level: %', st->'completed_level', st->'state'->'level';
  raise notice 'open rewards: %', (select count(*) from public.memory_level_rewards
                                    where user_id = uid and consumed_at is null);
end $$;
```

Expected: `completed = 1`, `new level = 2`, `open rewards >= 1` (Level 1 nur Truhe).

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/20260515_memory_game.sql
git commit -m "feat(memory): complete_level + reset_level RPCs"
```

---

## Task 6: RPC `memory_open_chest` + Leaderboard

**Files:**
- Modify: `supabase/migrations/20260515_memory_game.sql` (anhaengen)

- [ ] **Step 1: Chest-Oeffnen und Leaderboard anhaengen**

Folgendes ans Ende der Migration anhaengen:

```sql
-- Loest einen offenen Reward ein: 'chest' -> gewichteter Zufall aus
-- species_costs (wie open_boss_chest), 'animal' -> garantierte Art/Stufe.
create or replace function public.memory_open_chest(
  p_user_id uuid,
  p_reward_id bigint
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_rew record;
  v_qty int;
  v_w_total int;
  v_r int;
  v_acc int;
  v_rec record;
  v_picked text;
  v_ids uuid[] := '{}';
  v_species text[] := '{}';
  v_tier text;
  v_new public.animals%rowtype;
  i int;
begin
  if p_user_id is null then raise exception 'missing user'; end if;

  select * into v_rew from public.memory_level_rewards
   where id = p_reward_id and user_id = p_user_id for update;
  if not found then raise exception 'reward not found'; end if;
  if v_rew.consumed_at is not null then raise exception 'already opened'; end if;

  if v_rew.kind = 'animal' then
    v_picked := v_rew.payload->>'species';
    v_tier := coalesce(nullif(v_rew.payload->>'tier',''), 'normal');
    v_qty := greatest(1, coalesce((v_rew.payload->>'qty')::int, 1));
    if not exists (select 1 from public.species_costs where species = v_picked) then
      raise exception 'unknown reward species';
    end if;
    for i in 1..least(v_qty, 50) loop
      insert into public.animals(owner_id, species, tier, equipped)
      values (p_user_id, v_picked, v_tier, false)
      returning * into v_new;
      v_ids := v_ids || v_new.id;
      v_species := v_species || v_picked;
    end loop;
  else
    v_qty := greatest(1, coalesce((v_rew.payload->>'chest_qty')::int, 1));
    select coalesce(sum(weight), 0) into v_w_total
      from public.species_costs where enabled and weight > 0;
    if v_w_total <= 0 then raise exception 'no species available'; end if;

    for i in 1..v_qty loop
      v_r := 1 + floor(random() * v_w_total)::int;
      v_acc := 0;
      v_picked := null;
      for v_rec in
        select species, weight from public.species_costs
         where enabled and weight > 0 order by species
      loop
        v_acc := v_acc + v_rec.weight;
        if v_r <= v_acc then v_picked := v_rec.species; exit; end if;
      end loop;
      if v_picked is null then
        select species into v_picked from public.species_costs
         where enabled and weight > 0 order by species limit 1;
      end if;
      insert into public.animals(owner_id, species, equipped)
      values (p_user_id, v_picked, false)
      returning * into v_new;
      v_ids := v_ids || v_new.id;
      v_species := v_species || v_picked;
    end loop;
  end if;

  update public.memory_level_rewards
     set consumed_at = now() where id = p_reward_id;

  return jsonb_build_object(
    'reward_id', p_reward_id,
    'kind', v_rew.kind,
    'qty', coalesce(array_length(v_ids, 1), 0),
    'species', to_jsonb(v_species),
    'animal_ids', to_jsonb(v_ids)
  );
end $$;

revoke all on function public.memory_open_chest(uuid, bigint) from public, anon, authenticated;
grant execute on function public.memory_open_chest(uuid, bigint) to service_role;

create or replace function public.get_memory_leaderboard(p_limit int default 50)
returns table (
  username text,
  avatar_emoji text,
  highest_level int,
  total_pairs bigint,
  total_levels_cleared int
) language sql security definer set search_path = public as $$
  select p.username, p.avatar_emoji,
         m.highest_level, m.total_pairs, m.total_levels_cleared
  from public.memory_player_states m
  join public.profiles p on p.id = m.user_id
  where coalesce(p.is_banned, false) = false
    and (m.highest_level > 0 or m.total_pairs > 0)
  order by m.highest_level desc, m.total_pairs desc
  limit greatest(1, least(p_limit, 100));
$$;

grant execute on function public.get_memory_leaderboard(int) to authenticated, anon;
```

- [ ] **Step 2: Anwenden und verifizieren**

SQL aus Step 1 via `execute_sql` ausfuehren. Test:

```sql
do $$
declare
  uid uuid := (select id from public.profiles limit 1);
  rid bigint;
  res jsonb;
begin
  select id into rid from public.memory_level_rewards
   where user_id = uid and consumed_at is null and kind='chest' limit 1;
  res := public.memory_open_chest(uid, rid);
  raise notice 'opened: %', res;
end $$;
select * from public.get_memory_leaderboard(10);
```

Expected: `opened` zeigt `kind=chest`, `qty>=1`, Species-Array gefuellt; Leaderboard liefert mind. den Testnutzer mit `highest_level >= 1`.

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/20260515_memory_game.sql
git commit -m "feat(memory): open_chest + get_memory_leaderboard"
```

---

## Task 7: Finale Migration anwenden + Testdaten bereinigen

**Files:**
- (keine; nur DB-Operation)

- [ ] **Step 1: Migration final via apply_migration registrieren**

Den vollstaendigen Inhalt von `supabase/migrations/20260515_memory_game.sql` via `apply_migration` (name `20260515_memory_game`, Projekt `rkskpvbismdlsevaqoer`) anwenden. Da alle Statements idempotent sind (`create table if not exists`, `create or replace function`, `on conflict`), ist die erneute Anwendung sicher.

- [ ] **Step 2: Testdaten bereinigen**

```sql
delete from public.memory_player_states
 where user_id = (select id from public.profiles limit 1);
delete from public.memory_level_rewards
 where user_id = (select id from public.profiles limit 1) and level <= 1;
select count(*) as configs from public.memory_level_configs;
```

Expected: `configs = 20`; keine Fehler. (Die in den Tasks 3–6 angelegten Testanimals/-rewards des Testnutzers werden hier entfernt, damit kein Leaderboard-Muell entsteht.)

- [ ] **Step 3: Migrationen-Liste pruefen**

Via `list_migrations` (Projekt `rkskpvbismdlsevaqoer`) bestaetigen, dass `20260515_memory_game` registriert ist.

Expected: Eintrag `20260515_memory_game` vorhanden.

---

## Task 8: Edge Function `memory-game`

**Files:**
- Create: `supabase/functions/memory-game/index.ts`

- [ ] **Step 1: Edge Function schreiben**

Datei `supabase/functions/memory-game/index.ts` erstellen:

```typescript
// Edge Function: memory-game
// Serverautoritatives Memory-Minispiel. Das verdeckte Layout bleibt in der DB.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
}

function need(key: string): string {
  const value = Deno.env.get(key)
  if (!value) throw new Error(`missing env ${key}`)
  return value
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }
  try {
    const authHeader = req.headers.get('Authorization') || ''
    const userClient = createClient(
      need('SUPABASE_URL'),
      need('SUPABASE_ANON_KEY'),
      { global: { headers: { Authorization: authHeader } } },
    )
    const { data: userData, error: userErr } = await userClient.auth.getUser()
    if (userErr || !userData?.user) return json({ error: 'not authenticated' }, 401)
    const userId = userData.user.id

    const admin = createClient(
      need('SUPABASE_URL'),
      need('SUPABASE_SERVICE_ROLE_KEY'),
    )

    const body = req.method === 'POST' ? await req.json().catch(() => ({})) : {}
    const action = String(body.action || 'status')

    let rpc: string
    let args: Record<string, unknown>

    if (action === 'status') {
      rpc = 'get_memory_state'
      args = { p_user_id: userId }
    } else if (action === 'flip') {
      const index = Number(body.index)
      const version = String(body.version || '')
      if (!Number.isInteger(index) || index < 0) {
        return json({ error: 'invalid index' }, 400)
      }
      rpc = 'memory_flip'
      args = { p_user_id: userId, p_seen_version: version, p_index: index }
    } else if (action === 'complete') {
      rpc = 'memory_complete_level'
      args = { p_user_id: userId }
    } else if (action === 'reset') {
      rpc = 'memory_reset_level'
      args = { p_user_id: userId }
    } else if (action === 'open_chest') {
      const rewardId = Number(body.reward_id)
      if (!Number.isInteger(rewardId)) {
        return json({ error: 'invalid reward_id' }, 400)
      }
      rpc = 'memory_open_chest'
      args = { p_user_id: userId, p_reward_id: rewardId }
    } else {
      return json({ error: 'unknown action' }, 400)
    }

    const { data, error } = await admin.rpc(rpc, args)
    if (error) return json({ error: error.message }, 400)
    return json(data)
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : 'internal error' }, 500)
  }
})
```

- [ ] **Step 2: Edge Function deployen und verifizieren**

Via `deploy_edge_function` (Projekt `rkskpvbismdlsevaqoer`, name `memory-game`, Entrypoint `supabase/functions/memory-game/index.ts`) deployen. Dann `list_edge_functions` pruefen.

Expected: `memory-game` ist in der Funktionsliste mit Status `ACTIVE`.

- [ ] **Step 3: Commit**

```bash
git add supabase/functions/memory-game/index.ts
git commit -m "feat(memory): edge function memory-game"
```

---

## Task 9: Game-Store-Getter + Route

**Files:**
- Modify: `src/stores/game.js` (Getter nach `mergeShowCountdown` einfuegen)
- Modify: `src/router.js` (Route nach `/merge` einfuegen)

- [ ] **Step 1: Getter in game.js ergaenzen**

In `src/stores/game.js` direkt nach dem `mergeShowCountdown(state) { ... }`-Getter (er endet mit `return !!(cfg && cfg.show_countdown !== false && cfg.ends_at)` gefolgt von `},`) folgenden Block einfuegen:

```javascript
    memoryEndsAt(state) {
      const cfg = state.eventSchedule?.memory_game
      if (!cfg || cfg.show_countdown === false) return 0
      return cfg.ends_at ? new Date(cfg.ends_at).getTime() : 0
    },
    memoryActive(state) {
      const cfg = state.eventSchedule?.memory_game
      if (!cfg) return true
      if (cfg.enabled === false) return false
      const ends = cfg.ends_at ? new Date(cfg.ends_at).getTime() : 0
      const starts = cfg.starts_at ? new Date(cfg.starts_at).getTime() : 0
      const now = Date.now()
      if (starts && starts > now) return false
      if (ends && ends <= now) return false
      return true
    },
    memoryShowCountdown(state) {
      const cfg = state.eventSchedule?.memory_game
      return !!(cfg && cfg.show_countdown !== false && cfg.ends_at)
    },
```

- [ ] **Step 2: Route in router.js ergaenzen**

In `src/router.js` nach der Zeile
`  { path: '/merge', name: 'merge', component: () => import('./views/MergeGameView.vue'), meta: { auth: true } },`
diese Zeile einfuegen:

```javascript
  { path: '/memory', name: 'memory', component: () => import('./views/MemoryGameView.vue'), meta: { auth: true } },
```

- [ ] **Step 3: Build-Check**

Run: `npm run build`
Expected: Build erfolgreich, kein Fehler (auch wenn `MemoryGameView.vue` noch fehlt, schlaegt der dynamische Import erst zur Laufzeit fehl — daher in Task 10 erstellen, bevor manuell getestet wird).

> Falls `npm run build` den fehlenden Import bemaengelt: diesen Step erst nach Task 10 abschliessen. Reihenfolge im Zweifel: Task 10 vor Step 3.

- [ ] **Step 4: Commit**

```bash
git add src/stores/game.js src/router.js
git commit -m "feat(memory): store-getter + route"
```

---

## Task 10: `MemoryGameView.vue`

**Files:**
- Create: `src/views/MemoryGameView.vue`

- [ ] **Step 1: View-Grundgeruest mit i18n und Datenfluss schreiben**

Datei `src/views/MemoryGameView.vue` erstellen:

```vue
<script setup>
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import { supabase } from '../supabase'
import { locale } from '../i18n'
import { useGameStore } from '../stores/game'
import { useAppToast } from '../composables/useAppToast'

const router = useRouter()
const game = useGameStore()
const appToast = useAppToast()

const I18N = {
  de: {
    title: '🧠 Memory', sub: 'Finde alle Tier-Paare, bevor die Zuege ausgehen.',
    back: 'Zurueck', level: 'Level', moves: 'Zuege', best: 'Hoechstes Level',
    reset: 'Brett neu', loading: 'Lade Memory...', retry: 'Erneut versuchen',
    eventEndsIn: 'Verschwindet in {time}', eventEnded: 'Ereignis beendet',
    eventEndedSub: 'Das Memory-Ereignis ist vorbei. Es koennen keine Zuege mehr gemacht werden.',
    matched: 'Paar gefunden!', failed: 'Zuglimit erreicht - Brett neu',
    levelDone: 'Level geschafft!', chestTitle: 'Belohnung!', chestSub: 'Du erhaeltst:',
    continue: 'Weiter', resetTitle: 'Brett zuruecksetzen?',
    resetSub: 'Der aktuelle Fortschritt in diesem Level geht verloren.',
    resetCancel: 'Abbrechen', resetYes: 'Ja, neu mischen',
    rewardChest: '🎁 Truhe ({qty})', rewardAnimal: '{qty}x {emoji} {name}'
  },
  en: {
    title: '🧠 Memory', sub: 'Find all animal pairs before you run out of moves.',
    back: 'Back', level: 'Level', moves: 'Moves', best: 'Highest level',
    reset: 'New board', loading: 'Loading Memory...', retry: 'Try again',
    eventEndsIn: 'Disappears in {time}', eventEnded: 'Event ended',
    eventEndedSub: 'The Memory event is over. No more moves can be made.',
    matched: 'Pair found!', failed: 'Move limit reached - new board',
    levelDone: 'Level cleared!', chestTitle: 'Reward!', chestSub: 'You receive:',
    continue: 'Continue', resetTitle: 'Reset board?',
    resetSub: 'Your current progress in this level will be lost.',
    resetCancel: 'Cancel', resetYes: 'Yes, reshuffle',
    rewardChest: '🎁 Chest ({qty})', rewardAnimal: '{qty}x {emoji} {name}'
  },
  ru: {
    title: '🧠 Memory', sub: 'Найди все пары животных, пока не кончились ходы.',
    back: 'Назад', level: 'Уровень', moves: 'Ходы', best: 'Лучший уровень',
    reset: 'Новое поле', loading: 'Загрузка Memory...', retry: 'Повторить',
    eventEndsIn: 'Исчезнет через {time}', eventEnded: 'Событие завершено',
    eventEndedSub: 'Событие Memory завершено. Ходы больше недоступны.',
    matched: 'Пара найдена!', failed: 'Лимит ходов - новое поле',
    levelDone: 'Уровень пройден!', chestTitle: 'Награда!', chestSub: 'Вы получаете:',
    continue: 'Дальше', resetTitle: 'Сбросить поле?',
    resetSub: 'Текущий прогресс на этом уровне будет потерян.',
    resetCancel: 'Отмена', resetYes: 'Да, заново',
    rewardChest: '🎁 Сундук ({qty})', rewardAnimal: '{qty}x {emoji} {name}'
  }
}

function tx(key, vars = {}) {
  const dict = I18N[locale.value] || I18N.en
  let value = dict[key]
  if (value == null) value = I18N.en[key]
  return String(value ?? key).replace(/\{(\w+)\}/g, (_, k) => String(vars[k] ?? ''))
}

const data = ref(null)
const loading = ref(true)
const busy = ref(false)
const error = ref('')
const flash = ref(null)
const now = ref(Date.now())
let clockTimer = null
const showResetConfirm = ref(false)
const chestReveal = ref(null)

const visibleCards = computed(() => data.value?.visible_cards || [])
const cardCount = computed(() => Number(data.value?.card_count || 0))
const columns = computed(() => {
  const n = cardCount.value
  if (n <= 0) return 4
  return Math.min(6, Math.ceil(Math.sqrt(n)))
})
const cardMap = computed(() => {
  const map = {}
  for (const c of visibleCards.value) map[c.index] = c
  return map
})

const eventActive = computed(() => {
  void now.value
  return data.value?.event_active !== false && game.memoryActive
})
const eventShowCountdown = computed(() => game.memoryShowCountdown)
const eventRemaining = computed(() => {
  void now.value
  if (!eventShowCountdown.value) return 0
  return Math.max(0, game.memoryEndsAt - Date.now())
})

function formatCountdown(ms) {
  const total = Math.max(0, Math.floor(ms / 1000))
  const days = Math.floor(total / 86400)
  const hours = Math.floor((total % 86400) / 3600)
  const minutes = Math.floor((total % 3600) / 60)
  const seconds = total % 60
  const loc = locale.value
  if (days > 0) {
    if (loc === 'de') return `${days} ${days === 1 ? 'Tag' : 'Tagen'} ${hours}h`
    if (loc === 'ru') return `${days} ${days === 1 ? 'день' : 'дн.'} ${hours}ч`
    return `${days}d ${hours}h`
  }
  if (hours > 0) return loc === 'ru' ? `${hours}ч ${minutes}м` : `${hours}h ${minutes}m`
  return `${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`
}

function showFlash(text, kind = 'ok') {
  const id = Date.now()
  flash.value = { text, kind, id }
  setTimeout(() => { if (flash.value?.id === id) flash.value = null }, 1600)
}

function wait(ms) { return new Promise((r) => setTimeout(r, ms)) }

async function callMemory(action, payload = {}) {
  const { data: result, error: fnErr } = await supabase.functions.invoke('memory-game', {
    body: { action, ...payload }
  })
  if (fnErr) throw fnErr
  if (result?.error) throw new Error(result.error)
  return result
}

async function loadGame() {
  loading.value = true
  error.value = ''
  try {
    data.value = await callMemory('status')
  } catch (e) {
    error.value = e?.message || 'Fehler'
  } finally {
    loading.value = false
  }
}

async function flip(index) {
  if (busy.value || loading.value || !eventActive.value) return
  if (cardMap.value[index]?.matched) return
  busy.value = true
  try {
    const res = await callMemory('flip', { index, version: data.value.version })
    data.value = res.state
    if (res.turn?.matched) showFlash(tx('matched'), 'ok')
    if (res.turn?.failed) showFlash(tx('failed'), 'warn')
    if (res.turn?.cleared) {
      showFlash(tx('levelDone'), 'ok')
      await wait(550)
      await completeLevel()
    }
  } catch (e) {
    appToast.err(e?.message || 'Fehler')
    await loadGame()
  } finally {
    busy.value = false
  }
}

async function completeLevel() {
  try {
    const res = await callMemory('complete')
    const rewardIds = [res.chest_reward_id, res.animal_reward_id].filter(Boolean)
    data.value = res.state
    const opened = []
    for (const rid of rewardIds) {
      const o = await callMemory('open_chest', { reward_id: rid })
      opened.push(o)
    }
    await game.load()
    chestReveal.value = { phase: 'shake', items: opened }
    await wait(650)
    chestReveal.value = { ...chestReveal.value, phase: 'open' }
    await wait(420)
    chestReveal.value = { ...chestReveal.value, phase: 'reveal' }
  } catch (e) {
    appToast.err(e?.message || 'Fehler')
    await loadGame()
  }
}

function closeChestReveal() { chestReveal.value = null }

function requestReset() {
  if (busy.value || !eventActive.value) return
  showResetConfirm.value = true
}

async function confirmReset() {
  showResetConfirm.value = false
  if (busy.value) return
  busy.value = true
  try {
    const res = await callMemory('reset')
    data.value = res.state
  } catch (e) {
    appToast.err(e?.message || 'Fehler')
  } finally {
    busy.value = false
  }
}

function rewardLabel(o) {
  const species = Array.isArray(o.species) ? o.species : []
  if (o.kind === 'animal' && species.length) {
    return tx('rewardAnimal', { qty: o.qty, emoji: '🐾', name: species[0] })
  }
  return tx('rewardChest', { qty: o.qty })
}

onMounted(() => {
  clockTimer = setInterval(() => { now.value = Date.now() }, 1000)
  if (!Object.keys(game.eventSchedule || {}).length) {
    game.loadEventSchedule?.().catch(() => {})
  }
  loadGame()
})
onUnmounted(() => { if (clockTimer) clearInterval(clockTimer) })
</script>

<template>
  <div class="memory-view">
    <header class="memory-header">
      <Button class="btn small btn-ghost" @click="router.push('/')">
        <i class="pi pi-arrow-left"></i><span>{{ tx('back') }}</span>
      </Button>
      <div class="memory-title-block">
        <h1 class="memory-title">{{ tx('title') }}</h1>
        <p class="memory-sub">{{ tx('sub') }}</p>
      </div>
    </header>

    <div v-if="loading" class="card memory-state">
      <i class="pi pi-spin pi-spinner"></i><span>{{ tx('loading') }}</span>
    </div>
    <div v-else-if="error" class="card memory-state error-state">
      <span>{{ error }}</span>
      <Button class="btn small" @click="loadGame">{{ tx('retry') }}</Button>
    </div>

    <template v-else>
      <section class="memory-stats">
        <div class="memory-stat">
          <strong>{{ data.level }}</strong><span>{{ tx('level') }}</span>
        </div>
        <div class="memory-stat">
          <strong>{{ data.moves_used }} / {{ data.move_limit }}</strong>
          <span>{{ tx('moves') }}</span>
        </div>
        <div class="memory-stat">
          <strong>{{ data.highest_level }}</strong><span>{{ tx('best') }}</span>
        </div>
      </section>

      <section
        v-if="eventShowCountdown && (eventRemaining > 0 || !eventActive)"
        class="card event-banner" :class="{ ended: !eventActive }"
      >
        <span class="event-banner-icon">{{ eventActive ? '⏳' : '⏰' }}</span>
        <div class="event-banner-body">
          <div class="event-banner-title">
            <template v-if="eventActive">{{ tx('eventEndsIn', { time: formatCountdown(eventRemaining) }) }}</template>
            <template v-else>{{ tx('eventEnded') }}</template>
          </div>
          <div v-if="!eventActive" class="event-banner-sub">{{ tx('eventEndedSub') }}</div>
        </div>
      </section>

      <section class="memory-board-wrap">
        <div
          class="memory-board"
          :class="{ busy }"
          :style="{ gridTemplateColumns: 'repeat(' + columns + ', minmax(0, 1fr))' }"
        >
          <button
            v-for="i in cardCount"
            :key="i - 1"
            class="memory-card"
            :class="{
              flipped: !!cardMap[i - 1],
              matched: cardMap[i - 1]?.matched
            }"
            :disabled="busy || !eventActive || !!cardMap[i - 1]"
            @click="flip(i - 1)"
          >
            <span class="card-inner">
              <span class="card-face card-back">❓</span>
              <span class="card-face card-front">{{ cardMap[i - 1]?.emoji || '' }}</span>
            </span>
          </button>
        </div>
        <Transition name="memory-flash">
          <div v-if="flash" class="memory-flash" :class="flash.kind">{{ flash.text }}</div>
        </Transition>
      </section>

      <section class="memory-controls">
        <Button class="ctrl reset" :disabled="busy || !eventActive" @click="requestReset">
          <i class="pi pi-refresh"></i><span>{{ tx('reset') }}</span>
        </Button>
      </section>

      <div
        v-if="chestReveal"
        class="chest-modal"
        @click.self="chestReveal.phase === 'reveal' && closeChestReveal()"
      >
        <div v-if="chestReveal.phase !== 'reveal'" class="chest-stage">
          <div
            class="chest-box"
            :class="{ shake: chestReveal.phase === 'shake', opening: chestReveal.phase === 'open' }"
          >🎁</div>
        </div>
        <div v-if="chestReveal.phase === 'reveal'" class="chest-reveal">
          <h3>{{ tx('chestTitle') }}</h3>
          <p>{{ tx('chestSub') }}</p>
          <div class="chest-items">
            <div
              v-for="(o, i) in chestReveal.items"
              :key="i"
              class="chest-item"
              :style="{ animationDelay: (i * 0.12) + 's' }"
            ><b>{{ rewardLabel(o) }}</b></div>
          </div>
          <Button class="btn" @click="closeChestReveal">{{ tx('continue') }}</Button>
        </div>
      </div>

      <div v-if="showResetConfirm" class="confirm-backdrop" @click.self="showResetConfirm = false">
        <div class="confirm-dialog card">
          <div class="confirm-emoji">🔄</div>
          <h3 style="margin:0 0 6px">{{ tx('resetTitle') }}</h3>
          <p class="confirm-sub">{{ tx('resetSub') }}</p>
          <div class="confirm-actions">
            <Button class="btn confirm-cancel" @click="showResetConfirm = false">{{ tx('resetCancel') }}</Button>
            <Button class="btn confirm-yes" @click="confirmReset">{{ tx('resetYes') }}</Button>
          </div>
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
.memory-view { display:flex; flex-direction:column; gap:12px; padding-bottom:18px; }
.memory-header { display:flex; align-items:center; gap:10px; }
.btn-ghost { background:rgba(255,255,255,0.06); color:var(--muted);
  display:inline-flex; align-items:center; gap:5px; flex-shrink:0; }
.memory-title { margin:0; font-size:22px; font-weight:900; }
.memory-sub { margin:2px 0 0; color:var(--muted); font-size:13px; }
.memory-state { display:flex; align-items:center; justify-content:center; gap:10px;
  min-height:140px; color:var(--muted); font-weight:800; }
.error-state { flex-direction:column; color:var(--danger); }
.memory-stats { display:grid; grid-template-columns:repeat(3,1fr); gap:8px; }
.memory-stat { background:linear-gradient(135deg,rgba(255,255,255,0.04),rgba(255,255,255,0.01));
  border:1px solid var(--border); border-radius:14px; padding:12px 10px; text-align:center; }
.memory-stat strong { display:block; color:var(--accent); font-weight:900; font-size:17px; }
.memory-stat span { display:block; color:var(--muted); font-size:11px; font-weight:700;
  margin-top:4px; text-transform:uppercase; letter-spacing:0.03em; }
.event-banner { display:flex; align-items:center; gap:12px; padding:10px 14px;
  background:linear-gradient(135deg,#142244,#0d1730); border:1px solid rgba(72,202,228,0.45); }
.event-banner.ended { background:linear-gradient(135deg,#2a1226,#1a0a1a);
  border-color:rgba(239,71,111,0.55); }
.event-banner-icon { font-size:26px; }
.event-banner-title { font-weight:900; font-size:14px; color:#48cae4; }
.event-banner.ended .event-banner-title { color:#ef476f; }
.event-banner-sub { margin-top:2px; font-size:12px; color:var(--muted); font-weight:700; }
.memory-board-wrap { position:relative; }
.memory-board { display:grid; gap:8px; padding:10px; border-radius:18px;
  background:linear-gradient(135deg,rgba(255,255,255,0.05),rgba(0,0,0,0.15)),#0d1528;
  border:1px solid var(--border); box-shadow:inset 0 0 28px rgba(0,0,0,0.35); }
.memory-board.busy { opacity:0.8; }
.memory-card { aspect-ratio:1; border:none; padding:0; background:transparent;
  perspective:600px; cursor:pointer; }
.memory-card:disabled { cursor:default; }
.card-inner { position:relative; width:100%; height:100%; display:block;
  transform-style:preserve-3d; transition:transform 0.3s ease; }
.memory-card.flipped .card-inner { transform:rotateY(180deg); }
.card-face { position:absolute; inset:0; display:flex; align-items:center;
  justify-content:center; border-radius:12px; backface-visibility:hidden;
  font-size:clamp(20px,7vw,38px); }
.card-back { background:linear-gradient(145deg,#48cae4,#115b73);
  border:1px solid rgba(255,255,255,0.2); }
.card-front { background:linear-gradient(145deg,#ffd166,#9b5b12);
  border:1px solid rgba(255,255,255,0.28); transform:rotateY(180deg); }
.memory-card.matched .card-front { background:linear-gradient(145deg,#06d6a0,#0b6b55);
  box-shadow:0 0 0 2px rgba(6,214,160,0.45) inset; }
.memory-flash { position:absolute; top:50%; left:50%; transform:translate(-50%,-50%);
  border-radius:999px; padding:10px 16px; background:rgba(6,214,160,0.94); color:#062217;
  font-weight:900; box-shadow:0 14px 34px rgba(0,0,0,0.42); pointer-events:none; z-index:4; }
.memory-flash.warn { background:rgba(255,209,102,0.95); color:#2a1b00; }
.memory-flash-enter-active,.memory-flash-leave-active { transition:opacity 0.18s ease, transform 0.18s ease; }
.memory-flash-enter-from,.memory-flash-leave-to { opacity:0; transform:translate(-50%,-42%) scale(0.92); }
.memory-controls { display:flex; }
.ctrl.reset { flex:1; min-height:46px; border-radius:14px;
  background:linear-gradient(135deg,#ffd166,#f4a261); color:#1b1300; border:none;
  font-weight:900; display:inline-flex; align-items:center; justify-content:center; gap:5px; }
.ctrl.reset:active:not(:disabled) { transform:scale(0.97); }
.chest-modal { position:fixed; inset:0; z-index:1100; display:flex; flex-direction:column;
  align-items:center; justify-content:center; gap:24px; padding:20px;
  background:rgba(0,0,0,0.78); backdrop-filter:blur(6px); }
.chest-stage { width:200px; height:200px; display:flex; align-items:center; justify-content:center; }
.chest-box { font-size:100px; filter:drop-shadow(0 0 28px rgba(255,209,102,0.5)); }
.chest-box.shake { animation:chestShake 0.72s ease-in-out infinite; }
.chest-box.opening { animation:chestOpen 0.42s ease-out forwards; }
.chest-reveal { width:min(360px,100%); border-radius:18px; padding:22px;
  background:linear-gradient(135deg,rgba(255,209,102,0.14),rgba(6,214,160,0.1)),#111a30;
  border:1px solid rgba(255,209,102,0.4); text-align:center; }
.chest-reveal h3 { margin:0; font-size:20px; font-weight:900; }
.chest-reveal p { margin:6px 0 14px; color:var(--muted); font-size:13px; font-weight:700; }
.chest-items { display:flex; flex-direction:column; gap:8px; margin-bottom:14px; }
.chest-item { border-radius:14px; padding:12px 8px; background:rgba(255,255,255,0.08);
  border:1px solid rgba(255,255,255,0.1); animation:revealIn 0.3s ease-out both; }
.chest-item b { font-size:15px; font-weight:900; color:var(--accent); }
.confirm-backdrop { position:fixed; inset:0; background:rgba(0,0,0,0.65); display:flex;
  align-items:center; justify-content:center; z-index:1000; padding:16px; backdrop-filter:blur(4px); }
.confirm-dialog { max-width:340px; width:100%; display:flex; flex-direction:column;
  align-items:center; padding:24px; text-align:center; }
.confirm-emoji { font-size:48px; margin-bottom:10px; }
.confirm-sub { color:var(--muted); font-size:13px; margin:0 0 18px; }
.confirm-actions { display:flex; gap:8px; width:100%; }
.confirm-cancel { flex:1; background:rgba(255,255,255,0.08) !important; color:var(--muted) !important;
  border:1px solid var(--border) !important; }
.confirm-yes { flex:1; background:linear-gradient(135deg,#ef476f,#d62850) !important;
  color:#fff !important; border:none !important; }
@keyframes chestShake { 0%,100%{transform:translate(0,0) rotate(0);}
  25%{transform:translate(-4px,-2px) rotate(-4deg);} 50%{transform:translate(5px,2px) rotate(5deg);}
  75%{transform:translate(-2px,2px) rotate(-2deg);} }
@keyframes chestOpen { 0%{transform:scale(1);}
  40%{transform:scale(1.35);} 100%{transform:scale(0.1); opacity:0;} }
@keyframes revealIn { from{transform:translateY(14px) scale(0.94); opacity:0;}
  to{transform:translateY(0) scale(1); opacity:1;} }
@media (max-width:420px) {
  .memory-stats { grid-template-columns:1fr; }
  .memory-board { gap:6px; padding:8px; }
}
</style>
```

- [ ] **Step 2: Build-Check**

Run: `npm run build`
Expected: Build erfolgreich ohne Fehler.

- [ ] **Step 3: Commit**

```bash
git add src/views/MemoryGameView.vue
git commit -m "feat(memory): MemoryGameView mit Flip-UI und Truhen-Reveal"
```

---

## Task 11: Startseiten-Integration in `GameView.vue`

**Files:**
- Modify: `src/views/GameView.vue`

> Kontext: `GameView.vue` hat pro Sprache einen `I18N`-Block mit `mergeLink: { title, sub }` (de ~Zeile 144, en ~270, ru ~396) und `quick: { merge: ... }`. Es gibt eine Quick-Action `<router-link to="/merge" class="qa-btn">` (~Zeile 1205) und eine `<component :is="mergeEnded ? 'div' : 'router-link'" ... class="card merge-link">` (~Zeile 1712). Genaue Zeilen vor dem Edit per Grep auf `mergeLink` / `qa-btn` / `merge-link` bestaetigen.

- [ ] **Step 1: i18n `memoryLink` + `quick.memory` in allen drei Sprachen ergaenzen**

Im **deutschen** `I18N`-Block direkt nach dem `mergeLink: { ... }`-Objekt einfuegen:

```javascript
      memoryLink: {
        title: "🧠 Memory",
        sub: "Tier-Paare finden, Level schaffen & Truhen verdienen"
      },
```

Im **englischen** Block analog:

```javascript
      memoryLink: {
        title: "🧠 Memory",
        sub: "Find animal pairs, clear levels & earn chests"
      },
```

Im **russischen** Block analog:

```javascript
      memoryLink: {
        title: "🧠 Memory",
        sub: "Находи пары животных, проходи уровни и получай сундуки"
      },
```

In jedem der drei `quick`-Objekte (de/en/ru) neben `merge: "Merge"` ergaenzen:

```javascript
      memory: "Memory",
```

- [ ] **Step 2: Computed-Properties fuer Memory-Countdown ergaenzen**

Neben den bestehenden `mergeRemaining` / `mergeEnded` Computeds (~Zeile 594–599) einfuegen:

```javascript
const memoryRemaining = computed(() => {
  void nowTick.value
  return Math.max(0, game.memoryEndsAt - Date.now())
})
const memoryEnded = computed(() => game.memoryShowCountdown && (memoryRemaining.value <= 0 || !game.memoryActive))
```

> Hinweis: Den Reaktivitaets-Tick (`void X.value`) exakt so verwenden wie in `mergeRemaining` im selben File (dort heisst die Tick-Ref ggf. anders — vor dem Edit die Zeile von `mergeRemaining` lesen und dieselbe Tick-Ref verwenden).

- [ ] **Step 3: Quick-Action-Button ergaenzen**

Direkt nach dem Block
`<router-link to="/merge" class="qa-btn"> ... <span class="qa-label">{{ tx("quick.merge") }}</span> </router-link>`
folgenden Block einfuegen (Icon-Markup von der Merge-`qa-btn` uebernehmen, nur Emoji 🧠 und Label tauschen):

```vue
      <router-link to="/memory" class="qa-btn">
        <span class="qa-emoji">🧠</span>
        <span class="qa-label">{{ tx("quick.memory") }}</span>
      </router-link>
```

> Vor dem Edit die exakte innere Struktur der Merge-`qa-btn` lesen und 1:1 spiegeln (Klassennamen, Icon-Element), nur Ziel/Emoji/Label aendern.

- [ ] **Step 4: Link-Karte ergaenzen**

Direkt nach der Merge-Link-Karte (`<component :is="mergeEnded ? 'div' : 'router-link'" ... class="card merge-link">...</component>`) eine analoge Karte einfuegen:

```vue
    <component
      :is="memoryEnded ? 'div' : 'router-link'"
      :to="memoryEnded ? undefined : '/memory'"
      class="card memory-link"
      :class="{ 'event-ended': memoryEnded }"
    >
      <div class="ml-body">
        <div class="ml-title">{{ tx("memoryLink.title") }}</div>
        <div class="bpl-sub">{{ tx("memoryLink.sub") }}</div>
        <div
          v-if="memoryEnded"
          class="bpl-progress event-ended-text"
        >🔒 {{ tx("eventStatus.ended") }}</div>
        <div
          v-else-if="game.memoryEndsAt > 0"
          class="bpl-progress"
        >⏳ {{ tx("eventStatus.endsIn", { time: fmtCountdown(memoryRemaining) }) }}</div>
      </div>
      <div class="bpl-arrow">{{ memoryEnded ? '🔒' : '›' }}</div>
    </component>
```

> `tx("eventStatus.ended")` / `tx("eventStatus.endsIn")` und `fmtCountdown` werden bereits von der Merge-Karte im selben File benutzt — vorhandene Keys/Funktion wiederverwenden, nicht neu definieren. Falls die Merge-Karte andere Klassennamen nutzt, diese spiegeln.

- [ ] **Step 5: CSS fuer `.memory-link` ergaenzen**

Im `<style scoped>` von `GameView.vue` neben der `.merge-link`-Regel die Selektoren um `.memory-link` erweitern. Suche die Regeln `.merge-link { ... }`, `.merge-link:hover { ... }`, `.boss-path-link.event-ended, .merge-link.event-ended { ... }`, `.boss-path-link.event-ended:hover, .merge-link.event-ended:hover { ... }` und fuege jeweils `, .memory-link` (bzw. `, .memory-link.event-ended`) zur Selektorliste hinzu, sodass `.memory-link` dasselbe Styling wie `.merge-link` erhaelt. Beispiel fuer die Basisregel:

```css
.merge-link, .memory-link {
  /* unveraenderter bestehender Regelinhalt von .merge-link */
}
```

(Analog fuer die `:hover`- und `.event-ended`-Regeln. Keinen Regelinhalt aendern, nur Selektoren ergaenzen.)

- [ ] **Step 6: Build-Check**

Run: `npm run build`
Expected: Build erfolgreich ohne Fehler.

- [ ] **Step 7: Commit**

```bash
git add src/views/GameView.vue
git commit -m "feat(memory): Startseiten-Karte + Quick-Action"
```

---

## Task 12: Bestenliste-Tab in `LeaderboardView.vue`

**Files:**
- Modify: `src/views/LeaderboardView.vue`

> Kontext: `LeaderboardView.vue` hat eine `mode`-Ref, eine `load()`-Funktion mit `else if (mode.value === 'merge') { ... get_merge_leaderboard ... }`, ein `eventStatus`-Computed mit Merge-Zweig, ein `subtitle`-Computed, Tab-Buttons `.lb-tab` und Zeilen-Templates `<template v-else-if="mode === 'merge'">`. i18n laeuft ueber `t('leaderboard.*')` aus `src/i18n` (nicht lokales I18N).

- [ ] **Step 1: i18n-Strings fuer Memory in `src/i18n` ergaenzen**

In `src/i18n` (Datei per Grep auf `subtitleMerge` finden) im `leaderboard`-Abschnitt jeder Sprache (de/en/ru) folgende Keys analog zu den `*Merge*`-Keys ergaenzen:

- `byMemory`: de „Memory" / en „Memory" / ru „Memory"
- `subtitleMemory`: de „Hoechstes Memory-Level weltweit" / en „Highest memory level worldwide" / ru „Лучший уровень Memory в мире"
- `memoryLevel`: de „Level" / en „Level" / ru „Уровень"
- `memoryPairs`: de „Paare" / en „pairs" / ru „пар"

(Exakte Nachbarschaft: direkt nach den vorhandenen `subtitleMerge` / `byMerge` / `mergeScore`-Keys einfuegen, gleiche Quotes/Kommas wie umliegende Zeilen.)

- [ ] **Step 2: Lade-Zweig fuer Memory ergaenzen**

In `load()` nach dem Block
`} else if (mode.value === 'merge') { const { data, error: e } = await supabase.rpc('get_merge_leaderboard', { p_limit: 50 }) ... }`
einen analogen Zweig einfuegen:

```javascript
    } else if (mode.value === 'memory') {
      const { data, error: e } = await supabase.rpc('get_memory_leaderboard', { p_limit: 50 })
      if (e) throw e
      rows.value = data || []
```

> Den exakten Zuweisungs-/Fehlerstil (`rows.value = ...`, evtl. Mapping) vom Merge-Zweig im selben File 1:1 uebernehmen.

- [ ] **Step 3: `eventStatus`- und `subtitle`-Computed um Memory erweitern**

Im `eventStatus`-Computed nach dem Merge-Zweig:

```javascript
  if (mode.value === 'memory') {
    if (!game.memoryShowCountdown) return null
    const ms = Math.max(0, game.memoryEndsAt - Date.now())
    return { ended: !game.memoryActive, remainingMs: ms }
  }
```

Im `subtitle`-Computed nach `if (mode.value === 'merge') return t('leaderboard.subtitleMerge')`:

```javascript
  if (mode.value === 'memory') return t('leaderboard.subtitleMemory')
```

- [ ] **Step 4: Tab-Button + Zeilen-Template ergaenzen**

Nach dem Merge-Tab-Button (`<button class="lb-tab" :class="{ active: mode === 'merge' }" @click="setMode('merge')">🐾 {{ t('leaderboard.byMerge') }}</button>`) einfuegen:

```vue
    <button
      class="lb-tab"
      :class="{ active: mode === 'memory' }"
      @click="setMode('memory')"
    >
      🧠 {{ t('leaderboard.byMemory') }}
    </button>
```

Nach dem Merge-Zeilen-Template (`<template v-else-if="mode === 'merge'"> ... </template>`) einfuegen:

```vue
            <template v-else-if="mode === 'memory'">
              <span class="primary">🧠 {{ t('leaderboard.memoryLevel') }} {{ r.highest_level }}</span>
              <span class="secondary">🔁 {{ r.total_pairs }} {{ t('leaderboard.memoryPairs') }}</span>
            </template>
```

- [ ] **Step 5: Build-Check**

Run: `npm run build`
Expected: Build erfolgreich ohne Fehler.

- [ ] **Step 6: Commit**

```bash
git add src/views/LeaderboardView.vue src/i18n*
git commit -m "feat(memory): Bestenliste-Tab"
```

---

## Task 13: End-to-End-Verifikation (manuell, Browser-Preview)

**Files:**
- (keine; nur Verifikation)

- [ ] **Step 1: Dev-Server starten**

Run: `npm run dev`
Expected: Vite startet, URL erreichbar.

- [ ] **Step 2: Preview oeffnen und durchspielen**

Im Browser-Preview einloggen und pruefen:

1. Startseite zeigt die „🧠 Memory"-Karte mit Countdown und den Quick-Action-Button.
2. Klick → `/memory` laedt, Brett mit 12 Karten (Level 1, 6 Paare), alle verdeckt.
3. Eine Karte klicken → dreht um (eine sichtbar). Zweite klicken → Match (gruen, bleibt) oder kein Match (beide kurz sichtbar, dann wieder verdeckt beim naechsten Flip).
4. Level 1 komplett loesen → „Level geschafft!" → Truhen-Reveal-Modal (Shake → Open → Reveal) → „Weiter" → Level 2 (14 Karten).
5. „Brett neu" → Bestaetigungsdialog → mischt neu, `moves_used = 0`, kein Level-Fortschritt.
6. Absichtlich Zuglimit ueberschreiten (nur Fehlversuche) → Flash „Zuglimit erreicht", Brett wird neu gemischt, Level unveraendert.
7. Bestenliste → Tab „🧠 Memory" zeigt eigenen Eintrag mit Level + Paaren.
8. Sprache auf EN und RU umstellen → alle Texte korrekt, Umlaute in DE korrekt (ä ö ü ß, kein ae/oe/ue/ss).
9. Schmale Fensterbreite (<420px) → Layout bleibt nutzbar.

- [ ] **Step 3: Anti-Cheat-Verifikation**

In den Browser-DevTools den Netzwerk-Tab oeffnen, eine `flip`-Aktion ausloesen und die Response der `memory-game`-Funktion inspizieren.
Expected: Response enthaelt nur `visible_cards` (gematchte + aktuell aufgedeckte) und Metadaten — **kein** vollstaendiges verdecktes `board`. Verdeckte Karten sind im Response nicht enthalten.

- [ ] **Step 4: Event-Ende simulieren**

Via `execute_sql`:

```sql
update public.event_schedule
   set ends_at = now() - interval '1 minute'
 where key = 'memory_game';
```

Preview neu laden → `/memory` zeigt „Ereignis beendet"-Banner, Karten/Reset deaktiviert. Danach zuruecksetzen:

```sql
update public.event_schedule
   set ends_at = '2026-06-30 23:59:59+00'
 where key = 'memory_game';
```

Expected: Sperre greift bei abgelaufenem Event, nach Reset wieder spielbar.

- [ ] **Step 5: Abschluss-Commit (falls Korrekturen noetig waren)**

Nur falls in Schritten 1–4 Bugs gefunden und behoben wurden:

```bash
git add -A
git commit -m "fix(memory): E2E-Korrekturen"
```

---

## Self-Review-Notiz

- **Spec-Abdeckung:** Tabellen/Configs (T1–T2), `get_memory_state` (T3), `memory_flip` inkl. Zuglimit-Fail Variante (a) (T4), `complete`/`reset` (T5), `open_chest`/Leaderboard (T6), Migration final (T7), Edge Function (T8), Store/Route (T9), View (T10), Startseite (T11), Bestenliste (T12), E2E inkl. Anti-Cheat (T13). Alle Spec-Abschnitte abgedeckt.
- **Typkonsistenz:** Edge-Function-Actions (`status/flip/complete/reset/open_chest`) ↔ RPC-Namen (`get_memory_state/memory_flip/memory_complete_level/memory_reset_level/memory_open_chest`) konsistent. RPC-Antwortfelder (`version`, `visible_cards`, `card_count`, `turn.matched/cleared/failed`, `chest_reward_id`, `animal_reward_id`) werden im Frontend exakt so gelesen.
- **Keine Platzhalter:** Alle Code-Steps enthalten vollstaendigen Code; Stellen mit „Struktur vor Edit spiegeln" beziehen sich auf existierende Patterns im selben File und sind bewusst, da exakte Zeilennummern driften koennen.
