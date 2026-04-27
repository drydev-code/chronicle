import argparse
import importlib.util
import json
import os
import sqlite3
import sys
import tempfile
import threading
from http.server import ThreadingHTTPServer
from pathlib import Path


REQUIRED_TOPICS = {"rest", "ai", "database", "email", "transform"}


def main() -> int:
    parser = argparse.ArgumentParser(description="Smoke test Chronicle Python satellite examples without AMQP.")
    parser.add_argument("--repo-root", default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    sys.path.insert(0, str(repo_root / "satellites" / "python"))

    from chronicle_satellite.executors.database import close_cached_connections, execute_database
    from chronicle_satellite.executors.email_transform import execute_email, execute_transform
    from chronicle_satellite.executors.rest_ai import execute_ai, execute_rest

    diagrams = load_satellite_diagrams(repo_root)
    topics = collect_topics(diagrams)
    missing = REQUIRED_TOPICS - topics
    if missing:
        raise AssertionError(f"satellite example diagrams are missing topics: {sorted(missing)}")

    server = start_mock_service(repo_root)
    base_url = f"http://127.0.0.1:{server.server_port}"
    failures = []

    try:
        result, meta = execute_transform({"body": '{"greeting":"Hello {{name}}"}'}, {"name": "Ada"})
        assert result == {"greeting": "Hello Ada"}
        assert meta["executor"] == "satellite_transform"

        result, meta = execute_email(
            {"extensions": {"to": "ops@example.test", "subject": "Hi {{name}}", "body": "Ready"}},
            {"name": "Ada"},
        )
        assert result["status"] == "prepared"
        assert meta["executor"] == "satellite_email"

        with tempfile.TemporaryDirectory() as tmp_dir:
            db_path = Path(tmp_dir) / "satellite-smoke.sqlite"
            prepare_sqlite(db_path)
            os.environ["SATELLITE_DB_CONNECTIONS"] = json.dumps(
                {"default": {"adapter": "sqlite", "database": str(db_path), "pool": False}}
            )
            result, meta = execute_database(
                {
                    "extensions": {
                        "query": "select name from customers where id = ?",
                        "params": [1],
                        "resultMode": "scalar",
                    }
                },
                {},
            )
            assert result == "Ada"
            assert meta["executor"] == "satellite_database"
            expect_failure(
                failures,
                "database_read_only_policy",
                lambda: execute_database({"extensions": {"query": "delete from customers"}}, {}),
                "read-only",
            )
            close_cached_connections()

        result, meta = execute_rest(
            {
                "method": "POST",
                "endpoint": f"{base_url}/rest/no-auth",
                "body": '{"value":"{{value}}"}',
                "extensions": {"resultMode": "body", "resultPath": "data.body.value"},
            },
            {"value": "ok"},
        )
        assert result == "ok"
        assert meta["executor"] == "satellite_rest"

        result, _ = execute_rest(
            {
                "method": "GET",
                "endpoint": f"{base_url}/auth/bearer",
                "extensions": {
                    "auth": {"type": "bearer", "token": "satellite-token"},
                    "resultMode": "body",
                    "resultPath": "data.authorization",
                },
            },
            {},
        )
        assert result == "Bearer satellite-token"

        result, _ = execute_rest(
            {
                "method": "GET",
                "endpoint": f"{base_url}/auth/basic",
                "extensions": {
                    "auth": {"type": "basic", "username": "satellite", "password": "secret"},
                    "resultMode": "body",
                    "resultPath": "data.authorization",
                },
            },
            {},
        )
        assert result == "Basic c2F0ZWxsaXRlOnNlY3JldA=="

        result, _ = execute_rest(
            {
                "method": "GET",
                "endpoint": f"{base_url}/auth/api-key",
                "extensions": {
                    "auth": {"type": "api_key", "location": "header", "name": "x-api-key", "value": "satellite-key"},
                    "resultMode": "body",
                    "resultPath": "data.apiKey",
                },
            },
            {},
        )
        assert result == "satellite-key"

        result, _ = execute_rest(
            {
                "method": "GET",
                "endpoint": f"{base_url}/auth/oauth",
                "extensions": {
                    "auth": {
                        "type": "oauth2_client_credentials",
                        "tokenUrl": f"{base_url}/oauth/token",
                        "clientId": "satellite-client",
                        "clientSecret": "satellite-secret",
                    },
                    "resultMode": "body",
                    "resultPath": "data.authorization",
                },
            },
            {},
        )
        assert result == "Bearer oauth-satellite-token"

        result, meta = execute_ai(
            {
                "endpoint": f"{base_url}/ai/chat",
                "extensions": {
                    "model": "mock-model",
                    "prompt": "Summarize {{name}}",
                    "resultMode": "body",
                    "resultPath": "text",
                },
            },
            {"name": "Ada"},
        )
        assert result == "mock response: Summarize Ada"
        assert meta["executor"] == "satellite_ai"

        expect_failure(
            failures,
            "rest_auth_failure",
            lambda: execute_rest({"method": "GET", "endpoint": f"{base_url}/auth/bearer"}, {}),
            "status 401",
        )
        expect_failure(
            failures,
            "email_validation_failure",
            lambda: execute_email({"extensions": {"to": "ops@example.test", "subject": "Missing body"}}, {}),
            "requires to, subject, and body",
        )
    finally:
        server.shutdown()
        server.server_close()

    print(
        json.dumps(
            {
                "status": "ok",
                "diagrams": sorted(str(path.relative_to(repo_root)) for path in diagrams),
                "topics": sorted(topics),
                "expectedFailures": failures,
            },
            indent=2,
        )
    )
    return 0


def load_satellite_diagrams(repo_root: Path):
    diagrams = sorted((repo_root / "examples" / "workflows").glob("satellite-*.bpjs"))
    if not diagrams:
        raise AssertionError("no satellite example diagrams found")
    for path in diagrams:
        json.loads(path.read_text(encoding="utf-8"))
    return diagrams


def collect_topics(diagrams):
    topics = set()
    for path in diagrams:
        payload = json.loads(path.read_text(encoding="utf-8"))
        for node in payload.get("nodes", []):
            properties = node.get("properties") or {}
            topic = properties.get("topic")
            if topic:
                topics.add(str(topic).lower())
    return topics


def start_mock_service(repo_root: Path):
    module_path = repo_root / "satellites" / "mock" / "mock_service.py"
    spec = importlib.util.spec_from_file_location("chronicle_mock_service", module_path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    server = ThreadingHTTPServer(("127.0.0.1", 0), module.Handler)
    thread = threading.Thread(target=server.serve_forever, name="satellite-smoke-mock", daemon=True)
    thread.start()
    return server


def prepare_sqlite(path: Path) -> None:
    conn = sqlite3.connect(path)
    try:
        conn.execute("create table customers (id integer primary key, name text not null)")
        conn.execute("insert into customers (id, name) values (?, ?)", (1, "Ada"))
        conn.commit()
    finally:
        conn.close()


def expect_failure(failures, name, fn, expected_text: str) -> None:
    try:
        fn()
    except Exception as exc:
        if expected_text.lower() not in str(exc).lower():
            raise AssertionError(f"{name} failed with unexpected error: {exc}") from exc
        failures.append(name)
        return
    raise AssertionError(f"{name} unexpectedly succeeded")


if __name__ == "__main__":
    raise SystemExit(main())
