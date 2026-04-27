import datetime as dt
import hashlib
import hmac
import json
import random
import time
import uuid
from email.utils import parsedate_to_datetime
from typing import Any, Dict, Iterable, Optional, Tuple
from urllib.parse import parse_qsl, quote, urlencode, urlparse, urlsplit, urlunparse

import requests
from requests.auth import AuthBase, HTTPBasicAuth, HTTPDigestAuth

from ..ai import execute_ai_task
from ..ai.service import normalize_ai_response as service_normalize_ai_response
from ..core import env, extension_value, redact, render_template, result_path, shape_result, snake_get


OAUTH_TOKEN_CACHE: Dict[str, Tuple[str, float]] = {}
DEFAULT_RETRY_STATUSES = {408, 429, 500, 502, 503, 504}
IDEMPOTENT_METHODS = {"GET", "HEAD", "OPTIONS", "PUT", "DELETE", "TRACE"}


class RestConnectorError(RuntimeError):
    def __init__(
        self,
        category: str,
        message: str,
        *,
        status: Optional[int] = None,
        response: Optional[Dict[str, Any]] = None,
        retryable: bool = False,
        details: Optional[Dict[str, Any]] = None,
    ) -> None:
        self.category = category
        self.status = status
        self.response = response
        self.retryable = retryable
        self.details = details or {}
        super().__init__(message)

    def as_payload(self) -> Dict[str, Any]:
        payload = {
            "category": self.category,
            "message": str(self),
            "retryable": self.retryable,
        }
        if self.status is not None:
            payload["status"] = self.status
        if self.response is not None:
            payload["response"] = redact(self.response)
        if self.details:
            payload["details"] = redact(self.details)
        return payload


