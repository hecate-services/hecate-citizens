# hecate-citizens

**The shared citizens directory for the Macula mesh -- who exists, federated across instances via mesh facts**

## Plan

The full design -- why this exists as its own service rather than living
inside `hecate-mcp-mail`, the identity-only scope boundary, federation across
instances -- is in [`plans/PLAN_ROOT.md`](plans/PLAN_ROOT.md). Start there.

## Status

The service boots, joins the mesh, answers `/health`, and serves three
capabilities: `hecate_citizens.register_presence`,
`hecate_citizens.list_citizens` and `hecate_citizens.get_citizen`.
Registrations federate between instances as described under
[Federation](#federation).

## Running it

    rebar3 compile
    rebar3 eunit
    rebar3 lint

    scripts/health.sh                      # against a running node

Building the image needs a Rust toolchain, because macula ships a QUIC NIF and
the alpine build compiles it from source rather than fetching one linked against
a different libc.

    podman build -t hecate-citizens -f Containerfile .

## Configuration

| Variable | Default | Meaning |
|----------|---------|---------|
| `HECATE_REALM` | required | 64-hex realm tag, the `sha256` of the realm's name. No default: a service that guesses its realm announces itself where nobody can attribute it. |
| `MACULA_STATION_SEEDS` | required | Station to dial. No default: naming a realm costs nothing, dialling a production station from every dev clone does. |
| `HECATE_CITIZENS_PRESENCE_PUBLISHERS` | required | Node ids (64 hex, comma separated) of the hecate-citizens instances whose presence facts this one admits; see [Federation](#federation). This instance's own id is optional. A missing or malformed list stops the node at boot. |
| `HECATE_HEALTH_PORT` | `8491` | Health endpoint. Host networking makes a collision a silent bind failure, so check the host before changing.  |
| `HECATE_NODE_NAME` | `hecate_citizens` | Erlang node name. |
| `HECATE_NODE_HOST` | `127.0.0.1` | Erlang node host. |
| `HECATE_COOKIE` | `hecate_citizens` | Erlang cookie. |

`deploy/docker-compose.yml` runs it, and carries what the service knows about
itself. If you deploy through something else, let that carry **placement**: which
host, which station, which realm, which secret store. Keeping the two apart is
what stops a config table in a README and the real environment drifting.

## Federation

A citizen registers with `hecate_citizens.register_presence` at whichever
instance the call reaches. That instance refuses the call unless the caller
proves it holds the key for `citizen_did` **and** `citizen_did` is the CALL's
own verified caller, so a captured proof cannot be replayed by another identity.
It stamps the registration with its own clock as `registered_at`, writes it, and
publishes it as a `hecate_citizens.citizen_presence` fact carrying
`registered_at` and `ttl_ms`.

The topic is open to anyone in the realm, so a receiving instance admits a fact
only when macula verified its publisher signature and the publisher is listed in
`HECATE_CITIZENS_PRESENCE_PUBLISHERS`. An instance's node id is the public key of
its identity at `$HECATE_DATA_DIR/identity/keypair.erl.bin`, the same id its
`hecate_citizens.register_presence` advertisement carries.

Every instance computes the expiry itself and never takes a fact's `expires_at`:

- `ttl_ms` must be a positive integer and is capped at twenty minutes (the
  default).
- The entry expires at `registered_at` plus the TTL, and never later than twenty
  minutes from the receiving instance's own clock.
- A registration stamped more than a minute ahead of that clock is refused.
- Of two registrations of one citizen, the later `registered_at` wins, so an
  owner who registers again with a shorter TTL replaces their own entry.
- A fact whose `citizen_did` does not decode is refused.

All of this assumes the instances' clocks agree, so run NTP on every instance
host. A registration stamped more than a minute ahead is refused, and one more
than twenty minutes behind arrives already expired.

## Deployment

CI builds on every push to `main` and pushes
`ghcr.io/hecate-services/hecate-citizens:latest` plus the semver tag. Pull `:latest` under
watchtower and a merge is a deploy, while a rollback is pinning to a semver tag.

Two things CI cannot do for you, both of which have bitten:

1. The registry package may be created **private**, and the pull then fails on
   the host with a bare `unauthorized` that names nothing. Check it after the
   first build. On ghcr the `org.opencontainers.image.source` label in the
   Containerfile is what links the package to the repository.
2. The host needs `HECATE_REALM` supplied from somewhere it is not committed.

## The service contract

Six callbacks in `hecate_citizens_service`, all required, all resolved **by name** by
`hecate_om` at startup on a live node. The `-behaviour(hecate_om_service)`
attribute turns a missing one into a compile error rather than an `undef` where
nobody is watching, and the eunit suite guards the attribute itself.

### Adding a store later

This service has no `reckon-db` store, which is the right answer for most. The
reckon-db applications run either way; what a store adds is a data directory, an
open handle, and something written.

The cheapest way to get one is to scaffold again with `store=1`, which generates
the callbacks, the config and the guards together.

⚠ **By hand it is three things and not one, and the missing third crash-loops the
node.** Export `store_id/0` and `data_dir/0`; add the `evoq` adapter block to
`config/sys.config.src`, without which boot raises
`{not_configured, event_store_adapter}` before any service code runs; and mount a
volume in the compose file. A sibling service put two of three fleet nodes into a
boot loop by doing the first and not the second.

## Licence

Apache-2.0.
