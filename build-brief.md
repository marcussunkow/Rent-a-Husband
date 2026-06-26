# Rent a Husband — V1 Build Brief

A two-sided marketplace connecting Trinidad & Tobago homeowners with vetted handymen and contractors for small jobs. This brief is written to be handed directly to **Claude Code** and built in phases.

---

## 1. Product summary

- **What:** "Uber for home repairs." Homeowners post jobs; handymen quote/accept, do the work, get rated. Two-way reviews.
- **Who:** Homeowners (demand) + handymen/contractors (supply). Both register.
- **Where:** Launch in **one zone in Trinidad** first, then expand across T&T, then the wider CARICOM region.
- **Currency:** TTD (primary), with USD support kept in mind for later regional rollout.

---

## 2. V1 scope — locked decisions

These are settled. Build to exactly this, not more:

1. **Payment:** Job is paid either **in-app (WiPay)** or **cash on completion**. The homeowner chooses.
2. **No escrow** in v1. No holding/releasing funds. (Revisit only if the app proves out.)
3. **Job type:** Small handyman jobs first. No large multi-stage contracting yet.
4. **One launch zone.** The app supports geography from day one, but go-to-market is a single town/cluster.
5. **Revenue is cash-proof** — it does not depend on money flowing through the app (see §7).

---

## 3. Tech stack

Chosen for a solo/small builder working with Claude Code: one mobile codebase, a managed backend, and a Caribbean-friendly payment rail.

| Layer | Choice | Why |
|---|---|---|
| Mobile app | **React Native + Expo (TypeScript)** | One codebase → iOS + Android. Claude Code is strong here. Fast OTA updates via EAS. |
| Backend / DB / Auth / Storage | **Supabase** (Postgres, Auth, Storage, Edge Functions, Row-Level Security) | Auth, database, file storage, and serverless functions in one place. RLS cleanly enforces the two-role security model. Postgres = you own your data. |
| Payments | **WiPay** (Hosted Payment Page) via a Supabase Edge Function | Caribbean-native, supports TTD/USD, works in T&T where Stripe Connect does not. |
| Maps / location | Expo Location + a map component + a geocoding API key | Job location, contractor service areas, distance. |
| Push notifications | Expo Notifications | New job alerts, quote received, job status changes. |
| Admin (early) | **Supabase Studio** at first; a small **Next.js** dashboard later | Manual verification + dispute handling without building admin UI on day one. |
| App builds / distribution | **EAS Build** | Ships to App Store + Play Store from the Expo project. |

---

## 4. Architecture overview

```
[ React Native / Expo app ]
        |  (Supabase JS client: auth, DB reads/writes, storage, realtime)
        v
[ Supabase ]
   - Postgres (data + RLS policies)
   - Auth (email/phone)
   - Storage (ID docs, work photos, certificates)
   - Edge Functions:
       * wipay-create-payment   (build a payment request, return redirect URL)
       * wipay-callback         (receive WiPay result, mark payment paid)
       * (later) subscriptions, payouts reconciliation
        |
        v
[ WiPay Hosted Payment Page ]  <- card entry happens here, then redirects back
```

Key principle: the app **never** talks to WiPay directly with secrets. All payment creation and callback verification runs server-side in Edge Functions.

---

## 5. Data model (core tables)

Build these in Postgres. Names are suggestions; keep them consistent.

