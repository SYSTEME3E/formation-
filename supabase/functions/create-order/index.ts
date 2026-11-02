// Crée une commande "pending" avec le prix calculé côté serveur.
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
    const { slug, promo } = await req.json();

    const { data: course } = await db.from("courses").select("id, price_xof")
      .eq("slug", String(slug)).eq("is_published", true).maybeSingle();
    if (!course) return json({ error: "Formation introuvable." }, 404);

    const { data: owned } = await db.from("enrollments").select("id")
      .eq("user_id", user.id).eq("course_id", course.id).maybeSingle();
    if (owned) return json({ error: "Tu as déjà accès à cette formation." }, 409);

    let amount: number = course.price_xof;
    let promoId: string | null = null;
    if (promo) {
      const { data: p } = await db.from("promo_codes").select("*")
        .eq("code", String(promo).trim().toUpperCase()).eq("is_active", true).maybeSingle();
      const ok = p && (!p.expires_at || new Date(p.expires_at) > new Date()) &&
        (p.max_uses == null || p.used_count < p.max_uses);
      if (!ok) return json({ error: "Code promo invalide ou expiré." }, 400);
      amount = Math.round(amount * (100 - p.percent_off) / 100);
      promoId = p.id;
    }

    const free = amount === 0;
    const { data: order, error } = await db.from("orders").insert({
      user_id: user.id, course_id: course.id, amount_xof: amount, promo_code_id: promoId,
      status: free ? "paid" : "pending", paid_at: free ? new Date().toISOString() : null,
    }).select("id").single();
    if (error) throw error;

    if (free) {
      await db.from("enrollments").upsert(
        { user_id: user.id, course_id: course.id, order_id: order.id },
        { onConflict: "user_id,course_id" },
      );
    }
    return json({ orderId: order.id, amount, free });
  } catch (e) {
    console.error(e);
    return json({ error: "Erreur serveur." }, 500);
  }
});
