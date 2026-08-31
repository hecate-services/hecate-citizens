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
%%%
%%% WIRE ENCODING: macula-cli's JSON->CBOR bridge (wirevalue.FromJSON)
%%% sends every JSON string as a CBOR TEXT value, never a byte string --
%%% confirmed reading it directly, no `0x'-prefix special-casing on the
%%% way in (only on the way OUT, for display). So `citizen_did' and this
%%% proof's `signature' arrive here as ASCII hex TEXT (what
%%% `macula-cli identity sign' and `mesh_hello' print), not the 32/64
%%% raw bytes the crypto actually operates on. `decode_did/1' undoes
%%% that for citizen_did; `verify/3' undoes it for the signature
%%% internally, since nothing else ever needs that one raw.
%%% @end
-module(citizen_ownership_proof).

-export([verify/3, message/3, decode_did/1]).

-define(MAX_SKEW_MS, 60_000).

%% @doc Hex-decodes a wire-transported DID/node_id into its raw 32
%% bytes. `undefined' for anything that isn't well-formed hex of the
%% right length, rather than crashing the responder's transient
%% process on a malformed caller input -- verify/3's own byte_size
%% guard then rejects it cleanly as `invalid_citizen_did'.
-spec decode_did(term()) -> binary() | undefined.
decode_did(HexDid) when is_binary(HexDid), byte_size(HexDid) =:= 64 ->
    try binary:decode_hex(HexDid) catch error:badarg -> undefined end;
decode_did(RawDid) when is_binary(RawDid), byte_size(RawDid) =:= 32 ->
    %% Already raw bytes -- an in-VM caller (this repo's own eunit
    %% fixtures, or a future non-wire caller) never round-trips
    %% through hex at all.
    RawDid;
decode_did(_Other) ->
    undefined.

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

checked_fields({ok, Ts}, {ok, Sig}, CitizenDid, Procedure) when is_integer(Ts), is_binary(Sig) ->
    decoded_sig(decode_hex_sig(Sig), Ts, CitizenDid, Procedure);
checked_fields(_Ts, _Sig, _CitizenDid, _Procedure) ->
    {error, missing_proof}.

decode_hex_sig(Sig) when byte_size(Sig) =:= 128 ->
    try binary:decode_hex(Sig) catch error:badarg -> undefined end;
decode_hex_sig(Sig) when byte_size(Sig) =:= 64 ->
    %% Already raw -- see decode_did/1's own note on in-VM callers.
    Sig;
decode_hex_sig(_Other) ->
    undefined.

decoded_sig(undefined, _Ts, _CitizenDid, _Procedure) ->
    {error, bad_signature};
decoded_sig(Sig, Ts, CitizenDid, Procedure) ->
    fresh(Ts, CitizenDid, Sig, Procedure).

fresh(Ts, CitizenDid, Sig, Procedure) ->
    skew_checked(abs(erlang:system_time(millisecond) - Ts), Ts, CitizenDid, Sig, Procedure).

skew_checked(Skew, Ts, CitizenDid, Sig, Procedure) when Skew =< ?MAX_SKEW_MS ->
    signed(macula_identity:verify(message(CitizenDid, Ts, Procedure), Sig, CitizenDid));
skew_checked(_Skew, _Ts, _CitizenDid, _Sig, _Procedure) ->
    {error, stale_proof}.

signed(true) -> ok;
signed(false) -> {error, bad_signature}.
