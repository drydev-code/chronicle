import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import requests

from chronicle_satellite.executors import rest_ai


class TestHandler(BaseHTTPRequestHandler):
    token_requests = 0
    flaky_requests = 0

    def do_GET(self):
        self.handle_request()

    def do_POST(self):
        self.handle_request()

    def handle_request(self):
        parsed = urlparse(self.path)
        length = int(self.headers.get("content-length", "0"))
        raw_body = self.rfile.read(length).decode("utf-8") if length else ""

        if parsed.path == "/oauth/token":
            TestHandler.token_requests += 1
            return self.send_json(
                200,
                {
                    "access_token": "cached-token",
                    "token_type": "Bearer",
                    "expires_in": 3600,
                },
            )

        if parsed.path == "/flaky":
            TestHandler.flaky_requests += 1
            if TestHandler.flaky_requests < 3:
                return self.send_json(503, {"error": "try again"})

        if parsed.path == "/status":
            status = int(parse_qs(parsed.query).get("code", ["500"])[0])
            return self.send_json(status, {"error": "status"})

        try:
            body = json.loads(raw_body) if raw_body else {}
        except Exception:
            body = {"raw": raw_body}
        self.send_json(
            200,
            {
                "data": {
                    "path": parsed.path,
                    "query": parse_qs(parsed.query),
                    "method": self.command,
                    "body": body,
                    "authorization": self.headers.get("authorization"),
                    "apiKey": self.headers.get("x-api-key"),
                    "idempotencyKey": self.headers.get("idempotency-key"),
                }
            },
        )

    def send_json(self, status, payload):
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        return


class RestAiExecutorTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), TestHandler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base_url = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        rest_ai.OAUTH_TOKEN_CACHE.clear()
        TestHandler.token_requests = 0
        TestHandler.flaky_requests = 0

    def execute_body(self, properties, data=None):
        result, _meta = rest_ai.execute_rest(
            {
                **properties,
                "extensions": {
                    "resultMode": "body",
                    **properties.get("extensions", {}),
                },
            },
            data or {},
        )
        return result

    def test_bearer_basic_and_api_key_auth(self):
        bearer = self.execute_body(
            {
                "method": "GET",
                "endpoint": f"{self.base_url}/echo",
                "extensions": {"auth": {"type": "bearer", "token": "token-123"}},
            }
        )
        self.assertEqual("Bearer token-123", bearer["data"]["authorization"])

        basic = self.execute_body(
            {
                "method": "GET",
                "endpoint": f"{self.base_url}/echo",
                "extensions": {
                    "auth": {"type": "basic", "username": "satellite", "password": "secret"}
                },
            }
        )
        self.assertEqual("Basic c2F0ZWxsaXRlOnNlY3JldA==", basic["data"]["authorization"])

        api_key = self.execute_body(
            {
                "method": "GET",
                "endpoint": f"{self.base_url}/echo",
                "extensions": {
                    "auth": {
                        "type": "api_key",
                        "location": "query",
                        "name": "api_key",
                        "value": "key-123",
                    }
                },
            }
        )
        self.assertEqual(["key-123"], api_key["data"]["query"]["api_key"])

    def test_oauth_client_credentials_token_is_cached(self):
        properties = {
            "method": "GET",
            "endpoint": f"{self.base_url}/oauth/protected",
            "extensions": {
                "auth": {
                    "type": "oauth2_client_credentials",
                    "tokenUrl": f"{self.base_url}/oauth/token",
                    "clientId": "client",
                    "clientSecret": "secret",
                }
            },
        }
        first = self.execute_body(properties)
        second = self.execute_body(properties)

        self.assertEqual("Bearer cached-token", first["data"]["authorization"])
        self.assertEqual("Bearer cached-token", second["data"]["authorization"])
        self.assertEqual(1, TestHandler.token_requests)

    def test_retry_status_and_idempotency_key(self):
        result, meta = rest_ai.execute_rest(
            {
                "method": "POST",
                "endpoint": f"{self.base_url}/flaky",
                "body": {"ok": True},
                "extensions": {
                    "resultMode": "body",
                    "retry": {"maxAttempts": 3, "statuses": [503], "backoffMs": 0, "jitter": False},
                    "idempotencyKey": "job-{{jobId}}",
                },
            },
            {"jobId": "42"},
        )

        self.assertEqual(3, TestHandler.flaky_requests)
        self.assertEqual(3, meta["attempts"])
        self.assertEqual("job-42", result["data"]["idempotencyKey"])

    def test_http_status_errors_are_classified(self):
        with self.assertRaises(rest_ai.RestConnectorError) as raised:
            rest_ai.execute_rest(
                {
                    "method": "GET",
                    "endpoint": f"{self.base_url}/status?code=429",
                    "extensions": {"retry": {"maxAttempts": 1}},
                },
                {},
            )

        self.assertEqual("rate_limited", raised.exception.category)
        self.assertEqual(429, raised.exception.status)
        self.assertTrue(raised.exception.retryable)

    def test_timeout_tls_and_digest_options(self):
        self.assertEqual((1.5, 2.5), rest_ai.build_timeout({"extensions": {"timeout": {"connectMs": 1500, "readMs": 2500}}}))
        self.assertEqual(
            {"verify": "/tmp/ca.pem", "cert": ("/tmp/client.pem", "/tmp/client-key.pem")},
            rest_ai.build_tls_config(
                {
                    "extensions": {
                        "tls": {
                            "verify": "/tmp/ca.pem",
                            "clientCert": "/tmp/client.pem",
                            "clientKey": "/tmp/client-key.pem",
                        }
                    }
                }
            ),
        )

        headers = {}
        auth = rest_ai.build_auth(
            {"extensions": {"auth": {"type": "digest", "username": "u", "password": "p"}}},
            {},
            headers,
        )
        self.assertIsInstance(auth["request_auth"], requests.auth.HTTPDigestAuth)

    def test_aws_sigv4_auth_signs_request(self):
        auth = rest_ai.AwsSigV4Auth(
            access_key="AKID",
            secret_key="SECRET",
            region="eu-central-1",
            service="execute-api",
            session_token="SESSION",
        )
        prepared = requests.Request("POST", "https://example.amazonaws.com/items?a=1", data="{}").prepare()
        signed = auth(prepared)

        self.assertIn("AWS4-HMAC-SHA256 Credential=AKID/", signed.headers["Authorization"])
        self.assertIn("SignedHeaders=", signed.headers["Authorization"])
        self.assertEqual("SESSION", signed.headers["X-Amz-Security-Token"])
        self.assertEqual("example.amazonaws.com", signed.headers["Host"])


if __name__ == "__main__":
    unittest.main()
