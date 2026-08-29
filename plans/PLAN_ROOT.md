# hecate-citizens — Plan

**Status: Planning. Scaffold generated (`rebar3 new hecate_service`, no
store — this is read-model only), builds, all 10 generated tests pass. No
domain code written yet.**

## One-line answer to "why does this exist"

Two services independently need to know "who is a citizen of this mesh":
`hecate-mcp-mail` (to address a mailbox) and `hecate-mcp-agora` (to attribute
a public post) — see [[project_macula_mcp_track]] in memory for the
conversation this was extracted from. Rather than each maintaining its own
federated copy of the same identity data (which drift apart the moment
either one adds a citizen the other doesn't hear about), `hecate-citizens`
is the one shared directory both depend on.

## Why this was split out of `hecate-mcp-mail` rather than left there

`hecate-mcp-mail`'s original plan (see that repo's `plans/PLAN_ROOT.md`
decisions log) built the citizens directory directly into the mail service,
reasoning "one service, two internal concerns" — a defensible call *if
mail were the only consumer*. It stopped being the right call the moment a
second real consumer (`hecate-mcp-agora`) was named, not hypothetically but
as an actual next thing to build. Extracting now, before agora's code
exists, avoids the alternative: two independently-federated directories
that can silently diverge, discovered only once someone notices Alice is
listed on one and not the other.

**"One more standing service" is not, on its own, a reason not to do
this.** The whole ecosystem this belongs to is already a set of
collaborating microservices (`hecate-rag`, `hecate-stations`,
`hecate-turn-credentials`, `hecate-sentinel`, ...), each an institution with
its own realm-provisioned credential, each doing one thing. A shared
directory used by more than one of them is exactly the shape that
architecture is for — the operational cost (one more container, one more
credential) is the normal cost of doing this correctly, not a special
tax this decision has to justify away.

## Scope — identity only, deliberately thin

This service answers exactly one question: **does this DID belong to a
known citizen, and what did they say about themselves?** It does NOT know
or care which mail instance hosts someone's mailbox, which agora posts
belong to them, or anything else that's specific to a particular consumer.
That's a deliberate boundary, not an oversight:

- `hecate-mcp-mail`'s original `hosted_at` field (which mail instance a
  citizen's mailbox lives on) is mail-specific routing data. It does NOT
  belong here — it stays in `hecate-mcp-mail`'s own thin, mail-scoped
  directory (see that repo's revised PART2).
- A future `hecate-mcp-agora` needing to know "which relay is this citizen
  currently posting through," if it ever needs such a thing, would own that
  itself the same way.
- **The test for whether something belongs in `hecate-citizens` vs. in a
  consuming service: would a second, unrelated consumer plausibly want this
  same fact?** Display name: yes, obviously shared identity. Which specific
  mail server holds your inbox: no, that's mail's own business.

## Capabilities

```erlang
capabilities() ->
    [
     #{name => <<"hecate_citizens.register_presence">>, version => 1,
       handler => {register_presence_handler, []}},
     #{name => <<"hecate_citizens.list_citizens">>, version => 1,
       handler => {list_citizens_handler, []}},
     #{name => <<"hecate_citizens.get_citizen">>, version => 1,
       handler => {get_citizen_handler, []}}
    ].
```

Directly `mesh_call`-able from `macula-mcp` (or any MCP client) with zero
changes needed there, same as every capability in the `hecate-mcp-mail`
plan.

## Fields

```erlang
#{citizen_did    => Did,           % the citizen's own identity, Ed25519 node_id
  display_name   => DisplayName,   % self-asserted, not verified -- see Trust below
  offers         => Offers,        % self-described, informational list of what this citizen's agent can be asked to do
  expires_at     => ExpiresAt}     % presence TTL, drives staleness (below)
```

No `hosted_at`, no per-service routing fields, ever — see Scope above.

## Design: read-model, federated via mesh facts

Exactly the pattern already proven by `hecate-stations` and documented in
`hecate-om/guides/read_model_services.md` — this plan does not reinvent it,
it applies it:

1. **Self-registration** (`register_presence`): a citizen's own agent calls
   this, directly or periodically (client responsibility, e.g. every 5
   minutes for a 20-minute TTL — the same 3-4× republish-to-TTL margin the
   `hecate-om` guide recommends). The handler upserts the local `barrel_docdb`
   read model AND publishes a `hecate_citizens.citizen_presence` fact so
   every other running instance hears about it too.
2. **Federation** (`subscriptions/0` on the same topic): a Listener hands
   each incoming fact to a Policy (`decide/2`, pure, unit-tested with zero
   mesh) that admits it only if fresher than what's already known
   (`expires_at`-based, exact `hecate-stations` shape), then a Projection
   does the dumb upsert.
3. **Staleness for free**: the read side (`list_citizens`/`get_citizen`)
   filters out anything whose `expires_at` has passed. A citizen who stops
   re-registering (crash, network loss, deliberate departure — no
   distinction needed) ages out of every instance's copy on the same
   schedule, with zero explicit "goodbye" event and zero background sweep
   required for correctness (a periodic purge is a size optimization only,
   per the same guide's own explicit note).

```erlang
%% on_citizen_presence_maybe_admit.erl -- the one piece of decision logic
decide(undefined, _Incoming) -> admit;
decide(#{expires_at := Cur}, Incoming) when Incoming >= Cur -> admit;
decide(_Existing, _Incoming) -> stale.
```

## Trust — stated plainly, same framing as `hecate-mcp-mail`

Directory entries are self-asserted. Nothing here verifies that a
`display_name` is honest or that `offers` accurately describes what an
agent will actually do. This is a phone book, not a background check —
consistent with `identity_model.md`'s own v1/v2 roadmap (long-lived
realm-signed cert now, policy+UCAN delegation later) and with the framing
already settled for `hecate-mcp-mail`: a directory lists, it doesn't vouch.

## Consumers (as of this writing)

| Consumer | Uses it for |
|---|---|
| `hecate-mcp-mail` | Confirming a DID belongs to a real citizen before/while addressing mail to them (nice-to-have lookup, not a hard dependency for `deposit_letter` itself — see that repo's revised PART2) |
| `hecate-mcp-agora` (not yet built) | Attributing a public post to a citizen, showing a display name |

Neither consumer is a hard runtime dependency of this service — this
service works standalone. They depend on it, not the reverse.

## Deployment

Same model as every other `hecate-services` repo and as specified in
`hecate-mcp-mail`'s own PART4: a realm-provisioned service principal on
real infrastructure (`beam00-03` or `msi00`), never a citizen's laptop.
`identity_spec/0`:

```erlang
identity_spec() ->
    #{scope => <<"hecate-citizens">>,
      actions => [<<"register_presence">>, <<"list_citizens">>, <<"get_citizen">>],
      resources => [<<"citizens/*">>],
      ttl_days => 365}.
```

CI (already scaffolded) builds and pushes `ghcr.io/hecate-services/hecate-citizens`
on `main` and `v*` tags, same as every sibling service.

## Explicitly out of scope

- Any per-consumer routing data (see Scope above — this is the whole point
  of the split).
- Reputation, verification, or moderation of what a citizen self-asserts.
- A UI. This is mesh/MCP-facing only.

## Build order

Single phase — this service is small enough not to need one. Register,
list, get, federation, `test_live/` coverage of a real register → list
round trip against the demo fleet. Ship it, then update `hecate-mcp-mail`
to actually call it (currently a documented dependency, not yet wired in
code).
