-module(zhc_fabric_app).
-behaviour(application).

-export([start/2, stop/1, boot/0]).

start(_StartType, _StartArgs) ->
    zhc_fabric_sup:start_link().

stop(_State) ->
    ok.

%% Entry point for `erl -s zhc_fabric_app boot` (Docker CMD).
boot() ->
    case application:ensure_all_started(zhc_fabric) of
        {ok, _} ->
            io:format("zhc-fabric otp listening on http://~s:~b (max_inflight=~b)~n",
                      [zhc_fabric_config:host(), zhc_fabric_config:port(),
                       zhc_fabric_config:max_inflight()]);
        {error, Reason} ->
            io:format(standard_error, "zhc-fabric start failed: ~p~n", [Reason]),
            halt(1)
    end.
