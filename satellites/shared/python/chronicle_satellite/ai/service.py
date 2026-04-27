import importlib
import time
from typing import Any, Callable, Dict, Tuple

from ..core import result_path, snake_get
from .config import AIRequestConfig, build_config
from .schema import attach_structured_output


RestExecutor = Callable[[Dict[str, Any], Dict[str, Any], str], Tuple[Any, Dict[str, Any]]]


def execute_ai_task(properties: Dict[str, Any], data: Dict[str, Any], rest_executor: RestExecutor) -> Tuple[Any, Dict[str, Any]]:
    config = build_config(properties, data)
    provider = LiteLLMProvider() if config.provider == "litellm" else OpenAICompatibleHttpProvider(rest_executor)
    payload, meta = provider.execute(properties, data, config)
    normalized = normalize_ai_response(payload, config.operation)
    if isinstance(normalized, dict):
        normalized = attach_structured_output(normalized, config.schema, config.parse_json, config.strict_schema)
        meta.update(ai_metadata(normalized, config, meta))
    return result_path(normalized, config.result_path), meta


class OpenAICompatibleHttpProvider:
    def __init__(self, rest_executor: RestExecutor) -> None:
        self.rest_executor = rest_executor

    def execute(self, properties: Dict[str, Any], data: Dict[str, Any], config: AIRequestConfig) -> Tuple[Any, Dict[str, Any]]:
        if not config.endpoint:
            raise ValueError("endpoint is required for OpenAI-compatible HTTP AI provider")

        last_error: Exception | None = None
        models = config.models or [None]
        for model in models:
            body = dict(config.body)
            if model:
                body["model"] = model
            try:
                payload, meta = self.rest_executor(with_ai_body(properties, body, config), data, "satellite_ai")
                meta.update({"provider": "http", "operation": config.operation})
                if model:
                    meta["model"] = model
                return payload, meta
            except Exception as exc:
                last_error = exc
        if last_error:
            raise last_error
        raise RuntimeError("AI HTTP provider did not execute any model")


class LiteLLMProvider:
    def execute(self, properties: Dict[str, Any], data: Dict[str, Any], config: AIRequestConfig) -> Tuple[Any, Dict[str, Any]]:
        litellm = self.import_litellm()
        if not config.models:
            raise ValueError("model is required for LiteLLM AI provider")

        last_error: Exception | None = None
        for model in config.models:
            body = dict(config.body)
            body["model"] = model
            try:
                response = self.with_retries(lambda: self.call(litellm, config, body), config)
                payload = to_plain_data(response)
                return payload, {"executor": "satellite_ai", "provider": "litellm", "operation": config.operation, "model": model}
            except Exception as exc:
                last_error = exc
        if last_error:
            raise last_error
        raise RuntimeError("LiteLLM provider did not execute any model")

    def import_litellm(self) -> Any:
        try:
            return importlib.import_module("litellm")
        except ImportError as exc:
            raise RuntimeError("LiteLLM provider requested but the litellm package is not installed") from exc

    def call(self, litellm: Any, config: AIRequestConfig, body: Dict[str, Any]) -> Any:
        kwargs = {**litellm_kwargs(config), **body, "timeout": config.timeout_ms / 1000}
        if config.operation == "embeddings":
            return litellm.embedding(**kwargs)
        return litellm.completion(**kwargs)

    def with_retries(self, call: Callable[[], Any], config: AIRequestConfig) -> Any:
        attempts = max(0, config.max_retries) + 1
        for index in range(attempts):
            try:
                return call()
            except Exception as exc:
                if index >= attempts - 1 or not is_retryable_exception(exc):
                    raise
                time.sleep((config.retry_delay_ms / 1000) * (2**index))


def with_ai_body(properties: Dict[str, Any], body: Dict[str, Any], config: AIRequestConfig) -> Dict[str, Any]:
    copied = dict(properties)
    extensions = dict(snake_get(copied, "extensions", "Extensions", default={}) or {})
    extensions.pop("resultPath", None)
    extensions.pop("ResultPath", None)
    extensions.pop("result", None)
    extensions.pop("Result", None)
    extensions.setdefault(
        "retry",
        {
            "retries": config.max_retries,
            "backoffMs": config.retry_delay_ms,
            "retryUnsafe": True,
            "statuses": [408, 409, 425, 429, 500, 502, 503, 504],
        },
    )
    api_key = config.provider_config.get("apiKey") or config.provider_config.get("api_key")
    if api_key and "auth" not in extensions and "Auth" not in extensions:
        extensions["auth"] = {"type": "bearer", "token": api_key}
    if config.endpoint and not any(key in copied for key in ["endpoint", "endPoint", "Endpoint", "EndPoint"]):
        copied["endpoint"] = config.endpoint
    copied["body"] = body
    copied["extensions"] = extensions
    copied["Extensions"] = extensions
    return copied


