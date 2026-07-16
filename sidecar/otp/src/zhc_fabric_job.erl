%% One supervised process per in-flight job; parallel worker process per vote.
%% Mirrors _run_job/_fanout_votes in sidecar/stub/server.py.
-module(zhc_fabric_job).

-export([run/2, start_link/3]).

%% Called from the HTTP handler. Starts a supervised job process and waits.
run(Body, Reduce) ->
    case supervisor:start_child(zhc_fabric_job_sup, [self(), Body, Reduce]) of
        {ok, Pid} ->
            MRef = erlang:monitor(process, Pid),
            receive
                {job_result, Pid, Result} ->
                    erlang:demonitor(MRef, [flush]),
                    Result;
                {'DOWN', MRef, process, Pid, Reason} ->
                    internal_error(Reason)
            %% ponytail: hard ceiling = max timeout_ms (600s) + slack; jobs
            %% self-terminate well before this via per-call timeouts.
            after 700000 ->
                erlang:demonitor(MRef, [flush]),
                exit(Pid, kill),
                internal_error(timeout)
            end;
        {error, Reason} ->
            internal_error(Reason)
    end.

start_link(Caller, Body, Reduce) ->
    {ok, spawn_link(fun() ->
        Caller ! {job_result, self(), run_job(Body, Reduce)}
    end)}.

%% internal

internal_error(Reason) ->
    #{ok => false, answer => null, votes => [], elapsed_ms => 0,
      error => iolist_to_binary(io_lib:format("internal error: ~p", [Reason]))}.

run_job(Body, Reduce) ->
    T0 = now_ms(),
    Policy = policy_of(Body),
    case validate(Body, Policy) of
        {error, Err} ->
            early_err(Policy, Err, 0);
        {ok, Prompt} ->
            case resolve_endpoints(Body) of
                {error, Err} -> early_err(Policy, Err, since(T0));
                {ok, Endpoints} -> run_job2(Body, Policy, Prompt, Endpoints, Reduce, T0)
            end
    end.

run_job2(Body, Policy, Prompt, Endpoints, Reduce, T0) ->
    N = clamp_n(Body),
    TimeoutMs = clamp_timeout(Body),
    Temperature = temp_of(Body),
    SystemPrompt = sys_of(Body),
    Votes = fanout(Prompt, N, Endpoints, SystemPrompt, Temperature, TimeoutMs),
    case Reduce of
        false ->
            fanout_result(Votes, T0);
        true ->
            reduce_result(Policy, Prompt, Votes, Endpoints, TimeoutMs,
                          rubric_of(Body), T0)
    end.

validate(Body, Policy) ->
    Prompt = string:trim(bin_of(maps:get(<<"prompt">>, Body, <<>>))),
    MaxChars = zhc_fabric_config:max_prompt_chars(),
    Known = [<<"majority">>, <<"love_eq">>, <<"unanimous_soft">>],
    if
        Prompt =:= <<>> ->
            {error, <<"prompt required">>};
        true ->
            case string:length(Prompt) > MaxChars of
                true ->
                    {error, <<"prompt exceeds ",
                              (integer_to_binary(MaxChars))/binary, " chars">>};
                false ->
                    case lists:member(Policy, Known) of
                        true -> {ok, Prompt};
                        false -> {error, <<"unknown policy: ", Policy/binary>>}
                    end
            end
    end.

early_err(Policy, Err, ElapsedMs) ->
    #{ok => false, answer => null, policy => Policy, votes => [],
      elapsed_ms => ElapsedMs, error => Err}.

%% fan-out

