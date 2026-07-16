%% Top supervisor: lease gen_server, job supervisor, HTTP listener (inets httpd).
-module(zhc_fabric_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children = [
        #{id => lease, start => {zhc_fabric_lease, start_link, []}},
        #{id => job_sup, start => {zhc_fabric_job_sup, start_link, []},
          type => supervisor},
        #{id => httpd,
          start => {inets, start, [httpd, httpd_config(), stand_alone]}}
    ],
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, Children}}.

httpd_config() ->
    [{port, zhc_fabric_config:port()},
     {bind_address, bind_addr(zhc_fabric_config:host())},
     {ipfamily, inet},
     {server_name, "zhc-fabric"},
     {server_root, "/tmp"},
     {document_root, "/tmp"},
     {modules, [zhc_fabric_http]}].

bind_addr("0.0.0.0") -> any;
bind_addr(Host) ->
    case inet:parse_address(Host) of
        {ok, IP} -> IP;
        {error, _} -> Host
    end.
