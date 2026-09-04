%%% @doc Regression test for a real production incident: citizen_read_model:
%%% upsert/1 built a fresh doc map from scratch on every call, never
%%% carrying forward the existing doc's `_rev'. barrel_docdb requires the
%%% current `_rev' on a write over an existing document (optimistic
%%% concurrency) and correctly refuses a blind write with
%%% `{error, conflict}' -- which crashed put/1's own `{ok, _} = ...'
%%% match. Every RE-registration of an already-known citizen crashed
%%% register_presence AFTER the very first successful one, confirmed live
%%% 2026-09-04 (the exact same identity failing on every retry after its
%%% first successful registration).
%%%
%%% Fixed by reading the existing doc first and merging new fields into
%%% it (carrying its `_rev' forward), the same pattern hecate-stations'
%%% station_read_model already establishes for the identical situation
%%% (a heartbeat re-upserting the same node_id doc).
%%%
%%% Genuine integration test against a real barrel_docdb instance --
%%% upsert/1's actual bug was in its database interaction, not in any
%%% pure logic a mocked/DB-free test could have caught (see this repo's
%%% own citizen_read_model_tests.erl, which deliberately tests only
%%% to_wire/1 "without a database").
-module(citizen_read_model_upsert_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DB, <<"citizen_read_model_upsert_tests_db">>).

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

upsert_test_() ->
    {setup, fun setup/0, fun teardown/1, fun cases/0}.

cases() ->
    CitizenDid = crypto:strong_rand_bytes(32),
    First = #{citizen_did => CitizenDid, citizen_kind => <<"agent">>,
              display_name => <<"metis">>, offers => [<<"conversation">>],
              expires_at => erlang:system_time(millisecond) + 1_200_000},
    [
        ?_assertEqual(ok, citizen_read_model:upsert(First)),
        %% The re-registration that used to crash: same citizen_did, a
        %% write over the doc upsert/1 just created above.
        ?_assertEqual(ok, citizen_read_model:upsert(
            First#{expires_at => erlang:system_time(millisecond) + 1_300_000})),
        %% A third call, for good measure -- proves this isn't "works
        %% once more, then breaks again" (e.g. a rev that was carried
        %% forward once but not persisted correctly for the next round).
        ?_assertEqual(ok, citizen_read_model:upsert(
            First#{expires_at => erlang:system_time(millisecond) + 1_400_000})),
        ?_assertMatch({ok, #{<<"citizen_did">> := CitizenDid}},
                      citizen_read_model:find(CitizenDid))
    ].
