# hecate-citizens — Plan

**Status: Planning. Scaffold generated (`rebar3 new hecate_service`, no
store — this is read-model only), builds, all 10 generated tests pass. No
domain code written yet.**

## One-line answer to "why does this exist"

Two services independently need to know "who is a citizen of this mesh":
`hecate-mail` (to address a mailbox) and `hecate-mcp-agora` (to attribute
a public post) — see [[project_macula_mcp_track]] in memory for the
conversation this was extracted from. Rather than each maintaining its own
federated copy of the same identity data (which drift apart the moment
either one adds a citizen the other doesn't hear about), `hecate-citizens`
is the one shared directory both consume.

## Why this was split out of `hecate-mail` rather than left there

`hecate-mail`'s original plan (see that repo's `plans/PLAN_ROOT.md`
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

- `hecate-mail`'s original `hosted_at` field (which mail instance a
  citizen's mailbox lives on) is mail-specific routing data. It does NOT
  belong here — it stays in `hecate-mail`'s own thin, mail-scoped
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
changes needed there, same as every capability in the `hecate-mail`
plan.

## Fields

```erlang
#{citizen_did    => Did,           % the citizen's own identity, Ed25519 node_id
  citizen_kind   => Kind,          % human | agent | service -- see below
  display_name   => DisplayName,   % self-asserted, not verified -- see Trust below
  offers         => Offers,        % self-described, informational list of what this citizen's agent can be asked to do
  expires_at     => ExpiresAt}     % presence TTL, drives staleness (below)
```

No `hosted_at`, no per-service routing fields, ever — see Scope above.

## Citizen kinds: human, agent and service are not symmetric, and that matters

Three kinds of citizens register here: **humans**, via a mobile app
(`macula-passport`/`macula-cam2me`); **AI agents**, via `macula-mcp`; and
**services** — an institution (`hecate-mail`, `hecate-rag`, any
`hecate_om`-based service) registering itself as an addressable citizen in
its own right, not merely as the thing hosting other citizens' data. This
is what makes "a mailbox addressed to a service" meaningful: `guide_mailbox_lifecycle`
in `hecate-mail` treats `citizen_did` as opaque and has no idea which kind
it belongs to, so a service that registers itself here can receive
delegated work the same way a human or agent citizen would — the "delegate
work to a citizen who is not online right now" framing `hecate-mail`
already carries in its own description covers a service as much as a
person. `citizen_kind` records which, mainly so a consumer (a display, `hecate-mail`
deciding how to phrase a notification, whatever comes later) can treat them
differently if it wants to — but the three kinds get to that DID by
genuinely different paths, and two of those paths have a real gap worth
stating plainly rather than discovering later:

- **A human's DID comes from a realm-issued personal cert** — mortal,
  mobile, per `identity_model.md`'s own description of a citizen credential.
  Whatever mints it (the passport app, ultimately `hecate-realm`) is
  designed to produce something stable across app restarts.
- **An AI agent's DID, by default, is macula-mcp's own per-process
  identity** — and per this workspace's own `macula-mcp` v0.4.0 fix
  ([[project_macula_mcp_track]]), that identity is *deliberately* minted
  fresh per server process and deleted on exit, specifically to stop
  concurrent sessions from colliding with each other. **An agent citizen
  registering with macula-mcp's default identity would get a brand-new DID
  every session** — their own directory entry would be orphaned, and any
  reply addressed to their previous session's DID would go nowhere. This is
  not a hypothetical edge case; it's what happens by default, today, with
  no extra step.
- **The fix already exists, it just has to be used deliberately**:
  `macula-mcp` already supports pinning a stable identity via the
  `MACULA_MCP_IDENTITY` environment variable (built for a different reason
  — restoring shared-identity continuity — but it solves this exactly).
  An agent that wants to be a genuinely addressable citizen, not just a
  one-shot caller, needs `MACULA_MCP_IDENTITY` set to a fixed path before
  it ever calls `register_presence`. **This should be stated explicitly in
  whatever documentation tells an agent how to use `hecate-citizens`** —
  it's the one setup step that makes the difference between "a real
  citizen" and "a citizen that stops existing the moment this session
  ends."
- **A service's DID comes from its realm-provisioned service-principal
  cert** — the same credential every `hecate_om` service already gets at
  deploy time per `identity_model.md`'s institution path (POST
  `/api/v1/services/provision`, see [[reference_realm_service_principal_certs]]),
  issued once to the running instance and not regenerated per request or
  per restart the way an unpinned agent identity is. **This is the
  opposite failure mode from the agent gap**: a service citizen's DID is
  already stable by construction, no extra step needed, *provided the
  service registers using the same identity it authenticates to the mesh
  with* rather than minting a separate one — the thing worth stating
  explicitly here is "don't invent a second identity for this," not "go
  fix an instability."

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

## Trust — stated plainly, same framing as `hecate-mail`

Directory entries are self-asserted. Nothing here verifies that a
`display_name` is honest or that `offers` accurately describes what an
agent will actually do. This is a phone book, not a background check —
consistent with `identity_model.md`'s own v1/v2 roadmap (long-lived
realm-signed cert now, policy+UCAN delegation later) and with the framing
already settled for `hecate-mail`: a directory lists, it doesn't vouch.

**A sharper, related open question, same root cause as `hecate-mail`
PART3's**: nothing described above stops a caller from calling
`register_presence` with *any* `citizen_did`, including one they don't
actually hold the private key for — self-asserted extends to the DID
itself, not just `display_name`/`offers`. Whether `hecate_om` hands a
`macula_response` handler any cryptographically verified caller identity
at all is the same unresolved question `hecate-mail` flagged for reading
mailboxes; here it means someone could plausibly squat another citizen's
DID in the directory. Resolve once, in whichever service builds the fix
first — the answer doesn't differ between "can I read your mail" and "can
I register presence as you."

## Consumers (as of this writing)

| Consumer | Uses it for |
|---|---|
| `hecate-mail` | Confirming a DID belongs to a real citizen before/while addressing mail to them (nice-to-have lookup, not required for `deposit_letter` itself — see that repo's revised PART2) |
| `hecate-mcp-agora` (not yet built) | Attributing a public post to a citizen, showing a display name |

This service does not require either consumer to be present or reachable
— it works standalone. They consume it, not the reverse.

## Deployment

Same model as every other `hecate-services` repo and as specified in
`hecate-mail`'s own PART4: a realm-provisioned service principal on
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
round trip against the demo fleet. Ship it, then update `hecate-mail`
to actually call it (currently documented as a consumer, not yet wired in
code).
