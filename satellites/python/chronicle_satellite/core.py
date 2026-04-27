import json
import os
import threading
import time
import traceback
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict, List, Optional


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def split_csv(value: str) -> List[str]:
    return [part.strip().lower() for part in value.split(",") if part.strip()]


def env_flag(name: str, default: str = "false") -> bool:
    return env(name, default).lower() in ["1", "true", "yes", "on"]


def snake_get(data: Dict[str, Any], *keys: str, default: Any = None) -> Any:
    for key in keys:
        if key in data:
            return data[key]
        pascal = key[:1].upper() + key[1:]
        if pascal in data:
            return data[pascal]
    return default


def redact(value: Any) -> Any:
    if isinstance(value, dict):
        redacted = {}
        for key, item in value.items():
            lowered = str(key).lower()
            if any(secret in lowered for secret in ["token", "secret", "password", "authorization", "apikey", "api_key"]):
                redacted[key] = "[redacted]"
            else:
                redacted[key] = redact(item)
        return redacted
    if isinstance(value, list):
        return [redact(item) for item in value]
    return value


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def log_json(event: str, **fields: Any) -> None:
    payload = {
        "timestamp": utc_now(),
        "event": event,
        **{key: redact(value) for key, value in fields.items() if value is not None},
    }
    print(json.dumps(payload, separators=(",", ":"), sort_keys=True), flush=True)


def exception_fields(exc: Exception) -> Dict[str, Any]:
    return {
        "error_type": exc.__class__.__name__,
        "error_message": str(exc),
        "stack": traceback.format_exc(),
    }


class SatelliteHealth:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self.started_at = time.time()
        self.ready = False
        self.state = "starting"
        self.last_error: Optional[str] = None
        self.last_error_type: Optional[str] = None
        self.last_ready_at: Optional[float] = None
        self.last_unready_at: Optional[float] = self.started_at
        self.last_heartbeat_at = self.started_at
        self._heartbeat_started = False

    def start_heartbeat(self, interval_seconds: float) -> None:
        if self._heartbeat_started:
            return
        self._heartbeat_started = True

        def beat() -> None:
            while True:
                self.heartbeat()
                time.sleep(interval_seconds)

        thread = threading.Thread(target=beat, name="satellite-heartbeat", daemon=True)
        thread.start()

    def heartbeat(self) -> None:
        with self._lock:
            self.last_heartbeat_at = time.time()

    def mark_ready(self, state: str = "consuming") -> None:
        with self._lock:
            self.ready = True
            self.state = state
            self.last_error = None
            self.last_error_type = None
            self.last_ready_at = time.time()
            self.last_heartbeat_at = self.last_ready_at

    def mark_not_ready(self, state: str, exc: Optional[Exception] = None) -> None:
        with self._lock:
            self.ready = False
            self.state = state
            self.last_unready_at = time.time()
            self.last_heartbeat_at = self.last_unready_at
            if exc is not None:
                self.last_error = str(exc)
                self.last_error_type = exc.__class__.__name__

    def snapshot(self) -> Dict[str, Any]:
        with self._lock:
            now = time.time()
            return {
                "status": "ready" if self.ready else "not_ready",
                "ready": self.ready,
                "state": self.state,
                "startedAt": self.started_at,
                "uptimeSeconds": round(now - self.started_at, 3),
                "lastReadyAt": self.last_ready_at,
                "lastUnreadyAt": self.last_unready_at,
                "lastHeartbeatAt": self.last_heartbeat_at,
                "heartbeatAgeSeconds": round(now - self.last_heartbeat_at, 3),
                "lastError": self.last_error,
                "lastErrorType": self.last_error_type,
            }


