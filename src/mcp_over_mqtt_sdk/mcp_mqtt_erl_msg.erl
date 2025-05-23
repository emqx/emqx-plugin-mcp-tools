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

-module(mcp_mqtt_erl_msg).
-include("mcp_mqtt_erl_errors.hrl").
-include("mcp_mqtt_erl.hrl").

-export([
    json_rpc_request/3,
    json_rpc_response/2,
    json_rpc_error/4,
    json_rpc_notification/1,
    json_rpc_notification/2
]).

-export([
    initialize_request/2,
    initialize_request/3,
    initialize_response/4,
    initialized_notification/0
]).

-export([decode_rpc_msg/1, topic_type_of_rpc_msg/1, get_topic/2]).

-export([
    send_server_online_message/5,
    send_server_offline_message/3,
    publish_mcp_server_message/7
]).

-export([get_mcp_component_type_from_mqtt_props/1,
         get_mcp_client_id_from_mqtt_props/1]).

-type topic_type() :: server_control
                     | server_capability_list_changed
                     | server_resources_updated
                     | server_presence
                     | client_presence
                     | client_capability_list_changed
                     | rpc.
-type flags() :: #{retain => boolean(), qos => 0..2}.

%%==============================================================================
%% MCP Requests/Responses/Notifications
%%==============================================================================
initialize_request(ClientInfo, Capabilities) ->
    initialize_request(1, ClientInfo, Capabilities).

initialize_request(Id, ClientInfo, Capabilities) ->
    json_rpc_request(
        Id,
        <<"initialize">>,
        #{
            <<"protocolVersion">> => <<?MCP_VERSION>>,
            <<"clientInfo">> => ClientInfo,
            <<"capabilities">> => Capabilities
        }
    ).

initialize_response(Id, ServerInfo, Capabilities, Instructions) ->
    json_rpc_response(
        Id,
        #{
            <<"protocolVersion">> => <<?MCP_VERSION>>,
            <<"serverInfo">> => ServerInfo,
            <<"capabilities">> => Capabilities,
            <<"instructions">> => Instructions
        }
    ).

initialized_notification() ->
    json_rpc_notification(<<"notifications/initialized">>).

%%==============================================================================
%% JSON RPC Messages
%%==============================================================================
json_rpc_request(Id, Method, Params) ->
    json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"method">> => Method,
        <<"params">> => Params,
        <<"id">> => Id
    }).

json_rpc_response(Id, Result) ->
    json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"result">> => Result,
        <<"id">> => Id
    }).

json_rpc_notification(Method) ->
    json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"method">> => Method
    }).

json_rpc_notification(Method, Params) ->
    json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"method">> => Method,
        <<"params">> => Params
    }).

json_rpc_error(Id, Code, Message, Data) ->
    json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"error">> => #{
            <<"code">> => Code,
            <<"message">> => Message,
            <<"data">> => Data
        },
        <<"id">> => Id
    }).

