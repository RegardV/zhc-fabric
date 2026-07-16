%% One temporary child per in-flight consensus/fanout job.
%% A crashing job is logged and dropped; nothing else is affected.
-module(zhc_fabric_job_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    ChildSpec = #{id => job,
                  start => {zhc_fabric_job, start_link, []},
                  restart => temporary},
    {ok, {#{strategy => simple_one_for_one, intensity => 100, period => 1},
          [ChildSpec]}}.
