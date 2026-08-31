%%% @doc TEMPORARY diagnostic responder -- echoes the raw Payload map
%%% it received, verbatim, so a live mesh_call's actual wire shape can
%%% be observed directly instead of inferred. Remove before this repo's
%%% next real commit.
%%% @end
-module(debug_echo_responder).
-behaviour(macula_response).

-export([init/1, handle_request/2]).

init(_Args) -> {ok, []}.

-spec handle_request(map(), term()) -> {reply, map(), term()}.
handle_request(Payload, State) ->
    {reply, #{ok => 1, echo => describe(Payload)}, State}.

describe(Payload) when is_map(Payload) ->
    maps:fold(fun(K, V, Acc) -> Acc#{key_binary(K) => describe_term(V)} end, #{}, Payload);
describe(Other) ->
    describe_term(Other).

key_binary(K) when is_binary(K) -> K;
key_binary(K) when is_atom(K) -> atom_to_binary(K, utf8).

describe_term(V) when is_binary(V) ->
    #{type => binary, byte_size => byte_size(V), value => V};
describe_term(V) when is_atom(V) ->
    #{type => atom, value => atom_to_binary(V, utf8)};
describe_term(V) when is_integer(V) ->
    #{type => integer, value => V};
describe_term(V) when is_list(V) ->
    #{type => list, length => length(V)};
describe_term(V) when is_map(V) ->
    #{type => map, keys => maps:size(V)};
describe_term(_V) ->
    #{type => other}.
