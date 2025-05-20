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

-module(mcp_mqtt_erl_server_session).

-include_lib("emqx_plugin_helper/include/logger.hrl").
-include("mcp_mqtt_erl_errors.hrl").

-export_type([
    t/0
]).

-export([
    new/0,
    handle_rpc_msg/2,
]).

-type t() :: #{
    mod := module(),
    client_info := map(),
    client_capabilities := map(),
    next_req_id := integer(),
    server_id := binary(),
    server_name := binary(),
    mcp_client_id := binary(),
    client_roots => [map()],
    loop_data => map(),
    pending_requests => pending_requests()
}.

-type mcp_msg_type() ::
    initialize
    | initialized
    | ping
    | progress_notification
    | set_logging_level
    | list_resources
    | list_resource_templates
    | read_resource
    | subscribe_resource
    | unsubscribe_resource
    | call_tool
    | list_prompts
    | get_prompt
    | complete
    | list_tools
    | roots_list_changed
    | list_roots.

-type pending_requests() :: #{
    integer() => #{
        mcp_msg_type := mcp_msg_type(),
        timestamp := integer()
    }
}.

new(Mod, ServerId, ServerName, McpClientId, ClientInitParams) ->
    case verify_initialize_params(ClientInitParams) of
        {ok, ClientParams} ->
            {ok, ClientParams#{
                next_req_id => 0,
                mod => Mod,
                server_id => ServerId,
                server_name => ServerName,
                mcp_client_id => McpClientId,
                loop_data => #{},
                pending_requests => #{}
            }};
        {error, _} = Err ->
            Err
    end.

