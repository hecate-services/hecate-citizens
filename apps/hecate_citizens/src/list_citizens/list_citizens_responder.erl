%%% @doc RESPONDER for the `hecate_citizens.list_citizens` mesh
%%% capability. Ungated -- this is a public directory (PLAN_ROOT.md's
%%% "Trust": a phone book, not a background check), not one citizen's
%%% own private data.
%%% @end
-module(list_citizens_responder).
-behaviour(macula_response).

-export([init/1, handle_request/2]).

init(_Args) -> {ok, []}.

-spec handle_request(map(), term()) -> {reply, map(), term()}.
handle_request(_Payload, State) ->
    {ok, Docs} = citizen_read_model:fold_live(fun(Doc, Acc) -> {ok, [Doc | Acc]} end, []),
    {reply, #{ok => 1, citizens => lists:map(fun citizen_read_model:to_wire/1, Docs)}, State}.
