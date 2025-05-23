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
-module(emqx_mcp_tools_sup).

-behaviour(supervisor).

-export([start_link/0, start_server/2, stop_all_servers/0]).

-export([init/1]).

-define(SERVER_ID(MOD, INDEX), {server, MOD, INDEX}).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_server(integer(), mcp_mqtt_erl_server:config()) -> supervisor:startchild_ret().
start_server(Idx, #{callback_mod := Mod} = Conf) ->
    supervisor:start_child(?MODULE, server_spec(Mod, Idx, Conf)).

stop_all_servers() ->
    %% Stop all MCP servers
    lists:foreach(
        fun
            ({?SERVER_ID(_, _) = Id, _Pid, _, _}) ->
                _ = supervisor:terminate_child(?MODULE, Id),
                _ = supervisor:delete_child(?MODULE, Id);
            ({_, _Pid, _, _}) ->
                ok
        end,
        supervisor:which_children(?MODULE)
    ).

init([]) ->
    ConfigChildSpec = #{
        id => emqx_mcp_tools,
        start => {emqx_mcp_tools, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [emqx_mcp_tools]
    },
    SupFlags = #{
        strategy => one_for_all,
        intensity => 100,
        period => 10
    },
    {ok, {SupFlags, [ConfigChildSpec]}}.

server_spec(Mod, Idx, Conf) ->
    #{
        id => ?SERVER_ID(Mod, Idx),
        start => {Mod, start_link, [Idx, Conf]},
        restart => permanent,
        shutdown => 3_000,
        modules => [Mod],
        type => worker
    }.
