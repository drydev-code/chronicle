import json
import random
import re
import time
from types import SimpleNamespace
from typing import Any, Callable, Dict, Optional, Tuple

from .core import (
    SatelliteHealth,
    SatelliteMetrics,
    env,
    env_flag,
    exception_fields,
    log_json,
    snake_get,
    split_csv,
    start_observability_server,
)
from .signing import sign_headers, verify_or_raise


REQUESTED_TYPE = "Chronicle.Messages.Workflow+ServiceTaskExecutionRequestedEvent"
EXECUTED_TYPE = "Chronicle.Messages.Workflow+ServiceTaskExecutedEvent"
FAILED_TYPE = "Chronicle.Messages.Workflow+ServiceTaskFailedEvent"
Executor = Callable[[Dict[str, Any], Dict[str, Any]], Tuple[Any, Dict[str, Any]]]


DEFAULT_TOPICS = "rest,http,https,ai,llm,database,db,sql,email,mail,transform,echo,map"
DEFAULT_TRANSPORT_MAX_RETRIES = 5
TRANSPORT_RETRY_ATTEMPT_HEADER = "Chronicle.TransportRetry.Attempt"
TRANSPORT_RETRY_MAX_HEADER = "Chronicle.TransportRetry.MaxRetries"
TRANSPORT_RETRY_ERROR_HEADER = "Chronicle.TransportRetry.LastError"
TRANSPORT_RETRY_ERROR_TYPE_HEADER = "Chronicle.TransportRetry.LastErrorType"
TRANSPORT_RETRY_CONNECTOR_HEADER = "Chronicle.TransportRetry.ConnectorId"


