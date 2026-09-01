"""Drive host/mcp_server.py over stdio exactly as an MCP client would.

    python tools/test_mcp.py
Exits non-zero if any check fails.
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "..", "host", "mcp_server.py")

failures = []


def check(label, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + label + (("  -- " + detail) if detail else ""))
    if not cond:
        failures.append(label)


def main():
    p = subprocess.Popen([sys.executable, SERVER],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, text=True, bufsize=1)

    def rpc(method, params=None, msg_id=None):
        msg = {"jsonrpc": "2.0", "method": method}
        if msg_id is not None:
            msg["id"] = msg_id
        if params is not None:
            msg["params"] = params
        p.stdin.write(json.dumps(msg) + "\n")
        p.stdin.flush()
        if msg_id is None:
            return None
        line = p.stdout.readline()
        if not line:
            raise SystemExit("server produced no reply to %s" % method)
        return json.loads(line)

    print("initialize")
    r = rpc("initialize", {"protocolVersion": "2025-06-18",
                           "capabilities": {},
                           "clientInfo": {"name": "test", "version": "0"}}, 1)
    check("responds to initialize", "result" in r, json.dumps(r)[:120])
    check("echoes the requested protocol version",
          r.get("result", {}).get("protocolVersion") == "2025-06-18")
    check("names itself", r.get("result", {}).get("serverInfo", {}).get("name") == "g3bridge")
    check("declares the tools capability", "tools" in r.get("result", {}).get("capabilities", {}))

    rpc("notifications/initialized")

    print("tools/list")
    r = rpc("tools/list", {}, 2)
    tools = r.get("result", {}).get("tools", [])
    names = sorted(t["name"] for t in tools)
    check("lists the 8 tools", len(tools) == 8, str(names))
    check("every tool has a schema", all("inputSchema" in t for t in tools))
    check("g3_draw documents the grammar",
          any("PENSIZE" in t["description"] for t in tools if t["name"] == "g3_draw"))

    print("ping")
    r = rpc("ping", {}, 3)
    check("answers ping", "result" in r)

    print("tools/call g3_status")
    r = rpc("tools/call", {"name": "g3_status", "arguments": {}}, 4)
    text = r.get("result", {}).get("content", [{}])[0].get("text", "")
    print("      -> " + text.replace("\n", "\n         "))
    check("g3_status returns text", bool(text))

    print("tools/call g3_draw")
    r = rpc("tools/call", {"name": "g3_draw", "arguments": {
        "clear_first": True,
        "commands": ["PEN 0 255 128",
                     "RECT 40 40 600 440",
                     "PEN 255 255 0",
                     "TEXT 80 240 \"MCP -> G3\" 36"]}}, 5)
    res = r.get("result", {})
    text = res.get("content", [{}])[0].get("text", "")
    print("      -> " + text.replace("\n", "\n         "))
    check("g3_draw reports success", res.get("isError") is False, "isError=%s" % res.get("isError"))
    check("g3_draw auto-appended FLUSH", "FLUSH" in text)

    print("tools/call g3_transfers")
    r = rpc("tools/call", {"name": "g3_transfers", "arguments": {}}, 50)
    text = r.get("result", {}).get("content", [{}])[0].get("text", "")
    print("      -> " + text.replace("\n", "\n         "))
    check("g3_transfers lists both directions",
          "Waiting for the Mac" in text and "Sent up by the Mac" in text)

    print("tools/call g3_send_file")
    r = rpc("tools/call", {"name": "g3_send_file",
                           "arguments": {"path": SERVER, "rename": "staged_test.txt"}}, 51)
    res = r.get("result", {})
    print("      -> " + res.get("content", [{}])[0].get("text", "").replace("\n", "\n         "))
    check("g3_send_file stages a file", res.get("isError") is False)

    print("tools/call g3_send_file with a bad path")
    r = rpc("tools/call", {"name": "g3_send_file", "arguments": {"path": "Z:/nope.txt"}}, 52)
    check("missing file is an error", r.get("result", {}).get("isError") is True)

    print("unknown tool is an error, not a crash")
    r = rpc("tools/call", {"name": "g3_nope", "arguments": {}}, 6)
    check("unknown tool flagged isError", r.get("result", {}).get("isError") is True)

    print("unknown method")
    r = rpc("does/notexist", {}, 7)
    check("unknown method returns JSON-RPC error", "error" in r)

    print("server still alive after errors")
    r = rpc("ping", {}, 8)
    check("still responding", "result" in r)

    p.stdin.close()
    p.wait(timeout=5)

    print()
    if failures:
        print("%d CHECK(S) FAILED: %s" % (len(failures), ", ".join(failures)))
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
