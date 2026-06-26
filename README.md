# Rent a Husband

A two-sided marketplace connecting **Trinidad & Tobago** homeowners with vetted handymen and contractors for small jobs. "Uber for home repairs": homeowners post jobs, handymen quote and accept, the work gets done, and both sides rate each other.

This repository is the **build hand-off for Claude Code**. The full specification lives in [`docs/build-brief.md`](docs/build-brief.md). Read it before writing any code — and read [`CLAUDE.md`](CLAUDE.md) for working conventions and guardrails.

## Stack

- **Mobile:** React Native + Expo (TypeScript), one codebase for iOS + Android, OTA updates via EAS.
- **Backend:** Supabase — Postgres, Auth, Storage, Edge Functions, Row-Level Security.
- **Payments:** WiPay Hosted Payment Page, called only from Supabase Edge Functions (never from the app with secrets).
- **Admin (early):** Supabase Studio; a small Next.js dashboard later.

## Repo layout (target)

```
rent-a-husband/
  app/                # Expo React Native app (TypeScript)
  supabase/
    migrations/       # SQL: tables + RLS policies
    functions/
      wipay-create-payment/
      wipay-callback/
    seed.sql          # categories, launch-zone config
  docs/
    build-brief.md    # the full specification
  .env.example
```

## Backend foundation — already built

The Supabase backend for Phases 0–1 is scaffolded in this repo, ready to apply:

- `supabase/migrations/0001_init_schema.sql` — all core tables, enums, indexes, rating triggers (brief §5).
- `supabase/migrations/0002_rls_policies.sql` — full Row-Level Security, privileged-column guard triggers, and private/public storage buckets (brief §9). SQL validated against the Postgres grammar; run `supabase db reset` to apply and verify end-to-end.
- `supabase/seed.sql` — job categories + launch-zone row (brief §11).
- `supabase/functions/wipay-create-payment` + `wipay-callback` — the WiPay payment flow, built to WiPay's real API (see `docs/wipay-notes.md`).
- `docs/wipay-notes.md` — answers to the brief §13 open questions from WiPay's official docs.

Claude Code still creates the `app/` (Expo) tree and wires the screens to this backend.

## Phased build plan

- **Phase 0 — Foundations:** Expo scaffold, Supabase project, auth + role selection, profiles, private storage buckets, base navigation, RLS from the start.
- **Phase 1 — Core loop:** post job → see jobs → quote → book → connection fee via WiPay → mark complete (cash or in-app).
- **Phase 2 — Contractor onboarding & trust:** document upload, the submitted→approved→rejected review queue, two-way reviews, ratings, report/suspend.
- **Phase 3 — Monetization depth:** in-app WiPay job payment + commission, subscriptions, featured placement.
- **Phase 4 — Launch polish:** push notifications, maps/distance, error states, single-zone config, admin dashboard.

## Getting started with Claude Code

1. Clone this repo and open it in Claude Code.
2. Point Claude Code at `docs/build-brief.md` and work one phase per session, testing before moving on.
3. Suggested first prompt:
   > "Read `docs/build-brief.md` and `CLAUDE.md`. Scaffold the Expo + TypeScript app and the Supabase project structure (Phase 0). Set up the Supabase client and auth with role selection. Don't start Phase 1 yet."

Copy `.env.example` to `.env` and fill in real keys locally — never commit `.env`.

## Open questions to confirm before coding

See §13 of the brief. The biggest ones: WiPay API capabilities (card-on-file / pre-auth / recurring), Certificate of Character flow, payout-token storage, and Data Protection Act (T&T) obligations.
