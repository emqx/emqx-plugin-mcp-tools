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

-include_lib("emqx_plugin_helper/include/logger.hrl").
-include_lib("mcp_mqtt_erl/include/mcp_mqtt_erl_types.hrl").
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
    call_tool/3,
    list_tools/1
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

%%==============================================================================
%% mcp_mqtt_erl_server_session callbacks
%%==============================================================================
server_version() -> <<?PLUGIN_VSN>>.

server_name() ->
    <<"emqx_tools/info_apis">>.

server_id(Idx) ->
    Name = <<"emqx_tool_info_apis">>,
    Idx1 = integer_to_binary(Idx),
    Node = atom_to_binary(node()),
    <<Name/binary, ":", Idx1/binary, ":", Node/binary>>.

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

server_instructions() -> <<"">>.

server_meta() ->
    #{
        authorization => #{
            roles => [<<"admin">>, <<"user">>]
        }
    }.

-spec initialize(binary(), client_params()) -> {ok, loop_data()}.
initialize(ServerId, #{client_info := ClientInfo, client_capabilities := Capabilities, mcp_client_id := McpClientId}) ->
    {ok, #{
        server_id => ServerId,
        client_info => ClientInfo,
        client_capabilities => Capabilities,
        mcp_client_id => McpClientId
    }}.

-spec call_tool(binary(), map(), loop_data()) -> {ok, call_tool_result() | [call_tool_result()], loop_data()}.
call_tool(Name, Args, LoopData) ->
    try do_call_tool(Name, Args, LoopData)
    catch
        error:{badkey, Key} ->
            {error, #{code => 400, message => <<"Bad Request: Missing key '", Key/binary, "' in arguments">>}};
        Error:Reason:St ->
            ?SLOG(error, #{msg => call_tool_failed, name => Name, args => Args, error => Error, reason => Reason, stacktrace => St}),
            ErrReason = format_error_to_bin({Error, Reason}),
            {error, #{code => 500, message => <<"Internal Server Error: ", ErrReason/binary>>}}
    end.

do_call_tool(<<"get_emqx_cluster_info">>, _Args, LoopData) ->
    handle_http_api_result(emqx_mgmt_api_nodes:nodes(get, #{}), LoopData);
do_call_tool(<<"emqx_connector_info">>, Args, LoopData) ->
    ConnectorId = maps:get(<<"id">>, Args),
    Result = emqx_connector_api:'/connectors/:id'(get, #{bindings => #{id => ConnectorId}}),
    handle_http_api_result(Result, LoopData);
do_call_tool(<<"list_authenticators">>, _Args, LoopData) ->
    Result = emqx_authn_api:authenticators(get, #{}),
    handle_http_api_result(Result, LoopData);
do_call_tool(<<"get_authenticator_info">>, Args, LoopData) ->
    AuthenticatorId = maps:get(<<"id">>, Args),
    Result = emqx_authn_api:authenticator(get, #{bindings => #{id => AuthenticatorId}}),
    handle_http_api_result(Result, LoopData);
do_call_tool(<<"get_authenticator_status">>, Args, LoopData) ->
    AuthenticatorId = maps:get(<<"id">>, Args),
    Result = emqx_authn_api:authenticator_status(get, #{bindings => #{id => AuthenticatorId}}),
    handle_http_api_result(Result, LoopData);
do_call_tool(<<"list_authorization_sources">>, _Args, LoopData) ->
    handle_http_api_result(emqx_authz_api_sources:sources(get, #{}), LoopData);
do_call_tool(<<"get_authorization_source_info">>, Args, LoopData) ->
    SourceType = maps:get(<<"type">>, Args),
    Result = emqx_authz_api_sources:source(get, #{bindings => #{type => SourceType}}),
    handle_http_api_result(Result, LoopData);
do_call_tool(<<"get_authorization_source_status">>, Args, LoopData) ->
    SourceType = maps:get(<<"type">>, Args),
    AtomSourceType = binary_to_existing_atom(SourceType),
    Result = emqx_authz_api_sources:source_status(get, #{bindings => #{type => AtomSourceType}}),
    handle_http_api_result(Result, LoopData);
do_call_tool(<<"get_built_in_database_authorization_rules">>, Args, LoopData) ->
    Page = maps:get(<<"page">>, Args, 1),
    Limit = maps:get(<<"limit">>, Args, 100),
    QueryStr = #{<<"limit">> => Limit,<<"page">> => Page},
    Result =
        case maps:get(<<"type">>, Args) of
            <<"all">> ->
                emqx_authz_api_mnesia:all(get, #{});
            <<"clientid">> ->
                emqx_authz_api_mnesia:clients(get, #{query_string => QueryStr});
            <<"username">> ->
                emqx_authz_api_mnesia:users(get, #{query_string => QueryStr})
        end,
    handle_http_api_result(Result, LoopData);
do_call_tool(<<"check_tcp_connectivity">>, Args, LoopData) ->
    Host = maps:get(<<"host">>, Args),
    Port = maps:get(<<"port">>, Args),
    TimeoutMs = timer:seconds(maps:get(<<"timeout">>, Args, 5)),
    NodeResults = emqx_rpc:multicall_on_running(emqx:running_nodes(), emqx_mcp_tools_network, check_tcp_connectivity, [Host, Port, TimeoutMs], TimeoutMs + 1000),
    {ok, NodeResults, LoopData}.

-spec list_tools(loop_data()) -> {ok, [tool_def()], loop_data()}.
list_tools(LoopData) ->
    DefFiles = filelib:wildcard(filename:join([code:priv_dir(emqx_mcp_tools), "tools_definition", "*.json"])),
    case mcp_mqtt_erl_server_utils:get_tool_definitions_from_json(DefFiles) of
        {ok, ToolDefs} ->
            {ok, ToolDefs, LoopData};
        {error, _} = Err ->
            Err
    end.

%%==============================================================================
%% Helper functions
%%==============================================================================
handle_http_api_result({OkCode, Result}, LoopData) when OkCode =:= 200; OkCode =:= 201 ->
    Resp = mcp_mqtt_erl_server_utils:make_json_result(Result),
    {ok, Resp, LoopData};
handle_http_api_result({204}, LoopData) ->
    {ok, #{}, LoopData};
handle_http_api_result({Code, #{message := Msg}}, _LoopData) ->
    {error, #{code => Code, message => Msg}}.

format_error_to_bin(Term) ->
    iolist_to_binary(io_lib:format("~p", [Term])).
