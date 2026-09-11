%%% @doc POLICY: whether an incoming `hecate_citizens.citizen_presence'
%%% registration is written, and until when. It arrives either as a
%%% federated fact from a listed instance (via `citizen_presence_listener')
%%% or as this instance's own registration (via
%%% `register_presence_responder'). One code path either way -- "should
%%% this be written" has exactly one home, per
%%% hecate-corpus/examples/MESH_FACT_READ_MODELS.md.
%%%
%%% THE EXPIRY IS THIS INSTANCE'S OWN ARITHMETIC. A registration carries
%%% `registered_at', stamped by the instance that took the call, and
%%% `ttl_ms'. What is stored expires at registered_at plus the TTL, with the
%%% TTL bounded to twenty minutes and the result never later than twenty
%%% minutes from this instance's clock. An `expires_at' in the input is
%%% never read: a fact that names its own expiry could keep an entry alive
%%% for as long as it liked. A registration stamped more than a minute ahead
%%% of this clock is refused, so an instance whose clock runs fast cannot
%%% win against every later registration until its clock catches up.
%%%
%%% THE LATEST REGISTRATION WINS, by registered_at and not by expiry: an
%%% owner who registers again with a shorter TTL replaces their own entry,
%%% and a replayed older fact replaces nothing.
%%%
%%% `with_expiry/2' and `decide/2' are pure functions: no mesh call, no
%%% store and no clock inside them, trivially unit-testable with plain terms.
%%% @end
-module(on_citizen_presence_maybe_admit).

-export([handle/1, with_expiry/2, decide/2]).

-define(MAX_TTL_MS, 1_200_000).
-define(MAX_AHEAD_MS, 60_000).

-type refusal() :: invalid_citizen_did | invalid_registered_at | registered_at_ahead_of_clock
                 | invalid_ttl_ms.

%% @doc Write `Presence' if it wins against the stored registration of the
%% same citizen. Returns the fields as bounded here, whether or not they
%% won, or the reason they were refused.
-spec handle(map()) -> {ok, map()} | {refused, refusal()}.
handle(Presence) ->
    written(with_expiry(Presence, erlang:system_time(millisecond))).

written({ok, #{citizen_did := CitizenDid} = Fields}) ->
    ok = admitted(decide(existing(CitizenDid), Fields), Fields),
    {ok, Fields};
written({refused, _Reason} = Refused) ->
    Refused.

existing(CitizenDid) ->
    found(citizen_read_model:find(CitizenDid)).

found({ok, Doc}) -> Doc;
found({error, not_found}) -> undefined.

admitted(admit, Fields) -> citizen_read_model:upsert(Fields);
admitted(stale, _Fields) -> ok.

%% @doc `Presence' with its TTL bounded and its expiry computed against
%% `Now', or the reason it is refused. A citizen_did that did not decode to
%% 32 bytes is refused first: no entry can be keyed on it.
-spec with_expiry(map(), integer()) -> {ok, map()} | {refused, refusal()}.
with_expiry(#{citizen_did := CitizenDid} = Presence, Now)
  when is_binary(CitizenDid), byte_size(CitizenDid) =:= 32 ->
    timed(Presence, Now);
with_expiry(_Presence, _Now) ->
    {refused, invalid_citizen_did}.

timed(#{registered_at := RegisteredAt, ttl_ms := TtlMs} = Presence, Now) ->
    expiring(registered(RegisteredAt, Now), bounded(TtlMs), Presence, Now).

registered(RegisteredAt, Now)
  when is_integer(RegisteredAt), RegisteredAt =< Now + ?MAX_AHEAD_MS ->
    {ok, RegisteredAt};
registered(RegisteredAt, _Now) when is_integer(RegisteredAt) ->
    {refused, registered_at_ahead_of_clock};
registered(_RegisteredAt, _Now) ->
    {refused, invalid_registered_at}.

bounded(TtlMs) when is_integer(TtlMs), TtlMs > 0 -> {ok, min(TtlMs, ?MAX_TTL_MS)};
bounded(_TtlMs) -> {refused, invalid_ttl_ms}.

expiring({ok, RegisteredAt}, {ok, TtlMs}, Presence, Now) ->
    {ok, Presence#{ttl_ms => TtlMs,
                   expires_at => min(RegisteredAt + TtlMs, Now + ?MAX_TTL_MS)}};
expiring({refused, _Reason} = Refused, _TtlMs, _Presence, _Now) ->
    Refused;
expiring(_RegisteredAt, {refused, _Reason} = Refused, _Presence, _Now) ->
    Refused.

%% @doc Whether `Incoming' (bounded fields) replaces `Existing' (the stored
%% doc of the same citizen, `undefined' when there is none).
-spec decide(map() | undefined, map()) -> admit | stale.
decide(undefined, _Incoming) ->
    admit;
decide(#{<<"registered_at">> := Current}, #{registered_at := Incoming})
  when Incoming >= Current ->
    admit;
decide(#{<<"registered_at">> := _Current}, _Incoming) ->
    stale;
%% ROLLOUT ONLY. A doc stored before registered_at existed was admitted by
%% its expires_at alone, with no bound on the TTL, so it has no registration
%% time to compare and no standing to block a registration that has one: it
%% is replaced. This clause stops mattering once the docs written before the
%% rollout have expired. Ownership proof v2 orders registrations by the
%% owner's signed timestamp instead, and removes this clause.
decide(_StoredBeforeRegisteredAt, _Incoming) ->
    admit.
