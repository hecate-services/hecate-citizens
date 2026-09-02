%% @doc The wire shape of a citizen, asserted without a database: every
%% text field is `{text, Bin}' (CBOR text, so a non-BEAM reader gets a
%% string and not hex), the DID is the same lowercase hex text
%% register_presence accepts, absent fields are omitted, integers stay
%% integers, and nothing is a boolean.
-module(citizen_read_model_tests).

-include_lib("eunit/include/eunit.hrl").

raw_did() -> binary:decode_hex(<<"4f769c4e76402f3a0114f00f81a6b255f8f3298a1a9029ea5cf8a25c1463d7a0">>).

to_wire_tags_text_and_hexes_the_did_test() ->
    Doc = #{<<"id">> => <<"whatever">>,
            <<"citizen_did">> => raw_did(),
            <<"citizen_kind">> => <<"agent">>,
            <<"display_name">> => <<"fresh-install-repro">>,
            <<"offers">> => [<<"conversation">>],
            <<"expires_at">> => 1788355047886},
    Wire = citizen_read_model:to_wire(Doc),
    ?assertEqual({text, <<"4f769c4e76402f3a0114f00f81a6b255f8f3298a1a9029ea5cf8a25c1463d7a0">>},
                 maps:get(citizen_did, Wire)),
    ?assertEqual({text, <<"agent">>}, maps:get(citizen_kind, Wire)),
    ?assertEqual({text, <<"fresh-install-repro">>}, maps:get(display_name, Wire)),
    ?assertEqual([{text, <<"conversation">>}], maps:get(offers, Wire)),
    ?assertEqual(1788355047886, maps:get(expires_at, Wire)),
    ?assertNot(maps:is_key(id, Wire)).

to_wire_omits_an_absent_display_name_test() ->
    Doc = #{<<"citizen_did">> => raw_did(), <<"citizen_kind">> => <<"service">>, <<"expires_at">> => 1},
    Wire = citizen_read_model:to_wire(Doc),
    ?assertNot(maps:is_key(display_name, Wire)),
    ?assertEqual([], maps:get(offers, Wire)).

to_wire_passes_an_already_hex_did_through_test() ->
    Hex = <<"4f769c4e76402f3a0114f00f81a6b255f8f3298a1a9029ea5cf8a25c1463d7a0">>,
    Wire = citizen_read_model:to_wire(#{<<"citizen_did">> => Hex, <<"citizen_kind">> => <<"agent">>, <<"expires_at">> => 1}),
    ?assertEqual({text, Hex}, maps:get(citizen_did, Wire)).

to_wire_carries_only_integers_text_and_lists_of_text_test() ->
    Wire = citizen_read_model:to_wire(#{<<"citizen_did">> => raw_did(), <<"citizen_kind">> => <<"agent">>,
                                        <<"display_name">> => <<"x">>, <<"offers">> => [<<"a">>, <<"b">>],
                                        <<"expires_at">> => 2}),
    Bad = [K || {K, V} <- maps:to_list(Wire), not wire_safe(V)],
    ?assertEqual([], Bad).

wire_safe(N) when is_integer(N) -> true;
wire_safe({text, B}) when is_binary(B) -> true;
wire_safe(L) when is_list(L) -> lists:all(fun wire_safe/1, L);
wire_safe(_Other) -> false.
