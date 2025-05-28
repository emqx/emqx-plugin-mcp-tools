-module(emqx_mcp_tools_network).

-export([
    check_tcp_connectivity/3
]).

check_tcp_connectivity(Host, Port, TimeoutMs) ->
    T1 = erlang:monotonic_time(),
    Ret = gen_tcp:connect(maybe_str_host(Host), Port, [], TimeoutMs),
    T2 = erlang:monotonic_time(),
    TimeTaken = erlang:convert_time_unit(T2 - T1, native, millisecond),
    Result = case Ret of
        {ok, Socket} ->
            ok = gen_tcp:close(Socket),
            success;
        {error, Reason} ->
            Reason
    end,
    #{node_name => node(), check_result => Result, time_taken => TimeTaken}.

maybe_str_host(Host) when is_binary(Host) ->
    binary_to_list(Host);
maybe_str_host(Host) ->
    Host.
