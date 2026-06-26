-- Rent a Husband — Phase 0 schema (brief §5)
-- Tables, enums, indexes, and rating triggers. RLS lives in 0002_rls_policies.sql.
-- Apply with `supabase db reset` (local) or `supabase db push`.

-- ─────────────────────────────────────────────────────────────
-- Enums
-- ─────────────────────────────────────────────────────────────
create type user_role            as enum ('homeowner', 'contractor');
create type onboarding_status    as enum ('incomplete', 'submitted', 'approved', 'rejected', 'suspended');
create type subscription_tier    as enum ('free', 'pro');
create type doc_type             as enum ('gov_id_front', 'gov_id_back', 'selfie', 'proof_of_address', 'cert_of_character', 'trade_cert', 'insurance');
create type doc_status           as enum ('pending', 'approved', 'rejected');
create type payout_method        as enum ('bank', 'wipay');
create type payout_status        as enum ('unverified', 'verified');
create type job_status           as enum ('open', 'booked', 'completed', 'cancelled');
create type quote_status         as enum ('pending', 'accepted', 'declined');
create type booking_status       as enum ('active', 'completed', 'cancelled');
create type payment_method       as enum ('in_app', 'cash');
create type payment_type         as enum ('connection_fee', 'job_payment', 'subscription');
create type payment_status       as enum ('pending', 'paid', 'failed');
create type review_direction     as enum ('homeowner_to_contractor', 'contractor_to_homeowner');
create type report_status        as enum ('open', 'reviewing', 'resolved', 'dismissed');
create type subscription_status  as enum ('active', 'cancelled', 'past_due');

-- ─────────────────────────────────────────────────────────────
-- Reference data
-- ─────────────────────────────────────────────────────────────
create table categories (
  id          uuid primary key default gen_random_uuid(),
  slug        text unique not null,
  name        text not null,
  sort_order  int  not null default 0
);

