-define(PLUGIN_NAME, "emqx_mcp_tools").
-define(PLUGIN_VSN, ?plugin_rel_vsn).
-define(PLUGIN_NAME_VSN, <<?PLUGIN_NAME, "-", ?PLUGIN_VSN>>).
-define(TAG, "MCP_TOOLS").

-define(MCP_SERVER_ID(NAME),
    fun(N) ->
        HEX = binary:encode_hex(N),
        <<"$mcp-gateway:", HEX/binary>>
    end(
        NAME
    )
).
