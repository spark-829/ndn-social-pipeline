"""Tiny stdio client for the Power BI Modeling MCP: py mcp_call.py '<json list of [tool, args]>'"""
import subprocess, json, threading, queue, sys
exe = r"C:\Users\Spark\.vscode\extensions\analysis-services.powerbi-modeling-mcp-1.0.0-win32-x64\server\powerbi-modeling-mcp.exe"
p = subprocess.Popen([exe, "--start", "--accept-eula"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, encoding="utf-8")
q = queue.Queue()
threading.Thread(target=lambda: [q.put(l) for l in p.stdout], daemon=True).start()
def send(m): p.stdin.write(json.dumps(m) + "\n"); p.stdin.flush()
def wait(i, t=300):
    while True:
        m = json.loads(q.get(timeout=t))
        if m.get("id") == i: return m
send({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}); wait(1)
send({"jsonrpc":"2.0","method":"notifications/initialized"})
calls = json.loads(sys.argv[1])
if calls == "schema":
    send({"jsonrpc":"2.0","id":2,"method":"tools/list"})
    for t in wait(2)["result"]["tools"]:
        if t["name"] in sys.argv[2].split(","):
            print("###", t["name"]); print(t["description"][:1500]); print(json.dumps(t["inputSchema"])[:2500])
else:
    for i, (tool, args) in enumerate(calls, 10):
        send({"jsonrpc":"2.0","id":i,"method":"tools/call","params":{"name":tool,"arguments":args}})
        r = wait(i)
        out = r.get("result", r.get("error"))
        txt = "".join(c.get("text","") for c in out.get("content", [])) if isinstance(out, dict) and "content" in out else json.dumps(out)
        print(f"### {tool} {json.dumps(args)[:200]}\n{txt[:int(sys.argv[2]) if len(sys.argv)>2 else 4000]}\n")
p.kill()
