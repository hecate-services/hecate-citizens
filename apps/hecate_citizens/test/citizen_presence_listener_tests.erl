%%% @doc citizen_presence_listener against a real barrel_docdb read model:
%%% which facts it hands to Policy, and what gets stored from them.
%%%
%%% The topic is open to anyone in the realm, so a fact counts only when
%%% macula verified its publisher signature AND the publisher is one of the
%%% hecate-citizens instances the listener was started with. What is stored
%%% expires by this instance's own arithmetic over the fact's registered_at
%%% and ttl_ms, never at the fact's own expires_at, and the latest
%%% registration wins.
-module(citizen_presence_listener_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DB, <<"citizen_presence_listener_tests_db">>).
-define(TOPIC, <<"hecate_citizens.citizen_presence">>).
-define(LISTED, <<1:256>>).
-define(UNLISTED, <<2:256>>).
-define(MINUTE, 60_000).
-define(MONTH, 30 * 24 * 60 * ?MINUTE).

listener_test_() ->
    {foreach, fun setup/0, fun teardown/1,
     [fun admits_a_verified_fact_from_a_listed_instance/1,
      fun refuses_a_fact_from_an_instance_not_listed/1,
      fun refuses_an_unsigned_fact_from_a_listed_instance/1,
      fun refuses_a_fact_whose_signature_failed/1,
      fun stores_its_own_expiry_not_the_facts/1,
      fun caps_a_ttl_above_twenty_minutes/1,
      fun refuses_a_fact_without_registered_at/1,
      fun refuses_a_registration_more_than_a_minute_ahead/1,
      fun an_owners_later_registration_replaces_a_capped_one/1,
      fun a_replayed_earlier_registration_replaces_nothing/1]}.

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

admits_a_verified_fact_from_a_listed_instance(ok) ->
    Did = did(),
    RegisteredAt = now_ms(),
    ok = deliver(fact(Did, RegisteredAt, 20 * ?MINUTE), verified(?LISTED)),
    {ok, Doc} = citizen_read_model:find(Did),
    [?_assertEqual(<<"agent">>, maps:get(<<"citizen_kind">>, Doc)),
     ?_assertEqual(<<"metis">>, maps:get(<<"display_name">>, Doc)),
     ?_assertEqual([<<"conversation">>], maps:get(<<"offers">>, Doc)),
     ?_assertEqual(RegisteredAt, maps:get(<<"registered_at">>, Doc)),
     ?_assertEqual(RegisteredAt + 20 * ?MINUTE, maps:get(<<"expires_at">>, Doc))].

refuses_a_fact_from_an_instance_not_listed(ok) ->
    Did = did(),
    ok = deliver(fact(Did, now_ms(), 20 * ?MINUTE), verified(?UNLISTED)),
    [?_assertEqual({error, not_found}, citizen_read_model:find(Did))].

