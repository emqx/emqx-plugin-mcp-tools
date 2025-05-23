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

-module(mcp_mqtt_erl_server).

-feature(maybe_expr, enable).
-include_lib("emqx_plugin_helper/include/logger.hrl").
-include("mcp_mqtt_erl_errors.hrl").
-include("mcp_mqtt_erl_types.hrl").

-behaviour(gen_statem).

%% API
-export([
    start_link/2,
    stop/1,
    process_name/2
]).

-export([
    send_request/3,
    send_notification/2
]).

%% gen_statem callbacks
-export([init/1, callback_mode/0, terminate/3, code_change/4]).

%% gen_statem state functions
-export([idle/3, connected/3]).

-export_type([config/0]).

-type state_name() :: idle | connected.

-type mcp_client_id() :: binary().

-type broker_address() :: {emqtt:host(), emqtt:port()} | local.

-type config() :: #{
    broker_address := broker_address(),
    callback_mod := module(),
    mqtt_options => map()
}.

-type session() :: mcp_mqtt_erl_server_session:t().

-type sessions() :: #{
    mcp_client_id() => session()
} | #{}.

-type loop_data() :: #{
    server_id := binary(),
    callback_mod := module(),
    mqtt_options => map(),
    mqtt_client => pid() | local,
    sessions => sessions()
}.

-type server_request() ::
    ping
    | list_roots
    | log
    | sampling_create.

-type server_notification() ::
    progress_notification
    | prompt_list_changed
    | resource_updated
    | resource_list_changed
    | tool_list_changed.

