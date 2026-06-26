// supabase/functions/wipay-create-payment/index.ts
//
// Creates a pending `payments` row (service role) and returns a WiPay Hosted Page URL
// for the client to open. The app NEVER talks to WiPay directly — secrets stay here.
// See docs/wipay-notes.md for the WiPay API contract.
//
// Env (set with `supabase secrets set`): WIPAY_ENVIRONMENT (sandbox|live),
// WIPAY_ACCOUNT_NUMBER, WIPAY_API_KEY. SUPABASE_URL / SUPABASE_ANON_KEY /
// SUPABASE_SERVICE_ROLE_KEY are injected automatically.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

// tt. host for a TT-verified account (docs/wipay-notes.md).
const WIPAY_REQUEST_URL = "https://tt.wipayfinancial.com/plugins/payments/request";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const { booking_id, type = "connection_fee", amount, currency = "TTD" } =
      await req.json();
    if (!amount) return json({ error: "amount is required" }, 400);

    // Identify the caller from their JWT.
    const userClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
    );
    const { data: { user } } = await userClient.auth.getUser();
    if (!user) return json({ error: "unauthorized" }, 401);

    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const environment = Deno.env.get("WIPAY_ENVIRONMENT") ?? "sandbox";
    // Sandbox uses WiPay's fixed test account number (docs/wipay-notes.md).
    const accountNumber = environment === "sandbox"
      ? "1234567890"
      : Deno.env.get("WIPAY_ACCOUNT_NUMBER")!;

    const orderId = `rah-${crypto.randomUUID().slice(0, 8)}-${Date.now().toString().slice(-8)}`;

    // Create the pending payment. Clients cannot write `payments` (RLS) — only here.
    const { data: payment, error } = await admin
      .from("payments")
      .insert({
        booking_id: booking_id ?? null,
        contractor_id: type === "subscription" ? user.id : null,
        type,
        amount,
        currency,
        wipay_order_id: orderId,
        status: "pending",
      })
      .select()
      .single();
    if (error) return json({ error: error.message }, 500);

    const responseUrl = `${Deno.env.get("SUPABASE_URL")}/functions/v1/wipay-callback`;
    const body = new URLSearchParams({
      account_number: accountNumber,
      country_code: "TT",
      currency,
      environment,
      fee_structure: "customer_pay", // homeowner covers WiPay's cut (docs/wipay-notes.md §5)
      method: "credit_card",
      order_id: orderId,
      origin: "rent-a-husband",
      response_url: responseUrl,
      total: Number(amount).toFixed(2),
      avs: "0",
    });

    const wipayRes = await fetch(WIPAY_REQUEST_URL, {
      method: "POST",
      headers: {
        "Accept": "application/json",
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body,
    });
    const wipay = await wipayRes.json();

    if (!wipay?.url) {
      await admin.from("payments").update({ status: "failed", raw: wipay }).eq("id", payment.id);
      return json({ error: "wipay_error", detail: wipay }, 502);
    }

    await admin
      .from("payments")
      .update({ wipay_transaction_id: wipay.transaction_id ?? null })
      .eq("id", payment.id);

    // Client opens this URL (e.g. expo-web-browser) to complete payment.
    return json({ url: wipay.url, payment_id: payment.id, order_id: orderId });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});

function json(b: unknown, status = 200) {
  return new Response(JSON.stringify(b), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
