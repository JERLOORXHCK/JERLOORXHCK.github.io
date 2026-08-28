-- JERLOORXHCK BUSINESS DATABASE
-- Run this entire file in Supabase -> SQL Editor -> Run.
-- This SQL does NOT change Supabase Auth/email settings.
-- Email OTP is configured separately in Authentication -> Emails -> Confirm signup.

create extension if not exists pgcrypto;

-- =========================
-- PROFILES
-- =========================
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  first_name text,
  second_name text,
  display_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.profiles add column if not exists email text;
alter table public.profiles add column if not exists first_name text;
alter table public.profiles add column if not exists second_name text;
alter table public.profiles add column if not exists display_name text;
alter table public.profiles add column if not exists created_at timestamptz not null default now();
alter table public.profiles add column if not exists updated_at timestamptz not null default now();

alter table public.profiles enable row level security;

drop policy if exists "Users can view own profile" on public.profiles;
create policy "Users can view own profile"
on public.profiles for select
to authenticated
using (auth.uid() = id);

drop policy if exists "Users can insert own profile" on public.profiles;
create policy "Users can insert own profile"
on public.profiles for insert
to authenticated
with check (auth.uid() = id);

drop policy if exists "Users can update own profile" on public.profiles;
create policy "Users can update own profile"
on public.profiles for update
to authenticated
using (auth.uid() = id)
with check (auth.uid() = id);

-- =========================
-- SERVICES / ACTIVITIES
-- =========================
create table if not exists public.services (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text not null default '',
  icon text not null default '◈',
  price numeric(12,2) not null default 0 check (price >= 0),
  active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

alter table public.services enable row level security;

drop policy if exists "Anyone can view active services" on public.services;
create policy "Anyone can view active services"
on public.services for select
to anon, authenticated
using (active = true);

-- =========================
-- ORDERS
-- =========================
create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  order_number text unique,
  user_id uuid not null references auth.users(id) on delete cascade,
  service_id uuid references public.services(id) on delete set null,
  service_name text not null,
  amount numeric(12,2) not null default 0 check (amount >= 0),
  status text not null default 'pending'
    check (status in ('pending','processing','completed','cancelled')),
  customer_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.orders enable row level security;

drop policy if exists "Users can view own orders" on public.orders;
create policy "Users can view own orders"
on public.orders for select
to authenticated
using (auth.uid() = user_id);

drop policy if exists "Users can create own orders" on public.orders;
create policy "Users can create own orders"
on public.orders for insert
to authenticated
with check (auth.uid() = user_id);

-- =========================
-- UNIQUE ORDER NUMBER
-- Example: JX-260828-A1B2C3
-- =========================
create or replace function public.make_order_number()
returns text
language plpgsql
as $$
declare
  candidate text;
begin
  loop
    candidate :=
      'JX-' ||
      to_char(now(), 'YYMMDD') ||
      '-' ||
      upper(substr(encode(gen_random_bytes(4), 'hex'), 1, 6));

    exit when not exists (
      select 1
      from public.orders
      where order_number = candidate
    );
  end loop;

  return candidate;
end;
$$;

create or replace function public.set_order_number()
returns trigger
language plpgsql
as $$
begin
  if new.order_number is null or trim(new.order_number) = '' then
    new.order_number := public.make_order_number();
  end if;

  return new;
end;
$$;

drop trigger if exists before_order_number on public.orders;

create trigger before_order_number
before insert on public.orders
for each row
execute function public.set_order_number();

-- =========================
-- AUTO-CREATE PROFILE AFTER SIGNUP
-- =========================
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (
    id,
    email,
    first_name,
    second_name,
    display_name
  )
  values (
    new.id,
    new.email,
    nullif(new.raw_user_meta_data ->> 'first_name', ''),
    nullif(new.raw_user_meta_data ->> 'second_name', ''),
    nullif(
      trim(
        coalesce(new.raw_user_meta_data ->> 'first_name', '') ||
        ' ' ||
        coalesce(new.raw_user_meta_data ->> 'second_name', '')
      ),
      ''
    )
  )
  on conflict (id) do update
  set
    email = excluded.email,
    first_name = coalesce(excluded.first_name, public.profiles.first_name),
    second_name = coalesce(excluded.second_name, public.profiles.second_name),
    display_name = coalesce(excluded.display_name, public.profiles.display_name),
    updated_at = now();

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;

create trigger on_auth_user_created
after insert on auth.users
for each row
execute function public.handle_new_user();

-- =========================
-- UPDATED_AT
-- =========================
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists profiles_touch_updated_at on public.profiles;

create trigger profiles_touch_updated_at
before update on public.profiles
for each row
execute function public.touch_updated_at();

drop trigger if exists orders_touch_updated_at on public.orders;

create trigger orders_touch_updated_at
before update on public.orders
for each row
execute function public.touch_updated_at();

-- =========================
-- DEFAULT ACTIVITIES
-- =========================
insert into public.services (
  name, description, icon, price, sort_order
)
select *
from (
  values
    ('Account Recovery', 'Legitimate account-access recovery assistance.', '🔐', 0, 1),
    ('Cybersecurity', 'Security awareness and defensive protection guidance.', '🛡️', 0, 2),
    ('Ethical Hacking', 'Authorized security testing and learning.', '💻', 0, 3),
    ('Security Research', 'Controlled security research with authorization.', '🧪', 0, 4),
    ('E-Business', 'Digital business setup and automation.', '🌐', 0, 5),
    ('App Development', 'Modern mobile and web application development.', '📱', 0, 6),
    ('Website Creation', 'Responsive professional website creation.', '🖥️', 0, 7),
    ('Technical Support', 'Technical guidance for digital projects.', '⚙️', 0, 8)
) as v(name, description, icon, price, sort_order)
where not exists (
  select 1
  from public.services s
  where s.name = v.name
);

-- =========================
-- INDEXES
-- =========================
create index if not exists orders_user_created_idx
on public.orders(user_id, created_at desc);

create index if not exists services_active_sort_idx
on public.services(active, sort_order);

-- =========================
-- IMPORTANT: EMAIL OTP
-- =========================
-- SQL cannot change the hosted Supabase email template.
-- In Supabase Dashboard:
-- Authentication -> Emails -> Confirm signup
-- Put {{ .Token }} in the email body.
-- Supabase documents {{ .Token }} as the 6-digit email OTP.
