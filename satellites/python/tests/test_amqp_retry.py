import contextlib
import io
import json
import os
import sys
import unittest
from types import SimpleNamespace
from unittest import mock

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

from chronicle_satellite.app import (  # noqa: E402
    FAILED_TYPE,
    REQUESTED_TYPE,
    TRANSPORT_RETRY_ATTEMPT_HEADER,
    ChronicleSatellite,
)


def ok_executor(_properties, data):
    return {"ok": data.get("value", True)}, {"executor": "ok"}


def failing_executor(_properties, _data):
    raise ValueError("business rule failed")


class RecordingSatellite(ChronicleSatellite):
    def __init__(self, executors=None):
        super().__init__(executors or {"transform": ok_executor}, default_topics="transform", name="retry test")
        self.published_events = []

    def publish_event(self, channel, message_type, body, tenant_id, correlation_id):
        self.published_events.append(
            {
                "message_type": message_type,
                "body": body,
                "tenant_id": tenant_id,
                "correlation_id": correlation_id,
            }
        )
        if getattr(self, "fail_publish_event", False):
            raise RuntimeError("publish unavailable")
        self.metrics.inc("published_events_total")


class FakeChannel:
    def __init__(self, fail_basic_publish=False):
        self.exchanges = []
        self.queues = []
        self.bindings = []
        self.published = []
        self.acked = []
        self.nacked = []
        self.fail_basic_publish = fail_basic_publish

    def exchange_declare(self, **kwargs):
        self.exchanges.append(kwargs)

    def exchange_bind(self, **kwargs):
        self.bindings.append(("exchange", kwargs))

    def queue_declare(self, **kwargs):
        self.queues.append(kwargs)

    def queue_bind(self, **kwargs):
        self.bindings.append(("queue", kwargs))

    def basic_publish(self, **kwargs):
        if self.fail_basic_publish:
            raise RuntimeError("retry publish failed")
        self.published.append(kwargs)

    def basic_ack(self, delivery_tag):
        self.acked.append(delivery_tag)

    def basic_nack(self, delivery_tag, requeue=False):
        self.nacked.append({"delivery_tag": delivery_tag, "requeue": requeue})


def properties(headers=None):
    return SimpleNamespace(
        type=REQUESTED_TYPE,
        content_type="application/json",
        delivery_mode=2,
        headers=headers or {},
    )


def method(tag=1):
    return SimpleNamespace(delivery_tag=tag, routing_key=f"{REQUESTED_TYPE}.#.tenant-1")


def event(**overrides):
    value = {
        "ExternalTaskId": "task-1",
        "TenantId": "tenant-1",
        "CorrelationId": "corr-1",
        "Topic": "transform",
        "Connector": {"id": "alpha/main"},
        "TaskProperties": {"body": '{"ok":"{{value}}"}'},
        "Data": {"value": "yes"},
    }
    value.update(overrides)
    return value


class AmqpRetryTest(unittest.TestCase):
    def test_topology_declares_per_connector_dlq_and_retry_delay_queues(self):
        with mock.patch.dict(
            os.environ,
            {"SATELLITE_CONNECTOR_IDS": "alpha/main,beta", "SATELLITE_TRANSPORT_MAX_RETRIES": "2"},
            clear=False,
        ):
            satellite = RecordingSatellite()
        channel = FakeChannel()

        satellite.declare_topology(channel)

        queue_names = {queue["queue"] for queue in channel.queues}
        self.assertIn("Chronicle.Satellite.DLQ.alpha_main", queue_names)
        self.assertIn("Chronicle.Satellite.DLQ.beta", queue_names)
        self.assertIn("Chronicle.Satellite.Retry.alpha_main.1", queue_names)
        self.assertIn("Chronicle.Satellite.Retry.alpha_main.2", queue_names)

        main_queue = [queue for queue in channel.queues if queue["queue"] == "Chronicle.Satellite"][0]
        self.assertEqual({"x-queue-mode": "lazy"}, main_queue["arguments"])

    def test_malformed_json_is_scheduled_for_transport_retry(self):
        with mock.patch.dict(os.environ, {"SATELLITE_TRANSPORT_RETRY_JITTER": "false"}, clear=False):
            satellite = RecordingSatellite()
        channel = FakeChannel()

        with contextlib.redirect_stdout(io.StringIO()):
            satellite.handle_delivery(channel, method(7), properties(), b"{")

        self.assertEqual(channel.acked, [7])
        self.assertEqual(channel.nacked, [])
        self.assertEqual(len(channel.published), 1)
        retry = channel.published[0]
        self.assertEqual("Chronicle.Satellite.Transport.Retry", retry["exchange"])
        self.assertEqual("unknown.1", retry["routing_key"])
        self.assertEqual("1000", retry["properties"].expiration)
        self.assertEqual("1", retry["properties"].headers[TRANSPORT_RETRY_ATTEMPT_HEADER])
        self.assertEqual([], satellite.published_events)

    def test_transport_retry_max_can_be_overridden_from_execution_metadata(self):
        satellite = RecordingSatellite()
        channel = FakeChannel()
        body = json.dumps(
            event(
                Execution={
                    "maxTransportRetries": 0,
                    "transportRetry": {"baseDelayMs": 25, "jitter": False},
                }
            )
        ).encode("utf-8")

        with mock.patch("chronicle_satellite.app.verify_or_raise", side_effect=RuntimeError("bad signature")):
            with contextlib.redirect_stdout(io.StringIO()):
                satellite.handle_delivery(channel, method(9), properties(), body)

        self.assertEqual(channel.acked, [9])
        self.assertEqual(channel.nacked, [])
        self.assertEqual(len(channel.published), 1)
        dead_letter = channel.published[0]
        self.assertEqual("Chronicle.Satellite.Transport.DLX", dead_letter["exchange"])
        self.assertEqual("alpha_main", dead_letter["routing_key"])
        queue_names = {queue["queue"] for queue in channel.queues}
        self.assertIn("Chronicle.Satellite.DLQ.alpha_main", queue_names)

    def test_business_failure_publishes_chronicle_failure_and_acks(self):
        satellite = RecordingSatellite({"transform": failing_executor})
        channel = FakeChannel()
        body = json.dumps(event()).encode("utf-8")

        with contextlib.redirect_stdout(io.StringIO()):
            satellite.handle_delivery(channel, method(11), properties(), body)

        self.assertEqual(channel.acked, [11])
        self.assertEqual(channel.nacked, [])
        self.assertEqual(channel.published, [])
        self.assertEqual(1, len(satellite.published_events))
        self.assertEqual(FAILED_TYPE, satellite.published_events[0]["message_type"])

    def test_retry_publish_failure_nacks_original_for_broker_dead_lettering(self):
        satellite = RecordingSatellite()
        channel = FakeChannel(fail_basic_publish=True)

        with contextlib.redirect_stdout(io.StringIO()):
            satellite.handle_delivery(channel, method(13), properties(), b"{")

        self.assertEqual(channel.acked, [])
        self.assertEqual(channel.nacked, [{"delivery_tag": 13, "requeue": False}])


if __name__ == "__main__":
    unittest.main()
