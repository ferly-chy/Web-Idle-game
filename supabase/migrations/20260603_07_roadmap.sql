-- 20260603_07_roadmap.sql
-- Roadmap / Ideen-Feature: User-eingereichte Feature-Vorschlaege mit Voting.

create table if not exists public.roadmap_ideas (
  id          uuid primary key default gen_random_uuid(),
  title       text not null check (length(title) between 3 and 120),
  description text check (description is null or length(description) <= 1000),
  status      text not null default 'idea'
              check (status in ('idea','planned','in_progress','done','rejected')),
  created_by  uuid references auth.users on delete set null,
  created_at  timestamptz not null default now()
);
create index if not exists roadmap_ideas_status_idx on public.roadmap_ideas(status);

create table if not exists public.roadmap_votes (
  idea_id  uuid not null references public.roadmap_ideas(id) on delete cascade,
  user_id  uuid not null references auth.users on delete cascade,
  voted_at timestamptz not null default now(),
  primary key (idea_id, user_id)
);
create index if not exists roadmap_votes_user_idx on public.roadmap_votes(user_id);

alter table public.roadmap_ideas enable row level security;
alter table public.roadmap_votes enable row level security;

drop policy if exists "read ideas"   on public.roadmap_ideas;
drop policy if exists "read votes"   on public.roadmap_votes;
create policy "read ideas" on public.roadmap_ideas
  for select to authenticated using (true);
create policy "read votes" on public.roadmap_votes
  for select to authenticated using (true);

create or replace view public.roadmap_view as
select
  i.id, i.title, i.description, i.status, i.created_by, i.created_at,
  coalesce(p.username, '') as author_username,
  (select count(*) from public.roadmap_votes v where v.idea_id = i.id) as vote_count,
  exists (
    select 1 from public.roadmap_votes v
    where v.idea_id = i.id and v.user_id = auth.uid()
  ) as my_vote
from public.roadmap_ideas i
left join public.profiles p on p.id = i.created_by;

create or replace function public.submit_idea(p_title text, p_description text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  new_id uuid;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  p_title := trim(p_title);
  if p_title is null or length(p_title) < 3 then
    raise exception 'title too short';
  end if;
  insert into public.roadmap_ideas(title, description, created_by)
    values (p_title, nullif(trim(p_description), ''), uid)
    returning id into new_id;
  insert into public.roadmap_votes(idea_id, user_id) values (new_id, uid);
  return jsonb_build_object('id', new_id);
end $$;

create or replace function public.vote_idea(p_idea_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  cnt int;
  voted boolean;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  if not exists (select 1 from public.roadmap_ideas where id = p_idea_id) then
    raise exception 'idea not found';
  end if;
  insert into public.roadmap_votes(idea_id, user_id) values (p_idea_id, uid)
    on conflict do nothing;
  if found then
    voted := true;
  else
    delete from public.roadmap_votes where idea_id = p_idea_id and user_id = uid;
    voted := false;
  end if;
  select count(*) into cnt from public.roadmap_votes where idea_id = p_idea_id;
  return jsonb_build_object('voted', voted, 'count', cnt);
end $$;