%% What a PUBLISH without publisher_sig arrives as. Stations still relay one.
refuses_an_unsigned_fact_from_a_listed_instance(ok) ->
    Did = did(),
    ok = deliver(fact(Did, now_ms(), 20 * ?MINUTE),
                 #{publisher => ?LISTED, publisher_verified => not_signed}),
    [?_assertEqual({error, not_found}, citizen_read_model:find(Did))].

%% Delivered at all only when macula's pubsub_strict_publisher_sig is off.
refuses_a_fact_whose_signature_failed(ok) ->
    Did = did(),
    ok = deliver(fact(Did, now_ms(), 20 * ?MINUTE),
                 #{publisher => ?LISTED, publisher_verified => false}),
    [?_assertEqual({error, not_found}, citizen_read_model:find(Did))].

stores_its_own_expiry_not_the_facts(ok) ->
    Did = did(),
    RegisteredAt = now_ms(),
    Fact = (fact(Did, RegisteredAt, ?MINUTE))#{expires_at => RegisteredAt + ?MONTH},
    ok = deliver(Fact, verified(?LISTED)),
    {ok, Doc} = citizen_read_model:find(Did),
    [?_assertEqual(RegisteredAt + ?MINUTE, maps:get(<<"expires_at">>, Doc))].

caps_a_ttl_above_twenty_minutes(ok) ->
    Did = did(),
    RegisteredAt = now_ms(),
    ok = deliver(fact(Did, RegisteredAt, ?MONTH), verified(?LISTED)),
    {ok, Doc} = citizen_read_model:find(Did),
    [?_assertEqual(RegisteredAt + 20 * ?MINUTE, maps:get(<<"expires_at">>, Doc))].

%% The shape an instance published before registered_at existed: its only
%% expiry is the one it names itself, which is never taken.
refuses_a_fact_without_registered_at(ok) ->
    Did = did(),
    Fact = maps:without([registered_at, ttl_ms], fact(Did, now_ms(), 20 * ?MINUTE)),
    ok = deliver(Fact, verified(?LISTED)),
    [?_assertEqual({error, not_found}, citizen_read_model:find(Did))].

%% A listed instance whose clock runs fast must not stamp registrations that
%% win against every later one until its clock catches up.
refuses_a_registration_more_than_a_minute_ahead(ok) ->
    Ahead = did(),
    Within = did(),
    Now = now_ms(),
    ok = deliver(fact(Ahead, Now + 2 * ?MINUTE, 20 * ?MINUTE), verified(?LISTED)),
    ok = deliver(fact(Within, Now + 30_000, 20 * ?MINUTE), verified(?LISTED)),
    {ok, Doc} = citizen_read_model:find(Within),
    [?_assertEqual({error, not_found}, citizen_read_model:find(Ahead)),
     ?_assert(maps:get(<<"expires_at">>, Doc) =< now_ms() + 20 * ?MINUTE)].

an_owners_later_registration_replaces_a_capped_one(ok) ->
    Did = did(),
    First = now_ms() - 5_000,
    ok = deliver(fact(Did, First, ?MONTH, <<"planted">>), verified(?LISTED)),
    ok = deliver(fact(Did, First + 1_000, ?MINUTE, <<"owner">>), verified(?LISTED)),
    {ok, Doc} = citizen_read_model:find(Did),
    [?_assertEqual(<<"owner">>, maps:get(<<"display_name">>, Doc)),
     ?_assertEqual(First + 1_000 + ?MINUTE, maps:get(<<"expires_at">>, Doc))].

a_replayed_earlier_registration_replaces_nothing(ok) ->
    Did = did(),
    Current = now_ms(),
    ok = deliver(fact(Did, Current, 20 * ?MINUTE, <<"current">>), verified(?LISTED)),
    ok = deliver(fact(Did, Current - ?MINUTE, 20 * ?MINUTE, <<"replayed">>), verified(?LISTED)),
    {ok, Doc} = citizen_read_model:find(Did),
    [?_assertEqual(<<"current">>, maps:get(<<"display_name">>, Doc)),
     ?_assertEqual(Current, maps:get(<<"registered_at">>, Doc))].

%%------------------------------------------------------------------------------

deliver(Fact, Meta) ->
    {noreply, [?LISTED]} =
        citizen_presence_listener:handle_event(?TOPIC, Fact, Meta, [?LISTED]),
    ok.

verified(Publisher) ->
    #{publisher => Publisher, publisher_verified => true}.

fact(Did, RegisteredAt, TtlMs) ->
    fact(Did, RegisteredAt, TtlMs, <<"metis">>).

%% The fact exactly as register_presence_responder publishes it.
fact(Did, RegisteredAt, TtlMs, DisplayName) ->
    register_presence_responder:presence_fact(#{
        citizen_did => Did, citizen_kind => <<"agent">>, display_name => DisplayName,
        offers => [<<"conversation">>], registered_at => RegisteredAt,
        ttl_ms => TtlMs, expires_at => RegisteredAt + TtlMs}).

did() -> crypto:strong_rand_bytes(32).

now_ms() -> erlang:system_time(millisecond).
