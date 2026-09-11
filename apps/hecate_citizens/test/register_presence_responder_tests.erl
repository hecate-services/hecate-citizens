%%% @doc register_presence's wire output: the error reply and the
%%% citizen_presence fact carry text as `{text, Bin}' (CBOR text), so
%%% non-BEAM callers and subscribers get strings instead of bytes. The
%%% federation case runs the fact through the real listener into a real
%%% barrel_docdb read model, the way another instance receives it.
-module(register_presence_responder_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DB, <<"register_presence_responder_tests_db">>).
-define(HEX_DID, <<"4f769c4e76402f3a0114f00f81a6b255f8f3298a1a9029ea5cf8a25c1463d7a0">>).

fields() ->
    #{citizen_did => binary:decode_hex(?HEX_DID), citizen_kind => <<"agent">>,
      display_name => <<"metis">>, offers => [<<"conversation">>],
      expires_at => erlang:system_time(millisecond) + 1_200_000}.

%% A DID that doesn't decode fails the proof check before anything is
%% written or published, so this needs neither a read model nor a mesh.
unproven_registration_replies_its_error_as_text_test() ->
    ?assertEqual({reply, #{ok => 0, error => {text, <<"invalid_citizen_did">>}}, []},
                 register_presence_responder:handle_request(
                   #{citizen_did => {text, <<"not-a-did">>}}, [])).

presence_fact_sends_text_as_text_and_the_did_as_hex_test() ->
    #{expires_at := ExpiresAt} = Fields = fields(),
    ?assertEqual(#{citizen_did => {text, ?HEX_DID},
                   citizen_kind => {text, <<"agent">>},
                   display_name => {text, <<"metis">>},
                   offers => [{text, <<"conversation">>}],
                   expires_at => ExpiresAt},
                 register_presence_responder:presence_fact(Fields)).

presence_fact_omits_what_the_caller_left_out_test() ->
    Fact = register_presence_responder:presence_fact(
             (fields())#{citizen_kind => undefined, display_name => undefined}),
    ?assertNot(maps:is_key(citizen_kind, Fact)),
    ?assertNot(maps:is_key(display_name, Fact)).

presence_fact_federates_through_the_listener_test_() ->
    {setup, fun setup/0, fun teardown/1, fun federated/1}.

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

%% Another instance decodes the hex DID and the text fields back into the
%% same stored citizen that the registering instance wrote.
federated(ok) ->
    #{citizen_did := CitizenDid, expires_at := ExpiresAt} = Fields = fields(),
    Fact = register_presence_responder:presence_fact(Fields),
    {noreply, []} = citizen_presence_listener:handle_event(
                      <<"hecate_citizens.citizen_presence">>, Fact, #{}, []),
    {ok, Doc} = citizen_read_model:find(CitizenDid),
    [?_assertEqual(CitizenDid, maps:get(<<"citizen_did">>, Doc)),
     ?_assertEqual(<<"agent">>, maps:get(<<"citizen_kind">>, Doc)),
     ?_assertEqual(<<"metis">>, maps:get(<<"display_name">>, Doc)),
     ?_assertEqual([<<"conversation">>], maps:get(<<"offers">>, Doc)),
     ?_assertEqual(ExpiresAt, maps:get(<<"expires_at">>, Doc))].
