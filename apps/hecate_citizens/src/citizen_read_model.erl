%%% @doc The citizen directory every desk reads through directly --
%%% `on_citizen_presence_maybe_admit' writes here, `list_citizens'/
%%% `get_citizen' read here, neither ever touches `barrel_docdb' any
%%% other way. One document per citizen, keyed by `citizen_did', in the
%%% database `hecate_citizens_service:read_model_id/0' names.
%%%
%%% Filters expired entries at READ time
%%% (hecate-corpus/examples/MESH_FACT_READ_MODELS.md's "Correct Way"):
%%% a citizen who stops re-registering ages out on its own schedule,
%%% with no tombstone and no background sweep required for correctness.
%%% @end
-module(citizen_read_model).

-export([upsert/1, find/1, fold_live/2, to_wire/1]).

-spec upsert(map()) -> ok.
upsert(#{citizen_did := CitizenDid, expires_at := ExpiresAt} = Fields)
  when is_binary(CitizenDid), is_integer(ExpiresAt) ->
    Doc = #{
        <<"id">> => id(CitizenDid),
        <<"citizen_did">> => CitizenDid,
        <<"citizen_kind">> => maps:get(citizen_kind, Fields),
        <<"display_name">> => maps:get(display_name, Fields, undefined),
        <<"offers">> => maps:get(offers, Fields, []),
        <<"expires_at">> => ExpiresAt
    },
    put(Doc).

-spec find(binary()) -> {ok, map()} | {error, not_found}.
find(CitizenDid) when is_binary(CitizenDid) ->
    live(get_doc(id(CitizenDid))).

live({ok, #{<<"expires_at">> := ExpiresAt} = Doc}) ->
    not_expired(ExpiresAt > erlang:system_time(millisecond), Doc);
live({error, not_found}) ->
    {error, not_found}.

not_expired(true, Doc) -> {ok, Doc};
not_expired(false, _Doc) -> {error, not_found}.

%% @doc Fold every still-live citizen doc through Fun/2 (same shape as
%% barrel_docdb:fold_docs/3's own callback) -- list_citizens builds its
%% result over this.
-spec fold_live(fun((map(), Acc) -> {ok, Acc}), Acc) -> {ok, Acc}.
fold_live(Fun, Acc) ->
    Now = erlang:system_time(millisecond),
    {ok, DbName} = hecate_om:read_model(),
    barrel_docdb:fold_docs(DbName, fun(Doc, A) -> skip_expired(Now, Doc, Fun, A) end, Acc).

skip_expired(Now, #{<<"expires_at">> := ExpiresAt} = Doc, Fun, Acc) when ExpiresAt > Now ->
    Fun(Doc, Acc);
skip_expired(_Now, _Doc, _Fun, Acc) ->
    {ok, Acc}.

%% @doc A stored doc, shaped for an RPC reply -- `undefined' fields
%% omitted (`maybe_put' convention, `station_read_model').
-spec to_wire(map()) -> map().
to_wire(Doc) ->
    omit_undefined(#{
        citizen_did => maps:get(<<"citizen_did">>, Doc),
        citizen_kind => maps:get(<<"citizen_kind">>, Doc),
        display_name => maps:get(<<"display_name">>, Doc, undefined),
        offers => maps:get(<<"offers">>, Doc, []),
        expires_at => maps:get(<<"expires_at">>, Doc)
    }).

omit_undefined(Map) ->
    maps:filter(fun(_K, V) -> V =/= undefined end, Map).

id(CitizenDid) ->
    binary:encode_hex(CitizenDid, lowercase).

get_doc(Id) ->
    {ok, DbName} = hecate_om:read_model(),
    barrel_docdb:get_doc(DbName, Id).

put(Doc) ->
    {ok, DbName} = hecate_om:read_model(),
    {ok, _} = barrel_docdb:put_doc(DbName, Doc),
    ok.
