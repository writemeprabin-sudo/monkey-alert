-- Monkey Alert database with farmer accounts.
-- Run this once in Supabase: SQL Editor -> New query -> paste -> Run.
-- Safe to run on a brand-new project (it replaces any earlier version of these tables' rules).

-- ---------- profiles: one row per farmer, holds the display name ----------
create table if not exists public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 40),
  created_at   timestamptz not null default now()
);
alter table public.profiles enable row level security;

drop policy if exists "read own profile" on public.profiles;
create policy "read own profile" on public.profiles for select to authenticated using (id = auth.uid());

-- Create the profile automatically when a farmer signs up.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    left(coalesce(nullif(trim(new.raw_user_meta_data->>'display_name'), ''), 'Farmer'), 40)
  );
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- sightings ----------
create table if not exists public.sightings (
  id            uuid primary key default gen_random_uuid(),
  lat           double precision not null check (lat between -90 and 90),
  lng           double precision not null check (lng between -180 and 180),
  group_size    text not null check (group_size in ('few', 'group', 'troop')),
  device_id     text not null default '',
  confirms      int not null default 0,
  gone_votes    int not null default 0,
  created_at    timestamptz not null default now()
);
alter table public.sightings add column if not exists user_id uuid references auth.users(id) on delete set null;
alter table public.sightings add column if not exists reporter_name text;

create index if not exists sightings_created_idx on public.sightings (created_at desc);

-- The server fills in WHO reported, so nobody can report under another name.
create or replace function public.stamp_sighting()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then
    raise exception 'login required';
  end if;
  new.user_id := auth.uid();
  new.reporter_name := (select display_name from public.profiles where id = auth.uid());
  new.confirms := 0;
  new.gone_votes := 0;
  return new;
end;
$$;

drop trigger if exists stamp_sighting_trg on public.sightings;
create trigger stamp_sighting_trg
  before insert on public.sightings
  for each row execute function public.stamp_sighting();

alter table public.sightings enable row level security;

drop policy if exists "read sightings" on public.sightings;
drop policy if exists "add sightings" on public.sightings;

-- Only logged-in farmers can see or add reports.
create policy "read sightings" on public.sightings for select to authenticated using (true);
create policy "add sightings" on public.sightings for insert to authenticated
  with check (
    created_at > now() - interval '6 hours'      -- allows reports queued while offline
    and created_at < now() + interval '1 minute'
  );

-- ---------- votes: one vote per farmer per sighting ----------
drop function if exists public.vote_sighting(uuid, text, text);
drop table if exists public.sighting_votes;

create table public.sighting_votes (
  sighting_id uuid not null references public.sightings(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  kind        text not null check (kind in ('confirm', 'gone')),
  created_at  timestamptz not null default now(),
  primary key (sighting_id, user_id)
);
alter table public.sighting_votes enable row level security;   -- no policies: only the function below can write

create or replace function public.vote_sighting(p_sighting uuid, p_kind text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'login required'; end if;
  if p_kind not in ('confirm', 'gone') then raise exception 'invalid vote'; end if;

  insert into sighting_votes (sighting_id, user_id, kind)
  values (p_sighting, auth.uid(), p_kind)
  on conflict do nothing;

  if found then
    update sightings
    set confirms   = confirms   + (p_kind = 'confirm')::int,
        gone_votes = gone_votes + (p_kind = 'gone')::int
    where id = p_sighting;
  end if;
end;
$$;

revoke execute on function public.vote_sighting(uuid, text) from public, anon;
grant  execute on function public.vote_sighting(uuid, text) to authenticated;
