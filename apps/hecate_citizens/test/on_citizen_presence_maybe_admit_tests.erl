%%% @doc Tests for on_citizen_presence_maybe_admit's pure decide/2 --
%%% zero mesh, zero store, runs in the default `rebar3 eunit' gate.
-module(on_citizen_presence_maybe_admit_tests).

-include_lib("eunit/include/eunit.hrl").

admits_a_never_seen_citizen_test() ->
    ?assertEqual(admit, on_citizen_presence_maybe_admit:decide(undefined, 12345)).

admits_a_fresher_republish_test() ->
    ?assertEqual(admit, on_citizen_presence_maybe_admit:decide(
        #{<<"expires_at">> => 100}, 200)).

admits_an_equal_expires_at_test() ->
    ?assertEqual(admit, on_citizen_presence_maybe_admit:decide(
        #{<<"expires_at">> => 200}, 200)).

drops_a_late_stale_delivery_test() ->
    ?assertEqual(stale, on_citizen_presence_maybe_admit:decide(
        #{<<"expires_at">> => 200}, 100)).
