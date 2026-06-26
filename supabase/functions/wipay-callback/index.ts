// supabase/functions/wipay-callback/index.ts
//
// WiPay redirects the payer's BROWSER here (GET) after the hosted page, with the
// result in the querystring. There is no server-to-server webhook, so we MUST verify
// the MD5 hash before trusting "success". A booking is confirmed only once its
// connection-fee payment is verified paid (brief §7). See docs/wipay-notes.md.
//
// config.toml sets verify_jwt = false for this function (WiPay has no JWT); the hash
// is the authentication. Writes use the service role.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { crypto } from "https://deno.land/std@0.224.0/crypto/mod.ts";

Deno.serve(async (req) => {
  const params = new URL(req.url).searchParams;
  const status = params.get("status");
  const orderId = params.get("order_id");
  const transactionId = params.get("transaction_id");
  const total = params.get("total");
  const hash = params.get("hash");

  if (!orderId) return html("Missing order_id", 400);

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: payment } = await admin
    .from("payments")
    .select("*")
    .eq("wipay_order_id", orderId)
    .single();
  if (!payment) return html("Unknown order", 404);

  // Verify hash for success: md5(transaction_id + total + API_KEY), no separators.
  let verified = false;
  if (status === "success" && transactionId && total && hash) {
    const apiKey = (Deno.env.get("WIPAY_ENVIRONMENT") ?? "sandbox") === "live"
      ? Deno.env.get("WIPAY_API_KEY")!
      : "123"; // WiPay sandbox API key
    const expected = await md5(`${transactionId}${total}${apiKey}`);
    verified = expected.toLowerCase() === hash.toLowerCase();
  }

  const paid = status === "success" && verified;

  // A "success" that fails hash verification is suspicious — keep it pending for
  // manual reconciliation rather than marking it paid.
  const newStatus = paid ? "paid" : status === "success" ? "pending" : "failed";

  await admin
    .from("payments")
    .update({
      status: newStatus,
      wipay_transaction_id: transactionId ?? payment.wipay_transaction_id,
      hash_verified: verified,
      raw: Object.fromEntries(params.entries()),
    })
    .eq("id", payment.id);

  // Confirm the booking once the connection fee is verified paid (brief §7).
  if (paid && payment.type === "connection_fee" && payment.booking_id) {
    await admin
      .from("bookings")
      .update({ status: "active", connection_fee_payment_id: payment.id })
      .eq("id", payment.booking_id);

    const { data: booking } = await admin
      .from("bookings")
      .select("job_id")
      .eq("id", payment.booking_id)
      .single();
    if (booking?.job_id) {
      await admin.from("jobs").update({ status: "booked" }).eq("id", booking.job_id);
    }
  }

  // Send the browser back into the app via deep link.
  const scheme = Deno.env.get("APP_DEEP_LINK") ?? "rentahusband://";
  const deepLink =
    `${scheme}payment-result?status=${paid ? "paid" : status}&order_id=${orderId}`;
  return new Response(null, { status: 302, headers: { Location: deepLink } });
});

async function md5(input: string): Promise<string> {
  const buf = await crypto.subtle.digest("MD5", new TextEncoder().encode(input));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function html(msg: string, status = 200) {
  return new Response(`<html><body>${msg}</body></html>`, {
    status,
    headers: { "Content-Type": "text/html" },
  });
}
