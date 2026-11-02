// Serves the site and injects the Supabase address and public key from Cloudflare Secrets (never stored in GitHub).
export default {
  async fetch(request, env) {
    const url = new URL(request.url)
    if (url.pathname === '/config.js') {
      const cfg = { url: env.SUPABASE_URL, key: env.SUPABASE_ANON_KEY }
      return new Response('window.CFG=' + JSON.stringify(cfg), {
        headers: { 'content-type': 'application/javascript; charset=utf-8', 'cache-control': 'no-store' },
      })
    }
    return env.ASSETS.fetch(request)
  },
}
