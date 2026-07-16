%% Env-driven configuration. Read on demand (cheap, no cache needed).
-module(zhc_fabric_config).

-export([host/0, port/0, default_base_url/0, default_model/0, default_api_key/0,
         max_inflight/0, max_n/0, max_prompt_chars/0, love_eq_rubric/0]).

host() -> str_env("FABRIC_HOST", "127.0.0.1").

port() -> int_env("FABRIC_PORT", 7733).

default_base_url() ->
    string:trim(bin_env("DEFAULT_BASE_URL"), trailing, "/").

default_model() -> bin_env("DEFAULT_MODEL").

default_api_key() -> bin_env("DEFAULT_API_KEY").

max_inflight() -> max(1, int_env("MAX_INFLIGHT_COMPLETIONS", 2)).

max_n() -> max(1, min(16, int_env("FABRIC_MAX_N", 8))).

max_prompt_chars() -> int_env("FABRIC_MAX_PROMPT_CHARS", 100000).

love_eq_rubric() -> bin_env("FABRIC_LOVE_EQ_RUBRIC").

%% internal

str_env(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        "" -> Default;
        V -> V
    end.

bin_env(Name) ->
    unicode:characters_to_binary(str_env(Name, "")).

int_env(Name, Default) ->
    try list_to_integer(string:trim(str_env(Name, "")))
    catch _:_ -> Default
    end.
