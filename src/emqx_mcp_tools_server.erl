%%--------------------------------------------------------------------
%% Copyright (c) 2017-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_mcp_tools_server).

-behaviour(mcp_mqtt_erl_server_session).

-include("mcp_mqtt_erl_types.hrl").
-include("emqx_mcp_tools.hrl").

-export([
    start_link/2
]).

-export([
    server_name/0,
    server_id/1,
    server_version/0,
    server_capabilities/0,
    server_instructions/0,
    server_meta/0
]).

-export([
    initialize/2,
    set_logging_level/2,
    list_resources/1,
    list_resource_templates/1,
    read_resource/2,
    call_tool/3,
    list_tools/1,
    list_prompts/1,
    get_prompt/3,
    complete/3
]).

-type loop_data() :: #{
    server_id => binary(),
    client_info => map(),
    client_capabilities => map(),
    mcp_client_id => binary(),
    _ => any()
}.

-spec start_link(integer(), mcp_mqtt_erl_server:config()) -> gen_statem:start_ret().
start_link(Idx, Conf) ->
    mcp_mqtt_erl_server:start_link(Idx, Conf).

server_version() ->
    <<?PLUGIN_VSN>>.

server_name() ->
    <<"emqx_tools/info_apis">>.

server_id(Idx) ->
    Name = server_name(),
    Idx1 = integer_to_binary(Idx),
    <<Name/binary, ":", Idx1/binary>>.

server_capabilities() ->
    #{
        resources => #{
            subscribe => true,
            listChanged => true
        },
        tools => #{
            listChanged => true
        }
    }.

server_instructions() ->
    <<"">>.

server_meta() ->
    #{
        authorization => #{
            roles => [<<"admin">>, <<"user">>]
        }
    }.

-spec initialize(binary(), client_params()) -> {ok, loop_data()}.
initialize(ServerId, #{client_info := ClientInfo, client_capabilities := Capabilities, mcp_client_id := McpClientId}) ->
    io:format("initialize --- server_id: ~p, client_info: ~p, client_capabilities: ~p, mcp_client_id: ~p~n", [ServerId, ClientInfo, Capabilities, McpClientId]),
    {ok, #{
        server_id => ServerId,
        client_info => ClientInfo,
        client_capabilities => Capabilities,
        mcp_client_id => McpClientId
    }}.

-spec set_logging_level(binary(), loop_data()) -> {ok, loop_data()}.
set_logging_level(LoggingLevel, LoopData) ->
    io:format("set_logging_level --- logging_level: ~p~n", [LoggingLevel]),
    {ok, LoopData}.

-spec list_resources(loop_data()) -> {ok, [resource_def()], loop_data()}.
list_resources(LoopData) ->
    io:format("list_resources --- ~n", []),
    Resources = [
        #{
            uri => <<"http://example.com/resource1">>,
            name => <<"resource1">>,
            description => <<"This is resource 1">>,
            mimeType => <<"application/json">>,
            size => 1024
        },
        #{
            uri => <<"http://example.com/resource2">>,
            name => <<"resource2">>,
            description => <<"This is resource 2">>,
            mimeType => <<"application/xml">>,
            size => 2048
        }
    ],
    {ok, Resources, LoopData}.

-spec list_resource_templates(loop_data()) -> {ok, [resource_tmpl()], loop_data()}.
list_resource_templates(LoopData) ->
    io:format("list_resource_templates --- ~n", []),
    ResourceTemplates = [
        #{
            uriTemplate => <<"http://example.com/resource_template1">>,
            name => <<"resource_template1">>,
            description => <<"This is resource template 1">>,
            mimeType => <<"application/json">>
        },
        #{
            uriTemplate => <<"http://example.com/resource_template2">>,
            name => <<"resource_template2">>,
            description => <<"This is resource template 2">>,
            mimeType => <<"application/xml">>
        }
    ],
    {ok, ResourceTemplates, LoopData}.

-spec read_resource(binary(), loop_data()) -> {ok, resource(), loop_data()}.
read_resource(Uri, LoopData) ->
    io:format("read_resource --- uri: ~p~n", [Uri]),
    Resource = #{
        uri => Uri,
        mimeType => <<"application/json">>,
        text => <<"This is the content of the resource">>
    },
    {ok, Resource, LoopData}.

-spec call_tool(binary(), map(), loop_data()) -> {ok, call_tool_result() | [call_tool_result()], loop_data()}.
call_tool(ToolName, Args, LoopData) ->
    io:format("call_tool --- tool_name: ~p, args: ~p~n", [ToolName, Args]),
    Result = #{
        type => text,
        text => <<"This is the result of the tool call">>
    },
    {ok, Result, LoopData}.

-spec list_tools(loop_data()) -> {ok, [tool_def()], loop_data()}.
list_tools(LoopData) ->
    io:format("list_tools --- ~n", []),
    Tools = [
        #{
            name => <<"tool1">>,
            description => <<"This is tool 1">>,
            inputSchema => #{
                type => <<"object">>,
                properties => #{
                    arg1 => #{
                        type => <<"string">>,
                        description => <<"Argument 1">>
                    },
                    arg2 => #{
                        type => <<"integer">>,
                        description => <<"Argument 2">>
                    }
                }
            }
        },
        #{
            name => <<"tool2">>,
            description => <<"This is tool 2">>,
            inputSchema => #{
                type => <<"object">>,
                properties => #{
                    arg1 => #{
                        type => <<"string">>,
                        description => <<"Argument 1">>
                    },
                    arg2 => #{
                        type => <<"boolean">>,
                        description => <<"Argument 2">>
                    }
                }
            }
        }
    ],
    {ok, Tools, LoopData}.

-spec list_prompts(loop_data()) -> {ok, [prompt_def()], loop_data()}.
list_prompts(LoopData) ->
    io:format("list_prompts --- ~n", []),
    Prompts = [
        #{
            name => <<"prompt1">>,
            description => <<"This is prompt 1">>,
            arguments => [
                #{
                    name => <<"arg1">>,
                    description => <<"Argument 1">>,
                    required => true
                },
                #{
                    name => <<"arg2">>,
                    description => <<"Argument 2">>,
                    required => false
                }
            ]
        },
        #{
            name => <<"prompt2">>,
            description => <<"This is prompt 2">>,
            arguments => [
                #{
                    name => <<"arg1">>,
                    description => <<"Argument 1">>,
                    required => true
                },
                #{
                    name => <<"arg2">>,
                    description => <<"Argument 2">>,
                    required => true
                }
            ]
        }
    ],
    {ok, Prompts, LoopData}.

-spec get_prompt(binary(), map(), loop_data()) -> {ok, get_prompt_result(), loop_data()}.
get_prompt(Name, Args, LoopData) ->
    io:format("get_prompt --- name: ~p, args: ~p~n", [Name, Args]),
    Prompt = #{
        description => <<"This is the prompt description">>,
        messages => [
            #{
                role => <<"user">>,
                content => <<"This is the user message">>
            },
            #{
                role => <<"assistant">>,
                content => <<"This is the assistant message">>
            }
        ]
    },
    {ok, Prompt, LoopData}.

-spec complete(binary(), map(), loop_data()) -> {ok, complete_result(), loop_data()}.
complete(Ref, Args, LoopData) ->
    io:format("complete --- ref: ~p, args: ~p~n", [Ref, Args]),
    Result = #{
        values => [
            <<"This is the first completion">>,
            <<"This is the second completion">>
        ],
        total => 2,
        hasMore => false
    },
    {ok, Result, LoopData}.
