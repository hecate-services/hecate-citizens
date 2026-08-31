%% @doc The hecate_om service contract: what this service is and may do.
%%
%% SIX CALLBACKS, ALL REQUIRED. hecate_om resolves them BY NAME at startup, on a
%% live node, so a service that forgets one dies with `undef' where nobody is
%% watching. The `-behaviour' attribute below is what turns that into a compile
%% error instead, and the generated test suite guards the attribute itself.
%%
%% IT ANNOUNCES NOTHING AND ASKS FOR NOTHING, on purpose. A service that does
%% nothing yet has no capability to offer and needs no authority from the realm.
%% Advertising a capability before it exists puts a lie on the mesh that another
%% service can find and call. Both lists grow when the thing they name exists,
%% and a generated test fails when they change, so growing them is a deliberate
%% act rather than a comment someone forgot.
-module(hecate_citizens_service).

-behaviour(hecate_om_service).

-export([info/0, start/1, stop/1, health/0, capabilities/0, identity_spec/0]).
%% Read model (no event store -- this service is pure read-model, per
%% its own plans/PLAN_ROOT.md "Design: read-model, federated via mesh
%% facts") + the federation subscription that feeds it. read_model_id/0
%% REQUIRES data_dir/0 alongside it (hecate_om_service's own doc: "When
%% exported alongside data_dir/0, hecate_om:boot/1 opens the database
%% at data_dir/read_model_id") -- barrel_docdb starts idle without both.
-export([read_model_id/0, data_dir/0, subscriptions/0]).

info() ->
    #{name => <<"hecate-citizens">>,
      version => <<"0.1.0">>,
      description => <<"The shared citizens directory for the Macula mesh -- who exists, federated across instances via mesh facts">>}.

start(_Opts) -> hecate_citizens_sup:start_link().

stop(_State) -> ok.

%% Green once the supervision tree is up. Replace this with a real probe of
%% whatever this service needs in order to do its job. A dark mesh is usually NOT
%% a health failure: decide that deliberately rather than by default.
health() -> ok.

%% WHAT THIS SERVICE ANNOUNCES IT CAN DO. Other services find this one by these
%% names, so each entry is a promise that something answers.
%%
%% register_presence is gated behind citizen_ownership_proof (a caller
%% must prove they hold the private key for the citizen_did they're
%% registering). list_citizens/get_citizen are ungated -- this is a
%% public directory, not one citizen's own private data.
capabilities() ->
    [
     #{name => <<"hecate_citizens.register_presence">>, version => 1,
       handler => {register_presence_responder, []}},
     #{name => <<"hecate_citizens.list_citizens">>, version => 1,
       handler => {list_citizens_responder, []}},
     #{name => <<"hecate_citizens.get_citizen">>, version => 1,
       handler => {get_citizen_responder, []}},
     %% TEMPORARY, remove before the next real commit.
     #{name => <<"hecate_citizens.debug_echo">>, version => 1,
       handler => {debug_echo_responder, []}}
    ].

%% THE AUTHORITY THIS SERVICE ASKS THE REALM FOR, and deliberately nothing more.
%% Ask for exactly the topics you publish and subscribe to. Popped, an attacker
%% gains precisely this and no more, which is the whole point of listing it.
identity_spec() ->
    #{scope => <<"hecate-citizens">>,
      actions => [<<"register_presence">>, <<"list_citizens">>, <<"get_citizen">>],
      resources => [<<"citizens/*">>],
      ttl_days => 30}.

%% @doc The barrel_docdb database this service's directory lives in --
%% `citizen_read_model' writes/reads by this same name (`hecate_om_service''s
%% own doc: "PRJ code writes to it with barrel_docdb directly").
-spec read_model_id() -> binary().
read_model_id() -> <<"hecate_citizens">>.

%% @doc Where the read model (and, per config/sys.config.src, this
%% service's own signing keypair) live on disk. Defaults to a path
%% inside the container; the fleet keeps application data on its
%% `/bulk' drives, so the deploy compose mounts a volume and sets this.
-spec data_dir() -> string().
data_dir() -> os:getenv("HECATE_DATA_DIR", "/var/lib/hecate-citizens").

%% @doc Federation: hear every other instance's (and this instance's
%% own) citizen_presence republish, feeding on_citizen_presence_maybe_admit.
-spec subscriptions() -> [{binary(), module(), term()}].
subscriptions() ->
    [{<<"hecate_citizens.citizen_presence">>, citizen_presence_listener, []}].
