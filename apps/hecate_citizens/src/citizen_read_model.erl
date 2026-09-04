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
    %% Read-modify-write against whatever's already there -- barrel_docdb
    %% requires a write over an existing doc to carry its current `_rev'
    %% or it refuses with `{error, conflict}' (confirmed live: every
    %% re-registration of an already-known citizen crashed put/1 this
    %% way, since a from-scratch Doc here never carried one). Same
    %% pattern hecate-stations' station_read_model already establishes
    %% for the identical situation (a heartbeat re-upserting the same
    %% node_id doc).
    %%
    %% omit_undefined/1 on the new-fields side: barrel_docdb's automatic
    %% secondary indexing crashes outright on an `undefined' field value
    %% (barrel_store_keys:encode_path_component/1 has no clause for
    %% it) -- confirmed live on hecate-mail's identical pattern,
    %% display_name is `undefined' whenever a citizen doesn't set one.
    New = omit_undefined(#{
        <<"citizen_did">> => CitizenDid,
        <<"citizen_kind">> => maps:get(citizen_kind, Fields),
        <<"display_name">> => maps:get(display_name, Fields, undefined),
        <<"offers">> => maps:get(offers, Fields, []),
        <<"expires_at">> => ExpiresAt
    }),
    put(maps:merge(existing_or_new(id(CitizenDid)), New)).

existing_or_new(Id) ->
    {ok, DbName} = hecate_om:read_model(),
    case barrel_docdb:get_doc(DbName, Id) of
        {ok, Doc} -> Doc;
        {error, not_found} -> #{<<"id">> => Id}
    end.

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
%% omitted (`maybe_put' convention, `station_read_model'), and every text
%% field tagged `{text, Bin}'.
%%
%% The tag is the wire contract, not decoration: macula encodes a bare
%% Erlang binary as a CBOR BYTE string and `{text, Bin}' as a CBOR TEXT
%% string, so a reply that puts names and kinds in bare binaries reaches
%% every non-BEAM consumer (macula-cli, macula-mcp, the Go/Rust/.NET/PHP
%% SDKs) as hex -- which is exactly what the first macula-mcp agent to
%% register itself here got back from list_citizens on 2026-09-02:
%% `"display_name": "0x66726573682d..."'. The `citizen_did' goes out as
%% the same lowercase hex text `register_presence' accepts on the way in,
%% not as the raw 32 bytes the record keys on. Integers stay integers.
-spec to_wire(map()) -> map().
to_wire(Doc) ->
    omit_undefined(#{
        citizen_did => text(did_hex(maps:get(<<"citizen_did">>, Doc))),
        citizen_kind => text(maps:get(<<"citizen_kind">>, Doc)),
        display_name => text(maps:get(<<"display_name">>, Doc, undefined)),
        offers => [text(O) || O <- maps:get(<<"offers">>, Doc, []), is_binary(O)],
        expires_at => maps:get(<<"expires_at">>, Doc)
    }).

%% Raw 32-byte DID (how the record stores it) to lowercase hex; already-hex
%% text passes through.
did_hex(Did) when is_binary(Did), byte_size(Did) =:= 32 -> binary:encode_hex(Did, lowercase);
did_hex(Did) -> Did.

text(undefined) -> undefined;
text(Bin) when is_binary(Bin) -> {text, Bin};
text(Atom) when is_atom(Atom) -> {text, atom_to_binary(Atom, utf8)}.

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
