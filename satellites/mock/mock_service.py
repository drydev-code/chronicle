import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.handle_request()

    def do_POST(self):
        self.handle_request()

    def do_PUT(self):
        self.handle_request()

    def do_PATCH(self):
        self.handle_request()

    def handle_request(self):
        parsed = urlparse(self.path)
        length = int(self.headers.get("content-length", "0"))
        raw_body = self.rfile.read(length).decode("utf-8") if length else ""
        try:
            body = json.loads(raw_body) if raw_body else {}
        except Exception:
            body = {"raw": raw_body}

        if parsed.path == "/auth/bearer":
            if self.headers.get("authorization") != "Bearer satellite-token":
                return self.send_json(401, {"error": "missing bearer"})
        elif parsed.path == "/auth/basic":
            if self.headers.get("authorization") != "Basic c2F0ZWxsaXRlOnNlY3JldA==":
                return self.send_json(401, {"error": "missing basic"})
        elif parsed.path == "/auth/api-key":
            query = parse_qs(parsed.query)
            if self.headers.get("x-api-key") != "satellite-key" and query.get("api_key") != ["satellite-key"]:
                return self.send_json(401, {"error": "missing api key"})
        elif parsed.path == "/auth/oauth":
            if self.headers.get("authorization") != "Bearer oauth-satellite-token":
                return self.send_json(401, {"error": "missing oauth bearer"})

        if parsed.path == "/oauth/token":
            return self.send_json(200, {
                "access_token": "oauth-satellite-token",
                "token_type": "Bearer",
                "expires_in": 3600,
            })

        if parsed.path == "/ai/chat":
            prompt = ""
            messages = body.get("messages") or []
            if messages:
                prompt = messages[-1].get("content", "")
            return self.send_json(200, {
                "model": body.get("model", "mock-model"),
                "choices": [{
                    "message": {"role": "assistant", "content": f"mock response: {prompt}"},
                    "finish_reason": "stop",
                }],
                "usage": {"prompt_tokens": 3, "completion_tokens": 4, "total_tokens": 7},
            })

        return self.send_json(200, {
            "data": {
                "path": parsed.path,
                "method": self.command,
                "body": body,
                "authorization": self.headers.get("authorization"),
                "apiKey": self.headers.get("x-api-key"),
            }
        })

    def send_json(self, status, payload):
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        return


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
