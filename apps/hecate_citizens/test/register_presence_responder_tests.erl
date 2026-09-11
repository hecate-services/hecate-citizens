%%% @doc register_presence: its replies, what it stores, and its wire output.
%%%
%%% A proven registration is stamped with this instance's clock as
%%% registered_at, and its TTL is bounded by Policy: above twenty minutes it
%%% is capped, and one that is not a positive integer is refused with a text
%%% error rather than crashing the handler. The error reply and the
%%% citizen_presence fact carry text as `{text, Bin}' (CBOR text), so non-BEAM
%%% callers and subscribers get strings instead of bytes. The federation case
%%% runs the fact through the real listener into a real barrel_docdb read
%%% model, the way a listed instance receives it.
-module(register_presence_responder_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DB, <<"register_presence_responder_tests_db">>).
-define(PROCEDURE, <<"hecate_citizens.register_presence">>).
-define(HEX_DID, <<"4f769c4e76402f3a0114f00f81a6b255f8f3298a1a9029ea5cf8a25c1463d7a0">>).
-define(INSTANCE, <<1:256>>).
-define(MINUTE, 60_000).

fields() ->
    RegisteredAt = erlang:system_time(millisecond),
    #{citizen_did => binary:decode_hex(?HEX_DID), citizen_kind => <<"agent">>,
      display_name => <<"metis">>, offers => [<<"conversation">>],
      registered_at => RegisteredAt, ttl_ms => 20 * ?MINUTE,
      expires_at => RegisteredAt + 20 * ?MINUTE}.

%% A DID that doesn't decode fails the proof check before anything is
%% written or published, so this needs neither a read model nor a mesh.
unproven_registration_replies_its_error_as_text_test() ->
    ?assertEqual({reply, #{ok => 0, error => {text, <<"invalid_citizen_did">>}}, []},
                 register_presence_responder:handle_request(
                   #{citizen_did => {text, <<"not-a-did">>}}, [])).

%% registered_at and ttl_ms are what a receiving instance computes its own
%% expiry from. expires_at stays for subscribers that show it.
presence_fact_sends_text_as_text_and_the_did_as_hex_test() ->
    #{registered_at := RegisteredAt, expires_at := ExpiresAt} = Fields = fields(),
    ?assertEqual(#{citizen_did => {text, ?HEX_DID},
                   citizen_kind => {text, <<"agent">>},
                   display_name => {text, <<"metis">>},
                   offers => [{text, <<"conversation">>}],
                   registered_at => RegisteredAt,
                   ttl_ms => 20 * ?MINUTE,
                   expires_at => ExpiresAt},
                 register_presence_responder:presence_fact(Fields)).

presence_fact_omits_what_the_caller_left_out_test() ->
    Fact = register_presence_responder:presence_fact(
             (fields())#{citizen_kind => undefined, display_name => undefined}),
    ?assertNot(maps:is_key(citizen_kind, Fact)),
    ?assertNot(maps:is_key(display_name, Fact)).

registrations_test_() ->
    {foreach, fun setup/0, fun teardown/1,
     [fun federates_through_the_listener/1,
      fun stamps_registered_at_from_this_clock/1,
      fun caps_a_ttl_above_twenty_minutes/1,
      fun refuses_a_ttl_that_is_not_a_positive_integer/1,
      fun refuses_a_proof_presented_by_another_caller/1,
      fun refuses_a_registration_without_a_caller/1]}.

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

%% A listed instance decodes the hex DID and the text fields back into the
%% same stored citizen that the registering instance wrote.
federates_through_the_listener(ok) ->
    #{citizen_did := CitizenDid, registered_at := RegisteredAt} = Fields = fields(),
    Fact = register_presence_responder:presence_fact(Fields),
    {noreply, [?INSTANCE]} = citizen_presence_listener:handle_event(
                               <<"hecate_citizens.citizen_presence">>, Fact,
                               #{publisher => ?INSTANCE, publisher_verified => true},
                               [?INSTANCE]),
    {ok, Doc} = citizen_read_model:find(CitizenDid),
    [?_assertEqual(CitizenDid, maps:get(<<"citizen_did">>, Doc)),
     ?_assertEqual(<<"agent">>, maps:get(<<"citizen_kind">>, Doc)),
     ?_assertEqual(<<"metis">>, maps:get(<<"display_name">>, Doc)),
     ?_assertEqual([<<"conversation">>], maps:get(<<"offers">>, Doc)),
     ?_assertEqual(RegisteredAt, maps:get(<<"registered_at">>, Doc)),
     ?_assertEqual(RegisteredAt + 20 * ?MINUTE, maps:get(<<"expires_at">>, Doc))].

stamps_registered_at_from_this_clock(ok) ->
    {Did, Payload} = proven(default),
    Before = now_ms(),
    #{ok := 1, expires_at := ExpiresAt} = register(Payload),
    After = now_ms(),
    {ok, Doc} = citizen_read_model:find(Did),
    RegisteredAt = maps:get(<<"registered_at">>, Doc),
    [?_assert(Before =< RegisteredAt andalso RegisteredAt =< After),
     ?_assertEqual(RegisteredAt + 20 * ?MINUTE, ExpiresAt),
     ?_assertEqual(ExpiresAt, maps:get(<<"expires_at">>, Doc))].

caps_a_ttl_above_twenty_minutes(ok) ->
    {Did, Payload} = proven(30 * 24 * 60 * ?MINUTE),
    #{ok := 1, expires_at := ExpiresAt} = register(Payload),
    {ok, Doc} = citizen_read_model:find(Did),
    [?_assertEqual(maps:get(<<"registered_at">>, Doc) + 20 * ?MINUTE, ExpiresAt),
     ?_assertEqual(ExpiresAt, maps:get(<<"expires_at">>, Doc))].

%% A text ttl_ms used to reach the addition and crash the handler.
refuses_a_ttl_that_is_not_a_positive_integer(ok) ->
    Outcomes = [outcome(proven(TtlMs)) || TtlMs <- [0, -5, 1.5, {text, <<"soon">>}]],
    [?_assertEqual({#{ok => 0, error => {text, <<"invalid_ttl_ms">>}}, {error, not_found}},
                   Outcome)
     || Outcome <- Outcomes].

%% A valid proof is worth nothing to anyone but its owner: replaying a
%% captured one needs a CALL signed with the citizen's own key.
refuses_a_proof_presented_by_another_caller(ok) ->
    {Did, Payload} = proven(default),
    {Other, _OtherPriv} = crypto:generate_key(eddsa, ed25519),
    [?_assertEqual({#{ok => 0, error => {text, <<"citizen_did_is_not_the_caller">>}},
                    {error, not_found}},
                   outcome({Did, Payload#{caller => Other}}))].

refuses_a_registration_without_a_caller(ok) ->
    {Did, Payload} = proven(default),
    [?_assertEqual({#{ok => 0, error => {text, <<"citizen_did_is_not_the_caller">>}},
                    {error, not_found}},
                   outcome({Did, maps:remove(caller, Payload)}))].

%%------------------------------------------------------------------------------

outcome({Did, Payload}) ->
    {register(Payload), citizen_read_model:find(Did)}.

register(Payload) ->
    {reply, Reply, []} = register_presence_responder:handle_request(Payload, []),
    Reply.

%% A register_presence payload with a valid ownership proof for a fresh key,
%% as it reaches the handler: text arrives `{text, Bin}'-tagged, and macula
%% puts the CALL's verified caller in under `caller'.
proven(TtlMs) ->
    {Pub, Priv} = crypto:generate_key(eddsa, ed25519),
    Ts = now_ms(),
    Sig = crypto:sign(eddsa, none, citizen_ownership_proof:message(Pub, Ts, ?PROCEDURE),
                      [Priv, ed25519]),
    Payload = #{citizen_did => {text, binary:encode_hex(Pub, lowercase)},
                proof => #{timestamp => Ts,
                           signature => {text, binary:encode_hex(Sig, lowercase)}},
                citizen_kind => {text, <<"agent">>},
                display_name => {text, <<"metis">>},
                caller => Pub},
    {Pub, with_ttl(TtlMs, Payload)}.

with_ttl(default, Payload) -> Payload;
with_ttl(TtlMs, Payload) -> Payload#{ttl_ms => TtlMs}.

now_ms() -> erlang:system_time(millisecond).