class AwsSigV4Auth(AuthBase):
    def __init__(
        self,
        *,
        access_key: str,
        secret_key: str,
        region: str,
        service: str,
        session_token: Optional[str] = None,
    ) -> None:
        if not access_key or not secret_key or not region or not service:
            raise ValueError("aws_sigv4 requires accessKeyId, secretAccessKey, region, and service")
        self.access_key = access_key
        self.secret_key = secret_key
        self.region = region
        self.service = service
        self.session_token = session_token

    def __call__(self, request):
        now = dt.datetime.now(dt.timezone.utc)
        amz_date = now.strftime("%Y%m%dT%H%M%SZ")
        date_stamp = now.strftime("%Y%m%d")
        parsed = urlsplit(request.url)
        body = request.body or b""
        if isinstance(body, str):
            body = body.encode("utf-8")
        elif not isinstance(body, bytes):
            body = bytes(body)

        payload_hash = hashlib.sha256(body).hexdigest()
        request.headers["Host"] = parsed.netloc
        request.headers["X-Amz-Date"] = amz_date
        request.headers["X-Amz-Content-Sha256"] = payload_hash
        if self.session_token:
            request.headers["X-Amz-Security-Token"] = self.session_token

        canonical_headers, signed_headers = self._canonical_headers(request.headers)
        credential_scope = f"{date_stamp}/{self.region}/{self.service}/aws4_request"
        canonical_request = "\n".join(
            [
                request.method.upper(),
                quote(parsed.path or "/", safe="/-_.~"),
                self._canonical_query(parsed.query),
                canonical_headers,
                signed_headers,
                payload_hash,
            ]
        )
        string_to_sign = "\n".join(
            [
                "AWS4-HMAC-SHA256",
                amz_date,
                credential_scope,
                hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
            ]
        )
        signing_key = self._signing_key(date_stamp)
        signature = hmac.new(signing_key, string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()
        request.headers["Authorization"] = (
            "AWS4-HMAC-SHA256 "
            f"Credential={self.access_key}/{credential_scope}, "
            f"SignedHeaders={signed_headers}, Signature={signature}"
        )
        return request

    def _signing_key(self, date_stamp: str) -> bytes:
        key = ("AWS4" + self.secret_key).encode("utf-8")
        for value in [date_stamp, self.region, self.service, "aws4_request"]:
            key = hmac.new(key, value.encode("utf-8"), hashlib.sha256).digest()
        return key

    def _canonical_headers(self, headers: Dict[str, str]) -> Tuple[str, str]:
        items = []
        for key, value in headers.items():
            if str(key).lower() == "authorization":
                continue
            normalized = " ".join(str(value).strip().split())
            items.append((str(key).lower(), normalized))
        items.sort(key=lambda item: item[0])
        canonical = "".join(f"{key}:{value}\n" for key, value in items)
        signed = ";".join(key for key, _ in items)
        return canonical, signed

    def _canonical_query(self, query: str) -> str:
        params = parse_qsl(query, keep_blank_values=True)
        encoded = [(quote(str(key), safe="-_.~"), quote(str(value), safe="-_.~")) for key, value in params]
        encoded.sort()
        return "&".join(f"{key}={value}" for key, value in encoded)


def execute_rest(properties: Dict[str, Any], data: Dict[str, Any], executor_name: str = "satellite_rest") -> Tuple[Any, Dict[str, Any]]:
    endpoint = snake_get(properties, "endpoint", "endPoint", "Endpoint", "EndPoint")
    if not endpoint:
        raise ValueError("endpoint is required")
    endpoint = str(render_template(endpoint, data))
    method = str(snake_get(properties, "method", "Method", default="POST")).upper()
    headers = normalize_headers(render_template(extension_value(properties, "headers", {}), data))
    auth = build_auth(properties, data, headers)
    endpoint = add_query_auth(endpoint, auth)
    body = snake_get(properties, "body", "Body")
    idempotency_key = apply_idempotency_key(headers, properties, data)

    request_kwargs: Dict[str, Any] = {
        "headers": headers,
        "timeout": build_timeout(properties),
    }
    request_auth = auth.get("request_auth") if isinstance(auth, dict) else None
    if request_auth is not None:
        request_kwargs["auth"] = request_auth
    request_kwargs.update(build_tls_config(properties))
    if method not in ["GET", "DELETE"]:
        rendered_body = render_template(body, data) if body is not None else data
        if isinstance(rendered_body, (dict, list)):
            request_kwargs["json"] = rendered_body
        else:
            request_kwargs["data"] = "" if rendered_body is None else str(rendered_body)

    response, attempts = send_with_retries(method, endpoint, request_kwargs, properties, idempotency_key)
    response_body = parse_response_body(response)
    response_payload = {
        "status": response.status_code,
        "reason": response.reason,
        "headers": dict(response.headers),
        "body": response_body,
        "url": response.url,
        "attempts": attempts,
    }
    if extension_value(properties, "failOnStatus", True) is not False and response.status_code >= 400:
        category = classify_status(response.status_code)
        raise RestConnectorError(
            category,
            f"HTTP request failed with status {response.status_code}: {redact(response_payload)}",
            status=response.status_code,
            response=response_payload,
            retryable=response.status_code in DEFAULT_RETRY_STATUSES,
        )

    shaped = shape_result(
        response_payload,
        properties,
        "response",
        {
            "body": response_body,
            "status": {"status": response.status_code, "reason": response.reason},
            "headers": dict(response.headers),
            "response": response_payload,
        },
    )
    return shaped, {"executor": executor_name, "status": response.status_code, "attempts": attempts}


def normalize_headers(raw: Any) -> Dict[str, str]:
    if isinstance(raw, dict):
        headers = {str(key): str(value) for key, value in raw.items()}
    elif isinstance(raw, list):
        headers = {}
        for item in raw:
            if isinstance(item, (list, tuple)) and len(item) == 2:
                key, value = item
                headers[str(key)] = str(value)
    else:
        headers = {}
    lowered = {key.lower() for key in headers}
    if "content-type" not in lowered:
        headers["content-type"] = "application/json"
    return headers


def build_auth(properties: Dict[str, Any], data: Dict[str, Any], headers: Dict[str, str]) -> Dict[str, Any]:
    auth = extension_value(properties, "auth", {}) or {}
    if not isinstance(auth, dict):
        auth = {"type": str(auth)}

    auth_type = str(auth.get("type") or extension_value(properties, "authType", "")).lower()
    bearer = auth.get("token") or extension_value(properties, "bearerToken")
    bearer_env = auth.get("tokenEnv") or extension_value(properties, "bearerTokenEnv")
    if bearer_env:
        bearer = env(str(bearer_env))
    if not auth_type and bearer:
        auth_type = "bearer"

    if auth_type in ["", "none"]:
        return {}
    if auth_type == "bearer":
        headers["authorization"] = f"Bearer {render_template(bearer, data)}"
        return {}
    if auth_type == "basic":
        username, password = username_password(auth)
        return {"request_auth": HTTPBasicAuth(username, password)}
    if auth_type == "digest":
        username, password = username_password(auth)
        return {"request_auth": HTTPDigestAuth(username, password)}
    if auth_type == "api_key":
        value = (
            auth.get("value")
            or env(str(auth.get("valueEnv", "")))
            or env(str(extension_value(properties, "apiKeyEnv", "")))
            or extension_value(properties, "apiKey")
        )
        location = str(auth.get("location", "header")).lower()
        name = auth.get("name") or ("x-api-key" if location == "header" else "api_key")
        if location == "query":
            return {"query": {name: value}}
        headers[str(name)] = str(value)
        return {}
    if auth_type in ["oauth2_client_credentials", "client_credentials"]:
        token = oauth2_client_credentials_token(auth, data)
        headers["authorization"] = f"Bearer {token}"
        return {}
    if auth_type in ["aws_sigv4", "sigv4", "aws4"]:
        return {"request_auth": build_aws_sigv4_auth(auth, data)}
    raise ValueError(f"unsupported REST auth type {auth_type}")


def username_password(auth: Dict[str, Any]) -> Tuple[str, str]:
    username = auth.get("username") or env(str(auth.get("usernameEnv", "")))
    password = auth.get("password") or env(str(auth.get("passwordEnv", "")))
    return str(username or ""), str(password or "")


def build_aws_sigv4_auth(auth: Dict[str, Any], data: Dict[str, Any]) -> AwsSigV4Auth:
    access_key = (
        auth.get("accessKeyId")
        or auth.get("access_key_id")
        or env(str(auth.get("accessKeyIdEnv", "")))
        or env("AWS_ACCESS_KEY_ID")
    )
    secret_key = (
        auth.get("secretAccessKey")
        or auth.get("secret_access_key")
        or env(str(auth.get("secretAccessKeyEnv", "")))
        or env("AWS_SECRET_ACCESS_KEY")
    )
    session_token = (
        auth.get("sessionToken")
        or auth.get("session_token")
        or env(str(auth.get("sessionTokenEnv", "")))
        or env("AWS_SESSION_TOKEN", "")
    )
    return AwsSigV4Auth(
        access_key=str(render_template(access_key, data) or ""),
        secret_key=str(render_template(secret_key, data) or ""),
        region=str(render_template(auth.get("region") or env(str(auth.get("regionEnv", ""))) or env("AWS_REGION"), data) or ""),
        service=str(render_template(auth.get("service") or auth.get("signingName") or "execute-api", data)),
        session_token=str(render_template(session_token, data)) if session_token else None,
    )


def oauth2_client_credentials_token(auth: Dict[str, Any], data: Dict[str, Any]) -> str:
    token_url = render_template(auth.get("tokenUrl") or auth.get("token_url"), data)
    client_id = auth.get("clientId") or auth.get("client_id") or env(str(auth.get("clientIdEnv", "")))
    client_secret = (
        auth.get("clientSecret")
        or auth.get("client_secret")
        or env(str(auth.get("clientSecretEnv", "")))
    )
    scope = auth.get("scope")
    audience = auth.get("audience")
    if not token_url or not client_id or not client_secret:
        raise ValueError("oauth2_client_credentials requires tokenUrl, clientId, and clientSecret")

    cache_key = json.dumps(
        {"tokenUrl": token_url, "clientId": client_id, "scope": scope, "audience": audience},
        sort_keys=True,
    )
    cached = OAUTH_TOKEN_CACHE.get(cache_key)
    now = time.time()
    if cached and cached[1] > now + 30:
        return cached[0]

    form = {
        "grant_type": "client_credentials",
        "client_id": client_id,
        "client_secret": client_secret,
    }
    if scope:
        form["scope"] = scope
    if audience:
        form["audience"] = audience

    token_headers = normalize_headers(auth.get("headers") or {})
    token_headers.pop("content-type", None)
    token_auth = None
    if str(auth.get("tokenAuth", "body")).lower() == "basic":
        token_auth = HTTPBasicAuth(str(client_id), str(client_secret))
        form.pop("client_id", None)
        form.pop("client_secret", None)

    response = requests.post(
        str(token_url),
        data=form,
        headers=token_headers or None,
        auth=token_auth,
        timeout=timeout_value(auth.get("timeoutMs"), 15000),
    )
    response.raise_for_status()
    payload = response.json()
    token = payload.get("access_token")
    if not token:
        raise ValueError("oauth2 token response did not include access_token")
    expires_in = int(payload.get("expires_in", 300))
    OAUTH_TOKEN_CACHE[cache_key] = (token, now + expires_in)
    return token


def add_query_auth(endpoint: str, auth: Dict[str, Any]) -> str:
    query = auth.get("query") if isinstance(auth, dict) else None
    if not query:
        return endpoint
    parsed = urlparse(endpoint)
    params = dict(parse_qsl(parsed.query))
    params.update({str(key): str(value) for key, value in query.items()})
    return urlunparse(parsed._replace(query=urlencode(params)))


def build_timeout(properties: Dict[str, Any]) -> Any:
    raw = extension_value(properties, "timeout", None)
    if isinstance(raw, dict):
        connect = raw.get("connectMs") or raw.get("connectTimeoutMs") or raw.get("connect")
        read = raw.get("readMs") or raw.get("readTimeoutMs") or raw.get("read")
        total = raw.get("totalMs") or raw.get("totalTimeoutMs") or raw.get("total")
        total_ms = raw_timeout_ms(total, 30000)
        connect_s = timeout_value(connect, total_ms)
        read_s = timeout_value(read, total_ms)
        return (connect_s, read_s)
    return timeout_value(extension_value(properties, "timeoutMs", raw), 30000)


def raw_timeout_ms(raw: Any, default_ms: Any) -> float:
    value = default_ms if raw in [None, ""] else raw
    try:
        number = float(value)
    except (TypeError, ValueError):
        raise ValueError(f"timeout must be numeric milliseconds, got {value!r}")
    if number <= 0:
        raise ValueError("timeout must be greater than zero")
    return number


def timeout_value(raw: Any, default_ms: Any) -> float:
    return raw_timeout_ms(raw, default_ms) / 1000


def build_tls_config(properties: Dict[str, Any]) -> Dict[str, Any]:
    tls = extension_value(properties, "tls", {}) or extension_value(properties, "mtls", {}) or {}
    if not isinstance(tls, dict):
        tls = {"verify": tls}
    mtls = tls.get("mtls") if isinstance(tls.get("mtls"), dict) else tls
    config: Dict[str, Any] = {}
    verify = (
        tls.get("verify")
        if "verify" in tls
        else tls.get("caBundle")
        or tls.get("caBundlePath")
        or tls.get("caCert")
        or tls.get("caCertPath")
        or extension_value(properties, "verifyTls", None)
    )
    if verify not in [None, ""]:
        config["verify"] = normalize_verify(verify)

    client_cert = (
        mtls.get("clientCert")
        or mtls.get("clientCertPath")
        or mtls.get("cert")
        or mtls.get("certPath")
        or extension_value(properties, "clientCert", None)
    )
    client_key = (
        mtls.get("clientKey")
        or mtls.get("clientKeyPath")
        or mtls.get("key")
        or mtls.get("keyPath")
        or extension_value(properties, "clientKey", None)
    )
    if client_cert and client_key:
        config["cert"] = (str(client_cert), str(client_key))
    elif client_cert:
        config["cert"] = str(client_cert)
    return config


def normalize_verify(value: Any) -> Any:
    if isinstance(value, bool):
        return value
    lowered = str(value).strip().lower()
    if lowered in ["true", "1", "yes"]:
        return True
    if lowered in ["false", "0", "no"]:
        return False
    return str(value)


def apply_idempotency_key(headers: Dict[str, str], properties: Dict[str, Any], data: Dict[str, Any]) -> Optional[str]:
    raw = extension_value(properties, "idempotency", None)
    header = "Idempotency-Key"
    value = extension_value(properties, "idempotencyKey", None)
    if isinstance(raw, dict):
        header = str(raw.get("header") or raw.get("headerName") or header)
        value = raw.get("key") if "key" in raw else raw.get("value", value)
    elif raw not in [None, False, ""]:
        value = raw
    if value in [None, False, ""]:
        return None
    key = str(uuid.uuid4()) if value is True else str(render_template(value, data))
    if not any(existing.lower() == header.lower() for existing in headers):
        headers[header] = key
    return key


def send_with_retries(
    method: str,
    endpoint: str,
    request_kwargs: Dict[str, Any],
    properties: Dict[str, Any],
    idempotency_key: Optional[str],
):
    policy = retry_policy(properties, method, idempotency_key)
    session = requests.Session()
    attempt = 0
    last_error: Optional[Exception] = None
    try:
        while attempt < policy["max_attempts"]:
            attempt += 1
            try:
                response = session.request(method, endpoint, **request_kwargs)
            except requests.Timeout as exc:
                last_error = exc
                if attempt >= policy["max_attempts"] or not policy["retry_exceptions"]:
                    raise RestConnectorError(
                        "timeout",
                        f"HTTP request timed out after {attempt} attempt(s): {exc}",
                        retryable=attempt < policy["max_attempts"],
                        details={"attempts": attempt, "url": endpoint},
                    ) from exc
                sleep_before_retry(policy, attempt, None)
                continue
            except requests.RequestException as exc:
                last_error = exc
                if attempt >= policy["max_attempts"] or not policy["retry_exceptions"]:
                    raise RestConnectorError(
                        "transport",
                        f"HTTP transport failed after {attempt} attempt(s): {exc}",
                        retryable=attempt < policy["max_attempts"],
                        details={"attempts": attempt, "url": endpoint},
                    ) from exc
                sleep_before_retry(policy, attempt, None)
                continue

            if attempt < policy["max_attempts"] and response.status_code in policy["statuses"]:
                sleep_before_retry(policy, attempt, response)
                continue
            return response, attempt

        raise RestConnectorError(
            "transport",
            f"HTTP transport failed after {attempt} attempt(s): {last_error}",
            details={"attempts": attempt, "url": endpoint},
        )
    finally:
        session.close()


def retry_policy(properties: Dict[str, Any], method: str, idempotency_key: Optional[str]) -> Dict[str, Any]:
    raw = extension_value(properties, "retry", {}) or {}
    if not isinstance(raw, dict):
        raw = {"maxAttempts": raw}
    if "maxAttempts" in raw or "attempts" in raw:
        max_attempts = int(raw.get("maxAttempts") or raw.get("attempts") or 1)
    elif "retries" in raw:
        max_attempts = int(raw.get("retries") or 0) + 1
    else:
        max_attempts = 1
    statuses = raw.get("statuses") or raw.get("statusCodes") or raw.get("retryOnStatus") or DEFAULT_RETRY_STATUSES
    allowed_methods = normalize_method_list(raw.get("methods"))
    if not allowed_methods:
        allowed_methods = set(IDEMPOTENT_METHODS)
        if idempotency_key or raw.get("retryUnsafe") is True:
            allowed_methods.add(method.upper())
    if method.upper() not in allowed_methods:
        max_attempts = 1
    return {
        "max_attempts": max(1, max_attempts),
        "statuses": normalize_status_list(statuses),
        "backoff_ms": int(raw.get("backoffMs") or raw.get("initialBackoffMs") or 250),
        "max_backoff_ms": int(raw.get("maxBackoffMs") or 5000),
        "jitter": raw.get("jitter", True) is not False,
        "retry_exceptions": raw.get("retryExceptions", True) is not False,
        "respect_retry_after": raw.get("respectRetryAfter", True) is not False,
    }


def normalize_method_list(raw: Any) -> Optional[set]:
    if raw in [None, ""]:
        return None
    if isinstance(raw, str):
        values = [part.strip() for part in raw.split(",")]
    elif isinstance(raw, Iterable):
        values = [str(part).strip() for part in raw]
    else:
        values = [str(raw).strip()]
    return {value.upper() for value in values if value}


def normalize_status_list(raw: Any) -> set:
    if isinstance(raw, str):
        values = [part.strip() for part in raw.split(",")]
    elif isinstance(raw, Iterable):
        values = [str(part).strip() for part in raw]
    else:
        values = [str(raw).strip()]
    return {int(value) for value in values if value}


def sleep_before_retry(policy: Dict[str, Any], attempt: int, response: Any) -> None:
    retry_after = retry_after_seconds(response) if policy["respect_retry_after"] else None
    if retry_after is None:
        delay_ms = min(policy["max_backoff_ms"], policy["backoff_ms"] * (2 ** max(0, attempt - 1)))
        if policy["jitter"]:
            delay_ms = random.randint(0, max(0, delay_ms))
        retry_after = delay_ms / 1000
    if retry_after > 0:
        time.sleep(retry_after)


def retry_after_seconds(response: Any) -> Optional[float]:
    if response is None:
        return None
    value = response.headers.get("retry-after")
    if not value:
        return None
    try:
        return max(0.0, float(value))
    except ValueError:
        try:
            parsed = parsedate_to_datetime(value)
            return max(0.0, (parsed - dt.datetime.now(parsed.tzinfo)).total_seconds())
        except Exception:
            return None


def parse_response_body(response: requests.Response) -> Any:
    content_type = response.headers.get("content-type", "")
    try:
        return response.json() if "json" in content_type.lower() else response.text
    except Exception:
        return response.text


def classify_status(status: int) -> str:
    if status in [401, 403]:
        return "auth"
    if status == 408:
        return "timeout"
    if status == 409:
        return "conflict"
    if status == 422:
        return "validation"
    if status == 429:
        return "rate_limited"
    if 500 <= status <= 599:
        return "upstream"
    return "http_status"


def execute_ai(properties: Dict[str, Any], data: Dict[str, Any]) -> Tuple[Any, Dict[str, Any]]:
    return execute_ai_task(properties, data, execute_rest)


def without_result_path(properties: Dict[str, Any]) -> Dict[str, Any]:
    copied = dict(properties)
    extensions = dict(snake_get(copied, "extensions", "Extensions", default={}) or {})
    extensions.pop("resultPath", None)
    extensions.pop("ResultPath", None)
    extensions.pop("result", None)
    extensions.pop("Result", None)
    copied["extensions"] = extensions
    copied["Extensions"] = extensions
    return copied


def normalize_ai_response(payload: Any) -> Any:
    return service_normalize_ai_response(payload)
