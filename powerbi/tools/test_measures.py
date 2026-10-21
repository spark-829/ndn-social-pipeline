"""Evaluate every measure of the open Power BI Desktop model one by one: py test_measures.py <port>"""
import subprocess, json, threading, queue, sys
exe = r"C:\Users\Spark\.vscode\extensions\analysis-services.powerbi-modeling-mcp-1.0.0-win32-x64\server\powerbi-modeling-mcp.exe"
p = subprocess.Popen([exe, "--start", "--accept-eula"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, encoding="utf-8")
q = queue.Queue(); threading.Thread(target=lambda: [q.put(l) for l in p.stdout], daemon=True).start()
i = [0]
def call(tool, req):
    i[0] += 1
    p.stdin.write(json.dumps({"jsonrpc":"2.0","id":i[0],"method":"tools/call","params":{"name":tool,"arguments":{"request":req}}}) + "\n"); p.stdin.flush()
    while True:
        m = json.loads(q.get(timeout=300))
        if m.get("id") == i[0]:
            return "".join(c.get("text","") for c in m.get("result",{}).get("content",[])) or json.dumps(m)
p.stdin.write(json.dumps({"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}})+"\n"); p.stdin.flush(); q.get(timeout=60)
p.stdin.write(json.dumps({"jsonrpc":"2.0","method":"notifications/initialized"})+"\n"); p.stdin.flush()
print(call("connection_operations", {"operation": "Connect", "connectionString": f"data source=localhost:{sys.argv[1]}"})[:200])
ms = json.loads(call("measure_operations", {"operation": "List"}))
names = [m["name"] for tb in ms["data"] for m in tb["measures"]]
print(len(names), "measures")
bad = 0
for nm in names:
    r = call("dax_query_operations", {"operation": "Execute", "query": f'EVALUATE ROW("v", [{nm}])', "resultMode": "Inline"})
    ok = '"rows"' in r or "Rows" in r or '"v"' in r
    if "error" in r.lower() or not ok:
        bad += 1; print("FAIL", nm, "->", r[:300])
    elif len(sys.argv) > 2: print("ok", nm, r[-120:])
print("failed:", bad)
p.kill()
