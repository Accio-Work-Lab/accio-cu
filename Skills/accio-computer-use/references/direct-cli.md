# Direct CLI reference

Use this diagnostic surface for one isolated observation or action. Pipe Python
into `accio-computer-use` for normal multi-step work.

```bash
accio-computer-use call <tool_name> '<JSON>'
```

Useful flags:

| Flag | Purpose |
|---|---|
| `--filter "text"` | Return matching AX elements and ancestors |
| `--image-out <path>` | Save the screenshot as PNG |
| `--inline-image` | Include base64 image data |
| `--raw` | Print the complete MCP result |
| `--compact` | Print raw multiline AX text followed by a small JSON metadata block |

Examples:

```bash
accio-computer-use call get_app_state '{"app":"Safari"}' --filter Downloads
accio-computer-use call click '{"app":"TextEdit","element_text":"Save"}'
accio-computer-use call get_screen_state '{}'
```

Do not build a workflow from repeated direct calls when one Python block can
retain state, branch, wait, and recover locally.
