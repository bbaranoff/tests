// Sert le dossier qmd rendu (public/). Si le secret PASSWORD est défini
// (wrangler secret put PASSWORD), l'accès passe par une authentification Basic.
export default {
  async fetch(request, env) {
    if (env.PASSWORD) {
      const auth = request.headers.get("Authorization") || "";
      const [scheme, b64] = auth.split(" ");
      let ok = false;
      if (scheme === "Basic" && b64) {
        try { ok = atob(b64).split(":").slice(1).join(":") === env.PASSWORD; } catch {}
      }
      if (!ok) {
        return new Response("Authentification requise", {
          status: 401,
          headers: { "WWW-Authenticate": 'Basic realm="dossier", charset="UTF-8"' },
        });
      }
    }
    const res = await env.ASSETS.fetch(request);
    const out = new Response(res.body, res);
    out.headers.set("X-Robots-Tag", "noindex");
    out.headers.set("Cache-Control", "private, max-age=300");
    return out;
  },
};
