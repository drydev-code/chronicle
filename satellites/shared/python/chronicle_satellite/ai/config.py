from dataclasses import dataclass
from typing import Any, Dict, List, Optional

from ..core import env, extension_value, render_template, snake_get


@dataclass
class AIRequestConfig:
    provider: str
    operation: str
    body: Dict[str, Any]
    models: List[str]
    endpoint: Optional[str]
    result_path: Optional[str]
    schema: Any
    strict_schema: bool
    parse_json: bool
    timeout_ms: int
    max_retries: int
    retry_delay_ms: int
    provider_config: Dict[str, Any]

    @property
    def model(self) -> Optional[str]:
        return self.models[0] if self.models else None


def build_config(properties: Dict[str, Any], data: Dict[str, Any]) -> AIRequestConfig:
    extensions = snake_get(properties, "extensions", "Extensions", default={}) or {}
    provider = str(
        extension_value(properties, "provider")
        or env("CHRONICLE_AI_PROVIDER")
        or ("http" if snake_get(properties, "endpoint", "endPoint", "Endpoint", "EndPoint") else "litellm")
    ).strip().lower()
    if provider in ["openai", "openai_http", "openai-compatible", "openai_compatible", "rest"]:
        provider = "http"

    operation = str(
        extension_value(properties, "operation")
        or extension_value(properties, "task")
        or extension_value(properties, "mode")
        or ("embeddings" if extension_value(properties, "embedding") is True else "chat")
    ).strip().lower()
    if operation in ["completion", "chat_completion", "chat-completion"]:
        operation = "chat"
    if operation in ["embedding", "embed"]:
        operation = "embeddings"

    body = build_body(properties, data, operation)
    models = model_fallbacks(properties, body)
    if models and "model" not in body:
        body["model"] = models[0]

    schema = (
        extension_value(properties, "jsonSchema")
        or extension_value(properties, "responseSchema")
        or extension_value(properties, "schema")
        or extension_value(properties, "structuredOutput")
    )
    if isinstance(schema, str):
        schema = render_template(schema, data)
    strict_schema = bool(extension_value(properties, "strictSchema", True))
    parse_json = bool(extension_value(properties, "parseJson", schema is not None))

    provider_config = normalize_provider_config(render_template(extension_value(properties, "providerConfig", {}) or {}, data))
    for key in ["apiKey", "apiBase", "baseUrl", "organization", "project"]:
        value = extension_value(properties, key)
        if value not in [None, ""]:
            provider_config[key] = value
    api_key_env = extension_value(properties, "apiKeyEnv") or env("CHRONICLE_AI_API_KEY_ENV")
    if api_key_env and "apiKey" not in provider_config:
        provider_config["apiKey"] = env(str(api_key_env))
    if "apiKey" not in provider_config and env("CHRONICLE_AI_API_KEY"):
        provider_config["apiKey"] = env("CHRONICLE_AI_API_KEY")
    if "baseUrl" not in provider_config and env("CHRONICLE_AI_BASE_URL"):
        provider_config["baseUrl"] = env("CHRONICLE_AI_BASE_URL")
    endpoint = snake_get(properties, "endpoint", "endPoint", "Endpoint", "EndPoint") or provider_endpoint(provider_config, operation)

    return AIRequestConfig(
        provider=provider,
        operation=operation,
        body=body,
        models=models,
        endpoint=endpoint,
        result_path=extension_value(properties, "resultPath") or extension_value(properties, "result"),
        schema=schema,
        strict_schema=strict_schema,
        parse_json=parse_json,
        timeout_ms=int(extension_value(properties, "timeoutMs", 30000)),
        max_retries=int(extension_value(properties, "maxRetries", extension_value(properties, "retries", 2))),
        retry_delay_ms=int(extension_value(properties, "retryDelayMs", 250)),
        provider_config=provider_config,
    )


def build_body(properties: Dict[str, Any], data: Dict[str, Any], operation: str) -> Dict[str, Any]:
    raw_body = snake_get(properties, "body", "Body")
    if raw_body is not None:
        rendered = render_template(raw_body, data)
        return dict(rendered) if isinstance(rendered, dict) else {"input": rendered}

    body: Dict[str, Any] = {}
    for source, target in [
        ("model", "model"),
        ("temperature", "temperature"),
        ("maxTokens", "max_tokens"),
        ("topP", "top_p"),
        ("frequencyPenalty", "frequency_penalty"),
        ("presencePenalty", "presence_penalty"),
    ]:
        value = extension_value(properties, source)
        if value not in [None, ""]:
            body[target] = value

    response_format = extension_value(properties, "responseFormat")
    if response_format not in [None, ""]:
        body["response_format"] = render_template(response_format, data)

    schema = (
        extension_value(properties, "jsonSchema")
        or extension_value(properties, "responseSchema")
        or extension_value(properties, "schema")
    )
    if schema and "response_format" not in body and operation == "chat":
        rendered_schema = render_template(schema, data) if isinstance(schema, str) else schema
        body["response_format"] = {
            "type": "json_schema",
            "json_schema": {
                "name": str(extension_value(properties, "schemaName", "chronicle_response")),
                "schema": rendered_schema,
                "strict": bool(extension_value(properties, "strictSchema", True)),
            },
        }

    if operation == "embeddings":
        input_value = (
            extension_value(properties, "input")
            or extension_value(properties, "text")
            or extension_value(properties, "prompt")
        )
        body["input"] = render_template(input_value, data) if input_value is not None else data
        return body

    messages = extension_value(properties, "messages")
    prompt = extension_value(properties, "prompt")
    if isinstance(messages, list):
        body["messages"] = render_template(messages, data)
    elif prompt:
        body["messages"] = [{"role": "user", "content": render_template(prompt, data)}]
    else:
        body["input"] = data
    return body


def model_fallbacks(properties: Dict[str, Any], body: Dict[str, Any]) -> List[str]:
    configured = (
        extension_value(properties, "models")
        or extension_value(properties, "fallbackModels")
        or extension_value(properties, "modelFallbacks")
        or env("CHRONICLE_AI_MODEL_FALLBACKS")
    )
    values: List[str] = []
    if isinstance(configured, str):
        values.extend([part.strip() for part in configured.split(",") if part.strip()])
    elif isinstance(configured, list):
        values.extend([str(part).strip() for part in configured if str(part).strip()])

    single_model = body.get("model") or extension_value(properties, "model") or env("CHRONICLE_AI_MODEL")
    if single_model:
        values.insert(0, str(single_model).strip())

    deduped: List[str] = []
    for value in values:
        if value and value not in deduped:
            deduped.append(value)
    return deduped


def normalize_provider_config(raw: Any) -> Dict[str, Any]:
    if not isinstance(raw, dict):
        return {}
    return {str(key): value for key, value in raw.items() if value not in [None, ""]}


def provider_endpoint(provider_config: Dict[str, Any], operation: str) -> Optional[str]:
    base = provider_config.get("apiBase") or provider_config.get("baseUrl") or provider_config.get("api_base")
    if not base:
        return None
    endpoint = str(base).rstrip("/")
    known_suffixes = ["/chat/completions", "/embeddings"]
    if any(endpoint.endswith(suffix) for suffix in known_suffixes):
        return endpoint
    path = "embeddings" if operation == "embeddings" else "chat/completions"
    return f"{endpoint}/{path}"
