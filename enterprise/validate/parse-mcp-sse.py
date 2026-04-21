#!/usr/bin/env python3
"""
Parse an MCP Server-Sent Events (SSE) tools/list response from stdin.

MCP responses use the SSE wire format:

    data: {"jsonrpc":"2.0","id":2,"result":{"tools":[
      {"name":"deepwiki_read_wiki_structure","description":"Get a list of ...\n\nArgs:\n ..."},
      ...
    ]}}

The JSON payload starts on the `data: ` line and may continue on subsequent
lines (tool descriptions often contain embedded newlines).  Standard jq/grep
approaches that only strip the first `data: ` line therefore produce broken
JSON.  This script reassembles the full payload before parsing.

Usage:
    curl ... | python3 parse-mcp-sse.py           # prints one tool name per line
    curl ... | python3 parse-mcp-sse.py --count   # prints just the integer count
    curl ... | python3 parse-mcp-sse.py --json    # prints compact JSON list of names
"""
import sys
import json


def parse_sse(content: str) -> str:
    """
    Collect all SSE event lines into a single JSON string.

    SSE format rules we care about:
      - Lines starting with 'data: ' begin (or continue) an event.
      - The actual prefix appears only on the first line of the event value;
        subsequent continuation lines have no prefix.
      - Lines starting with ':' are comments — skip them.
      - A blank line terminates the event (we stop at the first blank line
        after data has started, since we only expect one event here).
    """
    lines: list[str] = []
    collecting = False

    for line in content.splitlines():
        if line.startswith("data: "):
            lines.append(line[6:])  # strip the 'data: ' prefix
            collecting = True
        elif line.startswith(":"):
            continue  # SSE comment
        elif line == "":
            if collecting:
                break  # end of this SSE event
        elif collecting:
            lines.append(line)  # continuation of the JSON payload

    return "\n".join(lines)


def main() -> None:
    args = set(sys.argv[1:])
    count_only = "--count" in args
    json_out   = "--json"  in args

    content = sys.stdin.read()
    json_str = parse_sse(content)

    if not json_str.strip():
        # Nothing to parse — print 0 and exit cleanly so callers don't break
        if count_only:
            print(0)
        elif json_out:
            print("[]")
        sys.exit(0)

    try:
        data = json.loads(json_str)
    except json.JSONDecodeError as exc:
        print(0 if count_only else "[]" if json_out else "", file=sys.stdout)
        print(f"parse-mcp-sse: JSON decode error: {exc}", file=sys.stderr)
        print(f"Raw (first 300 chars): {json_str[:300]}", file=sys.stderr)
        sys.exit(1)

    tools: list[dict] = data.get("result", {}).get("tools", [])
    names = [t["name"] for t in tools]

    if count_only:
        print(len(names))
    elif json_out:
        print(json.dumps(names))
    else:
        for name in names:
            print(name)


if __name__ == "__main__":
    main()
