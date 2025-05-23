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
-feature(maybe_expr, enable).

-include_lib("emqx_plugin_helper/include/logger.hrl").
-include("mcp_mqtt_erl_errors.hrl").
-include("mcp_mqtt_erl_types.hrl").
-include("mcp_mqtt_erl.hrl").

-export_type([
    t/0
]).

-export([
    init/4,
    handle_rpc_msg/2,
    handle_rpc_timeout/2,
    send_server_request/3,
    send_server_notification/2
]).

-type t() :: #{
    mod := module(),
    state => created | initialized,
    client_info := map(),
    client_capabilities := map(),
    server_id := binary(),
    server_name := binary(),
    mcp_client_id := binary(),
    client_roots => [map()],
    loop_data => map(),
    pending_requests => pending_requests()
}.

-type mcp_client_info() :: #{
    mcp_clientid := binary(),
    init_params := #{
        _ => _
    },
    req_id := any()
}.

-type pending_requests() :: #{
    integer() => #{
        mcp_msg_type := mcp_msg_type(),
        caller := pid() | no_caller,
        timestamp := integer()
    }
}.

-type client_params() :: #{
    client_info := map(),
    client_capabilities := map()
}.
-type error_details() :: #{
    reason := term(),
    _ => _
}.

-type loop_data() :: term().

-callback server_name() -> binary().
-callback server_version() -> binary().
-callback server_capabilities() -> map().
-callback initialize(ServerId :: binary(), client_params()) -> {ok, loop_data()} | {error, error_response()}.
-callback set_logging_level(LoggingLevel :: binary(), loop_data()) -> {ok, loop_data()} | {error, error_response()}.
-callback list_resources(loop_data()) -> {ok, [resource_def()], loop_data()} | {error, error_response()}.
-callback list_resource_templates(loop_data()) -> {ok, [resource_tmpl()], loop_data()} | {error, error_response()}.
-callback read_resource(Uri :: binary(), loop_data()) -> {ok, resource(), loop_data()} | {error, error_response()}.
-callback call_tool(ToolName :: binary(), Args :: map(), loop_data()) ->
    {ok, call_tool_result() | [call_tool_result()], loop_data()}
  | {error, call_tool_result() | [call_tool_result()]}.
-callback list_tools(loop_data()) -> {ok, [tool_def()], loop_data()} | {error, error_response()}.
-callback list_prompts(loop_data()) -> {ok, [prompt_def()], loop_data()} | {error, error_response()}.
-callback get_prompt(Name :: binary(), Args :: map(), loop_data()) ->
    {ok, get_prompt_result(), loop_data()} | {error, error_response()}.
-callback complete(Ref :: binary(), Args :: map(), loop_data()) ->
    {ok, complete_result(), loop_data()} | {error, error_response()}.

-define(MAX_PAGE_SIZE, 10).