decode_rpc_msg(Msg) ->
    try json:decode(Msg) of
        #{<<"jsonrpc">> := <<"2.0">>, <<"method">> := Method, <<"id">> := Id} = Msg1 ->
            Params = maps:get(<<"params">>, Msg1, #{}),
            {ok, #{type => json_rpc_request, method => Method, id => Id, params => Params}};
        #{<<"jsonrpc">> := <<"2.0">>, <<"result">> := Result, <<"id">> := Id} ->
            {ok, #{type => json_rpc_response, id => Id, result => Result}};
        #{<<"jsonrpc">> := <<"2.0">>, <<"error">> := Error, <<"id">> := Id} ->
            {ok, #{type => json_rpc_error, id => Id, error => Error}};
        #{<<"jsonrpc">> := <<"2.0">>, <<"method">> := Method} = Msg1 ->
            Params = maps:get(<<"params">>, Msg1, #{}),
            {ok, #{type => json_rpc_notification, method => Method, params => Params}};
        Msg1 ->
            {error, #{reason => ?ERR_MALFORMED_JSON_RPC, msg => Msg1}}
    catch
        error:Reason ->
            {error, #{reason => ?ERR_INVALID_JSON, msg => Msg, details => Reason}}
    end.

topic_type_of_rpc_msg(Msg) when is_binary(Msg) ->
    case decode_rpc_msg(Msg) of
        {ok, RpcMsg} ->
            topic_type_of_rpc_msg(RpcMsg);
        {error, _} = Err ->
            Err
    end;
topic_type_of_rpc_msg(#{method := <<"initialize">>}) ->
    server_control;
topic_type_of_rpc_msg(#{method := <<"notifications/resources/updated">>}) ->
    server_resources_updated;
topic_type_of_rpc_msg(#{method := <<"notifications/server/online">>}) ->
    server_presence;
topic_type_of_rpc_msg(#{method := <<"notifications/disconnected">>}) ->
    client_presence;
topic_type_of_rpc_msg(#{method := <<"notifications/roots/list_changed">>}) ->
    client_capability_list_changed;
topic_type_of_rpc_msg(#{type := json_rpc_notification, method := Method}) ->
    case string:find(Method, <<"/list_changed">>) of
        <<"/list_changed">> -> server_capability_list_changed;
        _ -> rpc
    end;
topic_type_of_rpc_msg(_) ->
    rpc.

get_topic(server_control, #{server_id := ServerId, server_name := ServerName}) ->
    <<"$mcp-server/", ServerId/binary, "/", ServerName/binary>>;
get_topic(server_capability_list_changed, #{server_id := ServerId, server_name := ServerName}) ->
    <<"$mcp-server/capability/list-changed/", ServerId/binary, "/", ServerName/binary>>;
get_topic(server_resources_updated, #{server_id := ServerId, server_name := ServerName}) ->
    <<"$mcp-server/capability/resource-updated/", ServerId/binary, "/", ServerName/binary>>;
get_topic(server_presence, #{server_id := ServerId, server_name := ServerName}) ->
    <<"$mcp-server/presence/", ServerId/binary, "/", ServerName/binary>>;
get_topic(client_presence, #{mcp_client_id := McpClientId}) ->
    <<"$mcp-client/presence/", McpClientId/binary>>;
get_topic(client_capability_list_changed, #{mcp_client_id := McpClientId}) ->
    <<"$mcp-client/capability/list-changed/", McpClientId/binary>>;
get_topic(rpc, #{mcp_client_id := McpClientId, server_id := ServerId, server_name := ServerName}) ->
    <<"$mcp-rpc-endpoint/", McpClientId/binary, "/", ServerId/binary, "/", ServerName/binary>>.

send_server_online_message(MqttClient, ServerId, ServerName, ServerDesc, ServerMeta) ->
    Payload = json_rpc_notification(<<"notifications/server/online">>, #{
        <<"server_name">> => ServerName,
        <<"description">> => ServerDesc,
        <<"meta">> => ServerMeta
    }),
    publish_mcp_server_message(MqttClient, ServerId, ServerName, undefined, server_presence,
        #{retain => true}, Payload).

send_server_offline_message(MqttClient, ServerId, ServerName) ->
    %% Empty payload for offline message
    publish_mcp_server_message(MqttClient, ServerId, ServerName, undefined, server_presence,
        #{retain => true}, <<>>).

-spec publish_mcp_server_message(MqttClient :: pid() | local, ServerId :: binary(), ServerName :: binary(), McpClientId :: binary() | undefined, topic_type(), flags(), Payload :: binary()) ->
    ok | {error, #{reason := term(), _ => _}}.
publish_mcp_server_message(MqttClient, ServerId, ServerName, McpClientId, TopicType, Flags, Payload) ->
    Topic = get_topic(TopicType, #{
        server_id => ServerId,
        server_name => ServerName,
        mcp_client_id => McpClientId
    }),
    do_publish_mcp_server_message(MqttClient, Topic, ServerId, Payload, Flags).

do_publish_mcp_server_message(local, Topic, ServerId, Payload, Flags) ->
    UserProps = [
        {<<"MCP-COMPONENT-TYPE">>, <<"mcp-server">>},
        {<<"MCP-MQTT-CLIENT-ID">>, ServerId}
    ],
    Headers = #{
        properties => #{
            'User-Property' => UserProps
        }
    },
    QoS = 1,
    MqttMsg = emqx_message:make(ServerId, QoS, Topic, Payload, Flags, Headers),
    _ = emqx:publish(MqttMsg),
    ok;
do_publish_mcp_server_message(MqttClient, Topic, ServerId, Payload, Flags) ->
    PubProps = #{
        'User-Property' => [
            {<<"MCP-COMPONENT-TYPE">>, <<"mcp-server">>},
            {<<"MCP-MQTT-CLIENT-ID">>, ServerId}
        ]
    },
    QoS = 1,
    Result = emqtt:publish(MqttClient, Topic, PubProps, Payload, maps:to_list(Flags#{qos => QoS})),
    handle_pub_result(Result).

get_mcp_component_type_from_mqtt_props(#{'User-Property' := UserProps}) ->
    case lists:keyfind(<<"MCP-COMPONENT-TYPE">>, 1, UserProps) of
        {_, <<"mcp-server">>} -> {ok, mcp_server};
        {_, <<"mcp-client">>} -> {ok, mcp_client};
        {_, Type} -> {error, {invalid_mcp_component_type, Type}};
        _ -> {error, mcp_component_type_not_found}
    end;
get_mcp_component_type_from_mqtt_props(_Props) ->
    {error, user_props_not_found}.

get_mcp_client_id_from_mqtt_props(#{'User-Property' := UserProps}) ->
    case lists:keyfind(<<"MCP-MQTT-CLIENT-ID">>, 1, UserProps) of
        {_, McpClientId} -> {ok, McpClientId};
        _ -> {error, mcp_client_id_not_found}
    end;
get_mcp_client_id_from_mqtt_props(_Props) ->
    {error, user_props_not_found}.

handle_pub_result(ok) ->
    ok;
handle_pub_result({ok, #{reason_code := 0}}) ->
    ok;
handle_pub_result({ok, #{reason_code := 16#10}}) ->
    {error, #{reason => no_matching_subscribers}};
handle_pub_result({ok, Reply}) ->
    {error, classify_reply(Reply)};
handle_pub_result({error, Reason}) ->
    {error, classify_error(Reason)}.

classify_reply(Reply = #{reason_code := _}) ->
    Reply#{reason => puback_error_code}.

classify_error(disconnected) ->
    #{reason => disconnected};
classify_error(ecpool_empty) ->
    #{reason => disconnected};
classify_error({disconnected, RC, _}) ->
    #{reason => disconnected, reason_code => RC};
classify_error({shutdown, Details}) ->
    #{reason => disconnected, details => Details};
classify_error(shutdown) ->
    #{reason => disconnected};
classify_error(Reason) ->
    #{reason => Reason}.
