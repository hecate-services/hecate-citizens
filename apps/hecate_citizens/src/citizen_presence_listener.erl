%%% @doc LISTENER for `hecate_citizens.citizen_presence' facts published
%%% by `hecate-citizens' instances, this one included (its own
%%% `register_presence_responder' publishes after writing locally) -- the
%%% federation half of the directory.
%%%
%%% ONLY THE LISTED INSTANCES ARE HEARD. Anyone in the realm can publish on
%%% this topic, and a fact carries no proof from the citizen: it is worth
%%% what the instance that published it checked, which is the citizen's
%%% ownership proof on the CALL. So a fact reaches Policy only when macula
%%% verified its publisher signature (`publisher_verified' is `true', not
%%% `not_signed' or `false') and its publisher is one of the instance node
%%% ids this listener was started with
%%% (`hecate_citizens_service:subscriptions/0'). Everything else is dropped
%%% here.
%%%
%%% Not a DHT record (no `_dht.records.N.stored' topic), so there's no
%%% `macula_record:verify/1' step here -- this is a plain published fact,
%%% same shape as `hecate-tube's `channel_announced_v1_to_mesh'.
%%%
%%% Payload arrives off the wire, so keys are NOT reliably atoms (a
%%% pubsub delivery is not guaranteed to preserve them the way an
%%% in-process call does -- same gotcha `hecate_om_wire:field/2,3' exists
%%% for on the RPC side). Every field is read through it before this
%%% gets handed to Policy, which expects a clean, atom-keyed map. The
%%% fact's `expires_at' is deliberately not read: Policy computes the
%%% expiry from `registered_at' and `ttl_ms'.
-module(citizen_presence_listener).

-behaviour(macula_subscriber).

-export([init/1, handle_event/4]).

%% `Publishers': the raw 32-byte node ids of the instances to hear.
init(Publishers) -> {ok, Publishers}.

handle_event(_Topic, Payload, Meta, Publishers) ->
    _ = heard(listed(Meta, Publishers), Payload),
    {noreply, Publishers}.

listed(#{publisher_verified := true, publisher := Publisher}, Publishers) ->
    lists:member(Publisher, Publishers);
listed(_Meta, _Publishers) ->
    false.

heard(true, Payload) ->
    on_citizen_presence_maybe_admit:handle(presence(Payload));
heard(false, _Payload) ->
    dropped.

presence(Payload) ->
    #{
        citizen_did => citizen_ownership_proof:decode_did(hecate_om_wire:field(citizen_did, Payload)),
        citizen_kind => citizen_ownership_proof:decode_text(hecate_om_wire:field(citizen_kind, Payload)),
        display_name => citizen_ownership_proof:decode_text(hecate_om_wire:field(display_name, Payload, undefined)),
        offers => decode_offers(hecate_om_wire:field(offers, Payload, [])),
        registered_at => hecate_om_wire:field(registered_at, Payload),
        ttl_ms => hecate_om_wire:field(ttl_ms, Payload)
    }.

decode_offers(Offers) when is_list(Offers) ->
    [citizen_ownership_proof:decode_text(Offer) || Offer <- Offers];
decode_offers(_Other) ->
    [].
