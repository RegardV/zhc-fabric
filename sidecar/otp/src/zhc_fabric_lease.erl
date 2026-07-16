%% Global lease capping concurrent outbound completions at max_inflight.
%% Also tracks job stats and uptime (single source of truth for /health, /v1/metrics).
%% Holders are monitored: a crashed worker auto-releases its slot.
-module(zhc_fabric_lease).
-behaviour(gen_server).

-export([start_link/0, acquire/1, release/0, job_done/2, snapshot/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% ok | busy. Blocks up to TimeoutMs for a free slot.
acquire(TimeoutMs) ->
    try gen_server:call(?MODULE, acquire, TimeoutMs)
    catch
        exit:{timeout, _} ->
            %% May have been granted concurrently with our timeout; cancel
            %% removes us from the queue or releases the racing grant.
            gen_server:cast(?MODULE, {cancel, self()}),
            busy
    end.

release() ->
    gen_server:cast(?MODULE, {release, self()}).

job_done(Ok, ElapsedMs) ->
    gen_server:cast(?MODULE, {job_done, Ok, ElapsedMs}).

snapshot() ->
    gen_server:call(?MODULE, snapshot).

%% gen_server

init([]) ->
    {ok, #{max => zhc_fabric_config:max_inflight(),
           holders => #{},
           waiters => queue:new(),
           stats => #{total => 0, ok => 0, err => 0, sum => 0},
           start_ts => erlang:monotonic_time(second)}}.

handle_call(acquire, {Pid, _} = From, #{max := Max, holders := H} = S) ->
    case map_size(H) < Max of
        true -> {reply, ok, add_holder(Pid, S)};
        false -> {noreply, S#{waiters := queue:in({From, Pid}, maps:get(waiters, S))}}
    end;
handle_call(snapshot, _From,
            #{max := Max, holders := H, stats := St, start_ts := T0} = S) ->
    Snap = #{inflight => map_size(H), max_inflight => Max, stats => St,
             uptime_s => erlang:monotonic_time(second) - T0},
    {reply, Snap, S}.

handle_cast({release, Pid}, S) ->
    {noreply, grant_next(remove_holder(Pid, S))};
handle_cast({cancel, Pid}, #{holders := H, waiters := W} = S) ->
    case maps:is_key(Pid, H) of
        true -> {noreply, grant_next(remove_holder(Pid, S))};
        false -> {noreply, S#{waiters := queue:filter(fun({_, P}) -> P =/= Pid end, W)}}
    end;
handle_cast({job_done, Ok, ElapsedMs}, #{stats := St} = S) ->
    #{total := T, ok := O, err := E, sum := Sum} = St,
    St2 = St#{total := T + 1,
              ok := O + bool01(Ok),
              err := E + bool01(not Ok),
              sum := Sum + ElapsedMs},
    {noreply, S#{stats := St2}}.

handle_info({'DOWN', _MRef, process, Pid, _Reason}, #{holders := H} = S) ->
    case maps:is_key(Pid, H) of
        true -> {noreply, grant_next(remove_holder(Pid, S))};
        false -> {noreply, S}
    end;
handle_info(_Msg, S) ->
    {noreply, S}.

%% internal

add_holder(Pid, #{holders := H} = S) ->
    MRef = erlang:monitor(process, Pid),
    S#{holders := H#{Pid => MRef}}.

remove_holder(Pid, #{holders := H} = S) ->
    case maps:take(Pid, H) of
        {MRef, H2} ->
            erlang:demonitor(MRef, [flush]),
            S#{holders := H2};
        error ->
            S
    end.

grant_next(#{max := Max, holders := H, waiters := W} = S) ->
    case map_size(H) < Max of
        false -> S;
        true ->
            case queue:out(W) of
                {empty, _} -> S;
                {{value, {From, Pid}}, W2} ->
                    gen_server:reply(From, ok),
                    grant_next(add_holder(Pid, S#{waiters := W2}))
            end
    end.

bool01(true) -> 1;
bool01(false) -> 0.
