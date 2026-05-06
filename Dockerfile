# syntax=docker/dockerfile:1
#
# Multi-stage Dockerfile for the Orelle Phoenix release.
#
# Stage 1 (`builder`) — full Elixir/OTP toolchain. Compiles deps, runs
# `mix assets.deploy`, and produces `_build/prod/rel/to_do`.
#
# Stage 2 (`runner`) — minimal Debian image. Receives only the compiled
# release plus the runtime libraries we actually need (libstdc++,
# libncurses, libssl, ca-certificates, locales).
#
# Pinned versions track the Phoenix 1.8 generator defaults; bump in
# concert with `mix.exs`'s elixir requirement when upgrading.
ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.5.2
ARG DEBIAN_VERSION=trixie-20251001-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# ----- builder ----------------------------------------------------------
FROM ${BUILDER_IMAGE} AS builder

# Toolchain for compiling NIFs (rustler_precompiled used by ecto_libsql
# usually downloads a prebuilt; the gcc/git fallback is here for safety).
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends build-essential git \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Hex/Rebar
RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

# Install deps first so the Docker layer cache can survive code changes.
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets

# Compile assets (Tailwind + esbuild), then digest into priv/static.
RUN mix assets.deploy

# Compile the project, then runtime config and finally release.
RUN mix compile
COPY config/runtime.exs config/
COPY rel rel
RUN mix release

# ----- runner -----------------------------------------------------------
FROM ${RUNNER_IMAGE}

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends \
       libstdc++6 openssl libncurses6 locales ca-certificates \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

# Set UTF-8 locale.
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody /app

# Where the libsql embedded replica lives. Ephemeral by design — the
# replica is a read-through cache of the Turso primary, so a fresh
# container will re-sync on first DB access.
ENV REPLICA_PATH=/tmp/to_do.db

ENV MIX_ENV=prod

COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/to_do ./

USER nobody

CMD ["/app/bin/server"]
