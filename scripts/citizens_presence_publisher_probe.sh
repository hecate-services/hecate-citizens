#!/usr/bin/env bash
# Read-only: subscribe to hecate_citizens.citizen_presence from this workstation
# with a scratch macula identity, for a fixed time, and print what macula hands a
# subscriber for every fact that arrives: the publisher node id, publisher_verified,
# the delivery path and the payload's key names. No payload values (no DIDs, no
# names). This is what hecate-citizens' listener will see, so it shows whether the
# live instances' facts really arrive signed and verified.
#
# usage: citizens_presence_publisher_probe.sh <worktree with compiled macula> <realm hex> <seconds> <seed urls, comma separated>
set -uo pipefail

W=$1
export PROBE_REALM=$2
export PROBE_SECONDS=$3
export PROBE_SEEDS=$4
ERL=${ERL:-/home/rl/.local/share/mise/installs/erlang/28.4.2/bin/erl}

read -r -d '' PROBE <<'ERLANG'
{ok, _} = application:ensure_all_started(macula),
Seeds = [list_to_binary(S) || S <- string:split(os:getenv("PROBE_SEEDS"), ",", all)],
Realm = binary:decode_hex(list_to_binary(os:getenv("PROBE_REALM"))),
Seconds = list_to_integer(os:getenv("PROBE_SECONDS")),
Topic = <<"hecate_citizens.citizen_presence">>,
{ok, Pool} = macula:connect(Seeds, #{}),
{ok, Ref} = macula:subscribe(Pool, Realm, Topic, self()),
io:format("=== subscribed ~s for ~p s~n", [Topic, Seconds]),
Deadline = erlang:monotonic_time(millisecond) + Seconds * 1000,
Hex = fun(B) when is_binary(B) -> binary:encode_hex(B, lowercase); (Other) -> io_lib:format("~p", [Other]) end,
Keys = fun(P) when is_map(P) -> lists:sort([io_lib:format("~p", [K]) || K <- maps:keys(P)]); (P) -> [io_lib:format("non-map ~p", [element(1, {P})])] end,
Loop = fun Loop(N) ->
    Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {macula_event, Ref, _T, Payload, Meta} ->
            io:format("~s publisher=~s verified=~p via=~p keys=~s~n",
                      [calendar:system_time_to_rfc3339(erlang:system_time(second)),
                       Hex(maps:get(publisher, Meta, undefined)),
                       maps:get(publisher_verified, Meta, missing),
                       maps:get(delivered_via, Meta, missing),
                       lists:join(",", Keys(Payload))]),
            Loop(N + 1)
    after Left ->
        N
    end
end,
Count = Loop(0),
io:format("=== ~p facts in ~p s~n", [Count, Seconds]),
halt(0).
ERLANG

cd "$W" || exit 2
exec "$ERL" -noshell -pa _build/default/lib/*/ebin -eval "$PROBE"
