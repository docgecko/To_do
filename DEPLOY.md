# Deploying Orelle to Fly.io

End-to-end first-time deployment. Covers creating the Fly app, provisioning
Tigris storage, configuring Resend for transactional email, and launching.

## 0. Prerequisites

- `flyctl` installed (`brew install flyctl`) and logged in (`flyctl auth login`).
- Turso credentials at hand. They're already stored in `.envrc`; you'll be
  copying them into Fly secrets, not sharing them anywhere else.
- A Resend account (`resend.com`) with a verified sending domain. Note its
  API key — you'll need it for `RESEND_API_KEY`.

## 1. Create the Fly app

```sh
flyctl apps create orelle --org personal
```

If `orelle` is taken, pick another name and update `app = ` in `fly.toml`
plus `PHX_HOST` in `[env]` to match.

## 2. Provision Cloudflare R2 storage for avatars

The avatar storage code talks to anything S3-compatible. We're using R2
because the egress is free and the free tier (10 GB / 10M reads / 1M writes
per month) easily covers the avatar workload.

### 2a. Create the bucket

In the Cloudflare dashboard → **R2** → **Create bucket**:

- **Name:** `orelle` (the avatars live under an `avatars/` key prefix
  that the app adds automatically — no need to bake "avatars" into the
  bucket name; if you ever store something else here later you'll
  appreciate the room)
- **Location:** Eastern Europe (matches `lhr` and Turso `eu-west-1`) — or
  whatever's closest
- **Default storage class:** Standard

### 2b. Enable public access

We want `<img src=...>` to work without signed URLs.

In the bucket → **Settings** → **Public access** → **R2.dev subdomain** →
**Allow Access**. Cloudflare gives you a URL like
`https://pub-3b8e4b5a1f2c4d8e9b3f6a7c2d1e0f5b.r2.dev`. **Save that** — it
goes into the `S3_PUBLIC_BASE` env below.

(Alternative: attach a custom domain like `avatars.orelle.app`. Better URLs
but more setup; skip for v1.)

### 2c. Generate API credentials

Cloudflare dashboard → **R2** → **Manage R2 API Tokens** → **Create API
Token**:

- **Permissions:** *Object Read & Write* on `orelle` only (principle of
  least privilege — the token can't hose other buckets)
- **TTL:** No expiry (or rotate annually if you want)

Cloudflare prints the credentials **once**. Capture:

- **Access Key ID** — goes into `S3_ACCESS_KEY_ID`
- **Secret Access Key** — goes into `S3_SECRET_ACCESS_KEY`
- **Endpoint** — `<account-id>.r2.cloudflarestorage.com` — goes into
  `S3_ENDPOINT`

### 2d. Set the secrets on Fly

```sh
flyctl secrets set \
  S3_BUCKET=orelle \
  S3_ENDPOINT=<account-id>.r2.cloudflarestorage.com \
  S3_PUBLIC_BASE=https://pub-<hash>.r2.dev \
  S3_REGION=auto \
  S3_ACCESS_KEY_ID=<from-token-creation> \
  S3_SECRET_ACCESS_KEY=<from-token-creation> \
  --app orelle
```

Substitute the `<account-id>` and `<hash>` values you captured above.

## 3. Configure secrets

The remaining secrets the runtime needs:

```sh
flyctl secrets set \
  SECRET_KEY_BASE=$(mix phx.gen.secret) \
  PHX_HOST=orelle.fly.dev \
  TURSO_DATABASE_URL=libsql://orelle-docgecko.aws-eu-west-1.turso.io \
  TURSO_AUTH_TOKEN=<paste-from-.envrc> \
  RESEND_API_KEY=<from-resend-dashboard> \
  --app orelle
```

> **Heads-up:** the Turso auth token is the same one in your local
> `.envrc`. Don't commit either it or `.envrc` (already gitignored).

## 4. First deploy

```sh
flyctl deploy --app orelle
```

The Dockerfile is multi-stage. First deploy takes ~5 minutes (full deps
compile + asset digest + release build). Subsequent deploys cache the deps
layer and run in ~2 minutes.

`fly.toml` runs `/app/bin/migrate` as a `release_command` before the new
machines accept traffic, so the new notifications/avatar/last_board_id
migrations get applied to Turso automatically.

Tail the logs while the deploy runs:

```sh
flyctl logs --app orelle
```

## 5. Verify the deploy

```sh
flyctl open --app orelle           # opens https://orelle.fly.dev in browser
```

End-to-end smoke checks:

- Marketing page loads at `/`.
- Log in (use a real account; `demo@example.com` is dev-seed only).
- Settings: upload an avatar, confirm it lands on Tigris (URL on
  `<img>` should be `https://orelle-avatars.fly.storage.tigris.dev/...`).
- Trigger a share or wait for the notifications scanner — within ~60s
  the bell should show a new entry.
- `flyctl logs --app orelle` shouldn't show repeating `[error]` lines.
- Resend dashboard → Logs should record any avatar-related digest mail
  the mailer sent in the first ~30 minutes (digest is throttled).

## 6. Custom domain (optional)

```sh
flyctl certs add orelle.app --app orelle
```

Then add a CNAME record at your registrar pointing `orelle.app` to
`orelle.fly.dev`. After Fly issues the cert (~minute) update
`PHX_HOST` to the new domain:

```sh
flyctl secrets set PHX_HOST=orelle.app --app orelle
```

That triggers a rolling restart; the endpoint will start sending
absolute URLs (in emails, etc.) under the new host.

## Troubleshooting

- **`(Mix) Could not start application to_do: ... TURSO_DATABASE_URL is missing`** —
  one of the three required runtime secrets isn't set. Re-run the `flyctl
  secrets set` step.
- **First avatar upload returns `:nxdomain` or `:invalid_response`** —
  bucket name doesn't match `S3_BUCKET`, the endpoint host is wrong, or
  the API token doesn't have write permission on the bucket.
- **Avatar uploads but `<img>` 404s** — public access not enabled on the
  R2 bucket, or `S3_PUBLIC_BASE` doesn't match the bucket's
  `pub-<hash>.r2.dev` URL.
- **Scanner logs `Failed to connect: SQLite failure: database is locked`
  on every tick** — Fly's machine restarted before the libsql sync
  finished. Harmless; the next tick succeeds. If it persists, increase the
  VM size in `fly.toml` (Turso syncs are CPU-bound).
- **Migrations failed with `WAL frame insert conflict`** — the local
  replica got out of sync with Turso. Easiest fix: SSH in
  (`flyctl ssh console`) and `rm /tmp/to_do.db*`, then redeploy. The
  embedded replica re-syncs from scratch.
- **`SQLite failure: no such column: ...` after a schema-change deploy**
  — replica drift. The boot script (rel/overlays/bin/server) already
  wipes /tmp/to_do.db* before each boot so this shouldn't happen, but if
  it does, `flyctl machine restart --app orelle` triggers a fresh boot
  and the wipe + resync.
- **`Hrana: api error: status=404 ... stream not found`** — Turso
  recycled the HTTP/2 streams the libsql adapter cached. Tends to happen
  after several days of uptime. Recovery: `flyctl machine restart --app
  orelle`. The boot wipe forces a clean reconnect.
