%%% @doc Verifies a caller actually holds the private key for the
%%% citizen_did they're registering presence as -- the fix for this
%%% repo's own plans/PLAN_ROOT.md "sharper, related open question":
%%% nothing stops a caller registering ANY citizen_did, including one
%%% they don't hold the key for (DID squatting in a public directory).
%%%
%%% Same root cause, same fix as `hecate-mail`'s `mailbox_ownership_proof'
%%% (confirmed once, straight from hecate_om's vendored macula SDK: a
%%% `macula_response' handler gets only the caller's self-asserted
%%% Payload, never a verified caller identity) -- duplicated here rather
%%% than shared via a new `hecate_om' module, since this is currently a
%%% two-repo, ~40-line concern; worth consolidating into `hecate_om'
%%% itself if a third consumer ever needs it (the "would a second,
%%% unrelated consumer plausibly want this same fact" test this repo's
%%% own plan already applies elsewhere).
%%%
%%% A Macula DID is literally an Ed25519 public key
%%% (macula_identity:node_id() :: pubkey()), so ownership is proved by
%%% signing {citizen_did, timestamp, procedure} with the matching
%%% private key -- procedure included so a proof minted for
%%% `register_presence' can't be replayed against any other gated
%%% capability this service adds later.
%%% @end
-module(citizen_ownership_proof).

-export([verify/3, message/3]).

-define(MAX_SKEW_MS, 60_000).

-spec message(binary(), integer(), binary()) -> binary().
message(CitizenDid, Timestamp, Procedure)
  when is_binary(CitizenDid), is_integer(Timestamp), is_binary(Procedure) ->
    <<CitizenDid/binary, Timestamp:64/big, Procedure/binary>>.

-spec verify(binary(), map(), binary()) -> ok | {error, atom()}.
verify(CitizenDid, Proof, Procedure)
  when is_binary(CitizenDid), byte_size(CitizenDid) =:= 32, is_map(Proof), is_binary(Procedure) ->
    checked_fields(maps:find(timestamp, Proof), maps:find(signature, Proof),
                   CitizenDid, Procedure);
verify(_CitizenDid, _Proof, _Procedure) ->
    {error, invalid_citizen_did}.

checked_fields({ok, Ts}, {ok, Sig}, CitizenDid, Procedure)
  when is_integer(Ts), is_binary(Sig) ->
    fresh(Ts, CitizenDid, Sig, Procedure);
checked_fields(_Ts, _Sig, _CitizenDid, _Procedure) ->
    {error, missing_proof}.

fresh(Ts, CitizenDid, Sig, Procedure) ->
    skew_checked(abs(erlang:system_time(millisecond) - Ts), Ts, CitizenDid, Sig, Procedure).

skew_checked(Skew, Ts, CitizenDid, Sig, Procedure) when Skew =< ?MAX_SKEW_MS ->
    signed(macula_identity:verify(message(CitizenDid, Ts, Procedure), Sig, CitizenDid));
skew_checked(_Skew, _Ts, _CitizenDid, _Sig, _Procedure) ->
    {error, stale_proof}.

signed(true) -> ok;
signed(false) -> {error, bad_signature}.