def litellm_kwargs(config: AIRequestConfig) -> Dict[str, Any]:
    aliases = {
        "apiKey": "api_key",
        "apiBase": "api_base",
        "baseUrl": "api_base",
    }
    kwargs: Dict[str, Any] = {}
    for key, value in config.provider_config.items():
        kwargs[aliases.get(key, key)] = value
    if config.endpoint and "api_base" not in kwargs:
        kwargs["api_base"] = config.endpoint
    return kwargs


def normalize_ai_response(payload: Any, operation: str = "chat") -> Any:
    payload = to_plain_data(payload)
    if not isinstance(payload, dict):
        return payload
    if operation == "embeddings" or "data" in payload and looks_like_embedding_payload(payload):
        return normalize_embedding_response(payload)

    choices = payload.get("choices")
    if isinstance(choices, list) and choices:
        first = choices[0]
        message = first.get("message") if isinstance(first, dict) else None
        text = None
        parsed = None
        if isinstance(message, dict):
            text = message.get("content")
            parsed = message.get("parsed")
        if text is None and isinstance(first, dict):
            text = first.get("text")
        normalized = {
            "text": text,
            "raw": payload,
            "usage": payload.get("usage"),
            "model": payload.get("model"),
            "finishReason": first.get("finish_reason") if isinstance(first, dict) else None,
        }
        if parsed is not None:
            normalized["json"] = parsed
        return normalized
    return payload


def normalize_embedding_response(payload: Dict[str, Any]) -> Dict[str, Any]:
    data = payload.get("data")
    embeddings = []
    if isinstance(data, list):
        embeddings = [item.get("embedding") for item in data if isinstance(item, dict) and "embedding" in item]
    return {
        "embeddings": embeddings,
        "raw": payload,
        "usage": payload.get("usage"),
        "model": payload.get("model"),
    }


def looks_like_embedding_payload(payload: Dict[str, Any]) -> bool:
    data = payload.get("data")
    return isinstance(data, list) and any(isinstance(item, dict) and "embedding" in item for item in data)


def ai_metadata(normalized: Dict[str, Any], config: AIRequestConfig, meta: Dict[str, Any]) -> Dict[str, Any]:
    usage = normalized.get("usage")
    model = normalized.get("model") or meta.get("model") or config.model
    extra: Dict[str, Any] = {"executor": "satellite_ai", "operation": config.operation}
    if model:
        extra["model"] = model
    if isinstance(usage, dict):
        extra["usage"] = usage
        tokens = token_metadata(usage)
        if tokens:
            extra["tokens"] = tokens
        cost = usage.get("cost") or usage.get("total_cost") or usage.get("cost_usd")
        if cost is not None:
            extra["cost"] = cost
    return extra


def token_metadata(usage: Dict[str, Any]) -> Dict[str, Any]:
    mapping = {
        "prompt": ["prompt_tokens", "input_tokens"],
        "completion": ["completion_tokens", "output_tokens"],
        "total": ["total_tokens"],
    }
    tokens: Dict[str, Any] = {}
    for target, keys in mapping.items():
        for key in keys:
            if key in usage:
                tokens[target] = usage[key]
                break
    return tokens


def to_plain_data(value: Any) -> Any:
    if isinstance(value, (dict, list, str, int, float, bool)) or value is None:
        return value
    if hasattr(value, "model_dump"):
        return value.model_dump()
    if hasattr(value, "dict"):
        return value.dict()
    if hasattr(value, "json"):
        try:
            import json

            return json.loads(value.json())
        except Exception:
            pass
    if hasattr(value, "__dict__"):
        return {key: to_plain_data(item) for key, item in vars(value).items() if not key.startswith("_")}
    return value


def is_retryable_exception(exc: Exception) -> bool:
    status = getattr(exc, "status_code", None) or getattr(exc, "code", None)
    if status in [408, 409, 425, 429, 500, 502, 503, 504]:
        return True
    name = exc.__class__.__name__.lower()
    message = str(exc).lower()
    return "rate" in name or "timeout" in name or "rate limit" in message or "temporarily" in message