- **profiles** — one row per user. `id` (=auth user), `role` (`homeowner` | `contractor`), `full_name`, `phone`, `phone_verified`, `email`, `avatar_url`, `created_at`.
- **contractor_profiles** — `user_id`, `bio`, `skills` (array / join table), `service_areas`, `onboarding_status` (`incomplete`|`submitted`|`approved`|`rejected`|`suspended`), `rating_avg`, `jobs_completed`, `subscription_tier` (`free`|`pro`). (Verification details live in `contractor_documents`; payout details in `contractor_payout`.)
- **contractor_documents** — one row per uploaded document. `id`, `contractor_id`, `doc_type` (`gov_id_front`|`gov_id_back`|`selfie`|`proof_of_address`|`cert_of_character`|`trade_cert`|`insurance`), `storage_path` (private bucket), `status` (`pending`|`approved`|`rejected`), `rejection_reason`, `expires_at` (for things like certs), `reviewed_by`, `reviewed_at`, `created_at`.
- **contractor_payout** — payout/banking destination. `contractor_id`, `method` (`bank`|`wipay`), `bank_name`, `account_name`, `account_last4`, `account_token` (see §8 — store a token/reference, **not** the raw account number where avoidable), `status` (`unverified`|`verified`), `created_at`. One row per contractor; sensitive.
- **categories** — e.g. plumbing, electrical, carpentry, painting, AC, general. Seed data.
- **jobs** — `id`, `homeowner_id`, `category_id`, `title`, `description`, `photos` (array), `location` (lat/lng + area), `preferred_time`, `budget_optional`, `status` (`open`|`booked`|`completed`|`cancelled`), `created_at`.
- **quotes** — `id`, `job_id`, `contractor_id`, `amount`, `message`, `status` (`pending`|`accepted`|`declined`), `created_at`.
- **bookings** — `id`, `job_id`, `contractor_id`, `homeowner_id`, `agreed_amount`, `connection_fee_payment_id`, `payment_method` (`in_app`|`cash`), `status` (`active`|`completed`|`cancelled`), `created_at`.
- **payments** — `id`, `booking_id`, `type` (`connection_fee`|`job_payment`|`subscription`), `amount`, `currency`, `wipay_transaction_id`, `status` (`pending`|`paid`|`failed`), `created_at`.
- **reviews** — `id`, `booking_id`, `rater_id`, `ratee_id`, `direction` (`homeowner_to_contractor`|`contractor_to_homeowner`), `stars`, `comment`, `created_at`.
- **reports** — `id`, `reporter_id`, `target_type`, `target_id`, `reason`, `status`, `created_at`. (Manual review.)
- **subscriptions** — `id`, `contractor_id`, `tier`, `status`, `current_period_end`, `wipay_reference`.

---

## 6. Core user flows

1. **Register & onboard** — pick role on signup. Contractors complete a **gated onboarding** (ID front/back, selfie, proof of address, Certificate of Character, banking/payout, skills, service areas, work photos) → status `submitted` → you approve → `approved`. Only then can they quote or be booked. Homeowners: phone/email verify only.
2. **Post a job** (homeowner) — category, description, photos, location, timing, optional budget → status `open`.
3. **Quote / accept** (contractor) — see nearby open jobs in their categories/areas, send a quote (or instant-accept fixed-price tasks).
4. **Book** (homeowner) — pick a contractor → **connection fee charged at this moment** (see §7) → booking created, contractors notified.
5. **Do the work** → homeowner marks **completed**, chooses **pay in-app (WiPay)** or **cash**.
6. **Review** — both sides rate each other; ratings update contractor average.
7. **Report/dispute** — either party can flag; handled manually by you early on.

---

## 7. Monetization (cash-proof) — implementation notes

Because cash is allowed, **do not depend on commission.** Revenue comes from points that fire regardless of how the job is ultimately paid:

- **Connection fee (primary hook):** a small fixed fee (e.g. a few TTD) charged to the **homeowner at the moment of booking**, via the WiPay Hosted Payment Page, *before* the job happens. This is your cash-proof revenue. Implement in `wipay-create-payment`; booking is confirmed only after `wipay-callback` marks it paid.
- **Contractor subscription:** `free` tier (listed, capped lead volume/visibility) vs `pro` tier (more leads, higher placement). Enforce limits in queries/RLS based on `subscription_tier`. Bill monthly via WiPay.
- **In-app payment commission (upside only):** when the homeowner pays the job in-app, take a %. Track in `payments`. Make in-app payment *attractive* (a "verified paid" badge, dispute support) so people opt into it over time.
- **Featured placement:** contractors pay to rank higher within a category/area.

