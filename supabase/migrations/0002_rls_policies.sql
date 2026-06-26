-- Rent a Husband — Row-Level Security (brief §9)
-- RLS is THE security model. Default-deny everywhere; explicit policies below.
-- Admin/Studio uses the service role, which BYPASSES RLS — so "admin-only" simply
-- means "no policy granted to authenticated, plus a guard trigger on privileged columns".

-- ─────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────
create or replace function auth_is_service()
returns boolean language sql stable as $$
  select coalesce(
           nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role',
           ''
         ) = 'service_role'
      or current_user in ('service_role', 'supabase_admin', 'postgres');
$$;

create or replace function is_approved_contractor(uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from contractor_profiles
    where user_id = uid and onboarding_status = 'approved'
  );
$$;

-- ─────────────────────────────────────────────────────────────
-- Guard triggers — privileged columns are admin/service-role only
-- ─────────────────────────────────────────────────────────────
create or replace function guard_contractor_profiles()
returns trigger language plpgsql as $$
begin
  if auth_is_service() then return new; end if;
  if new.onboarding_status is distinct from old.onboarding_status
     or new.subscription_tier is distinct from old.subscription_tier
     or new.rating_avg     is distinct from old.rating_avg
     or new.rating_count   is distinct from old.rating_count
     or new.jobs_completed is distinct from old.jobs_completed then
    raise exception 'onboarding_status / subscription_tier / rating / jobs_completed are admin-only';
  end if;
  return new;
end; $$;
create trigger trg_guard_contractor_profiles
  before update on contractor_profiles
  for each row execute function guard_contractor_profiles();

-- On self-insert, force a safe starting state (cannot self-approve).
create or replace function guard_contractor_profiles_insert()
returns trigger language plpgsql as $$
begin
  if auth_is_service() then return new; end if;
  new.onboarding_status := 'incomplete';
  new.subscription_tier := 'free';
  new.rating_avg := 0; new.rating_count := 0; new.jobs_completed := 0;
  return new;
end; $$;
create trigger trg_guard_contractor_profiles_insert
  before insert on contractor_profiles
  for each row execute function guard_contractor_profiles_insert();

create or replace function guard_contractor_documents()
returns trigger language plpgsql as $$
begin
  if auth_is_service() then return new; end if;
  if tg_op = 'INSERT' then
    new.status := 'pending';
    new.reviewed_by := null; new.reviewed_at := null; new.rejection_reason := null;
    return new;
  end if;
  raise exception 'contractor_documents status/review fields are admin-only';
end; $$;
create trigger trg_guard_contractor_documents
  before insert or update on contractor_documents
  for each row execute function guard_contractor_documents();

create or replace function guard_contractor_payout()
returns trigger language plpgsql as $$
begin
  if auth_is_service() then return new; end if;
  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    raise exception 'contractor_payout.status is admin-only';
  end if;
  if tg_op = 'INSERT' then new.status := 'unverified'; end if;
  return new;
end; $$;
create trigger trg_guard_contractor_payout
  before insert or update on contractor_payout
  for each row execute function guard_contractor_payout();

-- ─────────────────────────────────────────────────────────────
-- Enable RLS
-- ─────────────────────────────────────────────────────────────
alter table profiles             enable row level security;
alter table contractor_profiles  enable row level security;
alter table contractor_skills    enable row level security;
alter table contractor_documents enable row level security;
alter table contractor_payout    enable row level security;
alter table categories           enable row level security;
alter table service_zones        enable row level security;
alter table jobs                 enable row level security;
alter table quotes               enable row level security;
alter table bookings             enable row level security;
alter table payments             enable row level security;
alter table reviews              enable row level security;
alter table reports              enable row level security;
alter table subscriptions        enable row level security;

-- ─────────────────────────────────────────────────────────────
-- Reference data: world-readable, seeded only (no client writes)
-- ─────────────────────────────────────────────────────────────
create policy categories_read    on categories    for select using (true);
create policy zones_read         on service_zones for select using (true);

