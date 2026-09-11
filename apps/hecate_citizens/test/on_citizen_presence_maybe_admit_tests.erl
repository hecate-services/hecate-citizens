%%% @doc Tests for on_citizen_presence_maybe_admit's pure functions --
%%% zero mesh, zero store, runs in the default `rebar3 eunit' gate.
%%%
%%% `with_expiry/2': the expiry a registration gets from this instance's own
%%% arithmetic, and the registrations refused outright. `decide/2': which of
%%% two registrations of one citizen wins.
-module(on_citizen_presence_maybe_admit_tests).

-include_lib("eunit/include/eunit.hrl").

-define(MINUTE, 60_000).
-define(NOW, 1_788_000_000_000).

%%------------------------------------------------------------------------------
%% with_expiry/2
%%------------------------------------------------------------------------------

presence(RegisteredAt, TtlMs) ->
    #{citizen_did => <<7:256>>, registered_at => RegisteredAt, ttl_ms => TtlMs}.

expiry(Presence) ->
    {ok, #{expires_at := ExpiresAt, ttl_ms := TtlMs}} =
        on_citizen_presence_maybe_admit:with_expiry(Presence, ?NOW),
    {ExpiresAt, TtlMs}.

expires_one_ttl_after_registration_test() ->
    ?assertEqual({?NOW + 5 * ?MINUTE, 5 * ?MINUTE}, expiry(presence(?NOW, 5 * ?MINUTE))).

caps_a_ttl_above_twenty_minutes_test() ->
    ?assertEqual({?NOW + 20 * ?MINUTE, 20 * ?MINUTE},
                 expiry(presence(?NOW, 30 * 24 * 60 * ?MINUTE))).

%% A registration inside the clock allowance still expires no later than
%% twenty minutes from this instance's own clock.
caps_the_expiry_at_twenty_minutes_from_this_clock_test() ->
    ?assertEqual({?NOW + 20 * ?MINUTE, 20 * ?MINUTE},
                 expiry(presence(?NOW + 59_000, 20 * ?MINUTE))).

never_reads_an_expires_at_from_the_input_test() ->
    Planted = (presence(?NOW, ?MINUTE))#{expires_at => ?NOW + 10 * 24 * 60 * ?MINUTE},
    ?assertEqual({?NOW + ?MINUTE, ?MINUTE}, expiry(Planted)).

%% What a replayed old fact turns into: an entry that is already over.
an_old_registration_is_already_expired_test() ->
    ?assertEqual({?NOW - 10 * ?MINUTE, 20 * ?MINUTE},
                 expiry(presence(?NOW - 30 * ?MINUTE, 20 * ?MINUTE))).

accepts_a_registration_a_minute_ahead_of_this_clock_test() ->
    ?assertMatch({ok, _},
                 on_citizen_presence_maybe_admit:with_expiry(presence(?NOW + ?MINUTE, ?MINUTE), ?NOW)).

%% An instance whose clock runs fast must not hold entries against every
%% later registration until its clock catches up.
refuses_a_registration_more_than_a_minute_ahead_of_this_clock_test() ->
    ?assertEqual({refused, registered_at_ahead_of_clock},
                 on_citizen_presence_maybe_admit:with_expiry(presence(?NOW + ?MINUTE + 1, ?MINUTE), ?NOW)).

refuses_a_ttl_that_is_not_a_positive_integer_test() ->
    [?assertEqual({refused, invalid_ttl_ms},
                  on_citizen_presence_maybe_admit:with_expiry(presence(?NOW, TtlMs), ?NOW))
     || TtlMs <- [0, -1, 1.5, <<"600000">>, {text, <<"600000">>}, undefined]].

refuses_a_registered_at_that_is_not_an_integer_test() ->
    [?assertEqual({refused, invalid_registered_at},
                  on_citizen_presence_maybe_admit:with_expiry(presence(RegisteredAt, ?MINUTE), ?NOW))
     || RegisteredAt <- [undefined, <<"1788000000000">>, 1.788e12]].

%%------------------------------------------------------------------------------
%% decide/2
%%------------------------------------------------------------------------------

stored(RegisteredAt, ExpiresAt) ->
    #{<<"registered_at">> => RegisteredAt, <<"expires_at">> => ExpiresAt}.

incoming(RegisteredAt, ExpiresAt) ->
    #{registered_at => RegisteredAt, expires_at => ExpiresAt}.

admits_a_never_seen_citizen_test() ->
    ?assertEqual(admit, on_citizen_presence_maybe_admit:decide(
        undefined, incoming(?NOW, ?NOW + 20 * ?MINUTE))).

admits_a_later_registration_test() ->
    ?assertEqual(admit, on_citizen_presence_maybe_admit:decide(
        stored(?NOW, ?NOW + 20 * ?MINUTE), incoming(?NOW + 1, ?NOW + 20 * ?MINUTE + 1))).

%% Every instance hears its own publish back, so the same registration
%% arrives a second time.
admits_the_same_registration_again_test() ->
    ?assertEqual(admit, on_citizen_presence_maybe_admit:decide(
        stored(?NOW, ?NOW + 20 * ?MINUTE), incoming(?NOW, ?NOW + 20 * ?MINUTE))).

drops_an_earlier_registration_test() ->
    ?assertEqual(stale, on_citizen_presence_maybe_admit:decide(
        stored(?NOW, ?NOW + 20 * ?MINUTE), incoming(?NOW - 1, ?NOW + 30 * ?MINUTE))).

an_owner_who_shortens_the_ttl_still_replaces_the_entry_test() ->
    ?assertEqual(admit, on_citizen_presence_maybe_admit:decide(
        stored(?NOW, ?NOW + 20 * ?MINUTE), incoming(?NOW + ?MINUTE, ?NOW + 2 * ?MINUTE))).

an_owner_replaces_an_entry_that_reached_the_cap_test() ->
    ?assertEqual(admit, on_citizen_presence_maybe_admit:decide(
        stored(?NOW, ?NOW + 20 * ?MINUTE), incoming(?NOW + 1_000, ?NOW + 1_000 + ?MINUTE))).

%% An entry stored before registered_at existed has no registration time to
%% compare, however far its expiry reaches.
replaces_an_entry_stored_before_registered_at_existed_test() ->
    ?assertEqual(admit, on_citizen_presence_maybe_admit:decide(
        #{<<"expires_at">> => ?NOW + 10 * 24 * 60 * ?MINUTE}, incoming(?NOW, ?NOW + ?MINUTE))).
