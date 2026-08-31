%%% @doc Tests for citizen_ownership_proof -- pure crypto, zero mesh,
%%% runs in the default `rebar3 eunit' gate.
-module(citizen_ownership_proof_tests).

-include_lib("eunit/include/eunit.hrl").

-define(PROC, <<"hecate_citizens.register_presence">>).

sign(KeyPair, CitizenDid, Timestamp, Procedure) ->
    macula_identity:sign(citizen_ownership_proof:message(CitizenDid, Timestamp, Procedure), KeyPair).

fresh_proof(KeyPair, CitizenDid, Procedure) ->
    Ts = erlang:system_time(millisecond),
    #{timestamp => Ts, signature => sign(KeyPair, CitizenDid, Ts, Procedure)}.

accepts_a_genuine_fresh_proof_test() ->
    KeyPair = macula_identity:generate(),
    Did = macula_identity:public(KeyPair),
    ?assertEqual(ok, citizen_ownership_proof:verify(Did, fresh_proof(KeyPair, Did, ?PROC), ?PROC)).

rejects_a_signature_from_a_different_key_test() ->
    Impostor = macula_identity:generate(),
    Owner = macula_identity:generate(),
    Did = macula_identity:public(Owner),
    Proof = fresh_proof(Impostor, Did, ?PROC),
    ?assertEqual({error, bad_signature}, citizen_ownership_proof:verify(Did, Proof, ?PROC)).

rejects_a_stale_timestamp_test() ->
    KeyPair = macula_identity:generate(),
    Did = macula_identity:public(KeyPair),
    Ts = erlang:system_time(millisecond) - 120_000,
    Proof = #{timestamp => Ts, signature => sign(KeyPair, Did, Ts, ?PROC)},
    ?assertEqual({error, stale_proof}, citizen_ownership_proof:verify(Did, Proof, ?PROC)).

rejects_a_missing_proof_test() ->
    KeyPair = macula_identity:generate(),
    Did = macula_identity:public(KeyPair),
    ?assertEqual({error, missing_proof}, citizen_ownership_proof:verify(Did, #{}, ?PROC)).

%% decode_did/1 -- the wire hands hex TEXT, not raw bytes.

decodes_wire_hex_text_to_raw_bytes_test() ->
    KeyPair = macula_identity:generate(),
    Did = macula_identity:public(KeyPair),
    HexDid = binary:encode_hex(Did, lowercase),
    ?assertEqual(Did, citizen_ownership_proof:decode_did(HexDid)).

accepts_a_genuine_proof_shaped_exactly_like_the_wire_test() ->
    KeyPair = macula_identity:generate(),
    Did = macula_identity:public(KeyPair),
    Ts = erlang:system_time(millisecond),
    RawSig = macula_identity:sign(citizen_ownership_proof:message(Did, Ts, ?PROC), KeyPair),
    WireDid = binary:encode_hex(Did, lowercase),
    WireProof = #{timestamp => Ts, signature => binary:encode_hex(RawSig, lowercase)},
    DecodedDid = citizen_ownership_proof:decode_did(WireDid),
    ?assertEqual(ok, citizen_ownership_proof:verify(DecodedDid, WireProof, ?PROC)).
