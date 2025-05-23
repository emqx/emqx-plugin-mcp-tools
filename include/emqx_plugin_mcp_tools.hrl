
-define(PLUGIN_NAME, "emqx_plugin_mcp_tools").
-define(PLUGIN_VSN, "0.0.1").
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
