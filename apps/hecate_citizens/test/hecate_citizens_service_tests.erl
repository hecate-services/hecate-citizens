%% @doc The service contract, asserted locally.
%%
%% hecate_om resolves its six callbacks BY NAME at startup, on a live node, so a
%% service that forgets one dies with `undef' where nobody is watching. The
%% primary defence is the `-behaviour(hecate_om_service)' attribute on the
%% service module, which turns a missing callback into a compile error under
%% warnings_as_errors.
%%
%% What this suite adds is everything the compiler cannot see: that the attribute
%% has not been quietly dropped, that the values inside those callbacks are the
%% shapes hecate_om will destructure, and that the names and version this service
%% reports are the ones it actually has. Nothing local boots hecate_om, so
%% asserting the shape by hand is the closest available thing to a rehearsal.
-module(hecate_citizens_service_tests).

-include_lib("eunit/include/eunit.hrl").

-define(APP, hecate_citizens).
-define(SERVICE, hecate_citizens_service).

%% Belt and braces with the behaviour attribute, and it survives the attribute
%% being removed. If hecate_om ever adds a SEVENTH required callback this test
%% keeps passing and the deploy still breaks, which is the honest limit of a
%% local assertion about a remote contract.
exports_every_required_callback_test() ->
    _ = code:ensure_loaded(?SERVICE),
    Required = [{info, 0}, {start, 1}, {stop, 1},
                {health, 0}, {capabilities, 0}, {identity_spec, 0}],
    Missing = [F || {N, A} = F <- Required,
                    not erlang:function_exported(?SERVICE, N, A)],
    ?assertEqual([], Missing).

info_carries_the_three_keys_test() ->
    #{name := Name, version := Vsn, description := Desc} = ?SERVICE:info(),
    ?assert(is_binary(Name)),
    ?assert(is_binary(Vsn)),
    ?assert(is_binary(Desc)),
    ?assertEqual(<<"hecate-citizens">>, Name).

%% THE TWO NAMES MUST AGREE. The OTP application is snake_case because it is an
%% Erlang atom; the repository, the container image and the name this service
%% answers to on the mesh are kebab-case. They describe one service, so a
%% scaffold generated with a mismatched pair is caught here on the first eunit
%% run rather than by a puzzled reader months later.
mesh_name_matches_the_application_test() ->
    #{name := Wire} = ?SERVICE:info(),
    Snake = atom_to_binary(?APP, utf8),
    ?assertEqual(binary:replace(Snake, <<"_">>, <<"-">>, [global]), Wire).

%% The version in info/0 is what a peer reads off /health, so it disagreeing with
%% the application it describes is a lie that nothing else would catch.
info_version_matches_the_application_test() ->
    _ = application:load(?APP),
    {ok, Vsn} = application:get_key(?APP, vsn),
    #{version := Reported} = ?SERVICE:info(),
    ?assertEqual(list_to_binary(Vsn), Reported).

health_is_green_test() ->
    ?assertEqual(ok, ?SERVICE:health()).

%% The assertion is here so that adding a capability breaks a test and makes
%% someone write down what the service can now actually do.
announces_register_list_and_get_test() ->
    Names = [maps:get(name, C) || C <- ?SERVICE:capabilities()],
    ?assertEqual([<<"hecate_citizens.register_presence">>,
                  <<"hecate_citizens.list_citizens">>,
                  <<"hecate_citizens.get_citizen">>], Names).

identity_spec_has_the_shape_hecate_om_expects_test() ->
    #{scope := Scope, actions := Actions,
      resources := Resources, ttl_days := Ttl} = ?SERVICE:identity_spec(),
    ?assert(is_binary(Scope)),
    ?assert(is_list(Actions)),
    ?assert(is_list(Resources)),
    ?assert(is_integer(Ttl) andalso Ttl > 0).

%% A capability this service didn't ask authority for is a call the realm
%% would refuse once UCAN delegation lands -- every announced capability's
%% short name (the part after the scope prefix) must appear in `actions`.
authority_matches_what_is_announced_test() ->
    #{actions := Actions} = ?SERVICE:identity_spec(),
    ShortNames = [short_name(maps:get(name, C)) || C <- ?SERVICE:capabilities()],
    ?assertEqual(lists:sort(ShortNames), lists:sort(Actions)).

short_name(FullName) ->
    [_Scope, Short] = binary:split(FullName, <<".">>),
    Short.

%%==============================================================================
%% Federation: whose citizen_presence facts this instance hears
%%==============================================================================

%% The listener starts with the raw node ids of the instances named in
%% `presence_publishers'. Hex in either case, spaces around the commas allowed.
subscribes_the_listener_to_the_configured_instances_test() ->
    Ids = <<(binary:encode_hex(<<1:256>>, lowercase))/binary, ", ",
            (binary:encode_hex(<<2:256>>, uppercase))/binary>>,
    ?assertEqual([{<<"hecate_citizens.citizen_presence">>, citizen_presence_listener,
                   [<<1:256>>, <<2:256>>]}],
                 with_publishers(Ids, fun ?SERVICE:subscriptions/0)).

%% hecate_om calls subscriptions/0 during boot, so these errors stop the node:
%% one that hears no instance, or the wrong ones, looks healthy and is not.
refuses_to_boot_without_configured_instances_test() ->
    ?assertError({invalid_presence_publishers, missing},
                 with_publishers(unset, fun ?SERVICE:subscriptions/0)).

%% An unset HECATE_CITIZENS_PRESENCE_PUBLISHERS reaches here as `<<>>'.
refuses_to_boot_on_a_malformed_instance_list_test() ->
    Good = binary:encode_hex(<<1:256>>, lowercase),
    Malformed = [<<>>, <<"0">>, binary:part(Good, 0, 63), <<Good/binary, "0">>,
                 <<"zz", (binary:part(Good, 2, 62))/binary>>,
                 <<Good/binary, ",">>, <<Good/binary, ",,", Good/binary>>],
    [?assertError({invalid_presence_publishers, not_64_hex},
                  with_publishers(Ids, fun ?SERVICE:subscriptions/0))
     || Ids <- Malformed].