-- Single launch zone now; geography supported from day one (brief §2.4).
create table service_zones (
  id          uuid primary key default gen_random_uuid(),
  slug        text unique not null,
  name        text not null,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

-- ─────────────────────────────────────────────────────────────
-- Users
-- ─────────────────────────────────────────────────────────────
create table profiles (
  id              uuid primary key references auth.users (id) on delete cascade,
  role            user_role not null,
  full_name       text,
  phone           text,
  phone_verified  boolean not null default false,
  email           text,
  avatar_url      text,
  created_at      timestamptz not null default now()
);

create table contractor_profiles (
  user_id            uuid primary key references profiles (id) on delete cascade,
  bio                text,
  service_areas      uuid[] not null default '{}',          -- service_zones.id list
  onboarding_status  onboarding_status not null default 'incomplete',  -- admin/service-role only (see RLS + trigger)
  subscription_tier  subscription_tier not null default 'free',        -- admin/service-role only
  rating_avg         numeric(3,2) not null default 0,
  rating_count       int not null default 0,
  jobs_completed     int not null default 0,
  created_at         timestamptz not null default now()
);

-- Contractor ⇄ category skills (brief §5 "skills as join table").
create table contractor_skills (
  contractor_id  uuid not null references contractor_profiles (user_id) on delete cascade,
  category_id    uuid not null references categories (id) on delete cascade,
  primary key (contractor_id, category_id)
);

-- Highest-risk data. Files live in the PRIVATE 'contractor-docs' storage bucket.
create table contractor_documents (
  id               uuid primary key default gen_random_uuid(),
  contractor_id    uuid not null references contractor_profiles (user_id) on delete cascade,
  doc_type         doc_type not null,
  storage_path     text not null,
  status           doc_status not null default 'pending',  -- admin/service-role only
  rejection_reason text,
  expires_at       date,
  reviewed_by      uuid references profiles (id),
  reviewed_at      timestamptz,
  created_at       timestamptz not null default now()
);
create index on contractor_documents (contractor_id);

-- See docs/wipay-notes.md §13.3: WiPay has no payout token for contractors.
-- Store minimal data; encrypt sensitive fields at rest (handled outside RLS).
create table contractor_payout (
  contractor_id  uuid primary key references contractor_profiles (user_id) on delete cascade,
  method         payout_method not null default 'bank',
  bank_name      text,
  account_name   text,
  account_last4  text,
  account_token  text,                              -- reserved; unused until WiPay supports it
  status         payout_status not null default 'unverified',  -- admin/service-role only
  created_at     timestamptz not null default now()
);

-- ─────────────────────────────────────────────────────────────
-- Marketplace
-- ─────────────────────────────────────────────────────────────
create table jobs (
  id              uuid primary key default gen_random_uuid(),
  homeowner_id    uuid not null references profiles (id) on delete cascade,
  category_id     uuid not null references categories (id),
  zone_id         uuid references service_zones (id),
  title           text not null,
  description     text,
  photos          text[] not null default '{}',
  lat             double precision,
  lng             double precision,
  area_text       text,
  preferred_time  timestamptz,
  budget_optional numeric(10,2),
  status          job_status not null default 'open',
  created_at      timestamptz not null default now()
);
create index on jobs (status);
create index on jobs (category_id);
create index on jobs (zone_id);
create index on jobs (homeowner_id);

create table quotes (
  id             uuid primary key default gen_random_uuid(),
  job_id         uuid not null references jobs (id) on delete cascade,
  contractor_id  uuid not null references contractor_profiles (user_id) on delete cascade,
  amount         numeric(10,2) not null,
  message        text,
  status         quote_status not null default 'pending',
  created_at     timestamptz not null default now(),
  unique (job_id, contractor_id)
);
create index on quotes (job_id);
create index on quotes (contractor_id);

create table bookings (
  id                         uuid primary key default gen_random_uuid(),
  job_id                     uuid not null references jobs (id) on delete cascade,
  contractor_id              uuid not null references contractor_profiles (user_id),
  homeowner_id               uuid not null references profiles (id),
  agreed_amount              numeric(10,2) not null,
  connection_fee_payment_id  uuid,                         -- FK added after payments table
  payment_method             payment_method,               -- chosen at completion
  status                     booking_status not null default 'active',
  created_at                 timestamptz not null default now()
);
create index on bookings (contractor_id);
create index on bookings (homeowner_id);
create index on bookings (job_id);

-- Written ONLY by Edge Functions (service role). See RLS — no client write policy.
create table payments (
  id                   uuid primary key default gen_random_uuid(),
  booking_id           uuid references bookings (id) on delete set null,
  contractor_id        uuid references contractor_profiles (user_id),  -- for subscriptions
  type                 payment_type not null,
  amount               numeric(10,2) not null,
  currency             text not null default 'TTD',
  wipay_order_id       text unique,                  -- our order_id sent to WiPay
  wipay_transaction_id text,                         -- WiPay's transaction_id
  status               payment_status not null default 'pending',
  hash_verified        boolean not null default false,
  raw                  jsonb,                         -- raw WiPay response params
  created_at           timestamptz not null default now()
);
create index on payments (booking_id);
create index on payments (status);

alter table bookings
  add constraint bookings_connection_fee_fk
  foreign key (connection_fee_payment_id) references payments (id) on delete set null;

create table reviews (
  id          uuid primary key default gen_random_uuid(),
  booking_id  uuid not null references bookings (id) on delete cascade,
  rater_id    uuid not null references profiles (id),
  ratee_id    uuid not null references profiles (id),
  direction   review_direction not null,
  stars       int not null check (stars between 1 and 5),
  comment     text,
  created_at  timestamptz not null default now(),
  unique (booking_id, direction)
);
create index on reviews (ratee_id);

create table reports (
  id           uuid primary key default gen_random_uuid(),
  reporter_id  uuid not null references profiles (id),
  target_type  text not null,                  -- 'profile' | 'booking' | 'job' | 'quote'
  target_id    uuid not null,
  reason       text not null,
  status       report_status not null default 'open',
  created_at   timestamptz not null default now()
);

create table subscriptions (
  id                  uuid primary key default gen_random_uuid(),
  contractor_id       uuid not null references contractor_profiles (user_id) on delete cascade,
  tier                subscription_tier not null default 'pro',
  status              subscription_status not null default 'active',
  current_period_end  timestamptz,
  wipay_reference     text,
  created_at          timestamptz not null default now()
);
create index on subscriptions (contractor_id);

-- ─────────────────────────────────────────────────────────────
-- Rating maintenance: recompute contractor rating_avg/rating_count
-- whenever a homeowner_to_contractor review is written.
-- ─────────────────────────────────────────────────────────────
create or replace function recompute_contractor_rating()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  target uuid := coalesce(new.ratee_id, old.ratee_id);
begin
  update contractor_profiles cp
  set rating_avg = coalesce((
        select round(avg(stars)::numeric, 2)
        from reviews r
        where r.ratee_id = target
          and r.direction = 'homeowner_to_contractor'
      ), 0),
      rating_count = (
        select count(*)
        from reviews r
        where r.ratee_id = target
          and r.direction = 'homeowner_to_contractor'
      )
  where cp.user_id = target;
  return null;
end;
$$;

create trigger trg_reviews_recompute_rating
after insert or update or delete on reviews
for each row execute function recompute_contractor_rating();
