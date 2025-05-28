# emqx_mcp_tools

An EMQX plugin that provide some MCP tools/resources for health checking and problem analysis.

## Features

- **MCP Wrappers for some EMQX APIs**: Provides a set of MCP wrappers for EMQX APIs to facilitate health checking and problem analysis, such as get the cluster status, get information about the connectors, authenticators and authorization sources.

- **Network Tools**: Provides some network tools to help you check the network status, such as checking the connectivity to a host from the EMQX nodes.

## Installation

1. Download the plugin from the [releases page](https://github.com/emqx/emqx_mcp_tools/releases).

2. Copy the plugin to the EMQX plugins directory, usually located at `/var/lib/emqx/plugins/` if you installed EMQX using the binary package, or `<PATH>/<TO>/<EMQX DIR>/plugins/` directory if you installed EMQX using zip package.

3. Install and start the plugin by running the following command:

   ```bash
   ./bin/emqx ctl plugins install emqx_mcp_tools-<VSN>
   ./bin/emqx ctl plugins start emqx_mcp_tools-<VSN>
   ```

   Where `<VSN>` is the version of the plugin you downloaded.

## Configuration

You could change the plugin configuration from the EMQX dashboard.
