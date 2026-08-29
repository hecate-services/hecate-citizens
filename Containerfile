# hecate-citizens
#
# The shared citizens directory for the Macula mesh -- who exists, federated across instances via mesh facts
#
# NO DATA VOLUME AS GENERATED. The scaffold writes nothing, and a named volume
# for data that does not exist is a promise the image cannot keep. Add one
# together with the code that writes it, and declare it here and in the compose
# file at the same time.

# ⚠ THE RUNTIME IS PINNED IN TWO PLACES AND THEY MUST AGREE: here and `lint.yml'
# beside it. A generated service that builds on one release and tests on another
# only ever proves "the tests pass on the CI release".
#
# This template said 27 from the beginning and nothing revisited it, so every
# service scaffolded from it inherited 27 while development machines moved on.
# In `hecate-biotope' that cost three commits of red CI on a crash that does not
# occur on the development release at all, and because `build-push.yml' is a
# separate workflow the image shipped to the fleet regardless.
FROM docker.io/erlang:28-alpine AS builder
WORKDIR /build

# macula ships a QUIC NIF. MACULA_FORCE_SOURCE_BUILD makes it build here rather
# than fetch a prebuilt binary linked against a different libc, which is the
# recorded glibc trap: the fetched artifact loads on the build host and fails on
# alpine at runtime.
#
# openssl-dev/zstd-dev/snappy-dev/lz4-dev: hecate_om pulls in rocksdb (via
# barrel_docdb) and khepri/ra transitively, UNCONDITIONALLY -- confirmed on a
# storeless, producer-only service (no store_id/0 or data_dir/0 exported),
# which still failed to build without these. Not specific to a service that
# owns its own reckon-db store.
RUN apk add --no-cache git curl bash build-base cmake perl linux-headers \
        openssl-dev zstd-dev snappy-dev lz4-dev
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain stable --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"
ENV RUSTFLAGS="-C target-feature=-crt-static"
ENV MACULA_FORCE_SOURCE_BUILD=1

RUN curl -fsSL https://s3.amazonaws.com/rebar3/rebar3 -o /usr/local/bin/rebar3 \
    && chmod +x /usr/local/bin/rebar3

# Dependencies resolve from rebar.config alone, so this layer survives every
# change to config/ and apps/ and the Rust toolchain is not re-run per commit.
COPY rebar.config ./
RUN rebar3 get-deps

COPY config ./config
COPY apps ./apps
RUN rebar3 as prod release

FROM docker.io/alpine:3.22
# LINKS THE PACKAGE TO THE REPOSITORY. On registries that read it, ghcr among
# them, a package without this label is an orphan: it does not appear on the
# repository page and does not inherit its visibility. A service that shipped
# private by accident failed its first pull with a bare "unauthorized", which
# names nothing and sends you looking in the wrong place.
LABEL org.opencontainers.image.source="https://github.com/hecate-services/hecate-citizens"
# zstd-libs/snappy/lz4-libs: the RUNTIME shared libraries for rocksdb's
# compression backends, compiled against in the builder stage above via
# their -dev packages. Missing here crashes the release outright on
# boot -- rocksdb's on_load NIF init fails with "Failed to load NIF
# library: Error loading shared library liblz4.so.1: No such file or
# directory" and the whole node exits, since kernel can't start.
# Confirmed live: this stage shipped without them once already.
RUN apk add --no-cache ncurses-libs libstdc++ libgcc openssl ca-certificates curl \
        zstd-libs snappy lz4-libs
WORKDIR /app
COPY --from=builder /build/_build/prod/rel/hecate_citizens ./

ENV HOME=/app
ENV RELX_REPLACE_OS_VARS=true

ENV HECATE_NODE_NAME=hecate_citizens
ENV HECATE_NODE_HOST=127.0.0.1
ENV HECATE_COOKIE=hecate_citizens
ENV HECATE_HEALTH_PORT=8491

VOLUME ["/etc/hecate/secrets"]

EXPOSE 8491
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${HECATE_HEALTH_PORT}/health" || exit 1

CMD ["/app/bin/hecate_citizens", "foreground"]
