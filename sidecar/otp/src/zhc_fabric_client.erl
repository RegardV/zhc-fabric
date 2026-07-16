%% Outbound OpenAI-compatible chat completion via httpc, gated by the lease.
-module(zhc_fabric_client).

-export([chat_completion/4]).

%% -> {Text :: binary() | null, Error :: binary() | null, LatencyMs :: integer()}
chat_completion(Ep, Messages, Temperature, TimeoutMs) ->
    T0 = erlang:monotonic_time(millisecond),
    case zhc_fabric_lease:acquire(TimeoutMs) of
        busy ->
            {null, <<"fabric busy: no free completion slot">>, since(T0)};
        ok ->
            try request(Ep, Messages, Temperature, TimeoutMs, T0)
            after zhc_fabric_lease:release()
            end
    end.

%% internal

request(#{base_url := Base, model := Model, api_key := Key},
        Messages, Temperature, TimeoutMs, T0) ->
    Url = binary_to_list(<<Base/binary, "/chat/completions">>),
    Payload = iolist_to_binary(json:encode(
        #{model => Model, messages => Messages, temperature => Temperature})),
    Headers0 = [{"accept", "application/json"}],
    Headers = case Key of
                  <<>> -> Headers0;
                  _ -> [{"authorization", "Bearer " ++ binary_to_list(Key)} | Headers0]
              end,
    Result =
        try httpc:request(post, {Url, Headers, "application/json", Payload},
                          [{timeout, TimeoutMs}, {connect_timeout, TimeoutMs}],
                          [{body_format, binary}])
        catch C:R -> {error, {C, R}}
        end,
    Latency = since(T0),
    case Result of
        {ok, {{_, Code, _}, _, Body}} when Code >= 200, Code < 300 ->
            parse_body(Body, Latency);
        {ok, {{_, Code, Phrase}, _, _}} ->
            {null, iolist_to_binary(io_lib:format("HTTP ~b ~s", [Code, Phrase])), Latency};
        {error, Reason} ->
            {null, fmt(Reason), Latency}
    end.

parse_body(Body, Latency) ->
    case try {ok, json:decode(Body)} catch _:_ -> bad end of
        bad ->
            {null, <<"non-json completion response">>, Latency};
        {ok, Obj} when is_map(Obj) ->
            parse_choices(maps:get(<<"choices">>, Obj, []), Latency);
        {ok, _} ->
            {null, <<"no choices in completion response">>, Latency}
    end.

parse_choices([First | _], Latency) when is_map(First) ->
    Msg = case maps:get(<<"message">>, First, #{}) of
              M when is_map(M) -> M;
              _ -> #{}
          end,
    case maps:get(<<"content">>, Msg, null) of
        null -> {null, <<"empty message content">>, Latency};
        Text when is_binary(Text) -> {string:trim(Text), null, Latency};
        Other -> {string:trim(fmt(Other)), null, Latency}
    end;
parse_choices(_, Latency) ->
    {null, <<"no choices in completion response">>, Latency}.

since(T0) ->
    erlang:monotonic_time(millisecond) - T0.

fmt(Term) ->
    iolist_to_binary(io_lib:format("~p", [Term])).