-- ─────────────────────────────────────────────────────────────
-- profiles  (raw row is self-only; safe public fields via public_profiles view)
-- ─────────────────────────────────────────────────────────────
create policy profiles_select_own on profiles for select using (id = auth.uid());
create policy profiles_insert_own on profiles for insert with check (id = auth.uid());
create policy profiles_update_own on profiles for update using (id = auth.uid()) with check (id = auth.uid());

create or replace view public_profiles
with (security_invoker = off) as
  select id, full_name, avatar_url, role from profiles;
grant select on public_profiles to anon, authenticated;

-- ─────────────────────────────────────────────────────────────
-- contractor_profiles  (self full row; approved cards via view)
-- ─────────────────────────────────────────────────────────────
create policy cprofiles_select_own on contractor_profiles for select using (user_id = auth.uid());
create policy cprofiles_insert_own on contractor_profiles for insert with check (user_id = auth.uid());
create policy cprofiles_update_own on contractor_profiles for update using (user_id = auth.uid()) with check (user_id = auth.uid());

create or replace view public_contractor_cards
with (security_invoker = off) as
  select cp.user_id, p.full_name, p.avatar_url, cp.bio,
         cp.rating_avg, cp.rating_count, cp.jobs_completed, cp.service_areas
  from contractor_profiles cp
  join profiles p on p.id = cp.user_id
  where cp.onboarding_status = 'approved';
grant select on public_contractor_cards to anon, authenticated;

-- ─────────────────────────────────────────────────────────────
-- contractor_skills  (readable for matching; own writes)
-- ─────────────────────────────────────────────────────────────
create policy cskills_read       on contractor_skills for select using (true);
create policy cskills_write_own  on contractor_skills for insert with check (contractor_id = auth.uid());
create policy cskills_delete_own on contractor_skills for delete using (contractor_id = auth.uid());

-- ─────────────────────────────────────────────────────────────
-- contractor_documents  (own only; status admin-only via guard; raw files in private bucket)
-- ─────────────────────────────────────────────────────────────
create policy cdocs_select_own on contractor_documents for select using (contractor_id = auth.uid());
create policy cdocs_insert_own on contractor_documents for insert with check (contractor_id = auth.uid());
create policy cdocs_delete_own on contractor_documents for delete using (contractor_id = auth.uid() and status = 'pending');

-- ─────────────────────────────────────────────────────────────
-- contractor_payout  (own only; status admin-only via guard)
-- ─────────────────────────────────────────────────────────────
create policy cpayout_select_own on contractor_payout for select using (contractor_id = auth.uid());
create policy cpayout_insert_own on contractor_payout for insert with check (contractor_id = auth.uid());
create policy cpayout_update_own on contractor_payout for update using (contractor_id = auth.uid()) with check (contractor_id = auth.uid());

-- ─────────────────────────────────────────────────────────────
-- jobs
-- ─────────────────────────────────────────────────────────────
create policy jobs_select_owner on jobs for select using (homeowner_id = auth.uid());
create policy jobs_select_open_for_approved on jobs
  for select using (status = 'open' and is_approved_contractor(auth.uid()));
create policy jobs_select_involved on jobs for select using (
  exists (select 1 from quotes q   where q.job_id = jobs.id and q.contractor_id = auth.uid())
  or exists (select 1 from bookings b where b.job_id = jobs.id and b.contractor_id = auth.uid())
);
create policy jobs_insert_owner on jobs for insert with check (homeowner_id = auth.uid());
create policy jobs_update_owner on jobs for update using (homeowner_id = auth.uid()) with check (homeowner_id = auth.uid());

-- ─────────────────────────────────────────────────────────────
-- quotes  (only APPROVED contractors can create — brief §9)
-- ─────────────────────────────────────────────────────────────
create policy quotes_select_contractor on quotes for select using (contractor_id = auth.uid());
create policy quotes_select_homeowner on quotes for select using (
  exists (select 1 from jobs j where j.id = quotes.job_id and j.homeowner_id = auth.uid())
);
create policy quotes_insert_approved on quotes for insert with check (
  contractor_id = auth.uid()
  and is_approved_contractor(auth.uid())
  and exists (select 1 from jobs j where j.id = quotes.job_id and j.status = 'open')
);
create policy quotes_update_contractor on quotes for update using (contractor_id = auth.uid()) with check (contractor_id = auth.uid());
create policy quotes_update_homeowner on quotes for update using (
  exists (select 1 from jobs j where j.id = quotes.job_id and j.homeowner_id = auth.uid())
);

