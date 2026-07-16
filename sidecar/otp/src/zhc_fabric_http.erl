%% HTTP layer: inets httpd callback module. Routes match the Python stub.
-module(zhc_fabric_http).

-include_lib("inets/include/httpd.hrl").

-export([do/1]).

-define(VERSION, <<"0.1.0">>).

do(#mod{method = Method, request_uri = Uri} = Mod) ->
    handle(Method, normalize_path(Uri), Mod).

%% internal

handle("GET", "/health", _Mod) ->
    reply(200, health());
handle("GET", "/v1/metrics", _Mod) ->
    reply(200, metrics());
handle("POST", "/v1/consensus", Mod) ->
    post_job(Mod, true);
handle("POST", "/v1/fanout", Mod) ->
    post_job(Mod, false);
handle(_Method, Path, _Mod) ->
    reply(404, #{ok => false,
                 error => iolist_to_binary(["not found: ", Path])}).

post_job(Mod, Reduce) ->
    case read_json(Mod) of
        {ok, Body} -> reply(200, zhc_fabric_job:run(Body, Reduce));
        invalid -> reply(400, #{ok => false, error => <<"invalid JSON body">>})
    end.

read_json(#mod{entity_body = EntityBody}) ->
    Bin = iolist_to_binary(EntityBody),
    case byte_size(Bin) of
        0 -> {ok, #{}};
        N when N > 2000000 -> invalid;
        _ ->
            case try {ok, json:decode(Bin)} catch _:_ -> invalid end of
                {ok, M} when is_map(M) -> {ok, M};
                _ -> invalid
            end
    end.

health() ->
    #{inflight := Inflight, max_inflight := Max, uptime_s := Uptime} =
        zhc_fabric_lease:snapshot(),
    #{ok => true, api => <<"v1">>, version => ?VERSION, runtime => <<"otp">>,
      inflight => Inflight, max_inflight => Max, uptime_s => Uptime,
      degraded => Inflight >= Max,
      default_base_url => nullable(zhc_fabric_config:default_base_url()),
      default_model => nullable(zhc_fabric_config:default_model())}.

metrics() ->
    #{inflight := Inflight,
      stats := #{total := Total, ok := Ok, err := Err, sum := Sum}} =
        zhc_fabric_lease:snapshot(),
    Avg = case Total of
              0 -> 0;
              _ -> Sum div Total
          end,
    #{ok => true, jobs_total => Total, jobs_ok => Ok, jobs_err => Err,
      avg_elapsed_ms => Avg, inflight => Inflight}.

nullable(<<>>) -> null;
nullable(B) -> B.

normalize_path(Uri) ->
    [PathQ | _] = string:split(Uri, "?"),
    case string:trim(PathQ, trailing, "/") of
        "" -> "/";
        P -> P
    end.

reply(Code, Map) ->
    Body = binary_to_list(iolist_to_binary(json:encode(Map))),
    Head = [{code, Code},
            {content_type, "application/json; charset=utf-8"},
            {content_length, integer_to_list(length(Body))}],
    {proceed, [{response, {response, Head, Body}}]}.
