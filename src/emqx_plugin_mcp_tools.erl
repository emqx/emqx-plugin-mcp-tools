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

-module(emqx_plugin_mcp_tools).
-behaviour(gen_server).

%% for #message{} record
-include_lib("emqx_plugin_helper/include/emqx.hrl").
%% for hook priority constants
-include_lib("emqx_plugin_helper/include/emqx_hooks.hrl").
%% for logging
-include_lib("emqx_plugin_helper/include/logger.hrl").
-include("emqx_plugin_mcp_tools.hrl").
-include("emqx_mcp_errors.hrl").

-export([
    get_config/0,
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

%%==============================================================================
%% Config update
%%==============================================================================
get_config() ->
    emqx_plugin_helper:get_config(?PLUGIN_NAME_VSN).

on_config_changed(OldConfig, NewConfig) ->
    ok = gen_server:cast(?MODULE, {on_changed, OldConfig, NewConfig}).

on_health_check(_Options) ->
    case whereis(?MODULE) of
        undefined ->
            {error, <<"emqx_plugin_mcp_tools is not running">>};
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
    ?SLOG(debug, #{msg => "emqx_mcp_gateway_started"}),
    {ok, #{}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({on_changed, _OldConfig, _NewConfig}, State) ->
    ?SLOG(info, #{msg => "emqx_mcp_gateway_config_changed", 
                  old_config => _OldConfig,
                  new_config => _NewConfig}),
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
