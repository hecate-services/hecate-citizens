%%% @doc LISTENER for `hecate_citizens.citizen_presence' facts published
%%% by other `hecate-citizens' instances (and by this instance's own
%%% `register_presence_responder', which publishes after writing
%%% locally) -- the federation half of the directory.
%%%
%%% Not a DHT record (no `_dht.records.N.stored' topic), so there's no
%%% `macula_record:verify/1' transport-authenticity step here -- this is
%%% a plain published fact, same shape as `hecate-tube's
%%% `channel_announced_v1_to_mesh'. Its only job is to hand off to
%%% Policy, which owns "should this be written."
%%%
%%% Payload arrives off the wire, so keys are NOT reliably atoms (a
%%% pubsub delivery is not guaranteed to preserve them the way an
%%% in-process call does -- same gotcha `hecate_om_wire:field/2,3' exists
%%% for on the RPC side). Every field is read through it before this
%%% gets handed to Policy, which expects a clean, atom-keyed map.
-module(citizen_presence_listener).

-behaviour(macula_subscriber).

-export([init/1, handle_event/4]).

init(Args) -> {ok, Args}.

handle_event(_Topic, Payload, _Meta, State) ->
    ok = on_citizen_presence_maybe_admit:handle(#{
        citizen_did => citizen_ownership_proof:decode_did(hecate_om_wire:field(citizen_did, Payload)),
        citizen_kind => citizen_ownership_proof:decode_text(hecate_om_wire:field(citizen_kind, Payload)),
        display_name => citizen_ownership_proof:decode_text(hecate_om_wire:field(display_name, Payload, undefined)),
        offers => decode_offers(hecate_om_wire:field(offers, Payload, [])),
        expires_at => hecate_om_wire:field(expires_at, Payload)
    }),
    {noreply, State}.

decode_offers(Offers) when is_list(Offers) ->
    [citizen_ownership_proof:decode_text(Offer) || Offer <- Offers];
decode_offers(_Other) ->
    [].
