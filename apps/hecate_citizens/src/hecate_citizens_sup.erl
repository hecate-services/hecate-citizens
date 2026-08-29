%% @doc Supervises this service's own processes.
%%
%% NO CHILDREN AS GENERATED, and an empty child list is the honest scaffold
%% rather than a placeholder. There is nothing to supervise yet, and a worker
%% that ticks and does nothing is how a codebase ends up carrying an empty
%% heartbeat for a year.
-module(hecate_citizens_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, []}}.
