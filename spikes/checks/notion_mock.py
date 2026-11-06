"""Local stand-in for Notion's API: validates requests against the documented shapes."""
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG = sys.argv[2]
TYPES = {"paragraph", "heading_2", "bulleted_list_item", "to_do"}
problems, pages, appended = [], [], []

def check_blocks(blocks):
    if len(blocks) > 100: problems.append(f"{len(blocks)} blocks in one request (limit 100)")
    for b in blocks:
        t = b.get("type")
        if b.get("object") != "block" or t not in TYPES or t not in b:
            problems.append(f"bad block {str(b)[:80]}")
            continue
        for run in b[t].get("rich_text", []):
            if len(run["text"]["content"]) > 2000: problems.append("text run over 2000 chars")

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def handle_any(self, method):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        if not self.headers.get("Authorization", "").startswith("Bearer ntn_"): problems.append("missing bearer token")
        if self.headers.get("Notion-Version") != "2022-06-28": problems.append("missing Notion-Version")
        if method == "POST" and self.path == "/v1/pages":
            if len(body.get("parent", {}).get("page_id", "")) != 32: problems.append("bad parent page id")
            if not body.get("properties", {}).get("title", {}).get("title"): problems.append("missing title")
            check_blocks(body.get("children", []))
            pages.append({"title": body["properties"]["title"]["title"][0]["text"]["content"], "blocks": len(body["children"])})
            out = {"object": "page", "id": "page-1", "url": "https://www.notion.so/page-1"}
        elif method == "PATCH" and self.path.startswith("/v1/blocks/page-1/children"):
            check_blocks(body.get("children", [])); appended.append(len(body["children"]))
            out = {"object": "list", "results": []}
        else:
            problems.append(f"unexpected {method} {self.path}"); out = {"message": "not found"}
        data = json.dumps(out).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
        json.dump({"pages": pages, "appended": appended, "problems": problems}, open(LOG, "w"))
    def do_POST(self): self.handle_any("POST")
    def do_PATCH(self): self.handle_any("PATCH")

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
