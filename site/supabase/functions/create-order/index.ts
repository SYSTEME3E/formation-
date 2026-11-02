// Vérifie le paiement auprès de Kkiapay, puis donne accès à la formation.
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: { user } } = await asUser.auth.getUser();
    if (!user) return json({ error: "Connexion requise." }, 401);

    const db = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { orderId, transactionId } = await req.json();
    if (!orderId || !transactionId) return json({ error: "Données manquantes." }, 400);

    const { data: order } = await db.from("orders").select("*")
      .eq("id", orderId).eq("user_id", user.id).maybeSingle();
    if (!order) return json({ error: "Commande introuvable." }, 404);
    if (order.status === "paid") return json({ ok: true });
    if (order.status !== "pending") return json({ error: "Commande non valide." }, 400);

    // une transaction ne peut servir qu'une seule fois
    const { data: used } = await db.from("orders").select("id")
      .eq("kkiapay_transaction_id", String(transactionId)).maybeSingle();
    if (used) return json({ error: "Cette transaction a déjà été utilisée." }, 409);

    // vérification auprès de Kkiapay (clés privées : jamais dans le navigateur)
    const sandbox = Deno.env.get("KKIAPAY_SANDBOX") !== "false";
    const base = sandbox ? "https://api-sandbox.kkiapay.me" : "https://api.kkiapay.me";
    const res = await fetch(base + "/api/v1/transactions/status", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-API-KEY": Deno.env.get("KKIAPAY_PUBLIC_KEY")!,
        "X-PRIVATE-KEY": Deno.env.get("KKIAPAY_PRIVATE_KEY")!,
        "X-SECRET-KEY": Deno.env.get("KKIAPAY_SECRET")!,
      },
      body: JSON.stringify({ transactionId }),
    });
    const t = await res.json();
    if (t.status !== "SUCCESS") return json({ error: "Paiement non confirmé par Kkiapay." }, 402);
    if (Number(t.amount) < order.amount_xof) return json({ error: "Montant payé incorrect." }, 402);

    const { error } = await db.from("orders")
      .update({ status: "paid", kkiapay_transaction_id: String(transactionId), paid_at: new Date().toISOString() })
      .eq("id", order.id).eq("status", "pending");
    if (error) throw error;

    await db.from("enrollments").upsert(
      { user_id: user.id, course_id: order.course_id, order_id: order.id },
      { onConflict: "user_id,course_id" },
    );

    if (order.promo_code_id) {
      const { data: p } = await db.from("promo_codes").select("used_count").eq("id", order.promo_code_id).single();
      if (p) await db.from("promo_codes").update({ used_count: p.used_count + 1 }).eq("id", order.promo_code_id);
    }
    return json({ ok: true });
  } catch (e) {
    console.error(e);
    return json({ error: "Erreur serveur." }, 500);
  }
});
