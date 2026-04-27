import contextlib
import io
import json
import os
import sys
import unittest
import urllib.error
import urllib.request
from types import SimpleNamespace

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

from chronicle_satellite.app import ChronicleSatellite, REQUESTED_TYPE
from chronicle_satellite.core import SatelliteHealth, SatelliteMetrics, start_observability_server
from chronicle_satellite.executors.email_transform import execute_transform


class RecordingSatellite(ChronicleSatellite):
    def __init__(self):
        super().__init__({"transform": execute_transform}, default_topics="transform", name="test satellite")
        self.published = []

    def publish_event(self, channel, message_type, body, tenant_id, correlation_id):
        self.published.append(
            {
                "message_type": message_type,
                "body": body,
                "tenant_id": tenant_id,
                "correlation_id": correlation_id,
            }
        )
        self.metrics.inc("published_events_total")


class Channel:
    def __init__(self):
        self.acked = []
        self.nacked = []
        self.published = []
        self.declared = []
        self.bound = []

    def basic_ack(self, delivery_tag):
        self.acked.append(delivery_tag)

    def basic_nack(self, delivery_tag, requeue=False):
        self.nacked.append((delivery_tag, requeue))

    def basic_publish(self, **kwargs):
        self.published.append(kwargs)

    def exchange_declare(self, **kwargs):
        self.declared.append(("exchange", kwargs))

    def exchange_bind(self, **kwargs):
        self.bound.append(("exchange", kwargs))

    def queue_declare(self, **kwargs):
        self.declared.append(("queue", kwargs))

    def queue_bind(self, **kwargs):
        self.bound.append(("queue", kwargs))


class ObservabilityTest(unittest.TestCase):
    def test_health_and_metrics_render_readiness(self):
        health = SatelliteHealth()
        metrics = SatelliteMetrics()
        metrics.inc("received_messages_total")
        metrics.observe_duration(0.25)

        before = metrics.prometheus({"satellite": "unit"}, health)
        self.assertIn("chronicle_satellite_ready", before)
        self.assertIn(" 0", before)

        health.mark_ready()
        after = metrics.prometheus({"satellite": "unit"}, health)
        self.assertIn("chronicle_satellite_ready", after)
        self.assertIn("chronicle_satellite_received_messages_total", after)
        self.assertIn("chronicle_satellite_execution_duration_seconds_count", after)

    def test_observability_http_server_reports_readiness(self):
        health = SatelliteHealth()
        metrics = SatelliteMetrics()
        server = start_observability_server(
            host="127.0.0.1",
            port=0,
            health=health,
            metrics=metrics,
            labels={"satellite": "unit"},
        )
        base_url = f"http://127.0.0.1:{server.server_port}"
        try:
            with self.assertRaises(urllib.error.HTTPError) as raised:
                urllib.request.urlopen(f"{base_url}/readyz", timeout=2)
            self.assertEqual(raised.exception.code, 503)

            health.mark_ready()
            ready = json.loads(urllib.request.urlopen(f"{base_url}/readyz", timeout=2).read().decode("utf-8"))
            metrics_body = urllib.request.urlopen(f"{base_url}/metrics", timeout=2).read().decode("utf-8")

            self.assertTrue(ready["ready"])
            self.assertIn("chronicle_satellite_ready", metrics_body)
        finally:
            server.shutdown()
            server.server_close()

    def test_delivery_logs_correlation_task_and_connector_ids(self):
        satellite = RecordingSatellite()
        channel = Channel()
        method = SimpleNamespace(delivery_tag=123)
        properties = SimpleNamespace(
            type=REQUESTED_TYPE,
            headers={"Chronicle.CorrelationId": "corr-1"},
        )
        body = json.dumps(
            {
                "ExternalTaskId": "task-1",
                "TenantId": "tenant-1",
                "Topic": "transform",
                "TaskProperties": {
                    "connectorId": "transform-main",
                    "body": '{"ok":"{{value}}"}',
                },
                "Data": {"value": "yes"},
            }
        ).encode("utf-8")

        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            satellite.handle_delivery(channel, method, properties, body)

        events = [json.loads(line) for line in output.getvalue().splitlines() if line.strip()]
        completed = [event for event in events if event["event"] == "satellite_task_completed"][0]

        self.assertEqual(completed["correlation_id"], "corr-1")
        self.assertEqual(completed["external_task_id"], "task-1")
        self.assertEqual(completed["connector_id"], "transform-main")
        self.assertEqual(channel.acked, [123])
        self.assertEqual(len(satellite.published), 1)
        self.assertEqual(satellite.metrics.snapshot()["counters"]["completed_tasks_total"], 1)

    def test_transport_failure_retries_then_dead_letters_per_connector(self):
        satellite = RecordingSatellite()
        satellite.transport_retry_jitter = False
        channel = Channel()
        method = SimpleNamespace(delivery_tag=456)
        body = json.dumps(
            {
                "ExternalTaskId": "task-2",
                "TenantId": "tenant-1",
                "Topic": "transform",
                "Execution": {"transport": {"maxRetries": 1, "baseDelayMs": 10}},
                "TaskProperties": {"connectorId": "transform-main", "body": '{"ok": true}'},
                "Data": {},
            }
        ).encode("utf-8")

        properties = SimpleNamespace(type=REQUESTED_TYPE, headers={})
        satellite.handle_transport_failure(
            channel,
            method,
            properties,
            body,
            satellite.try_decode_event(body),
            RuntimeError("publish unavailable"),
            {},
        )

        self.assertEqual(channel.acked, [456])
        self.assertEqual(channel.published[0]["exchange"], satellite.transport_retry_exchange)
        self.assertEqual(channel.published[0]["routing_key"], "transform-main.1")
        retry_headers = channel.published[0]["properties"].headers
        self.assertEqual(retry_headers["Chronicle.TransportRetry.Attempt"], "1")

        channel = Channel()
        retried = SimpleNamespace(
            type=REQUESTED_TYPE,
            headers={"Chronicle.TransportRetry.Attempt": "1"},
        )
        satellite.handle_transport_failure(
            channel,
            method,
            retried,
            body,
            satellite.try_decode_event(body),
            RuntimeError("still unavailable"),
            {},
        )

        self.assertEqual(channel.acked, [456])
        self.assertEqual(channel.published[0]["exchange"], satellite.transport_dead_letter_exchange)
        self.assertEqual(channel.published[0]["routing_key"], "transform-main")
        self.assertEqual(channel.published[0]["properties"].headers["Chronicle.TransportRetry.DeadLettered"], "true")

    def test_topology_declares_per_connector_dlq_and_retry_queues(self):
        satellite = RecordingSatellite()
        satellite.connector_ids = {"crm-main"}
        satellite.transport_default_max_retries = 2
        satellite.transport_retry_jitter = False
        channel = Channel()

        satellite.declare_topology(channel)

        queues = [entry[1]["queue"] for entry in channel.declared if entry[0] == "queue"]
        self.assertIn("Chronicle.Satellite.DLQ.crm-main", queues)
        self.assertIn("Chronicle.Satellite.Retry.crm-main.1", queues)
        self.assertIn("Chronicle.Satellite.Retry.crm-main.2", queues)


if __name__ == "__main__":
    unittest.main()
