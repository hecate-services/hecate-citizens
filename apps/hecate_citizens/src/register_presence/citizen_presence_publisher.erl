%%% @doc Trivial fire-and-forget macula_publisher callback for
%%% `register_presence_responder''s federation publish -- it doesn't need
%%% to react to the publish outcome, just the supervised pid/mesh-fact
%%% machinery macula_publisher already provides around a bare
%%% macula:publish/4. Same pattern as hecate-tube's tube_mesh_publisher.
%%% @end
-module(citizen_presence_publisher).

-behaviour(macula_publisher).

-export([init/1, handle_published/2]).

init(_Args) -> {ok, undefined}.

handle_published(_Result, State) -> {stop, normal, State}.
