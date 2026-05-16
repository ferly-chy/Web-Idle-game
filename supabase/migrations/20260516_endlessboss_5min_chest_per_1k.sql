-- Endlessboss-Balance:
--  * Cooldown 1 Stunde → 5 Minuten (300s), damit jede 5 Min ein Versuch geht.
--  * boss_endless_finish akzeptiert jetzt auch einen bereits 'expired'
--    markierten Run. Bisher konnte boss_endless_status den aktiven Run
--    auto-ablaufen lassen (z. B. via Return-Refresh nach App-Wechsel),
--    während gleichzeitig der Finish-Aufruf lief → "run not active"-Fehler
--    nach jedem Versuch und stecken gebliebene Runs.
--  * Truhe: 1 Truhe (Tier) pro 1.000 Schaden, gedeckelt auf 50 Tiere/Run.

create or replace function public.boss_endless_status()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  v_active record;
  v_best record;
  v_last_finish timestamptz;
  v_cooldown_seconds int := 300;
  v_event_active boolean;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  v_event_active := public.event_is_active('boss_endless');

  select * into v_active from public.boss_endless_runs
   where user_id = uid and status = 'active'
   order by id desc limit 1;

  if v_active.id is not null and v_active.ends_at <= now() then
    update public.boss_endless_runs
       set status = 'expired',
           finished_at = ends_at
     where id = v_active.id;
    v_active := null;
  end if;

  select * into v_best from public.boss_endless_runs
   where user_id = uid and status = 'finished'
   order by damage desc, finished_at desc limit 1;

  select max(finished_at) into v_last_finish
    from public.boss_endless_runs
   where user_id = uid and status in ('finished', 'expired');

  return jsonb_build_object(
    'event_active', v_event_active,
    'cooldown_seconds', v_cooldown_seconds,
    'cooldown_until', case when v_last_finish is null then null
                       else v_last_finish + (v_cooldown_seconds || ' seconds')::interval end,
    'active_run', case when v_active.id is null then null
                       else jsonb_build_object(
                         'id', v_active.id,
                         'started_at', v_active.started_at,
                         'ends_at', v_active.ends_at
                       ) end,
    'best', case when v_best.id is null then null
                 else jsonb_build_object(
                   'id', v_best.id,
                   'damage', v_best.damage,
                   'finished_at', v_best.finished_at
                 ) end,
    'server_now', now()
  );
end $$;

grant execute on function public.boss_endless_status() to authenticated;

create or replace function public.boss_endless_start()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  v_now timestamptz := now();
  v_active record;
  v_last_finish timestamptz;
  v_cooldown_seconds int := 300;
  v_run_seconds int := 180;
  v_new_id bigint;
  v_ends_at timestamptz;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  if not public.event_is_active('boss_endless') then
    raise exception 'event ended';
  end if;

  update public.boss_endless_runs
     set status = 'expired', finished_at = ends_at
   where user_id = uid and status = 'active' and ends_at <= v_now;

  select * into v_active from public.boss_endless_runs
   where user_id = uid and status = 'active'
   order by id desc limit 1;

  if v_active.id is not null then raise exception 'run already active'; end if;

  select max(finished_at) into v_last_finish
    from public.boss_endless_runs
   where user_id = uid and status in ('finished', 'expired');

  if v_last_finish is not null
     and v_last_finish + (v_cooldown_seconds || ' seconds')::interval > v_now then
    raise exception 'cooldown active';
  end if;

  v_ends_at := v_now + (v_run_seconds || ' seconds')::interval;
  insert into public.boss_endless_runs(user_id, started_at, ends_at)
  values (uid, v_now, v_ends_at)
  returning id into v_new_id;

  return jsonb_build_object(
    'id', v_new_id,
    'started_at', v_now,
    'ends_at', v_ends_at,
    'duration_seconds', v_run_seconds,
    'cooldown_seconds', v_cooldown_seconds,
    'server_now', v_now
  );
end $$;

grant execute on function public.boss_endless_start() to authenticated;

create or replace function public.boss_endless_finish(p_run_id bigint, p_damage bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  v_now timestamptz := now();
  v_run public.boss_endless_runs%rowtype;
  v_damage bigint;
  v_max_damage bigint := 5000000000;
  v_coins_reward bigint;
  v_chest_threshold bigint := 1000;
  v_chest_cap int := 50;
  v_grants_chest boolean := false;
  v_chest_qty int := 0;
  v_weight_total numeric;
  v_roll numeric;
  v_acc numeric;
  v_rec record;
  v_picked_species text;
  v_new_id uuid;
  v_chest_animal_ids uuid[] := '{}';
  v_chest_species text[] := '{}';
  v_i int;
  v_profile record;
begin
  if uid is null then raise exception 'not authenticated'; end if;

  select * into v_run from public.boss_endless_runs
   where id = p_run_id and user_id = uid for update;
  if not found then raise exception 'run not found'; end if;
  -- 'active' (Normalfall) und 'expired' (Auto-Ablauf während Finish-Race)
  -- werden akzeptiert; nur ein bereits gewerteter Run wird abgelehnt.
  if v_run.status = 'finished' then raise exception 'run already finished'; end if;

  v_damage := greatest(0, least(coalesce(p_damage, 0), v_max_damage));

  update public.boss_endless_runs
     set damage = v_damage,
         status = 'finished',
         finished_at = least(v_now, v_run.ends_at)
   where id = v_run.id;

  v_coins_reward := greatest(0, v_damage / 100);
  v_chest_qty := least(v_chest_cap, (v_damage / v_chest_threshold)::int);
  v_grants_chest := v_chest_qty > 0;

  if v_coins_reward > 0 then
    update public.profiles
       set coins = coins + v_coins_reward
     where id = uid
     returning coins, tickets into v_profile;
  else
    select coins, tickets into v_profile from public.profiles where id = uid;
  end if;

  if v_grants_chest then
    select coalesce(sum(weight), 0) into v_weight_total
      from public.species_costs
     where enabled and weight > 0 and coalesce(craft_only, false) = false;
    if coalesce(v_weight_total, 0) > 0 then
      for v_i in 1..v_chest_qty loop
        v_roll := random() * v_weight_total;
        v_acc := 0;
        v_picked_species := null;
        for v_rec in
          select species, weight from public.species_costs
          where enabled and weight > 0 and coalesce(craft_only, false) = false
          order by species
        loop
          v_acc := v_acc + v_rec.weight;
          if v_roll < v_acc then
            v_picked_species := v_rec.species;
            exit;
          end if;
        end loop;
        if v_picked_species is not null then
          insert into public.animals(owner_id, species, equipped)
          values (uid, v_picked_species, false)
          returning id into v_new_id;
          v_chest_animal_ids := v_chest_animal_ids || v_new_id;
          v_chest_species := v_chest_species || v_picked_species;
        end if;
      end loop;
    end if;
  end if;

  return jsonb_build_object(
    'id', v_run.id,
    'damage', v_damage,
    'coins_reward', v_coins_reward,
    'chest_granted', v_grants_chest,
    'chest_qty', case when v_grants_chest then v_chest_qty else 0 end,
    'chest_species', to_jsonb(v_chest_species),
    'chest_animal_ids', to_jsonb(v_chest_animal_ids),
    'coins', coalesce(v_profile.coins, 0)
  );
end $$;

grant execute on function public.boss_endless_finish(bigint, bigint) to authenticated;
