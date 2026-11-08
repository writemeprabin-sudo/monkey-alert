-- Run this once in the Supabase SQL editor.

create table if not exists public.sightings (
  id          uuid primary key default gen_random_uuid(),
  lat         double precision not null check (lat between -90 and 90),
  lng         double precision not null check (lng between -180 and 180),
  group_size  text not null check (group_size in ('few', 'group', 'troop')),
  device_id   text not null,
  confirms    int not null default 0,
  gone_votes  int not null default 0,
  created_at  timestamptz not null default now()
);

create index if not exists sightings_created_idx on public.sightings (created_at desc);

create table if not exists public.sighting_votes (
  sighting_id uuid not null references public.sightings(id) on delete cascade,
  device_id   text not null,
  kind        text not null check (kind in ('confirm', 'gone')),
  created_at  timestamptz not null default now(),
  primary key (sighting_id, device_id)
);

alter table public.sightings enable row level security;
alter table public.sighting_votes enable row level security;

-- Anyone with the app key can read sightings and add one.
-- Counters can only change through vote_sighting() below.
drop policy if exists "read sightings" on public.sightings;
create policy "read sightings" on public.sightings for select using (true);

drop policy if exists "add sightings" on public.sightings;
create policy "add sightings" on public.sightings for insert
  with check (
    confirms = 0 and gone_votes = 0
    and created_at > now() - interval '6 hours'      -- allows reports queued while offline
    and created_at < now() + interval '1 minute'
  );

-- One vote per device per sighting.
create or replace function public.vote_sighting(p_sighting uuid, p_device text, p_kind text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_kind not in ('confirm', 'gone') then
    raise exception 'invalid vote';
  end if;

  insert into sighting_votes (sighting_id, device_id, kind)
  values (p_sighting, p_device, p_kind)
  on conflict do nothing;

  if found then
    update sightings
    set confirms   = confirms   + (p_kind = 'confirm')::int,
        gone_votes = gone_votes + (p_kind = 'gone')::int
    where id = p_sighting;
  end if;
end;
$$;

grant execute on function public.vote_sighting(uuid, text, text) to anon;

-- Enable realtime so phones get new sightings instantly.
alter publication supabase_realtime add table public.sightings;
