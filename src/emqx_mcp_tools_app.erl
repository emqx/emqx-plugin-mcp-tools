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
-module(emqx_mcp_tools_app).

-behaviour(application).

-emqx_plugin(?MODULE).

-export([
    start/2,
    stop/1
]).

-export([
    on_config_changed/2,
    on_health_check/1
]).

%% NOTE
%% Functions from EMQX are unavailable at compile time.
-dialyzer({no_unknown, [start/2, stop/1]}).

start(_StartType, _StartArgs) ->
    {ok, Sup} = emqx_mcp_tools_sup:start_link(),
    emqx_mcp_tools:start_mcp_tool_servers(),
    emqx_ctl:register_command(emqx_mcp_tools, {emqx_mcp_tools_cli, cmd}),
    {ok, Sup}.

stop(_State) ->
    emqx_ctl:unregister_command(emqx_mcp_tools).

on_config_changed(OldConfig, NewConfig) ->
    emqx_mcp_tools:on_config_changed(OldConfig, NewConfig).

on_health_check(Options) ->
    emqx_mcp_tools:on_health_check(Options).
