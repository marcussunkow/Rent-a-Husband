# CLAUDE.md — working guide for Claude Code

This file orients Claude Code on **how** to build Rent a Husband. The **what** is in [`docs/build-brief.md`](docs/build-brief.md) — treat that brief as the source of truth and re-read the relevant section before each phase.

## Build order

Build strictly in phases (brief §10). Each phase must be runnable and tested before the next.

- **Phase 0** — Foundations: Expo scaffold, Supabase project structure, auth + role selection, profiles, private storage buckets, base navigation. **RLS from the start.**
- **Phase 1** — Core loop: post job → job feed → quote → book → connection fee (WiPay) → mark complete (cash or in-app). Wire the `onboarding_status = approved` gate now, even if approval is seeded manually.
- **Phase 2** — Contractor onboarding & trust: document upload, review queue, two-way reviews, ratings, report/suspend.
- **Phase 3** — Monetization depth: in-app WiPay job payment + commission, subscriptions, featured placement.
- **Phase 4** — Launch polish: push, maps/distance, error states, single-zone config, admin dashboard.

Build one full vertical slice (post → book → pay → review) before widening features.

## Non-negotiable guardrails

- **Secrets stay server-side.** WiPay keys and the Supabase service-role key live **only** in Edge Functions / server env. Never in the app bundle, never in client code, never committed.
- **RLS is the security model, not the UI.** Enforce every access rule in Postgres Row-Level Security (brief §9), not by hiding buttons. A marketplace with broken RLS leaks every user's data. Write RLS tests.
- **Only `approved` contractors can quote or be booked** — enforce in RLS / function logic.
- **Payment rows are written only by Edge Functions** (service role), never by the client.
- **`onboarding_status`, document `status`, verification, subscription tier** are writable only by admin/service role — never self-set.
- **Sensitive data** (ID docs, banking) goes in a **private** Storage bucket, served via short-lived signed URLs to admin only. Prefer storing a WiPay payout token over raw bank account numbers. Treat the T&T Data Protection Act as a real obligation.

## Payments

- The app never talks to WiPay directly. All payment creation and callback verification run in Edge Functions: `wipay-create-payment` and `wipay-callback`.
- The **connection fee** is an immediate small charge to the homeowner at booking (not a pre-auth/hold). A booking is confirmed only after `wipay-callback` marks the payment `paid`.
- Confirm WiPay's API capabilities (card-on-file, pre-auth, recurring billing) before building anything that depends on them — see brief §13.

## Conventions

- TypeScript throughout the app.
- Keep table/column names consistent with brief §5.
- Seed `categories` and launch-zone config via `supabase/seed.sql`.
- Commit `.env.example` only; never commit `.env`.

## Out of scope for v1 (do not build)

Escrow / holding funds, large multi-stage contracting, automated dispute resolution, in-app chat, multi-country/multi-currency, native admin app. See brief §14.
