%%% @doc RESPONDER for the `hecate_citizens.get_citizen` mesh
%%% capability. Ungated, same reasoning as `list_citizens_responder'.
%%% @end
-module(get_citizen_responder).
-behaviour(macula_response).

-export([init/1, handle_request/2]).

init(_Args) -> {ok, []}.

-spec handle_request(map(), term()) -> {reply, map(), term()}.
handle_request(Payload, State) ->
    %% citizen_did arrives as ASCII hex TEXT over the wire, decoded here
    %% -- see citizen_ownership_proof's own doc on why.
    CitizenDid = citizen_ownership_proof:decode_did(hecate_om_wire:field(citizen_did, Payload)),
    Reply = fetched(citizen_read_model:find(CitizenDid)),
    {reply, Reply, State}.

fetched({ok, Doc}) -> #{ok => 1, citizen => citizen_read_model:to_wire(Doc)};
fetched({error, not_found}) -> #{ok => 0, error => <<"not_found">>}.
