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

## 2. Provision Tigris storage for avatars

Fly's `flyctl storage create` provisions a Tigris bucket and prints
S3-style credentials (access key + secret + endpoint). It also stores those
as Fly secrets on your app automatically.

```sh
flyctl storage create --name orelle-avatars --app orelle
```

The output gives you `BUCKET_NAME`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
`AWS_ENDPOINT_URL_S3`, etc. — all auto-set as secrets on the app.

The avatar-storage code expects two extra envs that `flyctl storage create`
doesn't set for you:

```sh
flyctl secrets set \
  TIGRIS_BUCKET=orelle-avatars \
  TIGRIS_PUBLIC_BASE=https://orelle-avatars.fly.storage.tigris.dev \
  --app orelle
```

(If `flyctl storage create` named the bucket something different, substitute
that name into both values above.)

The bucket's `avatars/` prefix needs public-read so `<img src=...>` works
without signed URLs. Set that policy via the Tigris CLI / dashboard, or
issue an `s3api put-bucket-policy` call. The Fly docs cover this in
[Tigris > Public access](https://fly.io/docs/tigris/object-storage/#public-access).

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
  Tigris bucket name doesn't match the configured `TIGRIS_BUCKET`, or the
  public-read policy isn't applied yet.
- **Scanner logs `Failed to connect: SQLite failure: database is locked`
  on every tick** — Fly's machine restarted before the libsql sync
  finished. Harmless; the next tick succeeds. If it persists, increase the
  VM size in `fly.toml` (Turso syncs are CPU-bound).
- **Migrations failed with `WAL frame insert conflict`** — the local
  replica got out of sync with Turso. Easiest fix: SSH in
  (`flyctl ssh console`) and `rm /tmp/to_do.db*`, then redeploy. The
  embedded replica re-syncs from scratch.