-- ─────────────────────────────────────────────────────────────
-- bookings  (homeowner creates; both parties read/update their own)
-- Only an approved contractor can be booked — brief §9.
-- ─────────────────────────────────────────────────────────────
create policy bookings_select_party on bookings for select using (
  homeowner_id = auth.uid() or contractor_id = auth.uid()
);
create policy bookings_insert_homeowner on bookings for insert with check (
  homeowner_id = auth.uid() and is_approved_contractor(contractor_id)
);
create policy bookings_update_party on bookings for update using (
  homeowner_id = auth.uid() or contractor_id = auth.uid()
) with check (
  homeowner_id = auth.uid() or contractor_id = auth.uid()
);

-- ─────────────────────────────────────────────────────────────
-- payments  (written ONLY by Edge Functions / service role; clients read their own)
-- ─────────────────────────────────────────────────────────────
create policy payments_select_party on payments for select using (
  contractor_id = auth.uid()
  or exists (
    select 1 from bookings b
    where b.id = payments.booking_id
      and (b.homeowner_id = auth.uid() or b.contractor_id = auth.uid())
  )
);
-- No insert/update/delete policies → only service role can write. Intentional.

-- ─────────────────────────────────────────────────────────────
-- reviews  (publicly readable; written by a party to the booking)
-- ─────────────────────────────────────────────────────────────
create policy reviews_read on reviews for select using (true);
create policy reviews_insert_party on reviews for insert with check (
  rater_id = auth.uid() and (
    (direction = 'homeowner_to_contractor' and exists (
       select 1 from bookings b where b.id = booking_id
         and b.homeowner_id = auth.uid() and b.contractor_id = ratee_id))
    or
    (direction = 'contractor_to_homeowner' and exists (
       select 1 from bookings b where b.id = booking_id
         and b.contractor_id = auth.uid() and b.homeowner_id = ratee_id))
  )
);

-- ─────────────────────────────────────────────────────────────
-- reports  (create + read own; status handled by admin/service role)
-- ─────────────────────────────────────────────────────────────
create policy reports_insert_own on reports for insert with check (reporter_id = auth.uid());
create policy reports_select_own on reports for select using (reporter_id = auth.uid());

-- ─────────────────────────────────────────────────────────────
-- subscriptions  (read own; written by billing Edge Function / service role)
-- ─────────────────────────────────────────────────────────────
create policy subs_select_own on subscriptions for select using (contractor_id = auth.uid());

-- ─────────────────────────────────────────────────────────────
-- Storage buckets + object policies
-- ─────────────────────────────────────────────────────────────
insert into storage.buckets (id, name, public) values
  ('contractor-docs', 'contractor-docs', false),  -- PRIVATE: ID/banking docs. Admin reads via signed URL.
  ('avatars',         'avatars',         true),
  ('job-photos',      'job-photos',      true),
  ('work-photos',     'work-photos',     true)
on conflict (id) do nothing;

-- contractor-docs: owner may upload into their own folder (path = "<uid>/..."); NO read
-- policy for clients, so only the service role (admin) can read, via signed URLs.
create policy docs_insert_own on storage.objects for insert to authenticated
  with check (bucket_id = 'contractor-docs' and (storage.foldername(name))[1] = auth.uid()::text);
create policy docs_delete_own on storage.objects for delete to authenticated
  using (bucket_id = 'contractor-docs' and (storage.foldername(name))[1] = auth.uid()::text);

-- Public-read buckets: anyone can read; only the owner can write into their folder.
create policy public_buckets_read on storage.objects for select
  using (bucket_id in ('avatars', 'job-photos', 'work-photos'));
create policy public_buckets_write_own on storage.objects for insert to authenticated
  with check (bucket_id in ('avatars', 'job-photos', 'work-photos')
              and (storage.foldername(name))[1] = auth.uid()::text);
create policy public_buckets_delete_own on storage.objects for delete to authenticated
  using (bucket_id in ('avatars', 'job-photos', 'work-photos')
         and (storage.foldername(name))[1] = auth.uid()::text);
