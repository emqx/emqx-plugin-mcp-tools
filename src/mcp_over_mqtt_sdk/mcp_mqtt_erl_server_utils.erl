-module(mcp_mqtt_erl_server_utils).

-feature(maybe_expr, enable).

-include("mcp_mqtt_erl_errors.hrl").
-include("mcp_mqtt_erl_types.hrl").

-export([
    get_tool_definitions_from_json/1,
    make_json_result/1
]).

-spec get_tool_definitions_from_json(file:name_all() | [file:name_all()]) ->
    {ok, [map()]} | {error, error_response()}.
get_tool_definitions_from_json(JsonFiles) when is_list(JsonFiles) ->
    Result = lists:foldl(
        fun(File, {SuccAcc, ErrAcc}) ->
            case get_tool_definitions_from_json(File) of
                {ok, ToolDefs} ->
                    {SuccAcc ++ ToolDefs, ErrAcc};
                {error, Reason} ->
                    Err = #{filename => File, reason => Reason},
                    {SuccAcc, ErrAcc ++ [Err]}
            end
        end,
        {[], []},
        JsonFiles
    ),
    case Result of
        {ToolDefs, []} ->
            {ok, ToolDefs};
        {_, Errs} ->
            {error, Errs}
    end;

get_tool_definitions_from_json(JsonFile) ->
    maybe
        {ok, Json} ?= file:read_file(JsonFile),
        JsonM = json:decode(Json),
        ToolDefs = maps:fold(
            fun(Name, Def, Acc) ->
                [#{
                    name => Name,
                    description => get_tool_description(Def),
                    inputSchema => maps:get(<<"inputSchema">>, Def, #{})
                } | Acc]
            end,
            [],
            JsonM
        ),
        {ok, ToolDefs}
    else
        {error, Reason} ->
            ReasonStr = format_error_msg("Failed to read tool definitions from JSON file, reason: ~p", [Reason]),
            {error, #{code => ?ERR_C_INTERNAL_ERROR,
                      message => ReasonStr,
                      data => #{filename => JsonFile}}}
    end.

make_json_result(Ret) ->
    #{
        type => text,
        text => erlang:iolist_to_binary(json:encode(Ret))
    }.

%%==============================================================================
%% Helper functions
%%==============================================================================
get_tool_description(Def) ->
    Desc = maps:get(<<"description">>, Def),
    case maps:get(<<"outputSchema">>, Def, null) of
        null -> Desc;
        OutputSchema when is_map(OutputSchema) ->
            erlang:iolist_to_binary([Desc, " The return of the function is a JSON formatted string with the following Schema definition: ", json:encode(OutputSchema)])
    end.

format_error_msg(Format, ErrorTerms) ->
    iolist_to_binary(io_lib:format(Format, ErrorTerms)).