fanout(Prompt, N, Endpoints, SystemPrompt, Temperature, TimeoutMs) ->
    PerTimeoutMs = max(5000, round(TimeoutMs * 0.9)),
    Parent = self(),
    Workers = [begin
        {Pid, MRef} = spawn_monitor(fun() ->
            Parent ! {vote, self(), I,
                      vote_work(I, Prompt, Endpoints, SystemPrompt,
                                Temperature, PerTimeoutMs)}
        end),
        {I, Pid, MRef}
    end || I <- lists:seq(0, N - 1)],
    Deadline = now_ms() + PerTimeoutMs * 2 + 5000,
    Acc = collect(Workers, Deadline, #{}, Endpoints),
    [maps:get(I, Acc) || I <- lists:seq(0, N - 1)].

collect([], _Deadline, Acc, _Endpoints) ->
    Acc;
collect(Workers, Deadline, Acc, Endpoints) ->
    Wait = max(0, Deadline - now_ms()),
    receive
        {vote, Pid, I, Vote} ->
            {value, {I, Pid, MRef}, Rest} = lists:keytake(Pid, 2, Workers),
            erlang:demonitor(MRef, [flush]),
            collect(Rest, Deadline, Acc#{I => Vote}, Endpoints);
        {'DOWN', MRef, process, Pid, Reason} ->
            case lists:keytake(Pid, 2, Workers) of
                {value, {I, Pid, MRef}, Rest} ->
                    Vote = error_vote(I, Endpoints, fmt(Reason)),
                    collect(Rest, Deadline, Acc#{I => Vote}, Endpoints);
                false ->
                    collect(Workers, Deadline, Acc, Endpoints)
            end
    after Wait ->
        lists:foldl(fun({I, Pid, MRef}, A) ->
            erlang:demonitor(MRef, [flush]),
            exit(Pid, kill),
            A#{I => error_vote(I, Endpoints, <<"worker timeout">>)}
        end, Acc, Workers)
    end.

vote_work(I, Prompt, Endpoints, SystemPrompt, Temperature, PerTimeoutMs) ->
    Ep = endpoint_for(I, Endpoints),
    Role = role_for(I),
    User = case Role of
               critic -> zhc_fabric_policy:critic_wrap(Prompt);
               proposer -> Prompt
           end,
    Messages = [#{role => <<"system">>,
                  content => zhc_fabric_policy:system_for(Role, SystemPrompt)},
                #{role => <<"user">>, content => User}],
    {Text, Err, Latency} =
        zhc_fabric_client:chat_completion(Ep, Messages, Temperature, PerTimeoutMs),
    #{id => vote_id(I), role => role_bin(I),
      model => maps:get(model, Ep), endpoint => maps:get(name, Ep),
      text => case Text of null -> <<>>; _ -> Text end,
      latency_ms => Latency, error => Err}.

error_vote(I, Endpoints, Err) ->
    Ep = endpoint_for(I, Endpoints),
    #{id => vote_id(I), role => role_bin(I),
      model => maps:get(model, Ep), endpoint => maps:get(name, Ep),
      text => <<>>, latency_ms => 0, error => Err}.

endpoint_for(I, Endpoints) ->
    lists:nth((I rem length(Endpoints)) + 1, Endpoints).

role_for(1) -> critic;
role_for(_) -> proposer.

role_bin(1) -> <<"critic">>;
role_bin(_) -> <<"proposer">>.

vote_id(I) -> <<"v", (integer_to_binary(I))/binary>>.

%% results

fanout_result(Votes, T0) ->
    Elapsed = since(T0),
    Ok = zhc_fabric_policy:good(Votes) =/= [],
    zhc_fabric_lease:job_done(Ok, Elapsed),
    #{ok => Ok, votes => Votes, elapsed_ms => Elapsed,
      error => case Ok of true -> null; false -> <<"all endpoints failed">> end}.

reduce_result(Policy, Prompt, Votes, Endpoints, TimeoutMs, Rubric, T0) ->
    case zhc_fabric_policy:good(Votes) of
        [] ->
            Elapsed = since(T0),
            zhc_fabric_lease:job_done(false, Elapsed),
            Errs = [case maps:get(error, V) of null -> <<"empty">>; E -> E end
                    || V <- Votes],
            #{ok => false, answer => null, policy => Policy, votes => Votes,
              scores => null, elapsed_ms => Elapsed,
              error => iolist_to_binary([<<"all endpoints failed: ">>,
                                         lists:join(<<"; ">>, Errs)])};
        Good ->
            RemainingMs = max(5000, TimeoutMs - since(T0)),
            {Answer, Scores} =
                apply_policy(Policy, Prompt, Votes, Good, Endpoints,
                             RemainingMs, Rubric),
            Elapsed = since(T0),
            Ok = is_binary(Answer) andalso Answer =/= <<>>,
            zhc_fabric_lease:job_done(Ok, Elapsed),
            #{ok => Ok, answer => Answer, policy => Policy, votes => Votes,
              scores => Scores, elapsed_ms => Elapsed,
              error => case Ok of
                           true -> null;
                           false -> <<"reduce produced empty answer">>
                       end}
    end.

