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
call_tool(<<"get_emqx_cluster_info">>, _Args, LoopData) ->
    {200, Ret} = emqx_mgmt_api_nodes:nodes(get, #{}),
    Result = mcp_mqtt_erl_server_utils:make_json_result(Ret),
    {ok, Result, LoopData};
call_tool(<<"emqx_connector_info">>, Args, LoopData) ->
    ConnectorId = maps:get(<<"id">>, Args),
    case emqx_mgmt_api_nodes:nodes(get, #{}) of
        {200, Ret} ->
            emqx_connector_api:'/connectors/:id'(get, #{bindings => #{id => ConnectorId}}),
            Result = mcp_mqtt_erl_server_utils:make_json_result(Ret),
            {ok, Result, LoopData};
        {404, #{message := Msg}} ->
            {error, #{code => 404, message => Msg}, LoopData}
    end.

-spec list_tools(loop_data()) -> {ok, [tool_def()], loop_data()}.
list_tools(LoopData) ->
    ToolsDefFile = filename:join([code:priv_dir(emqx_mcp_tools), "tools_definition.json"]),
    case mcp_mqtt_erl_server_utils:get_tool_definitions_from_json(ToolsDefFile) of
        {ok, ToolDefs} ->
            {ok, ToolDefs, LoopData};
        {error, _} = Err ->
            Err
    end.

%%==============================================================================
%% Helper functions
%%==============================================================================