class ChronicleSatellite:
    def __init__(
        self,
        executors: Dict[str, Executor],
        default_topics: str = DEFAULT_TOPICS,
        default_queue: str = "Chronicle.Satellite",
        name: str = "Chronicle satellite",
    ) -> None:
        self.executors = {key.lower(): value for key, value in executors.items()}
        self.topics = set(split_csv(default_topics)).intersection(self.executors)
        self.connector_ids = set(split_csv(env("SATELLITE_CONNECTOR_IDS", "")))
        self.queue = env("SATELLITE_QUEUE", default_queue)
        self.prefetch = int(env("SATELLITE_PREFETCH", "4"))
        self.transport_retry_exchange = env("SATELLITE_TRANSPORT_RETRY_EXCHANGE", "Chronicle.Satellite.Transport.Retry")
        self.transport_dead_letter_exchange = env("SATELLITE_TRANSPORT_DLX", "Chronicle.Satellite.Transport.DLX")
        self.transport_retry_base_delay_ms = int(env("SATELLITE_TRANSPORT_RETRY_BASE_DELAY_MS", "1000"))
        self.transport_retry_max_delay_ms = int(env("SATELLITE_TRANSPORT_RETRY_MAX_DELAY_MS", "60000"))
        self.transport_retry_jitter = env_flag("SATELLITE_TRANSPORT_RETRY_JITTER", "true")
        self.transport_default_max_retries = int(
            env("SATELLITE_TRANSPORT_MAX_RETRIES", str(DEFAULT_TRANSPORT_MAX_RETRIES))
        )
        self.name = name
        self.health = SatelliteHealth()
        self.metrics = SatelliteMetrics()
        self.observability_server = None
        self.rabbit = {
            "host": env("RABBITMQ_HOST", "rabbitmq"),
            "port": int(env("RABBITMQ_PORT", "5672")),
            "username": env("RABBITMQ_USER", "guest"),
            "password": env("RABBITMQ_PASS", "guest"),
            "virtual_host": env("RABBITMQ_VHOST", "/"),
        }

    def run_forever(self) -> None:
        self.start_observability()
        while True:
            try:
                self.run_once()
            except Exception as exc:
                self.health.mark_not_ready("amqp_disconnected", exc)
                self.metrics.inc("consumer_restarts_total")
                log_json("satellite_consumer_error", satellite=self.name, **exception_fields(exc))
                time.sleep(5)

    def run_once(self) -> None:
        pika = _pika()
        self.start_observability()
        self.health.mark_not_ready("connecting")
        credentials = pika.PlainCredentials(self.rabbit["username"], self.rabbit["password"])
        params = pika.ConnectionParameters(
            host=self.rabbit["host"],
            port=self.rabbit["port"],
            virtual_host=self.rabbit["virtual_host"],
            credentials=credentials,
            heartbeat=30,
            blocked_connection_timeout=30,
        )
        connection = pika.BlockingConnection(params)
        channel = connection.channel()
        self.declare_topology(channel)
        channel.basic_qos(prefetch_count=self.prefetch)
        channel.basic_consume(queue=self.queue, on_message_callback=self.handle_delivery)
        self.health.mark_ready("consuming")
        log_json(
            "satellite_consuming",
            satellite=self.name,
            queue=self.queue,
            topics=sorted(self.topics),
            connector_ids=sorted(self.connector_ids) or ["*"],
            rabbitmq_host=self.rabbit["host"],
        )
        try:
            channel.start_consuming()
        finally:
            self.health.mark_not_ready("consumer_stopped")
            try:
                connection.close()
            except Exception:
                pass

    def declare_topology(self, channel: Any) -> None:
        channel.exchange_declare(exchange="Chronicle.Events", exchange_type="headers", durable=True)
        channel.exchange_declare(exchange="Chronicle.Realm.Any", exchange_type="topic", durable=True)
        channel.exchange_declare(exchange=self.transport_retry_exchange, exchange_type="direct", durable=True)
        channel.exchange_declare(exchange=self.transport_dead_letter_exchange, exchange_type="direct", durable=True)
        channel.exchange_bind(
            destination="Chronicle.Realm.Any",
            source="Chronicle.Events",
            arguments={"Chronicle.Realm.Any": "True"},
        )
        channel.queue_declare(
            queue=self.queue,
            durable=True,
            arguments={"x-queue-mode": "lazy"},
        )
        channel.queue_bind(
            queue=self.queue,
            exchange="Chronicle.Realm.Any",
            routing_key=f"{REQUESTED_TYPE}.#.#",
        )
        self.declare_connector_dead_letter_queue(channel, "unknown")
        for connector_id in sorted(self.connector_ids):
            self.declare_connector_dead_letter_queue(channel, connector_id)
            for attempt in range(1, max(0, self.transport_default_max_retries) + 1):
                self.declare_retry_delay_queue(channel, connector_id, attempt)

    def handle_delivery(self, channel, method, properties, body: bytes) -> None:
        started = time.monotonic()
        context: Dict[str, Any] = {}
        if properties.type != REQUESTED_TYPE:
            self.metrics.inc("skipped_messages_total")
            log_json("satellite_delivery_skipped", reason="message_type", message_type=properties.type)
            channel.basic_ack(method.delivery_tag)
            return

        try:
            verify_or_raise(
                body,
                getattr(properties, "headers", None),
                message_type=properties.type,
                direction="incoming",
            )
            event = json.loads(body.decode("utf-8"))
        except Exception as exc:
            event = self.try_decode_event(body)
            context = self.log_context(event, properties) if event else {}
            self.handle_transport_failure(channel, method, properties, body, event, exc, context)
            return

        try:
            context = self.log_context(event, properties)
            self.metrics.inc("received_messages_total")
            self.health.heartbeat()
            log_json("satellite_delivery_received", satellite=self.name, **context)
            topic = str(snake_get(event, "Topic", "topic", default="")).strip().lower()
            connector_id = self.connector_id(event)
            if topic not in self.topics or not self.accepts_connector(connector_id):
                self.metrics.inc("skipped_messages_total")
                log_json(
                    "satellite_delivery_skipped",
                    satellite=self.name,
                    reason="topic_or_connector",
                    **context,
                )
                channel.basic_ack(method.delivery_tag)
                return
        except Exception as exc:
            self.handle_transport_failure(channel, method, properties, body, event, exc, context)
            return

        try:
            result_payload, result_meta = self.execute(event, topic)
        except Exception as exc:
            self.handle_business_failure(channel, method, properties, body, event, exc, started, context)
            return

        try:
            duration = time.monotonic() - started
            self.metrics.inc("completed_tasks_total")
            self.metrics.observe_duration(duration)
            self.metrics.set("last_success_timestamp_seconds", time.time())
            log_json(
                "satellite_task_completed",
                satellite=self.name,
                duration_ms=round(duration * 1000, 3),
                executor=result_meta.get("executor"),
                **context,
            )
            self.publish_executed(channel, event, result_payload, result_meta)
            channel.basic_ack(method.delivery_tag)
        except Exception as exc:
            self.handle_transport_failure(channel, method, properties, body, event, exc, context)

    def handle_business_failure(
        self,
        channel: Any,
        method: Any,
        properties: Any,
        body: bytes,
        event: Dict[str, Any],
        exc: Exception,
        started: float,
        context: Dict[str, Any],
    ) -> None:
        duration = time.monotonic() - started
        self.metrics.inc("failed_tasks_total")
        self.metrics.observe_duration(duration)
        self.metrics.set("last_failure_timestamp_seconds", time.time())
        log_json(
            "satellite_task_failed",
            satellite=self.name,
            duration_ms=round(duration * 1000, 3),
            **context,
            **exception_fields(exc),
        )
        try:
            self.publish_failed(channel, event, exc)
            channel.basic_ack(method.delivery_tag)
        except Exception as publish_exc:
            self.handle_transport_failure(channel, method, properties, body, event, publish_exc, context)

    def handle_transport_failure(
        self,
        channel: Any,
        method: Any,
        properties: Any,
        body: bytes,
        event: Dict[str, Any],
        exc: Exception,
        context: Dict[str, Any],
    ) -> None:
        event = event or {}
        current_attempt = self.transport_retry_attempt(properties)
        retry_config = self.transport_retry_config(event)
        connector_id = self.connector_id(event) or "unknown"
        max_retries = retry_config["max_retries"]

        self.metrics.inc("transport_failures_total")
        log_json(
            "satellite_transport_failure",
            satellite=self.name,
            retry_attempt=current_attempt,
            max_retries=max_retries,
            **context,
            **exception_fields(exc),
        )

        try:
            if current_attempt < max_retries:
                next_attempt = current_attempt + 1
                delay_ms = self.transport_retry_delay_ms(retry_config, next_attempt)
                self.schedule_transport_retry(
                    channel,
                    method,
                    properties,
                    body,
                    event,
                    exc,
                    connector_id,
                    next_attempt,
                    max_retries,
                    delay_ms,
                )
                channel.basic_ack(method.delivery_tag)
                self.metrics.inc("transport_retries_total")
                log_json(
                    "satellite_transport_retry_scheduled",
                    satellite=self.name,
                    retry_attempt=next_attempt,
                    delay_ms=delay_ms,
                    **context,
                )
                return

            self.publish_transport_dead_letter(channel, method, properties, body, event, exc, connector_id, max_retries)
            channel.basic_ack(method.delivery_tag)
            self.metrics.inc("transport_dead_lettered_total")
            log_json(
                "satellite_transport_dead_lettered",
                satellite=self.name,
                retry_attempt=current_attempt,
                max_retries=max_retries,
                **context,
            )
        except Exception as retry_exc:
            self.metrics.inc("transport_retry_publish_failures_total")
            log_json(
                "satellite_transport_retry_publish_failed",
                satellite=self.name,
                **context,
                **exception_fields(retry_exc),
            )
            self.dead_letter_original(channel, method)

    def start_observability(self) -> None:
        if self.observability_server is not None or not env_flag("SATELLITE_OBSERVABILITY_ENABLED", "true"):
            return
        self.health.start_heartbeat(float(env("SATELLITE_HEARTBEAT_INTERVAL_SECONDS", "10")))
        host = env("SATELLITE_OBSERVABILITY_HOST", "0.0.0.0")
        port = int(env("SATELLITE_OBSERVABILITY_PORT", "8090"))
        labels = {
            "satellite": self.name,
            "queue": self.queue,
            "topics": ",".join(sorted(self.topics)),
            "connectors": ",".join(sorted(self.connector_ids)) or "*",
        }
        try:
            self.observability_server = start_observability_server(
                host=host,
                port=port,
                health=self.health,
                metrics=self.metrics,
                labels=labels,
            )
            log_json("satellite_observability_started", satellite=self.name, host=host, port=port)
        except OSError as exc:
            log_json("satellite_observability_start_failed", satellite=self.name, host=host, port=port, **exception_fields(exc))

    def execute(self, event: Dict[str, Any], topic: str) -> Tuple[Any, Dict[str, Any]]:
        properties = snake_get(event, "TaskProperties", "taskProperties", default={}) or {}
        data = snake_get(event, "Data", "data", default={}) or {}
        if not isinstance(data, dict):
            data = {"value": data}

        executor = self.executors.get(topic)
        if executor is None:
            raise ValueError(f"unsupported satellite topic {topic}")
        return executor(properties, data)

    def connector_id(self, event: Dict[str, Any]) -> str:
        connector = snake_get(event, "Connector", "connector", default={}) or {}
        task_properties = snake_get(event, "TaskProperties", "taskProperties", default={}) or {}
        task_connector = snake_get(task_properties, "Connector", "connector", default={}) or {}
        extensions = snake_get(task_properties, "Extensions", "extensions", default={}) or {}
        value = (
            snake_get(connector, "Id", "id", "Name", "name")
            or snake_get(task_connector, "Id", "id", "Name", "name")
            or snake_get(task_properties, "ConnectorId", "connectorId")
            or snake_get(extensions, "ConnectorId", "connectorId", "ConnectionId", "connectionId")
        )
        return str(value or "").strip().lower()

    def accepts_connector(self, connector_id: str) -> bool:
        return not self.connector_ids or connector_id in self.connector_ids

    def declare_connector_dead_letter_queue(self, channel: Any, connector_id: str) -> None:
        queue = self.dlq_queue_name(connector_id)
        channel.queue_declare(queue=queue, durable=True, arguments={"x-queue-mode": "lazy"})
        channel.queue_bind(
            queue=queue,
            exchange=self.transport_dead_letter_exchange,
            routing_key=self.dlq_routing_key(connector_id),
        )

    def declare_retry_delay_queue(self, channel: Any, connector_id: str, attempt: int) -> str:
        queue = self.retry_queue_name(connector_id, attempt)
        channel.queue_declare(
            queue=queue,
            durable=True,
            arguments={
                "x-queue-mode": "lazy",
                "x-dead-letter-exchange": "",
                "x-dead-letter-routing-key": self.queue,
            },
        )
        channel.queue_bind(
            queue=queue,
            exchange=self.transport_retry_exchange,
            routing_key=self.retry_routing_key(connector_id, attempt),
        )
        return queue

    def schedule_transport_retry(
        self,
        channel: Any,
        method: Any,
        properties: Any,
        body: bytes,
        event: Dict[str, Any],
        exc: Exception,
        connector_id: str,
        attempt: int,
        max_retries: int,
        delay_ms: int,
    ) -> None:
        self.declare_retry_delay_queue(channel, connector_id, attempt)
        headers = self.transport_headers(properties, event, exc, connector_id, attempt, max_retries)
        retry_properties = self.copy_properties(properties, headers=headers, expiration=str(max(0, delay_ms)))
        channel.basic_publish(
            exchange=self.transport_retry_exchange,
            routing_key=self.retry_routing_key(connector_id, attempt),
            body=body,
            properties=retry_properties,
        )

    def publish_transport_dead_letter(
        self,
        channel: Any,
        method: Any,
        properties: Any,
        body: bytes,
        event: Dict[str, Any],
        exc: Exception,
        connector_id: str,
        max_retries: int,
    ) -> None:
        current_attempt = self.transport_retry_attempt(properties)
        self.declare_connector_dead_letter_queue(channel, connector_id)
        headers = self.transport_headers(properties, event, exc, connector_id, current_attempt, max_retries)
        headers["Chronicle.TransportRetry.Final"] = True
        headers["Chronicle.TransportRetry.DeadLettered"] = "true"
        dlq_properties = self.copy_properties(properties, headers=headers, expiration=None)
        channel.basic_publish(
            exchange=self.transport_dead_letter_exchange,
            routing_key=self.dlq_routing_key(connector_id),
            body=body,
            properties=dlq_properties,
        )

    def dead_letter_original(self, channel: Any, method: Any) -> None:
        if hasattr(channel, "basic_nack"):
            channel.basic_nack(method.delivery_tag, requeue=False)
            return
        channel.basic_reject(method.delivery_tag, requeue=False)

    def transport_headers(
        self,
        properties: Any,
        event: Dict[str, Any],
        exc: Exception,
        connector_id: str,
        attempt: int,
        max_retries: int,
    ) -> Dict[str, Any]:
        headers = dict(getattr(properties, "headers", None) or {})
        headers[TRANSPORT_RETRY_ATTEMPT_HEADER] = str(attempt)
        headers[TRANSPORT_RETRY_MAX_HEADER] = str(max_retries)
        headers[TRANSPORT_RETRY_ERROR_HEADER] = str(exc)
        headers[TRANSPORT_RETRY_ERROR_TYPE_HEADER] = exc.__class__.__name__
        headers[TRANSPORT_RETRY_CONNECTOR_HEADER] = self.connector_id(event) or connector_id or "unknown"
        return headers

    def copy_properties(self, properties: Any, *, headers: Dict[str, Any], expiration: Optional[str]) -> Any:
        values = {
            "content_type": getattr(properties, "content_type", "application/json"),
            "content_encoding": getattr(properties, "content_encoding", None),
            "headers": headers,
            "delivery_mode": getattr(properties, "delivery_mode", 2),
            "priority": getattr(properties, "priority", None),
            "correlation_id": getattr(properties, "correlation_id", None),
            "reply_to": getattr(properties, "reply_to", None),
            "expiration": expiration,
            "message_id": getattr(properties, "message_id", None),
            "timestamp": getattr(properties, "timestamp", None),
            "type": getattr(properties, "type", REQUESTED_TYPE),
            "user_id": getattr(properties, "user_id", None),
            "app_id": getattr(properties, "app_id", None),
            "cluster_id": getattr(properties, "cluster_id", None),
        }
        try:
            return _pika().BasicProperties(**values)
        except Exception:
            return SimpleNamespace(**values)

    def transport_retry_attempt(self, properties: Any) -> int:
        headers = getattr(properties, "headers", None) or {}
        return max(0, as_int(headers.get(TRANSPORT_RETRY_ATTEMPT_HEADER), 0))

    def transport_retry_config(self, event: Dict[str, Any]) -> Dict[str, Any]:
        metadata = self.execution_metadata(event)
        nested = first_dict(
            snake_get(metadata, "TransportRetry", "transportRetry", default=None),
            snake_get(metadata, "Transport", "transport", default=None),
            snake_get(metadata, "Retry", "retry", default=None),
        )
        max_retries = first_present(
            snake_get(metadata, "MaxTransportRetries", "maxTransportRetries", default=None),
            snake_get(metadata, "TransportMaxRetries", "transportMaxRetries", default=None),
            snake_get(metadata, "MaxTransportRetryAttempts", "maxTransportRetryAttempts", default=None),
            snake_get(metadata, "TransportRetryMaxAttempts", "transportRetryMaxAttempts", default=None),
            snake_get(nested, "MaxRetries", "maxRetries", "MaxAttempts", "maxAttempts", default=None),
        )
        base_delay_ms = first_present(
            snake_get(metadata, "TransportRetryBaseDelayMs", "transportRetryBaseDelayMs", default=None),
            snake_get(metadata, "TransportRetryDelayMs", "transportRetryDelayMs", default=None),
            snake_get(nested, "BaseDelayMs", "baseDelayMs", "DelayMs", "delayMs", "BackoffMs", "backoffMs", default=None),
        )
        max_delay_ms = first_present(
            snake_get(metadata, "TransportRetryMaxDelayMs", "transportRetryMaxDelayMs", default=None),
            snake_get(nested, "MaxDelayMs", "maxDelayMs", "MaxBackoffMs", "maxBackoffMs", default=None),
        )
        jitter = first_present(
            snake_get(metadata, "TransportRetryJitter", "transportRetryJitter", default=None),
            snake_get(nested, "Jitter", "jitter", default=None),
        )
        jitter_ratio = first_present(
            snake_get(metadata, "TransportRetryJitterRatio", "transportRetryJitterRatio", default=None),
            snake_get(nested, "JitterRatio", "jitterRatio", default=None),
        )

        return {
            "max_retries": clamp(as_int(max_retries, self.transport_default_max_retries), 0, 100),
            "base_delay_ms": max(0, as_int(base_delay_ms, self.transport_retry_base_delay_ms)),
            "max_delay_ms": max(0, as_int(max_delay_ms, self.transport_retry_max_delay_ms)),
            "jitter": as_bool(jitter, self.transport_retry_jitter),
            "jitter_ratio": max(0.0, min(1.0, as_float(jitter_ratio, 0.2))),
        }

    def execution_metadata(self, event: Dict[str, Any]) -> Dict[str, Any]:
        task_properties = snake_get(event, "TaskProperties", "taskProperties", default={}) or {}
        extensions = snake_get(task_properties, "Extensions", "extensions", default={}) or {}
        merged: Dict[str, Any] = {}
        for value in [
            snake_get(extensions, "Execution", "execution", default=None),
            snake_get(task_properties, "Execution", "execution", default=None),
            snake_get(event, "Execution", "execution", default=None),
        ]:
            if isinstance(value, dict):
                merged.update(value)
        return merged

    def transport_retry_delay_ms(self, retry_config: Dict[str, Any], attempt: int) -> int:
        base_delay_ms = retry_config["base_delay_ms"]
        max_delay_ms = retry_config["max_delay_ms"]
        delay_ms = min(max_delay_ms, base_delay_ms * (2 ** max(0, attempt - 1)))
        if retry_config["jitter"] and delay_ms > 0:
            delay_ms += int(random.uniform(0, delay_ms * retry_config["jitter_ratio"]))
        return int(delay_ms)

    def retry_queue_name(self, connector_id: str, attempt: int) -> str:
        return f"{self.queue}.Retry.{self.safe_connector_id(connector_id)}.{attempt}"

    def dlq_queue_name(self, connector_id: str) -> str:
        return f"{self.queue}.DLQ.{self.safe_connector_id(connector_id)}"

    def dlq_routing_key(self, connector_id: str) -> str:
        return self.safe_connector_id(connector_id)

    def retry_routing_key(self, connector_id: str, attempt: int) -> str:
        return f"{self.safe_connector_id(connector_id)}.{attempt}"

    def safe_connector_id(self, connector_id: str) -> str:
        safe = re.sub(r"[^a-zA-Z0-9_.-]+", "_", str(connector_id or "unknown").strip().lower())
        safe = safe.strip("._-")
        return safe[:80] or "unknown"

    def try_decode_event(self, body: bytes) -> Dict[str, Any]:
        try:
            decoded = json.loads(body.decode("utf-8"))
            return decoded if isinstance(decoded, dict) else {}
        except Exception:
            return {}

    def log_context(self, event: Dict[str, Any], properties: Any = None) -> Dict[str, Any]:
        headers = getattr(properties, "headers", None) or {}
        return {
            "topic": str(snake_get(event, "Topic", "topic", default="")).strip().lower(),
            "external_task_id": snake_get(event, "ExternalTaskId", "externalTaskId"),
            "tenant_id": snake_get(event, "TenantId", "tenantId"),
            "correlation_id": (
                snake_get(event, "CorrelationId", "correlationId")
                or headers.get("Chronicle.CorrelationId")
                or headers.get("correlation_id")
            ),
            "connector_id": self.connector_id(event) or None,
        }

    def publish_executed(self, channel, requested: Dict[str, Any], payload: Any, result: Dict[str, Any]) -> None:
        tenant_id = snake_get(requested, "TenantId", "tenantId", default="00000000-0000-0000-0000-000000000000")
        body = {
            "ExternalTaskId": snake_get(requested, "ExternalTaskId", "externalTaskId"),
            "Payload": payload,
            "Result": result,
            "TenantId": tenant_id,
        }
        self.publish_event(channel, EXECUTED_TYPE, body, tenant_id, snake_get(requested, "CorrelationId", "correlationId"))

    def publish_failed(self, channel, requested: Dict[str, Any], exc: Exception) -> None:
        tenant_id = snake_get(requested, "TenantId", "tenantId", default="00000000-0000-0000-0000-000000000000")
        body = {
            "ExternalTaskId": snake_get(requested, "ExternalTaskId", "externalTaskId"),
            "Error": {
                "error_message": str(exc),
                "error_type": exc.__class__.__name__,
            },
            "Retries": 0,
            "TenantId": tenant_id,
        }
        self.publish_event(channel, FAILED_TYPE, body, tenant_id, snake_get(requested, "CorrelationId", "correlationId"))

    def publish_event(self, channel, message_type: str, body: Dict[str, Any], tenant_id: str, correlation_id: Optional[str]) -> None:
        pika = _pika()
        payload = json.dumps(body, separators=(",", ":")).encode("utf-8")
        headers = {
            "Chronicle.Realm.Any": "True",
            "Chronicle.CorrelationId": correlation_id or "",
        }
        headers.update(sign_headers(payload, message_type=message_type, direction="outgoing"))
        properties = pika.BasicProperties(
            type=message_type,
            content_type="application/json",
            delivery_mode=2,
            headers=headers,
        )
        routing_key = f"{message_type}.#.{tenant_id or '#'}"
        channel.basic_publish(
            exchange="Chronicle.Events",
            routing_key=routing_key,
            body=payload,
            properties=properties,
        )
        self.metrics.inc("published_events_total")
        log_json(
            "satellite_event_published",
            satellite=self.name,
            message_type=message_type,
            external_task_id=body.get("ExternalTaskId"),
            tenant_id=tenant_id,
            correlation_id=correlation_id,
        )


def _pika():
    import pika

    return pika


def first_present(*values: Any) -> Any:
    for value in values:
        if value is not None:
            return value
    return None


def first_dict(*values: Any) -> Dict[str, Any]:
    for value in values:
        if isinstance(value, dict):
            return value
    return {}


def as_int(value: Any, default: int) -> int:
    if value is None:
        return default
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def as_float(value: Any, default: float) -> float:
    if value is None:
        return default
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def as_bool(value: Any, default: bool) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in {"1", "true", "yes", "on"}


def clamp(value: int, minimum: int, maximum: int) -> int:
    return max(minimum, min(maximum, value))
