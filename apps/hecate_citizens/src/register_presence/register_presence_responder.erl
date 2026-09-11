%%% @doc RESPONDER for the `hecate_citizens.register_presence` mesh
%%% capability.
%%%
%%% Gated twice. A caller must prove they hold the private key for the
%%% `citizen_did' they're registering (`citizen_ownership_proof'), or anyone
%%% could squat any citizen's identity in a shared directory. And the
%%% `citizen_did' must be the CALL's own caller: macula puts the
%%% wire-authenticated caller into the payload as `caller', overwriting
%%% anything the payload sent under that key. The proof signs only the DID,
%%% a timestamp and the procedure, so on its own anyone who saw it could
%%% replay it within its 60-second window; bound to the caller, a replay
%%% needs a CALL signed with the citizen's own key.
%%%
%%% Writes locally through the same Policy every federated fact goes
%%% through (`on_citizen_presence_maybe_admit'), stamped with this
%%% instance's clock as `registered_at' and carrying the caller's `ttl_ms'
%%% for Policy to bound, then publishes so every other instance hears about
%%% it too (PLAN_ROOT.md's "Design: read-model, federated via mesh facts",
%%% step 1).
%%% @end
-module(register_presence_responder).
-behaviour(macula_response).

-export([init/1, handle_request/2, presence_fact/1]).

-define(PROCEDURE, <<"hecate_citizens.register_presence">>).
-define(TOPIC, <<"hecate_citizens.citizen_presence">>).
%% 20-minute TTL against a client republish interval of ~5 minutes -- the
%% 3-4x republish-to-TTL margin PLAN_ROOT.md's own design section calls for.
%% It is also the most Policy allows.
-define(DEFAULT_TTL_MS, 1_200_000).

init(_Args) -> {ok, []}.

-spec handle_request(map(), term()) -> {reply, map(), term()}.
handle_request(Payload, State) ->
    %% citizen_did arrives as ASCII hex TEXT over the wire, decoded once
    %% here and reused for the proof check, the caller check and the stored
    %% fields -- see citizen_ownership_proof's own doc on why.
    CitizenDid = citizen_ownership_proof:decode_did(hecate_om_wire:field(citizen_did, Payload)),
    Proof = hecate_om_wire:field(proof, Payload, #{}),
    Proven = called_as(citizen_ownership_proof:verify(CitizenDid, Proof, ?PROCEDURE),
                       CitizenDid, hecate_om_wire:field(caller, Payload)),
    {reply, proven_reply(Proven, CitizenDid, Payload), State}.

%% The proof is checked first, so a DID that doesn't decode is reported as
%% that rather than as a caller mismatch.
called_as(ok, CitizenDid, CitizenDid) -> ok;
called_as(ok, _CitizenDid, _Caller) -> {error, citizen_did_is_not_the_caller};
called_as({error, _Reason} = Error, _CitizenDid, _Caller) -> Error.

proven_reply(ok, CitizenDid, Payload) ->
    registered_reply(on_citizen_presence_maybe_admit:handle(presence(CitizenDid, Payload)));
proven_reply({error, Reason}, _CitizenDid, _Payload) ->
    refused_reply(Reason).

registered_reply({ok, Fields}) ->
    ok = publish(Fields),
    #{ok => 1, expires_at => maps:get(expires_at, Fields)};
registered_reply({refused, Reason}) ->
    refused_reply(Reason).

%% The reason goes out as `{text, Bin}' (CBOR text); a bare binary would
%% reach non-BEAM callers as bytes.
refused_reply(Reason) ->
    #{ok => 0, error => {text, reason_to_binary(Reason)}}.

presence(CitizenDid, Payload) ->
    #{
        citizen_did => CitizenDid,
        citizen_kind => citizen_ownership_proof:decode_text(hecate_om_wire:field(citizen_kind, Payload)),
        display_name => citizen_ownership_proof:decode_text(hecate_om_wire:field(display_name, Payload, undefined)),
        offers => decode_offers(hecate_om_wire:field(offers, Payload, [])),
        registered_at => erlang:system_time(millisecond),
        ttl_ms => hecate_om_wire:field(ttl_ms, Payload, ?DEFAULT_TTL_MS)
    }.

decode_offers(Offers) when is_list(Offers) ->
    [citizen_ownership_proof:decode_text(Offer) || Offer <- Offers];
decode_offers(_Other) ->
    [].

%% @doc The `citizen_presence' fact for a registration: a list_citizens
%% entry (`citizen_read_model:to_wire/1' over the stored fields) plus the
%% bounded `ttl_ms'. A receiving instance computes its own expiry from
%% `registered_at' and `ttl_ms'; `expires_at' stays in the fact for
%% subscribers that show it, and no instance reads it back. Text goes out as
%% CBOR text and the DID as lowercase hex text, so non-BEAM subscribers get
%% strings instead of bytes.
-spec presence_fact(map()) -> map().
presence_fact(#{ttl_ms := TtlMs} = Fields) ->
    (citizen_read_model:to_wire(citizen_read_model:presence_doc(Fields)))#{ttl_ms => TtlMs}.

publish(Fields) ->
    publish_via(hecate_om:mesh_handles(), presence_fact(Fields)).

publish_via({ok, Pool, Realm}, Fact) ->
    {ok, _Pid} = macula_publisher:start_link(citizen_presence_publisher, Pool, Realm,
                                             ?TOPIC, Fact, []),
    ok;
publish_via({error, _Reason}, _Fact) ->
    %% Local write already committed -- federation is best-effort, same as
    %% hecate-tube's channel_announcement:publish_via/2. The periodic
    %% republish a client is expected to do (per this responder's own TTL
    %% margin) will retry this on its own schedule.
    ok.

reason_to_binary(R) when is_atom(R) -> atom_to_binary(R, utf8);
reason_to_binary(R) when is_binary(R) -> R;
reason_to_binary(R) -> iolist_to_binary(io_lib:format("~p", [R])).