-spec init(binary(), module(), binary(), mcp_client_info()) -> {ok, t()} | {error, error_details()}.
init(MqttClient, Mod, ServerId, _ClientInfo = #{
    mcp_clientid := McpClientId,
    init_params := InitParams,
    req_id := ReqId
}) ->
    ServerName = Mod:server_name(),
    ServerVsn = Mod:server_version(),
    ServerCapabilities = Mod:server_capabilities(),
    ServerInfo = #{<<"name">> => ServerName, <<"version">> => ServerVsn},
    maybe
        {ok, ClientParams} ?= verify_initialize_params(InitParams),
        {ok, LoopData} ?= Mod:initialize(ServerId, ClientParams),
        %% send initialize response to client
        InitializeResp = mcp_mqtt_erl_msg:initialize_response(
            ReqId, ServerInfo, ServerCapabilities
        ),
        ok ?= mcp_mqtt_erl_msg:publish_mcp_server_message(
            MqttClient, ServerId, ServerName, McpClientId, rpc, #{}, InitializeResp
        ),
        {ok, ClientParams#{
            state => created,
            mqtt_client => MqttClient,
            mod => Mod,
            server_id => ServerId,
            server_name => ServerName,
            mcp_client_id => McpClientId,
            loop_data => LoopData,
            pending_requests => #{}
        }}
    else
        {error, #{reason := Reason}} = Err when
                Reason == missing_capabilities;
                Reason == missing_client_info;
                Reason == missing_protocol_version ->
            ErrResult = mcp_mqtt_erl_msg:json_rpc_error(ReqId, ?ERR_C_REQUIRED_FILED_MISSING, Reason, #{}),
            ok = mcp_mqtt_erl_msg:publish_mcp_server_message(
                MqttClient, ServerId, ServerName, McpClientId, rpc, #{}, ErrResult
            ),
            Err;
        {error, #{reason := ?ERR_UNSUPPORTED_PROTOCOL_VERSION, vsn := Vsn}} = Err ->
            ErrResult = mcp_mqtt_erl_msg:json_rpc_error(ReqId, ?ERR_C_UNSUPPORTED_PROTOCOL_VERSION, <<"Unsupported protocol version">>, #{<<"requested">> => Vsn, <<"supported">> => [?MCP_VERSION]}),
            ok = mcp_mqtt_erl_msg:publish_mcp_server_message(
                MqttClient, ServerId, ServerName, McpClientId, rpc, #{}, ErrResult
            ),
            Err;
        {error, #{code := ErrCode, message := ErrMsg, data := ErrData} = Error} ->
            ErrResult = mcp_mqtt_erl_msg:json_rpc_error(ReqId, ErrCode, ErrMsg, ErrData),
            ok = mcp_mqtt_erl_msg:publish_mcp_server_message(
                MqttClient, ServerId, ServerName, McpClientId, rpc, #{}, ErrResult
            ),
            {error, Error#{reason => callback_mod_replies_an_error}};
        {error, _} = Err ->
            Err
    end.

send_server_request(Session, Caller, #{method := <<"ping">>} = Req) ->
    do_send_server_request(Session, Caller, Req);
send_server_request(#{state := initialized} = Session, Caller, Req) ->
    do_send_server_request(Session, Caller, Req);
send_server_request(Session, Caller, Req) ->
    maybe_reply_to_caller(Session, Caller, Req, {error, #{reason => ?ERR_NOT_INITIALIZED, request => Req}}).

do_send_server_request(#{pending_requests := Pendings, timers := Timers, mcp_clientid := McpClientId} = Session, Caller, #{id := ReqId, method := Method, params := Params}) ->
    Payload = mcp_mqtt_erl_msg:json_rpc_request(ReqId, Method, Params),
    ok = publish_mcp_server_message(Session, rpc, #{}, Payload),
    Pendings1 = Pendings#{ReqId => #{mcp_msg_type => list_roots, timestamp => ts_now(), caller => Caller}},
    Timers1 = Timers#{ReqId => start_rpc_timer(McpClientId, ReqId)},
    {ok, Session#{pending_requests => Pendings1, timers := Timers1}}.

send_server_notification(Session, #{method := Method} = Notif) ->
    Params = maps:get(params, Notif, #{}),
    Payload = mcp_mqtt_erl_msg:json_rpc_notification(Method, Params),
    ok = publish_mcp_server_message(Session, rpc, #{}, Payload),
    {ok, Session}.

handle_rpc_msg(Session, #{type := json_rpc_request, method := Method, id := ReqId, params := Params}) ->
    handle_rpc_request_and_send_response(Session, Method, ReqId, Params);
handle_rpc_msg(Session, #{type := json_rpc_notification, method := Method, params := Params}) ->
    handle_json_rpc_notification(Session, Method, Params);
handle_rpc_msg(Session, #{type := json_rpc_response, id := ReqId, result := Result}) ->
    handle_json_rpc_response(Session, ReqId, Result);
handle_rpc_msg(Session, #{type := json_rpc_error, id := ReqId, error := Error}) ->
    handle_json_rpc_error(Session, ReqId, Error);
handle_rpc_msg(_Session, Msg) ->
    {error, #{reason => ?ERR_MALFORMED_JSON_RPC, message => Msg}}.

handle_json_rpc_error(#{pending_requests := Pendings0, timers := Timers} = Session, ReqId, ErrMsg) ->
    case maps:take(ReqId, Pendings0) of
        {#{caller := Caller} = PendingReq, Pendings} ->
            {TRef, Timers1} = maps:take(ReqId, Timers),
            _ = erlang:cancel_timer(TRef),
            Session1 = maybe_reply_to_caller(Session, Caller, PendingReq,
                {error, #{reason => mcp_rpc_error, error_msg => ErrMsg}}),
            {ok, Session1#{pending_requests => Pendings, timers := Timers1}};
        {_, Pendings} ->
            {TRef, Timers1} = maps:take(ReqId, Timers),
            _ = erlang:cancel_timer(TRef),
            ?SLOG(error, #{msg => no_caller_to_reply, id => ReqId}),
            {ok, Session#{pending_requests => Pendings, timers := Timers1}};
        error ->
            {terminated, #{reason => ?ERR_WRONG_RPC_ID}}
    end.

handle_rpc_timeout(#{pending_requests := Pendings0, timers := Timers} = Session, ReqId) ->
    case maps:take(ReqId, Pendings0) of
        {#{caller := Caller}, Pendings} ->
            gen_statem:reply(Caller, {error, #{reason => ?ERR_TIMEOUT}}),
            {ok, Session#{pending_requests => Pendings, timers := maps:remove(ReqId, Timers)}};
        {_, Pendings} ->
            ?SLOG(error, #{msg => no_caller_to_reply, id => ReqId}),
            {ok, Session#{pending_requests => Pendings, timers := maps:remove(ReqId, Timers)}};
        error ->
            {terminated, #{reason => ?ERR_WRONG_RPC_ID}}
    end.

%%==============================================================================
%% Handle JSON-RPC requests/responses/notifications
%%==============================================================================
handle_rpc_request_and_send_response(Session, Method, ReqId, Params) ->
    MqttClient = maps:get(mqtt_client, Session),
    ServerId = maps:get(server_id, Session),
    ServerName = maps:get(server_name, Session),
    McpClientId = maps:get(mcp_client_id, Session),
    case handle_json_rpc_request(Session, Method, ReqId, Params) of
        {ok, Result, Session1} ->
            ok = mcp_mqtt_erl_msg:publish_mcp_server_message(
                MqttClient, ServerId, ServerName, McpClientId, rpc, #{}, Result
            ),
            {ok, Session1};
        {error, #{code := ErrCode, message := ErrMsg, data := ErrData}} ->
            ErrResult = mcp_mqtt_erl_msg:json_rpc_error(ReqId, ErrCode, ErrMsg, ErrData),
            ok = mcp_mqtt_erl_msg:publish_mcp_server_message(
                MqttClient, ServerId, ServerName, McpClientId, rpc, #{}, ErrResult
            ),
            {error, #{reason => ErrMsg, method => Method, id => ReqId}}
    end.

handle_json_rpc_request(Session, <<"ping">>, ReqId, _) ->
    PingResp = mcp_mqtt_erl_msg:json_rpc_response(ReqId, #{}),
    {ok, PingResp, Session};
handle_json_rpc_request(Session, <<"logging/setLevel">>, ReqId, #{<<"level">> := Level}) ->
    Mod = maps:get(mod, Session),
    LoopData = maps:get(loop_data, Session),
    case Mod:set_logging_level(Level, LoopData) of
        {ok, LoopData1} ->
            LoggingResp = mcp_mqtt_erl_msg:json_rpc_response(ReqId, #{}),
            {ok, LoggingResp, Session#{loop_data => LoopData1}};
        {error, _} = Err ->
            Err
    end;
handle_json_rpc_request(Session, <<"resources/list">>, ReqId, #{<<"cursor">> := PageNo}) ->
    case maps:find(cached_resources, Session) of
        {ok, Resources} ->
            ResList = lists:sublist(Resources, ?MAX_PAGE_SIZE * PageNo, ?MAX_PAGE_SIZE),
            Result = mcp_mqtt_erl_msg:json_rpc_response(ReqId,
                #{<<"resources">> => ResList, <<"nextCursor">> => PageNo + 1}),
            {ok, Result, Session};
        error ->
            {error, #{
                code => ?ERR_C_INVALID_CURSOR,
                message => <<"Invalid cursor">>,
                data => #{cursor => PageNo}
            }}
    end;
handle_json_rpc_request(Session, <<"resources/list">>, ReqId, _) ->
    Mod = maps:get(mod, Session),
    LoopData = maps:get(loop_data, Session),
    case Mod:list_resources(LoopData) of
        {ok, Resources, LoopData1} ->
            Resp = case length(Resources) > ?MAX_PAGE_SIZE of
                true ->
                    ResList = lists:sublist(Resources, ?MAX_PAGE_SIZE),
                    PageNo = 1, %% the second page
                    mcp_mqtt_erl_msg:json_rpc_response(ReqId,
                        #{<<"resources">> => ResList, <<"nextCursor">> => PageNo});
                false ->
                    mcp_mqtt_erl_msg:json_rpc_response(ReqId, #{<<"resources">> => Resources})
            end,
            {ok, Resp, Session#{loop_data => LoopData1, cached_resources => Resources}};
        {error, _} = Err ->
            {error, Err}
    end;
handle_json_rpc_request(Session, <<"resources/templates/list">>, ReqId, #{<<"cursor">> := PageNo}) ->
    case maps:find(cached_resource_templates, Session) of
        {ok, ResourceTemplates} ->
            ResList = lists:sublist(ResourceTemplates, ?MAX_PAGE_SIZE * PageNo, ?MAX_PAGE_SIZE),
            Result = mcp_mqtt_erl_msg:json_rpc_response(ReqId,
                #{<<"resources">> => ResList, <<"nextCursor">> => PageNo + 1}),
            {ok, Result, Session};
        error ->
            {error, #{
                code => ?ERR_C_INVALID_CURSOR,
                message => <<"Invalid cursor">>,
                data => #{cursor => PageNo}
            }}
    end;
handle_json_rpc_request(Session, <<"resources/templates/list">>, ReqId, _) ->
    Mod = maps:get(mod, Session),
    LoopData = maps:get(loop_data, Session),
    case Mod:list_resource_templates(LoopData) of
        {ok, ResourceTemplates, LoopData1} ->
            Resp = case length(ResourceTemplates) > ?MAX_PAGE_SIZE of
                true ->
                    ResList = lists:sublist(ResourceTemplates, ?MAX_PAGE_SIZE),
                    PageNo = 1, %% the second page
                    mcp_mqtt_erl_msg:json_rpc_response(ReqId,
                        #{<<"resources">> => ResList, <<"nextCursor">> => PageNo});
                false ->
                    mcp_mqtt_erl_msg:json_rpc_response(ReqId, #{<<"resourceTemplates">> => ResourceTemplates})
            end,
            {ok, Resp, Session#{loop_data => LoopData1, cached_resource_templates => ResourceTemplates}};
        {error, _} = Err ->
            {error, Err}
    end;
handle_json_rpc_request(Session, <<"resources/read">>, ReqId, #{<<"uri">> := Uri}) ->
    Mod = maps:get(mod, Session),
    LoopData = maps:get(loop_data, Session),
    case Mod:read_resource(Uri, LoopData) of
        {ok, Resource, LoopData1} ->
            ReadResp = mcp_mqtt_erl_msg:json_rpc_response(ReqId, #{<<"contents">> => [Resource]}),
            {ok, ReadResp, Session#{loop_data => LoopData1}};
        {error, _} = Err ->
            {error, Err}
    end;
handle_json_rpc_request(_Session, <<"resources/subscribe">>, _Id, _Params) ->
    throw({not_implemented, subscribe_resource});
handle_json_rpc_request(_Session, <<"resources/unsubscribe">>, _Id, _Params) ->
    throw({not_implemented, unsubscribe_resource});
handle_json_rpc_request(Session, <<"tools/call">>, ReqId, #{<<"name">> := ToolName, <<"arguments">> := Args}) ->
    Mod = maps:get(mod, Session),
    LoopData = maps:get(loop_data, Session),
    case Mod:call_tool(ToolName, Args, LoopData) of
        {ok, Result, LoopData1} ->
            CallToolResp = mcp_mqtt_erl_msg:json_rpc_response(ReqId, #{
                <<"content">> => ensure_list(Result),
                <<"isError">> => false
            }),
            {ok, CallToolResp, Session#{loop_data => LoopData1}};
        {error, Result} ->
            CallToolResp = mcp_mqtt_erl_msg:json_rpc_response(ReqId, #{
                <<"content">> => ensure_list(Result),
                <<"isError">> => true
            }),
            {ok, CallToolResp, Session}
    end;
handle_json_rpc_request(Session, <<"tools/list">>, ReqId, _Params) ->
    Mod = maps:get(mod, Session),
    LoopData = maps:get(loop_data, Session),
    case Mod:list_tools(LoopData) of
        {ok, Tools, LoopData1} ->
            ListResp = mcp_mqtt_erl_msg:json_rpc_response(ReqId, #{<<"tools">> => Tools}),
            {ok, ListResp, Session#{loop_data => LoopData1}};
        {error, _} = Err ->
            {error, Err}
    end;
handle_json_rpc_request(Session, <<"prompts/list">>, ReqId, _Params) ->
    Mod = maps:get(mod, Session),
    LoopData = maps:get(loop_data, Session),
    case Mod:list_prompts(LoopData) of
        {ok, Prompts, LoopData1} ->
            ListResp = mcp_mqtt_erl_msg:json_rpc_response(ReqId, #{<<"prompts">> => Prompts}),
            {ok, ListResp, Session#{loop_data => LoopData1}};
        {error, _} = Err ->
            {error, Err}
    end;
handle_json_rpc_request(Session, <<"prompts/get">>, ReqId, #{<<"name">> := Name, <<"arguments">> := Args}) ->
    Mod = maps:get(mod, Session),
    LoopData = maps:get(loop_data, Session),
    case Mod:get_prompt(Name, Args, LoopData) of
        {ok, Prompt, LoopData1} ->
            GetResp = mcp_mqtt_erl_msg:json_rpc_response(ReqId, Prompt),
            {ok, GetResp, Session#{loop_data => LoopData1}};
        {error, _} = Err ->
            {error, Err}
    end;
handle_json_rpc_request(Session, <<"completion/complete">>, ReqId, #{
        <<"ref">> := Ref, <<"argument">> := Args}) ->
    Mod = maps:get(mod, Session),
    LoopData = maps:get(loop_data, Session),
    case Mod:complete(Ref, Args, LoopData) of
        {ok, Completion, LoopData1} ->
            CompleteResp = mcp_mqtt_erl_msg:json_rpc_response(ReqId, #{<<"completion">> => Completion}),
            {ok, CompleteResp, Session#{loop_data => LoopData1}};
        {error, _} = Err ->
            {error, Err}
    end.

handle_json_rpc_notification(Session, <<"notifications/initialized">>, _) ->
    {ok, Session#{state => initialized}};
handle_json_rpc_notification(#{pending_requests := Pendings, timers := Timers} = Session, <<"notifications/roots/list_changed">>, _) ->
    ReqId = list_to_binary(emqx_utils:gen_id()),
    McpClientId = maps:get(mcp_client_id, Session),
    ListRequest = mcp_mqtt_erl_msg:json_rpc_request(ReqId, <<"roots/list">>, #{}),
    case publish_mcp_server_message(Session, rpc, #{}, ListRequest) of
        ok ->
            Pendings1 = Pendings#{ReqId => #{mcp_msg_type => list_roots, timestamp => ts_now(), caller => no_caller}},
            Timers1 = Timers#{ReqId => start_rpc_timer(McpClientId, ReqId)},
            {ok, Session#{pending_requests => Pendings1, timers := Timers1}};
        {error, _} = Err ->
            ?SLOG(error, #{msg => send_root_list_failed, error => Err}),
            {ok, Session}
    end.

handle_json_rpc_response(#{pending_requests := Pendings0, timers := Timers} = Session, ReqId, Result) ->
    case maps:take(ReqId, Pendings0) of
        {#{caller := Caller} = PendingReq, Pendings} ->
            {TRef, Timers1} = maps:take(ReqId, Timers),
            _ = erlang:cancel_timer(TRef),
            Session1 = maybe_reply_to_caller(Session, Caller, PendingReq, {ok, Result}),
            {ok, Session1#{pending_requests => Pendings, timers := Timers1}};
        {_, Pendings} ->
            {TRef, Timers1} = maps:take(ReqId, Timers),
            _ = erlang:cancel_timer(TRef),
            ?SLOG(error, #{msg => no_caller_to_reply, id => ReqId}),
            {ok, Session#{pending_requests => Pendings, timers := Timers1}};
        error ->
            {terminated, #{reason => ?ERR_WRONG_RPC_ID}}
    end.

%%==============================================================================
%% Internal Functions
%%==============================================================================
publish_mcp_server_message(Session, TopicType, Flags, Payload) ->
    MqttClient = maps:get(mqtt_client, Session),
    ServerId = maps:get(server_id, Session),
    ServerName = maps:get(server_name, Session),
    McpClientId = maps:get(mcp_client_id, Session),
    mcp_mqtt_erl_msg:publish_mcp_server_message(
        MqttClient, ServerId, ServerName, McpClientId, TopicType, Flags, Payload
    ).

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
verify_initialize_params(#{<<"protocolVersion">> := Vsn}) ->
    {error, #{reason => ?ERR_UNSUPPORTED_PROTOCOL_VERSION, vsn => Vsn}};
verify_initialize_params(_Params) ->
    {error, #{reason => missing_protocol_version}}.

maybe_reply_to_caller(Session, no_caller, #{mcp_msg_type := list_roots}, {ok, Result}) ->
    Session#{client_roots => Result};
maybe_reply_to_caller(Session, no_caller, #{mcp_msg_type := list_roots}, {error, Result}) ->
    ?SLOG(error, #{msg => list_tools_failed, error => Result}),
    Session;
maybe_reply_to_caller(Session, Caller, _, Result) ->
    gen_statem:reply(Caller, Result),
    Session.

start_rpc_timer(McpClientId, ReqId) ->
    erlang:send_after(?RPC_TIMEOUT, self(), {rpc_request_timeout, McpClientId, ReqId}).

ts_now() ->
    erlang:system_time(microsecond).

ensure_list(Term) when is_list(Term) -> true;
ensure_list(Term) -> [Term].