> **Note on WiPay & "authorize now, capture later":** WiPay's standard model is a hosted page redirect, not necessarily a pre-auth/hold. For v1, treat the connection fee as an **immediate small charge at booking**, not a hold. Confirm card-on-file / pre-auth support in WiPay's developer docs before designing anything that depends on it (see §13).

---

## 8. Trust, safety & contractor onboarding

This is the actual product — you're sending a stranger into someone's home, and (eventually) moving money to them. Onboarding is not a form; it's a **gate**. A contractor cannot appear in search, quote, or be booked until `onboarding_status = approved`.

### 8.1 What every contractor must submit

- **Government ID** — front and back (national ID, driver's permit, or passport).
- **Selfie / liveness photo** — to match against the ID (manual eyeball match at first).
- **Proof of address** — recent utility bill or bank statement (e.g. within 3 months), name + address must match the ID.
- **Certificate of Character (TTPS)** — the trust centrepiece for letting someone into a home.
- **Banking / payout details** — needed before any in-app payout can be made (see §8.3).
- **Skills + service areas**, **past-work photos**, and optionally **trade certs / insurance** and references.

### 8.2 Onboarding state machine

```
incomplete  -> submitted  -> approved   (can take jobs)
                         \-> rejected    (reason shown, can resubmit)
approved    -> suspended  (manual, e.g. after a serious report)
```

- `incomplete`: signed up, hasn't uploaded everything required.
- `submitted`: all required docs in → enters your review queue.
- `approved`: you've verified ID, address, and Certificate of Character. Now visible/bookable.
- `rejected`: with a reason; contractor can fix and resubmit.
- `suspended`: pulled from the marketplace pending investigation.

Each document in `contractor_documents` is approved/rejected individually, so you can tell a contractor exactly what to fix. Verification is **manual** in v1 (you, via Supabase Studio); don't build automated ID-matching yet.

### 8.3 Handling sensitive data (do this carefully)

Banking details and ID documents are the highest-risk data in the whole app. Rules:

- Store all documents in a **private Supabase Storage bucket** — never public URLs. Serve via short-lived signed URLs to admin only.
- For banking, **prefer storing a token/reference from WiPay over the raw account number.** If you must store account details, store only what you need (e.g. `account_last4`) and encrypt the rest at rest. Confirm what WiPay supports for holding payout destinations (see §13).
- `contractor_documents` and `contractor_payout` are readable **only** by the service role / admin — enforced in RLS, not just the UI. The owning contractor can see their *status*, not re-read raw files of others, and never another contractor's data.
- You're collecting personal data of T&T residents — treat the **Data Protection Act** as a real obligation. Have a privacy policy, collect only what you need, and define a retention/deletion path for rejected or departed contractors.

### 8.4 Ongoing trust

- **Two-way ratings + reviews**, visible on profiles.
- **Report/flag button** on profiles and bookings → can drive a contractor to `suspended`.
- **Manual dispute handling** at first — you, by hand, via Supabase Studio. Don't build automated dispute tooling in v1.
- **Homeowners:** lighter — phone/email verification only. Keep the friction on the supply side, where it matters.

---

## 9. Security — roles & RLS

The two-role model lives or dies on **Row-Level Security**. Enforce in Postgres, not just the app:

- A homeowner can read/write only their own jobs, bookings, and reviews they authored.
- A contractor can read open jobs in their service areas/categories; write only their own quotes and profile.
- **`contractor_documents` and `contractor_payout` are readable only by the owner (status only) and the admin/service role — raw files and account details never readable by other users.** Document files live in a private bucket served via signed URLs to admin only.
- **Only an `approved` contractor can create quotes or be booked** — enforce this gate in RLS / function logic, not just by hiding buttons.
- Nobody reads another user's ID docs or certificates except admin.
- Payment rows are written only by Edge Functions (service role), never by the client.
- `onboarding_status`, document `status`, verification, and subscription tier are writable only by admin/service role — never self-set.

---

## 10. Phased build plan

Build in this order. Each phase should be runnable before the next.

- **Phase 0 — Foundations:** Expo app scaffold, Supabase project, auth (email/phone), role selection, profiles, private storage buckets, base navigation. RLS from the start.
- **Phase 1 — The core loop:** post job → see jobs → quote → book → **connection fee via WiPay** → mark complete (cash or in-app choice). Wire the `onboarding_status = approved` gate now even if approval is still manual/seeded, so the loop is built correctly from day one.
- **Phase 2 — Contractor onboarding & trust (key pillar):** full document upload (ID front/back, selfie, proof of address, Certificate of Character, banking/payout), the submitted→approved→rejected review queue in Supabase Studio, two-way reviews, ratings on profiles, report button, suspend flow.
- **Phase 3 — Monetization depth:** in-app WiPay job payment + commission tracking, contractor subscriptions, featured placement.
- **Phase 4 — Launch polish:** push notifications, maps/distance, empty/error states, single-zone launch config, basic admin dashboard.

---

## 11. How to build this with Claude Code

**Suggested repo layout (monorepo):**

```
rent-a-husband/
  app/                # Expo React Native app (TypeScript)
    src/
      screens/
      components/
      lib/supabase.ts
      navigation/
  supabase/
    migrations/       # SQL: tables + RLS policies
    functions/
      wipay-create-payment/
      wipay-callback/
    seed.sql          # categories, launch-zone config
  docs/
    build-brief.md    # this file
  .env.example
```

**Sequencing prompts to Claude Code:**

1. "Scaffold an Expo + TypeScript app and a Supabase project structure per `docs/build-brief.md`. Set up the Supabase client and auth with role selection."
2. "Write Postgres migrations for the data model in §5, including RLS policies per §9. Add `seed.sql` for categories."
3. "Build Phase 1 screens and logic: post job, job feed, quote, booking, and the connection-fee payment flow via a `wipay-create-payment` Edge Function + `wipay-callback`."
4. Then Phase 2, 3, 4 in turn — one phase per working session, test before moving on.

**Tips:**
- Keep WiPay keys and the Supabase service role key **only** in Edge Functions / server env — never in the app bundle.
- Have Claude Code write RLS tests; a marketplace with broken RLS leaks every user's data.
- Build one full vertical slice (post → book → pay → review) before widening features.

---

## 12. Third-party setup checklist

- [ ] Supabase project (free tier fine to start)
- [ ] WiPay **verified business account** + API keys (business account required for API access)
- [ ] Expo / EAS account
- [ ] Maps/geocoding API key
- [ ] Apple Developer + Google Play Console accounts (for store release)
- [ ] A registered business entity for the WiPay account + app store listings

---

## 13. Open questions — confirm before coding

1. **WiPay API capabilities:** Does it support card-on-file / pre-auth, or only immediate charges via the hosted page? Recurring billing for subscriptions? This decides the connection-fee and subscription mechanics.
2. **Certificate of Character flow:** confirm the TTPS process and what you can reasonably require of contractors at signup vs. after first job.
3. **Banking/payout storage:** does WiPay let you store a payout destination as a token/reference so you avoid holding raw bank account numbers? This decides how `contractor_payout` is built.
4. **Data Protection Act (T&T):** privacy policy, lawful basis for collecting ID/banking data, and a retention/deletion policy for rejected or departed contractors.
5. **Connection fee amount:** what's low enough not to deter booking but worth collecting?
6. **Launch zone:** which specific town/cluster? This sets your supply-recruitment target.
7. **Cancellation policy:** is the connection fee refundable if a booking is cancelled, and by whom?

---

## 14. Explicitly OUT of scope for v1

- Escrow / holding funds
- Large multi-stage contracting jobs
- Automated dispute resolution
- In-app chat (use phone numbers post-booking at first, if acceptable)
- Multi-country / multi-currency rollout
- Native admin app (use Supabase Studio)

---

*Build the single vertical slice first. Recruit handymen in one zone before any homeowner marketing. Density beats coverage.*