handle_rpc_msg(Session, #{type := json_rpc_request, method := Method, id := Id, params := Params} = Msg) ->
    handle_json_rpc_request(Session, Method, Id, Params);
handle_rpc_msg(Session, #{type := json_rpc_notification, method := Method, params := Params} = Msg) ->
    handle_json_rpc_notification(Session, Method, Params);
handle_rpc_msg(Session, #{type := json_rpc_response, id := Id, result := Result} = Msg) ->
    handle_json_rpc_response(Session, Id, Result);
handle_rpc_msg(Session, #{type := json_rpc_error, id := Id, error := Error} = Msg) ->
    handle_json_rpc_error(Session, Id, Error);
handle_rpc_msg(Session, Msg) ->
    {error, #{reason => ?ERR_MALFORMED_JSON_RPC, msg => Msg}}.

handle_json_rpc_request(Session, <<"ping">>, Id, Params) ->
    PingResp = mcp_mqtt_erl_msg:json_rpc_response(Id, #{}),
    mcp_mqtt_erl_msg:publish_mcp_server_message(
        maps:get(server_id, Session),
        maps:get(server_name, Session),
        maps:get(mcp_client_id, Session),
        rpc, #{}, PingResp
    ),
    {ok, Session};
handle_json_rpc_request(Session, <<"logging/setLevel">>, Id, Params) ->
    Mod = maps:get(mod, Session),
    LoopData = maps:get(loop_data, Session),
    case Mod:set_logging_level(maps:get(<<"level">>), LoopData) of
        {ok, LoopData1} ->
            LoggingResp = mcp_mqtt_erl_msg:json_rpc_response(Id, #{}),
            mcp_mqtt_erl_msg:publish_mcp_server_message(
                maps:get(server_id, Session),
                maps:get(server_name, Session),
                maps:get(mcp_client_id, Session),
                rpc, #{}, LoggingResp
            ),
            {ok, Session#{loop_data => LoopData1}};
        {error, _} = Err ->
            {error, Err}
    end;
handle_json_rpc_request(Session, <<"resources/list">>, Id, Params) ->
    Mod = maps:get(mod, Session),
    LoopData = maps:get(loop_data, Session),
    case Mod:list_resources(Params, LoopData) of
        {ok, Resources, LoopData1} ->
            ListResp = mcp_mqtt_erl_msg:json_rpc_response(Id, Resources),
            mcp_mqtt_erl_msg:publish_mcp_server_message(
                maps:get(server_id, Session),
                maps:get(server_name, Session),
                maps:get(mcp_client_id, Session),
                rpc, #{}, ListResp
            ),
            {ok, Session#{loop_data => LoopData1}};
        {error, _} = Err ->
            {error, Err}
    end;
handle_json_rpc_request(Session, <<"resources/templates/list">>, Id, Params) ->
    Mod = maps:get(mod, Session),
    LoopData = maps:get(loop_data, Session),
    case Mod:list_resource_templates(Params, LoopData) of
        {ok, Templates, LoopData1} ->
            ListResp = mcp_mqtt_erl_msg:json_rpc_response(Id, Templates),
            mcp_mqtt_erl_msg:publish_mcp_server_message(
                maps:get(server_id, Session),
                maps:get(server_name, Session),
                maps:get(mcp_client_id, Session),
                rpc, #{}, ListResp
            ),
            {ok, Session#{loop_data => LoopData1}};
        {error, _} = Err ->
            {error, Err}
    end;
handle_json_rpc_request(Session, <<"resources/read">>, Id, Params) ->
    Mod = maps:get(mod, Session),
    LoopData = maps:get(loop_data, Session),
    case Mod:read_resource(Params, LoopData) of
        {ok, Resource, LoopData1} ->
            ReadResp = mcp_mqtt_erl_msg:json_rpc_response(Id, Resource),
            mcp_mqtt_erl_msg:publish_mcp_server_message(
                maps:get(server_id, Session),
                maps:get(server_name, Session),
                maps:get(mcp_client_id, Session),
                rpc, #{}, ReadResp
            ),
            {ok, Session#{loop_data => LoopData1}};
        {error, _} = Err ->
            {error, Err}
    end;
handle_json_rpc_request(_Session, <<"resources/subscribe">>, _Id, _Params, _Msg) ->
    throw({error, not_implemented});
handle_json_rpc_request(_Session, <<"resources/unsubscribe">>, _Id, _Params, _Msg) ->
    throw({error, not_implemented});
handle_json_rpc_request(Session, <<"tools/call">>, Id, Params) ->
    ToolName = maps:get(<<"name">>, Params),
    Args = maps:get(<<"arguments">>, Params),
    Mod = maps:get(mod, Session),
    LoopData = maps:get(loop_data, Session),
    case Mod:call_tool(ToolName, Args, LoopData) of
        {ok, Result, LoopData1} ->
            CallResp = mcp_mqtt_erl_msg:json_rpc_response(Id, Result),
            mcp_mqtt_erl_msg:publish_mcp_server_message(
                maps:get(server_id, Session),
                maps:get(server_name, Session),
                maps:get(mcp_client_id, Session),
                rpc, #{}, CallResp
            ),
            {ok, Session#{loop_data => LoopData1}};
        {error, _} = Err ->
            {error, Err}
    end;
handle_json_rpc_request(Session, <<"tools/list">>, Id, Params) ->
    Mod = maps:get(mod, Session),
    LoopData = maps:get(loop_data, Session),
    case Mod:list_tools(Params, LoopData) of
        {ok, Tools, LoopData1} ->
            ListResp = mcp_mqtt_erl_msg:json_rpc_response(Id, Tools),
            mcp_mqtt_erl_msg:publish_mcp_server_message(
                maps:get(server_id, Session),
                maps:get(server_name, Session),
                maps:get(mcp_client_id, Session),
                rpc, #{}, ListResp
            ),
            {ok, Session#{loop_data => LoopData1}};
        {error, _} = Err ->
            {error, Err}
    end;
handle_json_rpc_request(Session, <<"prompts/list">>, Id, Params) ->
    Mod = maps:get(mod, Session),
    LoopData = maps:get(loop_data, Session),
    case Mod:list_prompts(Params, LoopData) of
        {ok, Prompts, LoopData1} ->
            ListResp = mcp_mqtt_erl_msg:json_rpc_response(Id, Prompts),
            mcp_mqtt_erl_msg:publish_mcp_server_message(
                maps:get(server_id, Session),
                maps:get(server_name, Session),
                maps:get(mcp_client_id, Session),
                rpc, #{}, ListResp
            ),
            {ok, Session#{loop_data => LoopData1}};
        {error, _} = Err ->
            {error, Err}
    end;
handle_json_rpc_request(Session, <<"prompts/get">>, Id, Params) ->
    Mod = maps:get(mod, Session),
    LoopData = maps:get(loop_data, Session),
    case Mod:get_prompt(Params, LoopData) of
        {ok, Prompt, LoopData1} ->
            GetResp = mcp_mqtt_erl_msg:json_rpc_response(Id, Prompt),
            mcp_mqtt_erl_msg:publish_mcp_server_message(
                maps:get(server_id, Session),
                maps:get(server_name, Session),
                maps:get(mcp_client_id, Session),
                rpc, #{}, GetResp
            ),
            {ok, Session#{loop_data => LoopData1}};
        {error, _} = Err ->
            {error, Err}
    end;
handle_json_rpc_request(Session, <<"completion/complete">>, Id, Params) ->
    Mod = maps:get(mod, Session),
    LoopData = maps:get(loop_data, Session),
    case Mod:complete(Params, LoopData) of
        {ok, Completion, LoopData1} ->
            CompleteResp = mcp_mqtt_erl_msg:json_rpc_response(Id, Completion),
            mcp_mqtt_erl_msg:publish_mcp_server_message(
                maps:get(server_id, Session),
                maps:get(server_name, Session),
                maps:get(mcp_client_id, Session),
                rpc, #{}, CompleteResp
            ),
            {ok, Session#{loop_data => LoopData1}};
        {error, _} = Err ->
            {error, Err}
    end.

handle_json_rpc_notification(#{pending_requests := Pendings, timers := Timers} = Session, <<"notifications/roots/list_changed">>, Params) ->
    Id = maps:get(next_req_id, Session),
    ListRequest = mcp_mqtt_erl_msg:json_rpc_request(Id, <<"roots/list">>, #{}),
    mcp_mqtt_erl_msg:publish_mcp_server_message(
        maps:get(server_id, Session),
        maps:get(server_name, Session),
        maps:get(mcp_client_id, Session),
        rpc, #{}, ListRequest
    ),
    Pendings1 = Pendings#{Id => #{mcp_msg_type => list_roots, timestamp => ts_now()}},
    Timers1 = Timers#{Id => erlang:send_after(?RPC_TIMEOUT, self(), {rpc_request_timeout, Id})},
    {ok, Session#{next_req_id => Id + 1, pending_requests => Pendings1, timers := Timers1}}.

handle_json_rpc_response(#{pending_requests := Pendings0, timers := Timers} = Session, Id, Result) ->
    case maps:find(Id, Pendings0) of
        {ok, #{mcp_msg_type := list_roots}} ->
            Pendings = maps:remove(Id, Pendings0),
            {TRef, Timers1} = maps:take(Id, Timers),
            erlang:cancel_timer(TRef),
            {ok, Session#{pending_requests => Pendings, client_roots => Result, timers := Timers1}};
        {ok, #{caller := Caller}} ->
            Pendings = maps:remove(Id, Pendings0),
            {TRef, Timers1} = maps:take(Id, Timers),
            erlang:cancel_timer(TRef),
            gen_statem:reply(Caller, {ok, Result}),
            {ok, Session#{pending_requests => Pendings, timers := Timers1}};
        error ->
            {error, #{reason => ?ERR_WRONG_SERVER_RESPONSE_ID}}
    end.

handle_rpc_timeout(#{pending_requests := Pendings0, timers := Timers} = Session, Id) ->
    case maps:find(Id, Pendings0) of
        {ok, #{caller := Caller}} ->
            Pendings = maps:remove(Id, Pendings0),
            {TRef, Timers1} = maps:take(Id, Timers),
            erlang:cancel_timer(TRef),
            gen_statem:reply(Caller, {error, #{reason => ?ERR_TIMEOUT}}),
            {ok, Session#{pending_requests => Pendings, timers := Timers1}};
        error ->
            ok
    end.

%%==============================================================================
%% Internal Functions
%%==============================================================================
verify_initialize_params(#{<<"protocolVersion">> := <<?MCP_VERSION>>} = Params) ->
    case maps:find(<<"clientInfo">>, Params) of
        {ok, ClientInfo} ->
            case maps:find(<<"capabilities">>, Params) of
                {ok, Capabilities} ->
                    {ok, #{
                        client_info => ClientInfo,
                        client_capabilities => Capabilities
                    }};
                error ->
                    {error, #{reason => missing_capabilities}}
            end;
        error ->
            {error, #{reason => missing_client_info}}
    end;
verify_initialize_params(#{<<"protocolVersion">> := Vsn} = Params) ->
    {error, #{reason => ?ERR_UNSUPPORTED_PROTOCOL_VERSION, vsn => Vsn}};
verify_initialize_params(Params) ->
    {error, #{reason => missing_protocol_version}}.

ts_now() ->
    erlang:system_time(microsecond).