apply_policy(<<"love_eq">>, Prompt, Votes, Good, Endpoints, RemainingMs, Rubric) ->
    Scores = zhc_fabric_policy:love_eq_scores(Prompt, Votes, Endpoints,
                                              RemainingMs, Rubric),
    ById = maps:from_list([{maps:get(id, S), S} || S <- Scores]),
    Net = fun(V) -> maps:get(net, maps:get(maps:get(id, V), ById, #{}), 0) end,
    [G0 | Gs] = Good,
    Best = lists:foldl(fun(V, B) ->
                           case Net(V) > Net(B) of true -> V; false -> B end
                       end, G0, Gs),
    {maps:get(text, Best), Scores};
apply_policy(<<"unanimous_soft">>, Prompt, Votes, Good, Endpoints, RemainingMs,
             _Rubric) ->
    Norms = lists:usort([string:slice(zhc_fabric_policy:normalize(maps:get(text, V)),
                                      0, 120) || V <- Good]),
    case Norms of
        [_] ->
            {maps:get(text, hd(Good)), null};
        _ ->
            Synth = zhc_fabric_policy:judge_reduce(Prompt, Votes, Endpoints,
                                                   RemainingMs),
            A0 = case Synth of
                     T when is_binary(T), T =/= <<>> -> T;
                     _ -> zhc_fabric_policy:majority_pick(Votes)
                 end,
            A = case A0 of
                    <<>> -> A0;
                    _ -> <<(string:trim(A0, trailing))/binary,
                           "\n\n[Note: committee was not unanimous; "
                           "dissent retained in votes.]">>
                end,
            {A, null}
    end;
apply_policy(_Majority, Prompt, Votes, _Good, Endpoints, RemainingMs, _Rubric) ->
    A = case zhc_fabric_policy:judge_reduce(Prompt, Votes, Endpoints, RemainingMs) of
            T when is_binary(T), T =/= <<>> -> T;
            _ -> zhc_fabric_policy:majority_pick(Votes)
        end,
    {A, null}.

%% request field parsing (defaults/clamps mirror the stub)

bin_of(B) when is_binary(B) -> B;
bin_of(_) -> <<>>.

policy_of(Body) ->
    case maps:get(<<"policy">>, Body, null) of
        P when is_binary(P) ->
            case string:trim(P) of
                <<>> -> <<"majority">>;
                T -> T
            end;
        _ -> <<"majority">>
    end.

int_of(V, _Default) when is_integer(V) -> V;
int_of(V, _Default) when is_float(V) -> trunc(V);
int_of(V, Default) when is_binary(V) ->
    try binary_to_integer(string:trim(V)) catch _:_ -> Default end;
int_of(_, Default) -> Default.

clamp_n(Body) ->
    N = int_of(maps:get(<<"n">>, Body, null), 3),
    max(1, min(zhc_fabric_config:max_n(), N)).

clamp_timeout(Body) ->
    T = int_of(maps:get(<<"timeout_ms">>, Body, null), 120000),
    max(5000, min(600000, T)).

temp_of(Body) ->
    case maps:get(<<"temperature">>, Body, null) of
        V when is_float(V) -> V;
        V when is_integer(V) -> float(V);
        V when is_binary(V) ->
            try binary_to_float(string:trim(V))
            catch _:_ ->
                try float(binary_to_integer(string:trim(V)))
                catch _:_ -> 0.6
                end
            end;
        _ -> 0.6
    end.

%% Rubric override order: request "rubric" > env FABRIC_LOVE_EQ_RUBRIC >
%% built-in default (null here -> default inside zhc_fabric_policy).
rubric_of(Body) ->
    case maps:get(<<"rubric">>, Body, null) of
        R when is_binary(R), R =/= <<>> ->
            R;
        _ ->
            case zhc_fabric_config:love_eq_rubric() of
                <<>> -> null;
                R -> R
            end
    end.

sys_of(Body) ->
    case maps:get(<<"system_prompt">>, Body, null) of
        S when is_binary(S) -> S;
        _ -> null
    end.

resolve_endpoints(Body) ->
    case maps:get(<<"endpoints">>, Body, null) of
        Eps when is_list(Eps), Eps =/= [] ->
            case valid_endpoints(Eps) of
                [] -> {error, <<"endpoints provided but none valid "
                                "(need base_url + model)">>};
                Valid -> {ok, Valid}
            end;
        _ ->
            default_endpoint()
    end.

valid_endpoints(Eps) ->
    Indexed = lists:zip(lists:seq(0, length(Eps) - 1), Eps),
    lists:filtermap(fun valid_endpoint/1, Indexed).

valid_endpoint({I, E}) when is_map(E) ->
    Base = string:trim(bin_of(maps:get(<<"base_url">>, E, <<>>)), trailing, "/"),
    Model = bin_of(maps:get(<<"model">>, E, <<>>)),
    case Base =/= <<>> andalso Model =/= <<>> of
        false -> false;
        true ->
            Name = case bin_of(maps:get(<<"name">>, E, <<>>)) of
                       <<>> -> <<"ep", (integer_to_binary(I))/binary>>;
                       Nm -> Nm
                   end,
            {true, #{name => Name, base_url => Base, model => Model,
                     api_key => bin_of(maps:get(<<"api_key">>, E, <<>>))}}
    end;
valid_endpoint(_) ->
    false.

default_endpoint() ->
    Base = zhc_fabric_config:default_base_url(),
    Model = zhc_fabric_config:default_model(),
    case Base =/= <<>> andalso Model =/= <<>> of
        true ->
            {ok, [#{name => <<"default">>, base_url => Base, model => Model,
                    api_key => zhc_fabric_config:default_api_key()}]};
        false ->
            {error, <<"no endpoints configured "
                      "(set request.endpoints or DEFAULT_BASE_URL + DEFAULT_MODEL)">>}
    end.

now_ms() -> erlang:monotonic_time(millisecond).

since(T0) -> now_ms() - T0.

fmt(Term) -> iolist_to_binary(io_lib:format("~p", [Term])).
