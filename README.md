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

The `app/` and `supabase/` trees are created by Claude Code in Phase 0 — see the build plan in the brief.

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
