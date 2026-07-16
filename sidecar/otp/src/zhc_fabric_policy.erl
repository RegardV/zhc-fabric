%% Reduce policies and prompt templates. Mirrors sidecar/stub/server.py.
-module(zhc_fabric_policy).

-export([good/1, normalize/1, majority_pick/1, judge_reduce/4, love_eq_scores/1,
         system_for/2, critic_wrap/1]).

%% Votes with non-empty text and no error.
good(Votes) ->
    [V || #{text := T, error := E} = V <- Votes, T =/= <<>>, E =:= null].

normalize(Text) ->
    T = string:lowercase(string:trim(Text)),
    re:replace(T, "\\s+", " ", [global, unicode, {return, binary}]).

%% Cluster good votes by normalized prefix; best bucket = (count, len(first text)).
majority_pick(Votes) ->
    case good(Votes) of
        [] -> <<>>;
        Good ->
            Buckets = lists:foldl(fun bucket_add/2, [], Good),
            [First | Rest] = Buckets,
            {_, BestVs} = lists:foldl(
                fun({_, Vs} = B, {_, BestVs0} = Best) ->
                    case bucket_score(Vs) > bucket_score(BestVs0) of
                        true -> B;
                        false -> Best
                    end
                end, First, Rest),
            maps:get(text, hd(BestVs))
    end.

%% -> binary answer | null. Falls back to majority_pick on judge failure.
judge_reduce(Prompt, Votes, Endpoints, TimeoutMs) ->
    case good(Votes) of
        [] -> null;
        [#{text := T}] -> T;
        Good ->
            Picked = majority_pick(Votes),
            case norms(Good, 120) of
                [_] -> Picked;
                _ -> judge_call(Prompt, Good, Endpoints, TimeoutMs, Picked)
            end
    end.

%% Heuristic stub scores until a real rubric LLM pass is added.
love_eq_scores(Votes) ->
    [love_eq_score(V) || V <- Votes].

system_for(_Role, Custom) when is_binary(Custom), Custom =/= <<>> ->
    Custom;
system_for(critic, _) ->
    <<"You are a critical reviewer on a multi-agent committee. "
      "Identify weaknesses, risks, and missing considerations. "
      "Be concise and concrete. End with a clear recommendation.">>;
system_for(_, _) ->
    <<"You are an independent member of a multi-agent committee. "
      "Give a clear, direct answer with brief reasoning. Be concise.">>.

critic_wrap(Prompt) ->
    <<"Critique and improve upon answers to the following.\n\n"
      "QUESTION:\n", Prompt/binary,
      "\n\nProvide your own best answer after the critique.">>.

%% internal

norms(Good, Len) ->
    lists:usort([string:slice(normalize(maps:get(text, V)), 0, Len) || V <- Good]).

bucket_add(#{text := T} = V, Buckets) ->
    Key = string:slice(normalize(T), 0, 200),
    case lists:keyfind(Key, 1, Buckets) of
        false -> Buckets ++ [{Key, [V]}];
        {Key, Vs} -> lists:keyreplace(Key, 1, Buckets, {Key, Vs ++ [V]})
    end.

bucket_score(Vs) ->
    {length(Vs), string:length(maps:get(text, hd(Vs)))}.

judge_call(Prompt, Good, Endpoints, TimeoutMs, Picked) ->
    Parts = [[<<"### Vote ">>, maps:get(id, V), <<" (">>, maps:get(role, V),
              <<")\n">>, maps:get(text, V)] || V <- Good],
    JudgePrompt = iolist_to_binary(
        [<<"You are the aggregator for a multi-agent committee.\n"
           "Original question:\n">>, Prompt, <<"\n\nVotes:\n\n">>,
         lists:join(<<"\n\n">>, Parts),
         <<"\n\nSynthesize ONE clear final answer. Note dissent briefly if material. "
           "Do not invent facts not present in the votes.">>]),
    Messages = [#{role => <<"system">>,
                  content => <<"You merge committee votes into a single decisive answer.">>},
                #{role => <<"user">>, content => JudgePrompt}],
    JudgeTimeout = max(10000, round(TimeoutMs * 0.4)),
    case zhc_fabric_client:chat_completion(hd(Endpoints), Messages, 0.3, JudgeTimeout) of
        {Text, null, _} when is_binary(Text), Text =/= <<>> -> Text;
        _ -> Picked
    end.

love_eq_score(#{id := Id, text := Text}) ->
    C = min(10.0, 3.0 + string:length(Text) / 200),
    D = case has_bad(string:lowercase(Text)) of
            true -> 2.0;
            false -> 0.5
        end,
    #{id => Id, 'C' => round2(C), 'D' => round2(D), net => round2(C - D),
      note => <<"heuristic stub; not a full Love Equation model pass">>}.

has_bad(Lower) ->
    lists:any(fun(W) -> binary:match(Lower, W) =/= nomatch end,
              [<<"delete all">>, <<"ignore safety">>, <<"harm users">>]).

round2(X) -> round(X * 100) / 100.