-define(handle_common, ?FUNCTION_NAME(T, C, D) -> handle_common(?FUNCTION_NAME, T, C, D)).
-define(log_enter_state(OldState),
    ?SLOG(debug, #{msg => enter_state, state => ?FUNCTION_NAME, previous => OldState})
).
-define(REQUEST_TIMEOUT, 15_000).

%%==============================================================================
%% API
%%==============================================================================
-spec start_link(integer(), config()) -> gen_statem:start_ret().
start_link(Idx, #{callback_mod := Mod, broker_address := BrokerAddr} = Conf) ->
    ServerName = Mod:server_name(),
    RegisterName = process_name(ServerName, Idx),
    MqttOpts = maps:get(mqtt_options, Conf, #{}),
    gen_statem:start_link({local, RegisterName}, ?MODULE, {Idx, BrokerAddr, Mod, MqttOpts}, []).

stop(Pid) ->
    gen_statem:cast(Pid, stop).

process_name(ServerName, Idx) ->
    Idx1 = integer_to_binary(Idx),
    binary_to_atom(<<ServerName/binary, ":", Idx1/binary>>).

-spec send_request(pid(), mcp_client_id(), server_request()) -> Reply :: term().
send_request(Pid, TargetClient, Req) ->
    gen_statem:call(Pid, {server_request, TargetClient, Req}, {clean_timeout, ?REQUEST_TIMEOUT}).

-spec send_notification(pid(), server_notification()) -> ok.
send_notification(Pid, Notif) ->
    gen_statem:cast(Pid, {server_notif, Notif}).

%% gen_statem callbacks
-spec init({integer(), broker_address(), module(), map()}) ->
    {ok, state_name(), loop_data(), [gen_statem:action()]}.
init({Idx, BrokerAddr, Mod, MqttOpts}) ->
    process_flag(trap_exit, true),
    ServerId =
        case Mod:server_id(Idx) of
            random -> list_to_binary(emqx_utils:gen_id());
            Id -> Id
        end,
    LoopData = #{
        callback_mod => Mod,
        server_id => ServerId,
        sessions => #{}
    },
    case BrokerAddr of
        local ->
            %% Local mode, no need to connect to MQTT broker
            {ok, connected, LoopData#{mqtt_client => local}, []};
        {Host, Port} ->
            {ok, idle, LoopData#{mqtt_options => MqttOpts#{host => Host, port => Port}},
                [{next_event, internal, connect_broker}]}
    end.

callback_mode() ->
    [state_functions, state_enter].

-spec idle(enter | gen_statem:event_type(), state_name(), loop_data()) ->
    gen_statem:state_enter_result(state_name(), loop_data())
    | gen_statem:event_handler_result(state_name(), loop_data()).
idle(enter, _OldState, _LoopData) ->
    {keep_state_and_data, []};
idle(internal, connect_broker, LoopData) ->
    MqttOpts = maps:get(mqtt_options, LoopData),
    case emqtt:start_link(MqttOpts) of
        {ok, MqttClient} ->
            case emqtt:connect(MqttClient) of
                {ok, _} ->
                    {next_state, connected, LoopData#{mqtt_client => MqttClient}};
                {error, Reason} ->
                    ?SLOG(error, #{msg => connect_to_mqtt_broker_failed, reason => Reason}),
                    shutdown(#{error => Reason})
            end;
        {error, Reason} ->
            ?SLOG(error, #{msg => start_emqtt_failed, reason => Reason}),
            shutdown(#{error => Reason})
    end;
?handle_common.

-spec connected(enter | gen_statem:event_type(), state_name(), loop_data()) ->
    gen_statem:state_enter_result(state_name(), loop_data())
    | gen_statem:event_handler_result(state_name(), loop_data()).
connected(enter, OldState, #{callback_mod := Mod, mqtt_client := MqttClient, server_id := ServerId}) ->
    ok = send_server_online_notification(MqttClient, Mod, ServerId),
    ?log_enter_state(OldState),
    keep_state_and_data;
connected({call, Caller}, {server_request, TargetClient, Req}, #{sessions := Sessions} = LoopData) ->
    case maps:find(TargetClient, Sessions) of
        {ok, Session} ->
            case mcp_mqtt_erl_server_session:send_server_request(Session, Caller, Req) of
                {ok, Session1} ->
                    %% we will reply the caller in the session
                    {keep_state, LoopData#{sessions => Sessions#{TargetClient => Session1}}};
                {error, Reason} ->
                    ?SLOG(error, #{msg => send_server_request_error, reason => Reason}),
                    {keep_state, LoopData};
                {terminated, Reason} ->
                    ?SLOG(warning, #{msg => session_terminated_on_send_server_request, reason => Reason}),
                    {keep_state, LoopData#{sessions => maps:remove(TargetClient, Sessions)}}
            end;
        error ->
            ?SLOG(error, #{msg => send_server_request_failed, reason => session_not_found}),
            {keep_state, LoopData}
    end;
connected(cast, {server_notif, Notif}, #{sessions := Sessions} = LoopData) ->
    Sessions1 = send_server_notification_to_all(Sessions, Notif),
    {keep_state, LoopData#{sessions => Sessions1}};

connected(info, {publish, #{topic := <<"$mcp-server/", _/binary>>, payload := Payload, properties := Props} = Msg}, #{mod := Mod, mqtt_client := MqttClient} = LoopData) ->
    maybe
        Sessions = maps:get(sessions, LoopData),
        ServerId = maps:get(server_id, LoopData),
        {ok, McpClientId} ?= mcp_mqtt_erl_msg:get_mcp_client_id_from_mqtt_props(Props),
        {ok, mcp_client} ?= mcp_mqtt_erl_msg:get_mcp_component_type_from_mqtt_props(Props),
        {ok, #{method := <<"initialize">>, id := Id, params := Params}} ?= mcp_mqtt_erl_msg:decode_rpc_msg(Payload),
        {ok, Sess} ?= mcp_mqtt_erl_server_session:init(
            MqttClient, Mod, ServerId,
            #{
                mcp_client_id => McpClientId,
                init_params => Params,
                req_id => Id
            }
        ),
        {keep_state, LoopData#{sessions => Sessions#{McpClientId => Sess}}, []}
    else
        {ok, RpcMsg} ->
            ?SLOG(debug, #{msg => unexpected_rpc_msg, details => RpcMsg}),
            {keep_state, LoopData};
        {error, #{reason := ?ERR_INVALID_JSON}} ->
            ?SLOG(error, #{msg => non_json_msg, details => Msg}),
            {keep_state, LoopData};
        {error, Reason} ->
            ?SLOG(error, #{msg => invalid_initialize_msg, details => Msg, reason => Reason}),
            {keep_state, LoopData}
    end;
connected(info, {publish, #{topic := <<"$mcp-client/presence/", McpClientId/binary>>, payload := Payload}}, #{sessions := Sessions} = LoopData) ->
    case mcp_mqtt_erl_msg:decode_rpc_msg(Payload) of
        {ok, #{method := <<"notifications/disconnected">>}} ->
            ?SLOG(debug, #{msg => client_disconnected}),
            {keep_state, LoopData#{sessions => maps:remove(McpClientId, Sessions)}};
        {ok, Msg} ->
            ?SLOG(error, #{msg => unsupported_client_presence_msg, rpc_msg => Msg}),
            {keep_state, LoopData};
        {error, Reason} ->
            ?SLOG(error, #{msg => decode_rpc_msg_failed, reason => Reason}),
            {keep_state, LoopData}
    end;
connected(info, {publish, #{topic := <<"$mcp-client/capability/list-changed/", _/binary>>}}, LoopData) ->
    ?SLOG(error, #{msg => unimplemented_client_capability_list_changed}),
    {keep_state, LoopData};
connected(info, {publish, #{topic := <<"$mcp-rpc-endpoint/", ClientIdAndServerName/binary>>, payload := Payload}}, #{sessions := Sessions} = LoopData) ->
    {McpClientId, _} = split_id_and_server_name(ClientIdAndServerName),
    case maps:find(McpClientId, Sessions) of
        {ok, Session} ->
            case emqx_mcp_message:decode_rpc_msg(Payload) of
                {ok, Msg} ->
                    case mcp_mqtt_erl_server_session:handle_rpc_msg(Session, Msg) of
                        {ok, Session1} ->
                            {keep_state, LoopData#{sessions => Sessions#{McpClientId => Session1}}};
                        {error, Reason} ->
                            ?SLOG(error, #{msg => handle_rpc_msg_failed, reason => Reason}),
                            {keep_state, LoopData};
                        {terminated, Reason} ->
                            ?SLOG(warning, #{msg => session_terminated_on_rpc_msg, reason => Reason}),
                            {keep_state, LoopData#{sessions => maps:remove(McpClientId, Sessions)}}
                    end;
                {error, Reason} ->
                    ?SLOG(error, #{msg => decode_rpc_msg_failed, reason => Reason}),
                    {keep_state, LoopData}
            end;
        error ->
            ?SLOG(error, #{msg => handle_rpc_failed, reason => session_not_found}),
            {keep_state, LoopData}
    end;
connected(info, {publish, #{topic := Topic}}, _LoopData) ->
    ?SLOG(error, #{msg => unsupported_topic, topic => Topic}),
    keep_state_and_data;
connected(info, {rpc_request_timeout, McpClientId, ReqId}, #{sessions := Sessions} = LoopData) ->
    case maps:find(McpClientId, Sessions) of
        {ok, Session} ->
            case mcp_mqtt_erl_server_session:handle_rpc_timeout(Session, ReqId) of
                {ok, Session1} ->
                    {keep_state, LoopData#{sessions => Sessions#{McpClientId => Session1}}};
                {terminated, Reason} ->
                    ?SLOG(warning, #{msg => session_terminated_on_rpc_timeout, reason => Reason}),
                    {keep_state, LoopData#{sessions => maps:remove(McpClientId, Sessions)}}
            end;
        error ->
            ?SLOG(error, #{msg => handle_rpc_timeout_failed, reason => session_not_found}),
            {keep_state, LoopData}
    end;
?handle_common.

terminate(_Reason, connected, #{mqtt_client := MqttClient, server_id := ServerId, mod := Mod}) ->
    send_server_offline_message(MqttClient, Mod, ServerId);
terminate(_Reason, _State, _LoopData) ->
    ok.

code_change(_OldVsn, State, LoopData, _Extra) ->
    {ok, State, LoopData}.

handle_common(_State, state_timeout, TimeoutReason, _LoopData) ->
    shutdown(#{error => TimeoutReason});
handle_common(_State, info, {'EXIT', MqttClient, Reason}, #{mqtt_client := MqttClient}) ->
    ?SLOG(error, #{msg => mqtt_client_exit, reason => Reason}),
    shutdown(#{error => Reason});
handle_common(_State, cast, stop, _LoopData) ->
    ?SLOG(debug, #{msg => stop}),
    shutdown(#{error => normal});
handle_common(State, EventType, EventContent, _LoopData) ->
    ?SLOG(error, #{
        msg => unexpected_msg,
        state => State,
        event_type => EventType,
        event_content => EventContent
    }),
    keep_state_and_data.

shutdown(ErrObj) ->
    shutdown(ErrObj, []).

shutdown(#{error := normal}, Actions) ->
    {stop, normal, Actions};
shutdown(#{error := Error} = ErrObj, Actions) ->
    ?SLOG(warning, ErrObj#{msg => shutdown}),
    {stop, {shutdown, Error}, Actions}.

%%==============================================================================
%% Internal functions
%%==============================================================================
send_server_online_notification(MqttClient, Mod, ServerId) ->
    mcp_mqtt_erl_msg:send_server_online_message(
        MqttClient,
        ServerId,
        Mod:server_name(),
        Mod:server_instructions(),
        Mod:server_meta()
    ).

send_server_offline_message(MqttClient, Mod, ServerId) ->
    mcp_mqtt_erl_msg:send_server_offline_message(MqttClient, ServerId, Mod:server_name()).

send_server_notification_to_all(Sessions, Notif) ->
    maps:fold(
        fun(McpClientId, Session, Acc) ->
            {ok, Session1} = mcp_mqtt_erl_server_session:send_server_notification(Session, Notif),
            Acc#{McpClientId => Session1}
        end, #{}, Sessions
    ).

split_id_and_server_name(Str) ->
    %% Split the server ID and name from the topic
    case string:split(Str, <<"/">>) of
        [Id, ServerName] -> {Id, ServerName};
        _ -> throw({error, {invalid_id_and_server_name, Str}})
    end.
