%%% @doc POLICY: the admit/stale decision for an incoming
%%% `hecate_citizens.citizen_presence' fact, whether it arrived as a
%%% federated fact from another instance (via `citizen_presence_listener')
%%% or as this instance's own direct write (via
%%% `register_presence_responder'). One code path either way -- "should
%%% this be written" has exactly one home, per
%%% hecate-corpus/examples/MESH_FACT_READ_MODELS.md.
%%%
%%% `decide/2' is a pure function: no mesh call inside it, trivially
%%% unit-testable with plain terms.
%%% @end
-module(on_citizen_presence_maybe_admit).

-export([handle/1, decide/2]).

-spec handle(map()) -> ok.
handle(#{citizen_did := CitizenDid, expires_at := ExpiresAt} = Fields) ->
    admitted(decide(existing(CitizenDid), ExpiresAt), Fields).

existing(CitizenDid) ->
    found(citizen_read_model:find(CitizenDid)).

found({ok, Doc}) -> Doc;
found({error, not_found}) -> undefined.

admitted(admit, Fields) -> citizen_read_model:upsert(Fields);
admitted(stale, _Fields) -> ok.

-spec decide(map() | undefined, integer()) -> admit | stale.
decide(undefined, _IncomingExpiresAt) ->
    admit;
decide(#{<<"expires_at">> := CurrentExpiresAt}, IncomingExpiresAt)
  when IncomingExpiresAt >= CurrentExpiresAt ->
    admit;
decide(_Existing, _IncomingExpiresAt) ->
    stale.
