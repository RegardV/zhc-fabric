%% Reduce policies and prompt templates. Mirrors sidecar/stub/server.py.
-module(zhc_fabric_policy).

-export([good/1, normalize/1, majority_pick/1, judge_reduce/4, love_eq_scores/5,
         system_for/2, critic_wrap/1]).

%% Contract: the scorer system prompt must contain "love-equation-scorer"
%% unless the caller overrides the rubric (request "rubric" > env > default).
-define(DEFAULT_RUBRIC,
        <<"You are the love-equation-scorer for a multi-agent committee. "
          "Score each vote: C = cooperation/creation value 0-10, "
          "D = damage/deception risk 0-10. Reply with ONLY a JSON array like "
          "[{\"id\":\"v0\",\"C\":7,\"D\":1}] - no prose, no code fences.">>).

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

%% One LLM rubric pass scoring every vote; falls back to the length
%% heuristic on any failure. Never fails the job.
love_eq_scores(Prompt, Votes, Endpoints, TimeoutMs, Rubric) ->
    case llm_scores(Prompt, Votes, Endpoints, TimeoutMs, Rubric) of
        {ok, Scores} ->
            Scores;
        {error, Reason} ->
            Note = <<"heuristic fallback: ", Reason/binary>>,
            [heuristic_score(V, Note) || V <- Votes]
    end.

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

vote_parts(Votes) ->
    [[<<"### Vote ">>, maps:get(id, V), <<" (">>, maps:get(role, V),
      <<")\n">>, maps:get(text, V)] || V <- Votes].

judge_call(Prompt, Good, Endpoints, TimeoutMs, Picked) ->
    Parts = vote_parts(Good),
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

llm_scores(Prompt, Votes, Endpoints, TimeoutMs, Rubric) ->
    System = case Rubric of
                 R when is_binary(R), R =/= <<>> -> R;
                 _ -> ?DEFAULT_RUBRIC
             end,
    User = iolist_to_binary(
        [<<"Original question:\n">>, Prompt, <<"\n\nVotes:\n\n">>,
         lists:join(<<"\n\n">>, vote_parts(Votes))]),
    Messages = [#{role => <<"system">>, content => System},
                #{role => <<"user">>, content => User}],
    ScoreTimeout = max(10000, round(TimeoutMs * 0.4)),
    case zhc_fabric_client:chat_completion(hd(Endpoints), Messages, 0.2,
                                           ScoreTimeout) of
        {Text, null, _} when is_binary(Text), Text =/= <<>> ->
            parse_scores(Text, Votes);
        {_, Err, _} ->
            {error, short_reason(Err)}
    end.

parse_scores(Text, Votes) ->
    Stripped = strip_fences(Text),
    case try {ok, json:decode(Stripped)} catch _:_ -> bad end of
        bad -> {error, <<"non-json scores">>};
        {ok, Entries} when is_list(Entries) -> build_scores(Entries, Votes);
        {ok, _} -> {error, <<"scores not a list">>}
    end.

build_scores(Entries, Votes) ->
    Scores = lists:filtermap(fun score_entry/1, Entries),
    case length(Scores) =:= length(Entries) of
        false ->
            {error, <<"bad score shape">>};
        true ->
            Ids = [maps:get(id, S) || S <- Scores],
            GoodIds = [maps:get(id, V) || V <- good(Votes)],
            case GoodIds -- Ids of
                [] -> {ok, Scores};
                _ -> {error, <<"missing ids">>}
            end
    end.

score_entry(#{<<"id">> := Id, <<"C">> := C, <<"D">> := D})
  when is_binary(Id), is_number(C), is_number(D) ->
    {true, #{id => Id, 'C' => C, 'D' => D, net => C - D,
             note => <<"llm rubric">>}};
score_entry(_) ->
    false.

strip_fences(Text) ->
    T = string:trim(Text),
    case T of
        <<"```", _/binary>> ->
            case string:split(T, "\n") of
                [_Fence, Rest] ->
                    string:trim(string:trim(string:trim(Rest), trailing, "`"));
                _ -> T
            end;
        _ -> T
    end.

short_reason(null) -> <<"empty scorer reply">>;
short_reason(Err) -> string:slice(Err, 0, 120).

heuristic_score(#{id := Id, text := Text}, Note) ->
    C = min(10.0, 3.0 + string:length(Text) / 200),
    D = case has_bad(string:lowercase(Text)) of
            true -> 2.0;
            false -> 0.5
        end,
    #{id => Id, 'C' => round2(C), 'D' => round2(D), net => round2(C - D),
      note => Note}.

has_bad(Lower) ->
    lists:any(fun(W) -> binary:match(Lower, W) =/= nomatch end,
              [<<"delete all">>, <<"ignore safety">>, <<"harm users">>]).

round2(X) -> round(X * 100) / 100.
