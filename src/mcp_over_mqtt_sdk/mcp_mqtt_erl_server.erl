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
-behaviour(gen_statem).

%% API
-export([
    start_supervised/1,
    start_link/1,
    stop_supervised_all/0,
    stop/1
]).

%% gen_statem callbacks
-export([init/1, callback_mode/0, terminate/3, code_change/4]).

%% gen_statem state functions
-export([idle/3, connected/3, server_initialized/3]).

-export_type([config/0]).

-type state_name() ::
    idle
    | connected
    | server_initialized.

-type server_name() :: emqx_types:topic().
-type mcp_client_id() :: emqx_types:clientid().
-type mcp_server_config() :: #{_ => _}.
-type opts() :: #{
    mqtt_options => [emqtt:option()],
    atom() => term()
}.
-type config() :: #{
    callback_mod := module(),
    server_name := server_name(),
    server_version := binary(),
    server_desc => binary(),
    server_meta => #{},
    opts => opts()
}.

-type session() :: mcp_mqtt_erl_server_session:t().

-type sessions() :: #{
    mcp_client_id() => session()
}.

-type loop_data() :: #{
    callback_mod := module(),
    server_name := server_name(),
    server_version := binary(),
    server_id := emqx_types:clientid(),
    server_desc := binary(),
    server_meta => #{}
    opts => opts(),
    sessions => sessions()
}.

-define(CLIENT_INFO, #{
    <<"name">> => <<"emqx-mcp-gateway">>,
    <<"version">> => <<"0.1.0">>
}).

-define(handle_common, ?FUNCTION_NAME(T, C, D) -> handle_common(?FUNCTION_NAME, T, C, D)).
-define(log_enter_state(OldState),
    ?SLOG(debug, #{msg => enter_state, state => ?FUNCTION_NAME, previous => OldState})
).
-define(SERVER_CAPABILITIES, #{
    <<"logging">> => #{},
    <<"prompts">> => #{<<"listChanged">> => true},
    <<"resources">> => #{<<"subscribe">> => true, <<"listChanged">> => true},
    <<"tools">> => #{<<"listChanged">> => true}
}).

%%==============================================================================
%% API
%%==============================================================================
-spec start_supervised(config()) -> supervisor:startchild_ret().
start_supervised(Conf) ->
    mcp_mqtt_erl_server_sup:start_child(Conf).

stop_supervised_all() ->
    %% Stop all MCP servers
    StartedServers = supervisor:which_children(mcp_mqtt_erl_server_sup),
    lists:foreach(
        fun({_Name, Pid, _, _}) ->
            supervisor:terminate_child(mcp_mqtt_erl_server_sup, Pid)
        end,
        StartedServers
    ).

-spec start_link(config()) -> gen_statem:start_ret().
start_link(Conf) ->
    gen_statem:start_link(?MODULE, Conf, []).

stop(Pid) ->
    gen_statem:cast(Pid, stop).

%% gen_statem callbacks
-spec init(config()) ->
    gen_statem:init_result(state_name(), loop_data()).
