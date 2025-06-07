-module(emqx_mcp_tools_common).
-include_lib("kernel/include/file.hrl").
-include_lib("emqx_plugin_helper/include/logger.hrl").

-export([
    get_system_time/0,
    get_log_messages/4
]).

-ifdef(TEST).
-export([
    parse_time/1,
    log_level/1,
    parse_line/2
]).
-endif.

-define(READ_AHEAD, 128 * 1024).

get_system_time() ->
    Ts = list_to_binary(calendar:system_time_to_rfc3339(now_us(), [{unit, microsecond}])),
    #{system_time => Ts, node => node()}.

get_log_messages(LogLevel0, MaxMsgs0, StartTime0, EndTime0) ->
    LogLevel = log_level(LogLevel0),
    MaxMsgs = validate_range(MaxMsgs0, 1, 1000),
    StartTime = parse_time(StartTime0),
    EndTime = parse_time(EndTime0),
    MsgOrder =
        case StartTime > EndTime of
            true -> reverse;
            false -> normal
        end,
    LogFiles = get_log_files(),
    %% sort the log files by modification time
    SortedFiles = lists:sort(
        fun(#{mtime := Mtime1}, #{mtime := Mtime2}) ->
            Mtime1 < Mtime2
        end,
        LogFiles
    ),
    %% remove the log files that are not in the range of StartTime and EndTime
    FilteredFiles = lists:filter(
        fun(#{mtime := Mtime}) ->
            Mtime >= min(StartTime, EndTime)
        end,
        SortedFiles
    ),
    %% search the log messages in the filtered log files, where the timestamp is in the range of StartTime and EndTime
    {LogMsgs, _} = read_logs_from_files(
        FilteredFiles, {[], 0}, LogLevel, StartTime, EndTime, MsgOrder, MaxMsgs
    ),
    #{node_name => node(), log_messages => LogMsgs}.

%%==============================================================================
%% Read log files
%%==============================================================================
read_logs_from_files(
    [#{file := File, log_type := LogType} | Files],
    {LogMsgs, LastLogTs},
    LogLevel,
    StartTime,
    EndTime,
    MsgOrder,
    MaxMsgs
) ->
    {ok, Fd} = file:open(File, [read, binary, raw, {read_ahead, ?READ_AHEAD}]),
    try
        {LogMsgs1, LastLogTs1} = read_lines_to_list(
            Fd, LogType, LogLevel, StartTime, EndTime, MsgOrder
        ),
        {LogMsgs2, LastLogTs2} =
            case LastLogTs1 >= LastLogTs of
                true when MsgOrder =:= normal ->
                    {LogMsgs ++ LogMsgs1, LastLogTs1};
                true when MsgOrder =:= reverse ->
                    {LogMsgs1 ++ LogMsgs, LastLogTs1};
                false when MsgOrder =:= normal ->
                    {LogMsgs1 ++ LogMsgs, LastLogTs};
                false when MsgOrder =:= reverse ->
                    {LogMsgs ++ LogMsgs1, LastLogTs}
            end,
        case length(LogMsgs2) >= MaxMsgs of
            true ->
                {lists:sublist(LogMsgs2, MaxMsgs), LastLogTs2};
            false ->
                read_logs_from_files(
                    Files, {LogMsgs2, LastLogTs2}, LogLevel, StartTime, EndTime, MsgOrder, MaxMsgs
                )
        end
    catch
        throw:Reason ->
            ?SLOG(error, #{msg => read_log_failed, file => File, error => Reason}),
            read_logs_from_files(
                Files, {LogMsgs, LastLogTs}, LogLevel, StartTime, EndTime, MsgOrder, MaxMsgs
            );
        Err:Reason:St ->
            ?SLOG(error, #{
                msg => read_log_failed,
                file => File,
                error => Err,
                reason => Reason,
                stacktrace => St
            }),
            read_logs_from_files(
                Files, {LogMsgs, LastLogTs}, LogLevel, StartTime, EndTime, MsgOrder, MaxMsgs
            )
    after
        file:close(Fd)
    end;
read_logs_from_files([], Acc, _LogLevel, _StartTime, _EndTime, _MsgOrder, _MaxMsgs) ->
    Acc.

read_lines_to_list(Fd, LogType, LogLevel, StartTime, EndTime, MsgOrder) ->
    read_lines_to_list(Fd, LogType, LogLevel, StartTime, EndTime, MsgOrder, {[], 0}).

read_lines_to_list(Fd, LogType, LogLevel, StartTime, EndTime, MsgOrder, {LogMsgs, LastLogTs} = Acc) ->
    case file:read_line(Fd) of
        {ok, Line} ->
            case parse_line(Line, LogType) of
                {ok, #{time := Ts, level := Level, message := LogMsg}} when
                    MsgOrder =:= normal, Ts > StartTime, Ts =< EndTime
                ->
                    case logger:compare_levels(Level, LogLevel) of
                        lt ->
                            read_lines_to_list(
                                Fd, LogType, LogLevel, StartTime, EndTime, MsgOrder, Acc
                            );
                        _ ->
                            read_lines_to_list(
                                Fd, LogType, LogLevel, StartTime, EndTime, MsgOrder, {
                                    [LogMsg | LogMsgs], Ts
                                }
                            )
                    end;
                {ok, #{time := Ts, level := Level, message := LogMsg}} when
                    MsgOrder =:= reverse, Ts < StartTime, Ts >= EndTime
                ->
                    case logger:compare_levels(Level, LogLevel) of
                        lt ->
                            read_lines_to_list(
                                Fd, LogType, LogLevel, StartTime, EndTime, MsgOrder, Acc
                            );
                        _ ->
                            read_lines_to_list(
                                Fd, LogType, LogLevel, StartTime, EndTime, MsgOrder, {
                                    [LogMsg | LogMsgs], Ts
                                }
                            )
                    end;
                {ok, _} ->
                    read_lines_to_list(Fd, LogType, LogLevel, StartTime, EndTime, MsgOrder, Acc);
                {error, Reason} ->
                    ?SLOG(error, #{msg => parse_log_failed, reason => Reason, line => Line}),
                    read_lines_to_list(Fd, LogType, LogLevel, StartTime, EndTime, MsgOrder, Acc)
            end;
        eof ->
            case MsgOrder of
                normal -> {lists:reverse(LogMsgs), LastLogTs};
                reverse -> Acc
            end;
        {error, Reason} ->
            throw({file_read_line_failed, Reason})
    end.

parse_line(Line, json) ->
    try
        #{<<"time">> := Ts, <<"level">> := Level} = LogMsg = emqx_utils_json:decode(Line),
        {ok, #{time => parse_time(Ts), level => log_level(Level), message => LogMsg}}
    catch
        _:_ ->
            {error, {bad_json_format, Line}}
    end;
parse_line(Line, text) ->
    try
        [TsStr, LevelStr | _] = string:lexemes(Line, " "),
        Ts =
            case is_numeric_str(TsStr) of
                true -> parse_time(binary_to_integer(TsStr));
                false -> parse_time(TsStr)
            end,
        Level = log_level(string:trim(LevelStr, both, "[]")),
        {ok, #{time => Ts, level => Level, message => Line}}
    catch
        _:_ ->
            {error, {bad_text_format, Line}}
    end.

%%==============================================================================
%% Internal functions
%%==============================================================================
get_log_files() ->
    #{handlers := Confs} = logger:get_config(),
    lists:foldl(
        fun
            (
                #{
                    module := logger_disk_log_h,
                    config := #{file := FilePrefix},
                    formatter := {Fmtr, _}
                },
                Acc
            ) ->
                LogType =
                    case Fmtr of
                        emqx_logger_jsonfmt -> json;
                        emqx_logger_textfmt -> text
                    end,
                WithoutFiles = [FilePrefix ++ ".siz", FilePrefix ++ ".idx"],
                Files = filelib:wildcard(FilePrefix ++ ".*") -- WithoutFiles,
                [
                    begin
                        {ok, #file_info{size = Size, mtime = MtimeS}} = file:read_file_info(File, [
                            {time, posix}
                        ]),
                        MtimeUs = timer:seconds(MtimeS) * 1000,
                        #{file => File, log_type => LogType, size => Size, mtime => MtimeUs}
                    end
                 || File <- Files
                ] ++ Acc;
            (_, Acc) ->
                Acc
        end,
        [],
        Confs
    ).

log_level(<<"debug">>) -> debug;
log_level(<<"info">>) -> info;
log_level(<<"notice">>) -> notice;
log_level(<<"warning">>) -> warning;
log_level(<<"error">>) -> error;
log_level(<<"critical">>) -> critical;
log_level(<<"alert">>) -> alert;
log_level(<<"emergency">>) -> emergency;
log_level(Level) -> throw({bad_log_level, #{level => Level}}).

validate_range(Value, Min, Max) when is_integer(Value) ->
    case Value of
        V when V >= Min; V =< Max ->
            Value;
        _ ->
            throw({bad_range, #{value => Value, min => Min, max => Max}})
    end;
validate_range(Value, _Min, _Max) ->
    throw({should_be_integer, #{value => Value}}).

-spec parse_time(binary() | integer()) -> integer().
parse_time(<<"now">>) ->
    now_us();
parse_time(<<"now", Str/binary>> = T) ->
    case string:trim(Str, both) of
        <<"-", OffsetStr/binary>> ->
            parse_relative_time(-1, OffsetStr);
        <<"+", OffsetStr/binary>> ->
            parse_relative_time(1, OffsetStr);
        _ ->
            throw({bad_time_format, #{time => T}})
    end;
parse_time(TimeUs) when is_integer(TimeUs) ->
    case TimeUs >= 1_000_000_000_000_000 of
        true -> TimeUs;
        false -> throw({bad_epoch_time, #{time => TimeUs}})
    end;
parse_time(Time) when is_binary(Time) ->
    try
        calendar:rfc3339_to_system_time(binary_to_list(Time), [{unit, microsecond}])
    catch
        error:Reason ->
            throw({bad_rfc3339_format, #{time => Time, reason => Reason}})
    end.

parse_relative_time(Sign, OffsetStr) ->
    case re:run(OffsetStr, "^(\\d+\\.?\\d*)([smhdw])$", [{capture, all_but_first, binary}]) of
        {match, [NumStr, Unit]} ->
            Num =
                try
                    case string:find(NumStr, ".") of
                        nomatch -> binary_to_integer(NumStr);
                        _ -> binary_to_float(NumStr)
                    end
                catch
                    _:_ -> throw({bad_time_format, #{offset => OffsetStr}})
                end,
            OffSetMs =
                case Unit of
                    <<"s">> -> timer:seconds(Num);
                    <<"m">> -> timer:minutes(Num);
                    <<"h">> -> timer:hours(Num);
                    <<"d">> -> timer:hours(Num) * 24;
                    <<"w">> -> timer:hours(Num) * 24 * 7;
                    _ -> throw({bad_time_unit, #{unit => Unit}})
                end,
            OffSetUs = Sign * OffSetMs * 1000,
            erlang:floor(now_us() + OffSetUs);
        nomatch ->
            throw({bad_time_format, #{offset => OffsetStr}})
    end.

is_numeric_str(Str) when is_binary(Str) ->
    String = binary_to_list(Str),
    [Char || Char <- String, Char < $0 orelse Char > $9] == [].

now_us() ->
    os:system_time(microsecond).
