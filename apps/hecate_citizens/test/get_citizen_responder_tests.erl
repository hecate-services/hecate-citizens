%%% @doc get_citizen's replies on the wire, against a real barrel_docdb
%%% read model: a found citizen in citizen_read_model:to_wire/1's shape,
%%% and `not_found' as `{text, Bin}' (CBOR text) rather than a byte string.
-module(get_citizen_responder_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DB, <<"get_citizen_responder_tests_db">>).
-define(HEX_DID, <<"4f769c4e76402f3a0114f00f81a6b255f8f3298a1a9029ea5cf8a25c1463d7a0">>).

get_citizen_test_() ->
    {setup, fun setup/0, fun teardown/1, fun replies/1}.

setup() ->
    {ok, _} = application:ensure_all_started(barrel_docdb),
    _ = barrel_docdb:delete_db(?DB),
    {ok, _} = barrel_docdb:create_db(?DB),
    persistent_term:put(hecate_om_read_model_db, ?DB),
    ok.

teardown(_) ->
    _ = barrel_docdb:delete_db(?DB),
    persistent_term:erase(hecate_om_read_model_db),
    ok.

replies(ok) ->
    ok = citizen_read_model:upsert(#{
        citizen_did => binary:decode_hex(?HEX_DID), citizen_kind => <<"agent">>,
        display_name => <<"metis">>, offers => [],
        expires_at => erlang:system_time(millisecond) + 60_000}),
    Unknown = binary:encode_hex(crypto:strong_rand_bytes(32), lowercase),
    {reply, Found, []} =
        get_citizen_responder:handle_request(#{citizen_did => {text, ?HEX_DID}}, []),
    {reply, Missing, []} =
        get_citizen_responder:handle_request(#{citizen_did => {text, Unknown}}, []),
    [?_assertMatch(#{ok := 1, citizen := #{citizen_did := {text, ?HEX_DID},
                                           display_name := {text, <<"metis">>}}},
                   Found),
     ?_assertEqual(#{ok => 0, error => {text, <<"not_found">>}}, Missing)].
