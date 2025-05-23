-type client_params() :: #{
    client_info := map(),
    client_capabilities := map(),
    mcp_client_id := binary()
}.

-type mcp_msg_type() :: mcp_server_sent_msg_type() | mcp_client_sent_msg_type() | mcp_common_msg_type().

-type mcp_common_msg_type() ::
    ping
    | progress_notification.

-type mcp_server_sent_msg_type() ::
    list_roots
    | log
    | sampling_create
    | prompt_list_changed
    | resource_updated
    | resource_list_changed
    | tool_list_changed.

-type mcp_client_sent_msg_type() ::
    initialize
    | initialized
    | set_logging_level
    | list_resources
    | list_resource_templates
    | read_resource
    | subscribe_resource
    | unsubscribe_resource
    | list_tools
    | call_tool
    | list_prompts
    | get_prompt
    | complete
    | roots_list_changed.

-type resource_def() :: #{
    uri := binary(),
    name := binary(),
    description => binary(),
    mimeType => binary(),
    size => integer(),
    annotations => annotations()
}.

-type resource() :: #{
    uri := binary(),
    mimeType := binary(),
    text | blob => binary()
}.

-type resource_tmpl() :: #{
    uriTemplate := binary(),
    name := binary(),
    description => binary(),
    mimeType => binary(),
    annotations => annotations()
}.

-type user_defined_error_code() :: 10000..20000.

-type error_response() :: #{
    code => user_defined_error_code(),
    message => binary(),
    data => map()
}.

-type annotations() :: #{
    audience => [any()] | [],
    priority => [number()] | []
}.

-type text_content() :: #{
    type := text,
    text => binary(),
    annotations => annotations()
}.

-type image_content() :: #{
    type := image,
    data := binary(), %% base64-encoded-data
    mimeType := binary(),
    annotations => annotations()
}.

-type audio_content() :: #{
    type := audio,
    data := binary(), %% base64-encoded-data
    mimeType := binary(),
    annotations => annotations()
}.

-type embedded_resource() :: #{
    type := resource,
    resource := resource(),
    annotations => annotations()
}.

-type call_tool_result() :: text_content() | image_content() | audio_content() | embedded_resource().

-type input_schema() :: #{
    type := object,
    properties => #{
        atom() => map()
    },
    required => [atom()] | []
}.

-type tool_annotations() :: #{
    title => binary(),
    readOnlyHint => boolean(),
    destructiveHint => boolean(),
    idempotentHint => boolean(),
    openWorldHint => boolean()
}.

-type tool_def() :: #{
    name := binary(),
    description => binary(),
    inputSchema := input_schema(),
    annotations => tool_annotations()
}.

-type prompt_arguments() :: #{
    name := binary(),
    description => binary(),
    required => boolean()
}.

-type prompt_def() :: #{
    name := binary(),
    description => binary(),
    arguments => prompt_arguments()
}.

-type prompt_message() :: #{
    role := binary(),
    content := text_content() | image_content() | audio_content() | embedded_resource()
}.

-type get_prompt_result() :: #{
    description => binary(),
    messages := [prompt_message()] | []
}.

-type complete_result() :: #{
    values := [string()] | [],
    total => number(),
    hasMore => boolean()
}.