refuses_to_boot_on_an_instance_list_that_is_not_a_binary_test() ->
    Ids = binary_to_list(binary:encode_hex(<<1:256>>, lowercase)),
    ?assertError({invalid_presence_publishers, not_a_binary},
                 with_publishers(Ids, fun ?SERVICE:subscriptions/0)).

%% The release config takes the list from the environment and leaves macula's
%% publisher signature on. The listener hears a fact only when that signature
%% verified, so an instance that stopped signing would publish facts no other
%% instance accepts. macula signs every PUBLISH unless
%% `pubsub_emit_publisher_sig' is set to something other than true.
release_config_lists_instances_and_keeps_publisher_signatures_test() ->
    {ok, Text} = file:read_file(alongside("config/sys.config.src")),
    ?assertMatch({match, _},
                 re:run(Text, <<"\\{presence_publishers,\\s*"
                                "<<\"\\$\\{HECATE_CITIZENS_PRESENCE_PUBLISHERS\\}\">>\\}">>)),
    %% relx substitutes the ${VARS} at boot; any value parses for this check.
    Substituted = re:replace(Text, <<"\\$\\{[A-Z_]+\\}">>, <<"0">>, [global, {return, list}]),
    {ok, Tokens, _End} = erl_scan:string(Substituted),
    {ok, Config} = erl_parse:parse_term(Tokens),
    Macula = proplists:get_value(macula, Config, []),
    ?assertEqual(true, proplists:get_value(pubsub_emit_publisher_sig, Macula, true)),
    _ = application:load(macula),
    ?assertEqual(true, application:get_env(macula, pubsub_emit_publisher_sig, true)).

with_publishers(Ids, Fun) ->
    _ = application:load(?APP),
    ok = set_publishers(Ids),
    try Fun()
    after application:unset_env(?APP, presence_publishers)
    end.

set_publishers(unset) -> application:unset_env(?APP, presence_publishers);
set_publishers(Ids) -> application:set_env(?APP, presence_publishers, Ids).

%% The supervisor starts and stops cleanly on its own, without hecate_om. It has
%% no children as generated; this asserts the tree is startable, not that it does
%% any work.
supervisor_starts_and_stops_test() ->
    {ok, Pid} = hecate_citizens_sup:start_link(),
    ?assert(is_process_alive(Pid)),
    ?assertEqual([], supervisor:which_children(Pid)),
    unlink(Pid),
    exit(Pid, shutdown).

%%==============================================================================
%% The runtime is pinned in two places, and neither is the one you are running
%%==============================================================================

%% ⚠ THIS GUARD EXISTS BECAUSE A SIBLING SERVICE DID NOT HAVE IT, AND IT COST
%% THREE COMMITS AND AN IMAGE THAT SHIPPED ANYWAY.
%%
%% Its `Containerfile' said 27 while development ran on 28. So `rebar3 eunit'
%% passing locally meant "passing on 28" and nothing more, CI failed on a crash
%% that does not occur on 28 at all, and because the image build is a separate
%% workflow the image went to the fleet regardless.
%%
%% The release is pinned in TWO files, and the version actually running is a
%% third thing that agrees with neither by default. **A comment in each file
%% saying they must match is not a mechanism**, and both files carried one.
%%
%% ⚠⚠ IT FAILS RATHER THAN WARNS WHEN YOUR VM DIFFERS, AND THAT IS DELIBERATE.
%% Developing on a release you do not ship makes a green suite mean less than it
%% appears to. If you want to work on another release, move both pins and find
%% out what breaks, which is the whole point of having them.
the_runtime_agrees_between_the_image_the_ci_and_this_vm_test() ->
    Image = pinned("Containerfile", "FROM docker.io/erlang:([0-9]+)"),
    Ci = pinned(".github/workflows/lint.yml", "image: erlang:([0-9]+)"),
    Running = list_to_binary(erlang:system_info(otp_release)),
    %% Sorted and deduplicated, so a failure prints all three rather than the
    %% first pair that happened to be compared.
    ?assertEqual([Image], lists:usort([Image, Ci, Running])).

pinned(Relative, Pattern) ->
    {ok, Text} = file:read_file(alongside(Relative)),
    {match, [Version]} = re:run(Text, Pattern,
                                [{capture, all_but_first, binary}]),
    Version.

%% Relative to the beam rather than the working directory, because eunit runs
%% from wherever the developer happens to be standing.
alongside(Name) -> climb(filename:dirname(code:which(?MODULE)), Name, 8).

climb(_Dir, Name, 0) -> Name;
climb(Dir, Name, Left) ->
    Candidate = filename:join(Dir, Name),
    found(filelib:is_regular(Candidate), Candidate, Dir, Name, Left).

found(true, Candidate, _Dir, _Name, _Left) -> Candidate;
found(false, _Candidate, Dir, Name, Left) ->
    climb(filename:dirname(Dir), Name, Left - 1).
