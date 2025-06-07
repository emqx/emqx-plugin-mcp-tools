-module(emqx_mcp_tools_common_tests).
-compile(export_all).
-compile(nowarn_export_all).
-include_lib("eunit/include/eunit.hrl").

-define(M, emqx_mcp_tools_common).

parse_time_test_() ->
    [ {"verify now is integer", ?_assert(is_integer(?M:parse_time(<<"now">>)))}
    , {"verify now is microsecond", ?_test(within_passed_n_secs(?M:parse_time(<<"now">>), 0.001))}
    , {"verify relative time, unit:s, -", ?_test(is_n_secs_ago(?M:parse_time(<<"now-10s">>), 10))}
    , {"verify relative time, unit:s, +", ?_test(is_n_secs_later(?M:parse_time(<<"now+10s">>), 10-0.1))}
    , {"verify relative time, unit:m, -", ?_test(is_n_secs_ago(?M:parse_time(<<"now-10m">>), 600))}
    , {"verify relative time, unit:m, +", ?_test(is_n_secs_later(?M:parse_time(<<"now+10m">>), 600-0.1))}
    , {"verify relative time, unit:h, -", ?_test(is_n_secs_ago(?M:parse_time(<<"now-1h">>), 3600))}
    , {"verify relative time, unit:h, +", ?_test(is_n_secs_later(?M:parse_time(<<"now+1h">>), 3600-0.1))}
    , {"verify relative time, unit:d, -", ?_test(is_n_secs_ago(?M:parse_time(<<"now-1d">>), 86400))}
    , {"verify relative time, unit:d, +", ?_test(is_n_secs_later(?M:parse_time(<<"now+1d">>), 86400-0.1))}
    , {"verify relative time, unit:w, +", ?_test(is_n_secs_later(?M:parse_time(<<"now+1w">>), 604800-0.1))}
    , {"verify relative time, unit:w, -", ?_test(is_n_secs_ago(?M:parse_time(<<"now-1w">>), 604800))}
    , {"verify relative time, float 0.1", ?_test(is_n_secs_ago(?M:parse_time(<<"now-0.1s">>), 0.1))}
    , {"verify relative time, float 1.1", ?_test(is_n_secs_ago(?M:parse_time(<<"now-1.1s">>), 1.1))}
    , {"verify relative time, float 10.02", ?_test(is_n_secs_ago(?M:parse_time(<<"now-10.02s">>), 10.02))}
    , {"verify RFC 3339 time format", ?_test(is_n_secs_ago(?M:parse_time(<<"2025-06-06T10:00:00+08:00">>), 86400))}
    , {"verify it support integer", ?_test(begin Now = nowus(), ?assertEqual(Now, ?M:parse_time(Now)) end)}
    , {"invalid integer", ?_assertThrow({bad_epoch_time, _}, ?M:parse_time(11))}
    , {"invalid time format", ?_assertThrow({bad_rfc3339_format, _}, ?M:parse_time(<<"invalid">>))}
    , {"invalid time format 1", ?_assertThrow({bad_rfc3339_format, _}, ?M:parse_time(<<"2025-06-06T10:00:">>))}
    , {"invalid time offset +1.s", ?_assertThrow({bad_time_format, _}, ?M:parse_time(<<"now+1.s">>))}
    , {"invalid time offset +.1s", ?_assertThrow({bad_time_format, _}, ?M:parse_time(<<"now+.1s">>))}
    , {"invalid time offset +1x", ?_assertThrow({bad_time_format, _}, ?M:parse_time(<<"now+1x">>))}
    , {"invalid time offset -y", ?_assertThrow({bad_time_format, _}, ?M:parse_time(<<"now-y">>))}
    , {"invalid time offset -", ?_assertThrow({bad_time_format, _}, ?M:parse_time(<<"now-">>))}
    , {"invalid time offset +", ?_assertThrow({bad_time_format, _}, ?M:parse_time(<<"now+">>))}
    ].

log_level_test_() ->
    [ {"verify log level debug", ?_assertEqual(debug, ?M:log_level(<<"debug">>))}
    , {"verify log level info", ?_assertEqual(info, ?M:log_level(<<"info">>))}
    , {"verify log level notice", ?_assertEqual(notice, ?M:log_level(<<"notice">>))}
    , {"verify log level warning", ?_assertEqual(warning, ?M:log_level(<<"warning">>))}
    , {"verify log level error", ?_assertEqual(error, ?M:log_level(<<"error">>))}
    , {"verify log level critical", ?_assertEqual(critical, ?M:log_level(<<"critical">>))}
    , {"verify log level alert", ?_assertEqual(alert, ?M:log_level(<<"alert">>))}
    , {"verify log level emergency", ?_assertEqual(emergency, ?M:log_level(<<"emergency">>))}
    , {"verify log level invalid", ?_assertThrow({bad_log_level, _}, ?M:log_level(<<"invalid">>))}
    , {"verify log level empty", ?_assertThrow({bad_log_level, _}, ?M:log_level(<<"">>))}
    ].

parse_line_test_() ->
    [ {"parse normal text log msg", ?_assertMatch(
        {ok, #{time := 1749056174568393, level := debug, message := _}},
        ?M:parse_line(<<"2025-06-05T00:56:14.568393+08:00 debug debug test message">>, text))}
    , {"parse normal json log msg", ?_assertMatch(
        {ok, #{time := 1749056174568393, level := warning, message := _}},
        ?M:parse_line(<<"{\"time\":1749056174568393,\"level\":\"warning\",\"msg\":\"retry_connect_to_localhost_broker\",\"tag\":\"MCP_SERVER\",\"reason\":\"not_authorized\",\"pid\":\"<0.5024.0>\"}">>, json))}
    , {"parse normal json log msg with rfc3339 timestamp", ?_assertMatch(
        {ok, #{time := 1749056174568393, level := warning, message := _}},
        ?M:parse_line(<<"{\"time\":\"2025-06-05T00:56:14.568393+08:00\",\"level\":\"warning\",\"msg\":\"retry_connect_to_localhost_broker\",\"tag\":\"MCP_SERVER\",\"reason\":\"not_authorized\",\"pid\":\"<0.5024.0>\"}">>, json))}
    ].

%%==============================================================================
%% Helper functions for time assertions
%%==============================================================================
is_n_secs_ago(Time, N) when is_integer(Time) ->
    Now = nowus(),
    ?assert(Time < Now andalso (Now - Time) >= us(N)).

is_n_secs_later(Time, N) when is_integer(Time) ->
    Now = nowus(),
    ?assert(Time > Now andalso (Time - Now) >= us(N)).

within_passed_n_secs(Time, N) when is_integer(Time) ->
    Now = nowus(),
    ?assert(Time >= (Now - us(N)) andalso Time =< Now).

nowus() ->
    os:system_time(microsecond).

us(N) ->
    N * 1_000_000.
