%%% @doc Regression test for a real production incident: register_presence_
%%% responder:publish_via/2 calls
%%% `macula_publisher:start_link(citizen_presence_publisher, ...)' and
%%% unconditionally pattern-matches `{ok, _Pid} = ...' on the result --
%%% but `citizen_presence_publisher' never existed as a module. Every
%%% `hecate_citizens.register_presence' call crashed AFTER the local
%%% write already committed, surfacing to a caller as a BOLT#4
%%% temporary_relay_failure (a recovered handler panic), on both the
%%% plain call and the direct-dial path -- confirmed live 2026-09-04.
%%%
%%% Exercising `citizen_presence_publisher:init/1' directly is enough to
%%% catch this bug class: before the fix, this call raised `undef' since
%%% the module didn't exist at all -- the same failure
%%% `macula_publisher:init/1' hit internally via `Module:init(InitArgs)',
%%% just without needing a real mesh pool to reach it.
-module(citizen_presence_publisher_tests).

-include_lib("eunit/include/eunit.hrl").

init_and_handle_published_test() ->
    ?assertEqual({ok, undefined}, citizen_presence_publisher:init([])),
    ?assertEqual({stop, normal, undefined},
                 citizen_presence_publisher:handle_published(ok, undefined)),
    ?assertEqual({stop, normal, undefined},
                 citizen_presence_publisher:handle_published({error, boom}, undefined)).