init(#{callback_mod := Mod, server_name := ServerName, server_version := ServerVsn} = Conf) ->
    process_flag(trap_exit, true),
    LoopData = #{
        callback_mod => Mod,
        server_name => ServerName,
        server_desc => maps:get(server_desc, Conf, <<"">>),
        server_version => ServerVsn,
        server_id => mcp_mqtt_erl_msg:gen_mqtt_client_id(),
        opts => maps:get(opts, Conf, #{}),
        sessions => #{}
    },
    {ok, idle, LoopData, [{next_event, internal, connect_broker}]}.

callback_mode() ->
    [state_functions, state_enter].

-spec idle(enter | gen_statem:event_type(), state_name(), loop_data()) ->
    gen_statem:state_enter_result(state_name(), loop_data())
    | gen_statem:event_handler_result(state_name(), loop_data()).
idle(enter, _OldState, _LoopData) ->
    {keep_state_and_data, []};
idle(internal, connect_broker, LoopData) ->
    MqttOpts = maps:get(mqtt_options, LoopData, #{}),
    case emqtt:start_link(MqttOpts) of
        {ok, MqttClient} ->
            case emqtt:connect(C) of
                {ok, _} ->
                    ServerOnlineMsg = mcp_mqtt_erl_msg:json_rpc_notification(
                        <<"notifications/server/online">>,
                        #{
                            <<"server_name">> => maps:get(server_name, LoopData),
                            <<"description">> => maps:get(server_desc, LoopData),
                            <<"meta">> => maps:get(server_meta, LoopData)
                        }
                    ),
                    emqx_mcp_message:publish_mcp_server_message(
                        maps:get(server_id, LoopData),
                        maps:get(server_name, LoopData),
                        undefined,
                        server_presence,
                        #{retain => true},
                        ServerOnlineMsg
                    ),
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
connected(enter, OldState, _LoopData) ->
    ?log_enter_state(OldState),
    {keep_state_and_data, []};
connected(info, {publish, #{topic := <<"$mcp-server/", _/binary>>, payload := Payload, properties := Props} = Msg}, #{mod := Mod} = LoopData) ->
    maybe
        Sessions = maps:get(sessions, LoopData),
        ServerId = maps:get(server_id, LoopData),
        ServerName = maps:get(server_name, LoopData),
        {ok, McpClientId} ?= mcp_mqtt_erl_msg:get_mcp_client_id_from_mqtt_props(Props),
        {ok, mcp_client} ?= mcp_mqtt_erl_msg:get_mcp_component_type_from_mqtt_props(Props),
        {ok, #{method := <<"initialize">>, id := Id, params := Params}} ?= mcp_mqtt_erl_msg:decode_rpc_msg(Payload),
        {ok, NewSession} = mcp_mqtt_erl_server_session:new(Mod, ServerId, ServerName, McpClientId, Params)
        %% send initialize response to client
        ServerInfo = #{<<"name">> => ServerName, version => maps:get(server_version, LoopData)},
        InitializeResp = mcp_mqtt_erl_msg:initialize_response(
            Id, ServerInfo, ?SERVER_CAPABILITIES
        ),
        mcp_mqtt_erl_msg:publish_mcp_server_message(
            ServerId, ServerName, McpClientId, rpc, #{}, InitializeResp
        ),
        {next_state, server_initialized, LoopData#{sessions => Sessions#{McpClientId => NewSession}}, []}
    else
        {ok, RpcMsg} ->
            ?SLOG(debug, #{msg => unexpected_rpc_msg, details => RpcMsg}),
            {keep_state, LoopData};
        {error, #{reason := ?ERR_INVALID_JSON}} ->
            ?SLOG(error, #{msg => non_json_msg, details => Msg}),
            {keep_state, LoopData};
        {error, #{reason := Reason}} when
                Reason == missing_capabilities;
                Reason == missing_client_info;
                Reason == missing_protocol_version ->
            ErrMsg = mcp_mqtt_erl_msg:json_rpc_error(Id, ?ERR_C_REQUIRED_FILED_MISSING, Reason, #{}),
            mcp_mqtt_erl_msg:publish_mcp_server_message(
                ServerId, ServerName, McpClientId, rpc, #{}, ErrMsg
            ),
        {error, #{reason := ?ERR_UNSUPPORTED_PROTOCOL_VERSION, vsn := Vsn}} ->
            ErrMsg = mcp_mqtt_erl_msg:json_rpc_error(Id, ?ERR_C_UNSUPPORTED_PROTOCOL_VERSION, Reason, #{}),
            mcp_mqtt_erl_msg:publish_mcp_server_message(
                ServerId, ServerName, McpClientId, rpc, #{}, ErrMsg
            ),
        {error, Reason} ->
            ?SLOG(error, #{msg => invalid_initialize_msg, details => Msg, reason => Reason}),
            {keep_state, LoopData}
    end;
connected(info, {publish, #{topic := <<"$mcp-client/presence/", McpClientId/binary>>}}, #{sessions := Sessions} = LoopData) ->
    case emqx_mcp_message:decode_rpc_msg(PresenceMsg) of
        {ok, #{method := <<"notifications/disconnected">>}} ->
            ?SLOG(debug, #{msg => client_disconnected}),
            {keep_state, LoopData#{sessions => maps:remove(McpClientId, Sessions)}}
        {ok, Msg} ->
            ?SLOG(error, #{msg => unsupported_client_presence_msg, rpc_msg => Msg}),
            {keep_state, LoopData};
        {error, Reason} ->
            ?SLOG(error, #{msg => decode_rpc_msg_failed, reason => Reason}),
            {keep_state, LoopData}
    end;
connected(info, {publish, #{topic := <<"$mcp-client/capability/list-changed/", _/binary>>, payload := Payload}}, LoopData) ->
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
                            ?SLOG(error, #{msg => session_terminated_on_rpc_msg, reason => Reason}),
                            {keep_state, LoopData#{sessions => maps:remove(McpClientId, Sessions)}}
                    end;
                {error, Reason} ->
                    ?SLOG(error, #{msg => decode_rpc_msg_failed, reason => Reason}),
                    {keep_state, LoopData}
            end;
        error ->
            ?SLOG(error, #{msg => session_not_found}),
            {keep_state, LoopData}
    end;
connected(info, {publish, #{topic := Topic}}, _LoopData) ->
    ?SLOG(error, #{msg => unsupported_topic, topic => Topic}),
    keep_state_and_data;
?handle_common.

terminate(_Reason, State, LoopData) ->
    case State of
        server_initialized ->
            %% Notify the client that the server has disconnected
            ServerName = maps:get(server_name, LoopData),
            mcp_mqtt_erl_msg:send_server_offline_message(ServerName);
        _ ->
            ok
    end;
terminate(_Reason, _State, _LoopData) ->
    ok.

code_change(_OldVsn, State, LoopData, _Extra) ->
    {ok, State, LoopData}.

handle_common(_State, state_timeout, TimeoutReason, _LoopData) ->
    shutdown(#{error => TimeoutReason});
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
split_id_and_server_name(Str) ->
    %% Split the server ID and name from the topic
    case string:split(Str, <<"/">>) of
        [Id, ServerName] -> {Id, ServerName};
        _ -> throw({error, {invalid_id_and_server_name, Str}})
    end.
