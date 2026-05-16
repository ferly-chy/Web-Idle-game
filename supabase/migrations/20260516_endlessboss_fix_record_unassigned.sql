-- Fix: "record v_active is not assigned yet"
-- boss_endless_status setzt v_active nach Auto-Ablauf auf NULL und liest danach
-- v_active.id wieder aus. Bei einer untypisierten `record`-Variable ist das nach
-- der NULL-Zuweisung ein Fehler. Mit %rowtype ist die Struktur zur Compile-Zeit
-- bekannt, daher sind die Feldzugriffe (NULL) zulässig. Gleiches gilt für v_best
-- (kein Treffer) und v_active in boss_endless_start.

create or replace function public.boss_endless_status()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  v_active public.boss_endless_runs%rowtype;
  v_best public.boss_endless_runs%rowtype;
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
  v_active public.boss_endless_runs%rowtype;
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
