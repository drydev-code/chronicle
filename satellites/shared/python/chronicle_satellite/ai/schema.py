import json
from typing import Any, Dict, Optional


def attach_structured_output(normalized: Dict[str, Any], schema: Any, parse_json: bool, strict: bool) -> Dict[str, Any]:
    if not parse_json and schema is None:
        return normalized

    parsed = normalized.get("json")
    if parsed is None:
        parsed = parse_content(normalized.get("text"))

    if parsed is None:
        if schema is not None:
            raise ValueError("AI response did not contain valid JSON for structured output")
        return normalized

    if schema is not None:
        validate_json(parsed, schema, strict)
    normalized["json"] = parsed
    return normalized


def parse_content(value: Any) -> Optional[Any]:
    if isinstance(value, (dict, list)):
        return value
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        return json.loads(value)
    except Exception:
        return None


def validate_json(value: Any, schema: Any, strict: bool) -> None:
    if not isinstance(schema, dict):
        if strict:
            raise ValueError("structured output schema must be a JSON object")
        return

    try:
        import jsonschema  # type: ignore

        jsonschema.validate(value, schema)
        return
    except ImportError:
        validate_minimal(value, schema, "$")
    except Exception as exc:
        raise ValueError(f"AI structured output failed schema validation: {exc}") from exc


def validate_minimal(value: Any, schema: Dict[str, Any], path: str) -> None:
    expected_type = schema.get("type")
    if expected_type:
        expected_types = expected_type if isinstance(expected_type, list) else [expected_type]
        if not any(matches_type(value, item) for item in expected_types):
            raise ValueError(f"AI structured output field {path} expected type {expected_type}")

    enum = schema.get("enum")
    if enum is not None and value not in enum:
        raise ValueError(f"AI structured output field {path} is not one of the allowed enum values")

    if isinstance(value, dict):
        required = schema.get("required", [])
        for key in (required if isinstance(required, list) else []):
            if key not in value:
                raise ValueError(f"AI structured output missing required field {path}.{key}")
        properties = schema.get("properties", {})
        if isinstance(properties, dict):
            for key, child_schema in properties.items():
                if key in value and isinstance(child_schema, dict):
                    validate_minimal(value[key], child_schema, f"{path}.{key}")
    elif isinstance(value, list):
        items = schema.get("items")
        if isinstance(items, dict):
            for index, item in enumerate(value):
                validate_minimal(item, items, f"{path}[{index}]")


def matches_type(value: Any, expected: str) -> bool:
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "string":
        return isinstance(value, str)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "null":
        return value is None
    return True
