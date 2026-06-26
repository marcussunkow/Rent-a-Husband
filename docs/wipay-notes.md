# WiPay integration notes — answers to brief §13

Researched from the official **WiPay Payments API Documentation v1.0.8 (23/12/2024)**
(`https://wipaycaribbean.com/WiPay-API-Documentation.pdf`) plus WiPay's site. These
answers drive the connection-fee, subscription, and payout design. Re-confirm against
the live docs before launch — WiPay changes things.

## TL;DR for the build

- WiPay is a **Hosted Payment Page only**. No card-on-file, no tokenization, no
  pre-auth/hold, no capture-later, no recurring/auto-billing API. Every charge is an
  **immediate payment** completed by the payer on WiPay's hosted page.
- This **confirms the brief's core assumption**: the connection fee is an immediate
  small charge to the homeowner at booking, not a hold.
- The "callback" is a **browser GET redirect** to your `response_url`, not a
  server-to-server webhook. You **must verify the MD5 hash** to trust it.
- **WiPay only pays out to YOUR merchant bank account.** There is no API to store a
  *contractor's* payout destination as a token. This changes §8.3 (see Payouts below).

## The one endpoint

`POST https://tt.wipayfinancial.com/plugins/payments/request`
(use the `tt.` host for a TT-verified account; `bb.`/`gy.`/`jm.` exist for other countries)

- Content-Type: `application/x-www-form-urlencoded`
- Send header `Accept: application/json` to get a JSON response instead of an auto-redirect.

**Required body params:** `account_number`, `country_code` (TT), `currency` (TTD),
`environment` (`sandbox` | `live`), `fee_structure` (`customer_pay` | `merchant_absorb`
| `split`), `method` (`credit_card`), `order_id` (your unique id, alphanumeric, ≤48 chars
FAC), `origin` (your app id), `response_url`, `total` (2 dp).
**Optional:** `card_type`, `avs` + AVS pre-fill fields (`fname`, `lname`, `email`,
`phone`, address…), `version`, `data` (echoed back in the response).

**Success JSON response:**
```json
{ "url": "<hosted_page_url>", "message": "<status>", "transaction_id": "<id>" }
```
Redirect the user's browser to `url`. Sandbox API key is `123`; sandbox account number
is `1234567890`.

## The response / "callback"

After the payer finishes, WiPay does a **GET web-redirect to your `response_url`** with
the result appended as a querystring. Key response params:

- `status` — `success` | `failed` | `error`
- `transaction_id`, `order_id`, `total`, `currency`, `card` (last 4 only), `date`
- `message` — e.g. `[1-R1]: Transaction is approved.`
- `hash` — **present on `success` only**

**Verify every success:** `hash == md5(transaction_id + total + API_KEY)` (concatenated
in that order, no separators). If it doesn't match, do **not** mark the payment paid.

Because this is a browser redirect (the user could close the tab before it fires), treat
the DB write as the source of truth and design for the missing-redirect case: WiPay says
transaction recovery turns over in ≤5 min, but this API doc exposes **no status-query
endpoint**, so build a manual/assisted reconciliation path (check the WiPay dashboard)
for stuck `pending` payments. Flag for Claude Code.

## Answers to §13

1. **Card-on-file / pre-auth / recurring?** No to all. Hosted page, immediate charge
   only. → Connection fee = immediate charge at booking. Subscriptions can't auto-bill.
2. **Certificate of Character (TTPS):** out of WiPay's scope — unchanged, manual.
3. **Payout-token storage?** **No.** WiPay pays out only to the merchant's (your) bank
   account, via manual Withdraw in the dashboard (3–7 business days). There is no token
   for a contractor's bank account. → For v1, in-app job payments land in **your** WiPay
   balance and you pay contractors **out-of-band**. Keep `contractor_payout` minimal and
   encrypted; do not pretend a WiPay payout token exists. Consider deferring payouts.
4. **Data Protection Act (T&T):** unchanged — still your obligation.
5. **Connection fee amount:** WiPay minimum charge is **$1.00 USD-equivalent** (~TTD 6.80
   at WiPay's static 6.80 rate). TT fees are **3.5% + US$0.25** (free plan) or
   **3.0% + US$0.25** (paid plan) per transaction. The fixed ~US$0.25 means a tiny
   connection fee is mostly eaten by fees — price the fee with that in mind, and use
   `fee_structure = customer_pay` so the homeowner covers WiPay's cut.
6. **Launch zone:** business decision, unchanged.
7. **Cancellation/refund:** WiPay refunds are **manual** (handled in the dashboard), no
   refund API here. So connection-fee refund policy must be operated by hand in v1.

## Implications baked into this repo

- `supabase/functions/wipay-create-payment` builds the POST, returns `url`.
- `supabase/functions/wipay-callback` parses the GET querystring, recomputes the MD5
  hash, and (service role) marks `payments` paid + confirms the `booking`.
- Subscriptions (`subscription_tier = pro`) are modelled, but billing is a **monthly
  assisted charge** (re-send the hosted page each period) — not auto-recurring. Don't
  build auto-charge against this API.
- Only Visa/Mastercard, no Amex; base currency TTD.
