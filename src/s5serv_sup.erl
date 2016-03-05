-module(s5serv_sup).
-behaviour(supervisor).
-define(PORT, 1080).

%% external API
-export([start_link/0, start_socket/0]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [?PORT]).

start_socket() -> supervisor:start_child(?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================
init([Port]) ->
    {ok, ListenSock} = gen_tcp:listen(Port, [{active, true}, binary]),

    spawn_link(fun empty_listeners/0),

    {ok,
        {
            {simple_one_for_one, 60, 3600},
            [{socket,
             {sin, start_link, [ListenSock]},
             temporary, 1000, worker, [sin]}]
        }
    }.

empty_listeners() ->
    [start_socket() || _ <- lists:seq(1, 10)],
    ok.
