%%% @doc RESPONDER for the `hecate_citizens.register_presence` mesh
%%% capability.
%%%
%%% Gated behind `citizen_ownership_proof' -- a caller must prove they
%%% hold the private key for the `citizen_did' they're registering, or
%%% anyone could squat any citizen's identity in a shared directory.
%%%
%%% Writes locally through the same Policy every federated fact goes
%%% through (`on_citizen_presence_maybe_admit'), then publishes so every
%%% other instance hears about it too (PLAN_ROOT.md's "Design: read-
%%% model, federated via mesh facts", step 1).
%%% @end
-module(register_presence_responder).
-behaviour(macula_response).

-export([init/1, handle_request/2]).

-define(PROCEDURE, <<"hecate_citizens.register_presence">>).
-define(TOPIC, <<"hecate_citizens.citizen_presence">>).
%% 20-minute TTL against a client republish interval of ~5 minutes -- the
%% 3-4x republish-to-TTL margin PLAN_ROOT.md's own design section calls for.
-define(DEFAULT_TTL_MS, 1_200_000).

init(_Args) -> {ok, []}.

-spec handle_request(map(), term()) -> {reply, map(), term()}.
handle_request(Payload, State) ->
    %% citizen_did arrives as ASCII hex TEXT over the wire, decoded once
    %% here and reused for both the proof check and the stored fields --
    %% see citizen_ownership_proof's own doc on why.
    CitizenDid = citizen_ownership_proof:decode_did(hecate_om_wire:field(citizen_did, Payload)),
    Proof = hecate_om_wire:field(proof, Payload, #{}),
    Reply = proven_reply(citizen_ownership_proof:verify(CitizenDid, Proof, ?PROCEDURE), CitizenDid, Payload),
    {reply, Reply, State}.

proven_reply(ok, CitizenDid, Payload) ->
    Fields = fields(CitizenDid, Payload),
    ok = on_citizen_presence_maybe_admit:handle(Fields),
    ok = publish(Fields),
    #{ok => 1, expires_at => maps:get(expires_at, Fields)};
proven_reply({error, Reason}, _CitizenDid, _Payload) ->
    #{ok => 0, error => reason_to_binary(Reason)}.

fields(CitizenDid, Payload) ->
    TtlMs = hecate_om_wire:field(ttl_ms, Payload, ?DEFAULT_TTL_MS),
    #{
        citizen_did => CitizenDid,
        citizen_kind => citizen_ownership_proof:decode_text(hecate_om_wire:field(citizen_kind, Payload)),
        display_name => citizen_ownership_proof:decode_text(hecate_om_wire:field(display_name, Payload, undefined)),
        offers => decode_offers(hecate_om_wire:field(offers, Payload, [])),
        expires_at => erlang:system_time(millisecond) + TtlMs
    }.

decode_offers(Offers) when is_list(Offers) ->
    [citizen_ownership_proof:decode_text(Offer) || Offer <- Offers];
decode_offers(_Other) ->
    [].

publish(Fields) ->
    publish_via(hecate_om:mesh_handles(), Fields).

publish_via({ok, Pool, Realm}, Fields) ->
    {ok, _Pid} = macula_publisher:start_link(citizen_presence_publisher, Pool, Realm,
                                             ?TOPIC, Fields, []),
    ok;
publish_via({error, _Reason}, _Fields) ->
    %% Local write already committed -- federation is best-effort, same as
    %% hecate-tube's channel_announcement:publish_via/2. The periodic
    %% republish a client is expected to do (per this responder's own TTL
    %% margin) will retry this on its own schedule.
    ok.

reason_to_binary(R) when is_atom(R) -> atom_to_binary(R, utf8);
reason_to_binary(R) when is_binary(R) -> R;
reason_to_binary(R) -> iolist_to_binary(io_lib:format("~p", [R])).