class SatelliteMetrics:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self.counters: Dict[str, int] = {}
        self.gauges: Dict[str, float] = {}
        self.duration_count = 0
        self.duration_sum = 0.0
        self.duration_max = 0.0

    def inc(self, name: str, amount: int = 1) -> None:
        with self._lock:
            self.counters[name] = self.counters.get(name, 0) + amount

    def set(self, name: str, value: float) -> None:
        with self._lock:
            self.gauges[name] = value

    def observe_duration(self, seconds: float) -> None:
        with self._lock:
            self.duration_count += 1
            self.duration_sum += seconds
            self.duration_max = max(self.duration_max, seconds)

    def snapshot(self) -> Dict[str, Any]:
        with self._lock:
            return {
                "counters": dict(self.counters),
                "gauges": dict(self.gauges),
                "executionDurationSeconds": {
                    "count": self.duration_count,
                    "sum": self.duration_sum,
                    "max": self.duration_max,
                },
            }

    def prometheus(self, labels: Dict[str, str], health: SatelliteHealth) -> str:
        snapshot = self.snapshot()
        health_snapshot = health.snapshot()
        label_text = ",".join(f'{key}="{_prom_escape(value)}"' for key, value in sorted(labels.items()) if value)
        label_suffix = "{" + label_text + "}" if label_text else ""
        lines = [
            "# HELP chronicle_satellite_ready 1 when the satellite AMQP consumer is ready.",
            "# TYPE chronicle_satellite_ready gauge",
            f"chronicle_satellite_ready{label_suffix} {1 if health_snapshot['ready'] else 0}",
            "# HELP chronicle_satellite_uptime_seconds Process uptime in seconds.",
            "# TYPE chronicle_satellite_uptime_seconds gauge",
            f"chronicle_satellite_uptime_seconds{label_suffix} {health_snapshot['uptimeSeconds']}",
            "# HELP chronicle_satellite_heartbeat_age_seconds Seconds since the satellite heartbeat advanced.",
            "# TYPE chronicle_satellite_heartbeat_age_seconds gauge",
            f"chronicle_satellite_heartbeat_age_seconds{label_suffix} {health_snapshot['heartbeatAgeSeconds']}",
        ]
        for name, value in sorted(snapshot["counters"].items()):
            lines.extend([
                f"# TYPE chronicle_satellite_{name} counter",
                f"chronicle_satellite_{name}{label_suffix} {value}",
            ])
        for name, value in sorted(snapshot["gauges"].items()):
            lines.extend([
                f"# TYPE chronicle_satellite_{name} gauge",
                f"chronicle_satellite_{name}{label_suffix} {value}",
            ])
        duration = snapshot["executionDurationSeconds"]
        lines.extend([
            "# TYPE chronicle_satellite_execution_duration_seconds summary",
            f"chronicle_satellite_execution_duration_seconds_count{label_suffix} {duration['count']}",
            f"chronicle_satellite_execution_duration_seconds_sum{label_suffix} {duration['sum']:.6f}",
            f"chronicle_satellite_execution_duration_seconds_max{label_suffix} {duration['max']:.6f}",
        ])
        return "\n".join(lines) + "\n"


def start_observability_server(
    *,
    host: str,
    port: int,
    health: SatelliteHealth,
    metrics: SatelliteMetrics,
    labels: Dict[str, str],
) -> ThreadingHTTPServer:
    class ObservabilityHandler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            if self.path in ["/livez", "/healthz", "/heartbeat"]:
                self._send_json(200, health.snapshot())
                return
            if self.path == "/readyz":
                snapshot = health.snapshot()
                self._send_json(200 if snapshot["ready"] else 503, snapshot)
                return
            if self.path == "/metrics":
                self._send_text(200, metrics.prometheus(labels, health), "text/plain; version=0.0.4")
                return
            self._send_json(404, {"error": "not_found"})

        def _send_json(self, status: int, payload: Dict[str, Any]) -> None:
            data = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")
            self.send_response(status)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _send_text(self, status: int, payload: str, content_type: str) -> None:
            data = payload.encode("utf-8")
            self.send_response(status)
            self.send_header("content-type", content_type)
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, fmt: str, *args: Any) -> None:
            return

    server = ThreadingHTTPServer((host, port), ObservabilityHandler)
    thread = threading.Thread(target=server.serve_forever, name="satellite-observability", daemon=True)
    thread.start()
    return server


def _prom_escape(value: Any) -> str:
    return str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def render_template(value: Any, data: Dict[str, Any]) -> Any:
    if isinstance(value, str):
        rendered = value
        for key, item in data.items():
            rendered = rendered.replace("{{" + str(key) + "}}", str(item))
            rendered = rendered.replace("${" + str(key) + "}", str(item))
        try:
            return json.loads(rendered)
        except Exception:
            return rendered
    if isinstance(value, list):
        return [render_template(item, data) for item in value]
    if isinstance(value, dict):
        return {key: render_template(item, data) for key, item in value.items()}
    return value


def result_path(value: Any, path: Optional[str]) -> Any:
    if not path:
        return value
    current = value
    for segment in path.split("."):
        if isinstance(current, dict):
            current = current.get(segment)
        elif isinstance(current, list) and segment.isdigit():
            current = current[int(segment)]
        else:
            return None
    return current


def extension_value(properties: Dict[str, Any], key: str, default: Any = None) -> Any:
    extensions = snake_get(properties, "extensions", "Extensions", default={}) or {}
    if key in extensions:
        return extensions[key]
    pascal = key[:1].upper() + key[1:]
    if pascal in extensions:
        return extensions[pascal]
    return default


def shape_result(value: Any, properties: Dict[str, Any], default_mode: str, modes: Dict[str, Any]) -> Any:
    mode = str(extension_value(properties, "resultMode", default_mode)).lower()
    shaped = modes.get(mode, value)
    return result_path(shaped, extension_value(properties, "resultPath") or extension_value(properties, "result"))
