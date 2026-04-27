from typing import Any, Dict, List, Tuple

from ..core import extension_value, render_template, result_path, snake_get


def execute_transform(properties: Dict[str, Any], data: Dict[str, Any]) -> Tuple[Any, Dict[str, Any]]:
    template = snake_get(properties, "body", "Body") or extension_value(properties, "template") or extension_value(properties, "value")
    if template is None:
        payload = data
    else:
        payload = render_template(template, data)
    return payload, {"executor": "satellite_transform"}


def execute_email(properties: Dict[str, Any], data: Dict[str, Any]) -> Tuple[Any, Dict[str, Any]]:
    merged = {**(snake_get(properties, "extensions", "Extensions", default={}) or {}), **data}
    to = merged.get("to")
    subject = render_template(merged.get("subject"), data)
    body = render_template(merged.get("body"), data)
    if not to or not subject or body is None:
        raise ValueError("email requires to, subject, and body")
    email = {
        "to": normalize_recipients(to),
        "cc": normalize_recipients(merged.get("cc")),
        "bcc": normalize_recipients(merged.get("bcc")),
        "fromEmail": merged.get("fromEmail"),
        "subject": subject,
        "body": body,
        "isHtml": bool(merged.get("isHtml")),
        "attachments": merged.get("attachments") or [],
        "status": "prepared",
    }
    return result_path(email, extension_value(properties, "resultPath") or extension_value(properties, "result")), {"executor": "satellite_email"}


def normalize_recipients(value: Any) -> List[str]:
    if value is None:
        return []
    if isinstance(value, list):
        return [str(item).strip() for item in value if str(item).strip()]
    return [part.strip() for part in str(value).replace(";", ",").split(",") if part.strip()]
