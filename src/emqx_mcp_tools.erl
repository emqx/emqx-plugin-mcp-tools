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

-module(emqx_mcp_tools).
-behaviour(gen_server).

%% for #message{} record
-include_lib("emqx_plugin_helper/include/emqx.hrl").
%% for hook priority constants
-include_lib("emqx_plugin_helper/include/emqx_hooks.hrl").
%% for logging
-include_lib("emqx_plugin_helper/include/logger.hrl").
-include("emqx_mcp_tools.hrl").
-include_lib("mcp_mqtt_erl/include/mcp_mqtt_erl_errors.hrl").

-export([
    get_config/0,
    start_mcp_tool_servers/0,
    start_mcp_tool_servers/2,
    stop_mcp_tool_servers/0,
    on_config_changed/2,
    on_health_check/1
]).

-export([
    start_link/0,
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-define(CB_MOD, emqx_mcp_tools_server).
-define(LOG_T(LEVEL, REPORT), ?SLOG(LEVEL, maps:put(tag, "EMQX_MCP_TOOLS", REPORT))).

%%==============================================================================
%% Config update
%%==============================================================================
get_config() ->
    emqx_plugin_helper:get_config(?PLUGIN_NAME_VSN).

-spec start_mcp_tool_servers() -> ok.
start_mcp_tool_servers() ->
    start_mcp_tool_servers(?CB_MOD, get_config()).

start_mcp_tool_servers(Mod, Config) ->
    ?LOG_T(info, #{msg => start_mcp_tool_servers, mod => Mod,
        config => Config, pid => self(), group_leader => group_leader()}),
    MqttBroker = maps:get(<<"mqtt_broker">>, Config, <<"local">>),
    NumServerIds = maps:get(<<"num_server_ids">>, Config, 1),
    MqttOptions = maps:get(<<"mqtt_options">>, Config, #{}),
    Conf = #{
        broker_address => get_broker_address(MqttBroker),
        callback_mod => Mod,
        mqtt_options => MqttOptions
    },
    lists:foreach(
        fun(Idx) ->
            {ok, _} = emqx_mcp_tools_sup:start_server(Idx, Conf)
        end,
        lists:seq(0, NumServerIds - 1)
    ).

stop_mcp_tool_servers() ->
    emqx_mcp_tools_sup:stop_all_servers().

on_config_changed(OldConfig, NewConfig) ->
    ok = gen_server:cast(?MODULE, {on_changed, OldConfig, NewConfig}).

on_health_check(_Options) ->
    case whereis(?MODULE) of
        undefined ->
            {error, <<"emqx_mcp_tools is not running">>};
        _ ->
            ok
    end.

%%==============================================================================
%% gen_server callbacks
%%==============================================================================
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    erlang:process_flag(trap_exit, true),
    ?LOG_T(debug, #{msg => "emqx_mcp_tools_started"}),
    {ok, #{}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({on_changed, _OldConfig, NewConfig}, State) ->
    ?LOG_T(info, #{msg => emqx_mcp_tools_config_changed,
                  old_config => _OldConfig,
                  new_config => NewConfig}),
    ok = stop_mcp_tool_servers(),
    ok = start_mcp_tool_servers(?CB_MOD, NewConfig),
    {noreply, State};
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Request, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%==============================================================================
%% Internal functions
%%==============================================================================
get_broker_address(<<"local">>) -> local;
get_broker_address(MqttBroker) when is_binary(MqttBroker) ->
    case string:split(MqttBroker, ":") of
        [Host, Port] -> {Host, binary_to_integer(Port)};
        Host -> {Host, 1883}
    end.
