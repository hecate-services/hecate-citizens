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
%%% WIRE ENCODING, corrected after a real live-mesh test failed the
%%% first version of this module: macula's frame decoder walks a
%%% payload map and converts every CBOR TEXT value to an ATOM via
%%% `binary_to_existing_atom/1' whenever the RECEIVING VM already has
%%% that atom loaded -- if not, it stays a `{text, Binary}' tuple.
%%% Which shape a given value arrives as therefore depends on what
%%% atoms this VM happens to already know, not on anything the caller
%%% controls: a real DID (effectively random hex) is essentially never
%%% already an atom, so it always arrives `{text, Bin}'-tagged.
%%% `unwrap_text/1' handles all three shapes (bare binary, bare atom,
%%% `{text, Bin}') plus `undefined'; `decode_did/1' layers hex-decoding
%%% on top for DID/signature fields, `decode_text/1' is the same
%%% unwrap alone for any other wire-transported string (display_name,
%%% offers, ...).
%%% @end
-module(citizen_ownership_proof).

-export([verify/3, message/3, decode_did/1, decode_text/1]).

-define(MAX_SKEW_MS, 60_000).

%% @doc Unwraps whatever shape a wire-transported string value arrived
%% in (bare binary, bare atom, or `{text, Binary}') into a plain
%% binary. `undefined' passes through unchanged.
-spec unwrap_text(term()) -> binary() | undefined.
unwrap_text(undefined) -> undefined;
unwrap_text(Bin) when is_binary(Bin) -> Bin;
unwrap_text({text, Bin}) when is_binary(Bin) -> Bin;
unwrap_text(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8);
unwrap_text(_Other) -> undefined.

%% @doc `unwrap_text/1' alone, for any wire-transported string that
%% isn't a DID/signature.
-spec decode_text(term()) -> binary() | undefined.
decode_text(V) -> unwrap_text(V).

%% @doc Unwraps, then hex-decodes, a wire-transported DID/node_id into
%% its raw 32 bytes.
-spec decode_did(term()) -> binary() | undefined.
decode_did(V) -> hex_or_raw(unwrap_text(V)).

hex_or_raw(undefined) ->
    undefined;
hex_or_raw(HexDid) when byte_size(HexDid) =:= 64 ->
    try binary:decode_hex(HexDid) catch error:badarg -> undefined end;
hex_or_raw(RawDid) when byte_size(RawDid) =:= 32 ->
    RawDid;
hex_or_raw(_Other) ->
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

checked_fields({ok, Ts}, {ok, Sig}, CitizenDid, Procedure) when is_integer(Ts) ->
    decoded_sig(hex_or_raw_sig(unwrap_text(Sig)), Ts, CitizenDid, Procedure);
checked_fields(_Ts, _Sig, _CitizenDid, _Procedure) ->
    {error, missing_proof}.

hex_or_raw_sig(undefined) ->
    undefined;
hex_or_raw_sig(Sig) when byte_size(Sig) =:= 128 ->
    try binary:decode_hex(Sig) catch error:badarg -> undefined end;
hex_or_raw_sig(Sig) when byte_size(Sig) =:= 64 ->
    Sig;
hex_or_raw_sig(_Other) ->
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
