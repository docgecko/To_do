// Orelle service worker
//
// Minimal v1: caches the static asset bundle so the app shell loads even
// when offline / on a flaky connection. Doesn't try to cache LiveView
// pages or API requests — those need the network. Doesn't yet handle
// push events (TODO for v2).
//
// The cache name embeds a version. Bumping it on each release ensures
// returning users get the new assets instead of stale ones. Phoenix's
// asset digest already cache-busts at the URL level; this is belt + braces.

const CACHE_VERSION = "orelle-v1";
const RUNTIME_CACHE = `${CACHE_VERSION}-runtime`;

self.addEventListener("install", (event) => {
  // Activate the new SW as soon as it's installed — don't wait for all
  // existing tabs to close (acceptable trade-off for a low-traffic beta).
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  // Sweep old cache versions so storage doesn't accumulate.
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(
        keys
          .filter((k) => k !== RUNTIME_CACHE)
          .map((k) => caches.delete(k))
      )
    ).then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const req = event.request;

  // Only handle same-origin GETs. Skip everything else (LiveView websocket
  // upgrades, R2 avatar URLs, third-party scripts, etc.).
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;

  // Cache strategy depends on the kind of resource:
  //   * /assets/* and /icons/* → cache-first (long-cached, hash-busted by Phoenix)
  //   * /uploads/* → cache-first (R2 URLs, rarely change)
  //   * everything else → network-first (HTML pages need fresh CSRF tokens etc.)
  if (
    url.pathname.startsWith("/assets/") ||
    url.pathname.startsWith("/icons/") ||
    url.pathname.startsWith("/uploads/") ||
    url.pathname === "/manifest.webmanifest"
  ) {
    event.respondWith(cacheFirst(req));
  } else {
    event.respondWith(networkFirstWithFallback(req));
  }
});

async function cacheFirst(req) {
  const cache = await caches.open(RUNTIME_CACHE);
  const hit = await cache.match(req);
  if (hit) return hit;
  try {
    const res = await fetch(req);
    if (res && res.ok) cache.put(req, res.clone());
    return res;
  } catch (e) {
    // Offline and not in cache — nothing we can do.
    return new Response("", { status: 504, statusText: "Offline" });
  }
}

// ---------- Web Push ----------
//
// The server (ToDo.Notifications.create_or_skip → ToDo.PushSubscriptions)
// dispatches a JSON payload through the user's push service whenever a
// new in-app notification is created. The shape matches push_payload/1
// in lib/to_do/notifications.ex:
//   { title, body, tag, url, icon, badge }
self.addEventListener("push", (event) => {
  let payload = {};
  try { payload = event.data?.json() ?? {}; } catch (_) {}

  const title = payload.title || "Orelle";
  const opts = {
    body: payload.body || "",
    tag: payload.tag,            // dedupes if multiple pushes arrive for the same notif
    icon: payload.icon || "/icons/icon-192.png",
    badge: payload.badge || "/icons/icon-192.png",
    data: { url: payload.url || "/today" }
  };

  event.waitUntil(self.registration.showNotification(title, opts));
});

// Tap on a lock-screen notification → focus an existing window if one
// is open at the same URL, otherwise open a new one.
self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const url = event.notification.data?.url || "/today";

  event.waitUntil((async () => {
    const all = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const client of all) {
      // Existing window already open — focus + navigate it
      if ("focus" in client) {
        await client.focus();
        if ("navigate" in client) await client.navigate(url).catch(() => {});
        return;
      }
    }
    if (self.clients.openWindow) await self.clients.openWindow(url);
  })());
});

async function networkFirstWithFallback(req) {
  const cache = await caches.open(RUNTIME_CACHE);
  try {
    const res = await fetch(req);
    if (res && res.ok && req.headers.get("accept")?.includes("text/html")) {
      // Stash a copy of HTML responses so an offline page-load can still
      // show *something* recognisable.
      cache.put(req, res.clone());
    }
    return res;
  } catch (e) {
    const hit = await cache.match(req);
    if (hit) return hit;
    // No cache, no network — give the user a recognisable "offline" page.
    return new Response(
      `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
       <title>Offline — Orelle</title>
       <style>body{font-family:system-ui;background:#0b0c10;color:#e5e5e7;
         display:flex;flex-direction:column;align-items:center;justify-content:center;
         height:100vh;margin:0;padding:1.5rem;text-align:center}
         h1{font-weight:600;margin:0 0 .5rem}p{color:#a1a1aa;max-width:24rem}</style>
       <h1>You're offline</h1>
       <p>Orelle needs a connection to sync your boards. Reconnect and tap to retry.</p>`,
      { status: 503, headers: { "Content-Type": "text/html; charset=utf-8" } }
    );
  }
}
