import json
import importlib
import re
import sqlite3
from dataclasses import dataclass
from typing import Any, Dict, Iterable, List, Optional, Tuple, Union

from ..core import env, extension_value, render_template, shape_result, snake_get


Params = Union[List[Any], Tuple[Any, ...], Dict[str, Any]]

READ_ONLY_STATEMENTS = {"select", "with", "show", "describe", "desc", "explain", "pragma"}
WRITE_STATEMENTS = {
    "insert",
    "update",
    "delete",
    "merge",
    "replace",
    "truncate",
    "create",
    "alter",
    "drop",
    "grant",
    "revoke",
    "call",
    "exec",
    "execute",
}

DB_CONNECTION_CACHE: Dict[str, Tuple[str, Any]] = {}

ADAPTER_ALIASES = {
    "postgresql": "postgres",
    "postgresql+pgvector": "postgres",
    "postgres-pgvector": "postgres",
    "pg": "postgres",
    "pgvector": "postgres",
    "maria": "mysql",
    "mariadb": "mysql",
    "maria_db": "mysql",
    "mysql8": "mysql",
    "mysql-compatible": "mysql",
    "microsoft_sql_server": "mssql",
    "ms-sql": "mssql",
    "ms_sql": "mssql",
    "sqlserver": "mssql",
    "sql_server": "mssql",
    "sql-server": "mssql",
}

DEFAULT_PORTS = {
    "mysql": 3306,
    "postgres": 5432,
    "mssql": 1433,
}

DRIVER_IMPORT_NAMES = {
    "mysql": "pymysql",
    "postgres": "psycopg",
    "mssql": "pymssql",
    "sqlite": "sqlite3",
}

DRIVER_ALIASES = {
    "mariadb": "pymysql",
    "mysql": "pymysql",
    "postgres": "psycopg",
    "postgresql": "psycopg",
    "sqlserver": "pymssql",
    "mssql": "pymssql",
}

VECTOR_OPERATORS = {
    "cosine": "<=>",
    "cosine_distance": "<=>",
    "cosine-distance": "<=>",
    "l2": "<->",
    "euclidean": "<->",
    "euclidean_distance": "<->",
    "euclidean-distance": "<->",
    "inner": "<#>",
    "inner_product": "<#>",
    "inner-product": "<#>",
    "ip": "<#>",
    "max_inner_product": "<#>",
}


@dataclass
class SqlOperation:
    query: str
    params: Params
    procedure: Optional[str] = None
    operation: str = "sql"


def execute_database(properties: Dict[str, Any], data: Dict[str, Any]) -> Tuple[Any, Dict[str, Any]]:
    extensions = snake_get(properties, "extensions", "Extensions", default={}) or {}
    connector_id = connector_id_from_properties(properties, extensions)
    connection_id = connection_id_from_properties(connector_id, extensions)
    config = database_connection_config(connection_id)
    operation = database_operation(properties, data, extensions, adapter=config.get("adapter"))

    allow_write = truthy(
        extension_value(
            properties,
            "allowWrite",
            config.get("allowWrite", False) if not truthy(config.get("readOnly", False)) else False,
        )
    )
    ensure_sql_allowed(operation.query, allow_write, properties, config, procedure=operation.procedure)

    execution = run_sql(
        connector_id,
        config,
        operation.query,
        operation.params,
        procedure=operation.procedure,
        transaction_mode=str(extension_value(properties, "transactionMode", config.get("transactionMode", "autocommit"))),
    )
    result = {
        "columns": execution["columns"],
        "rows": [dict(zip(execution["columns"], row)) for row in execution["rows"]],
        "numRows": execution["numRows"],
        "rowCount": execution["numRows"],
    }
    shaped = shape_result(
        result,
        properties,
        "result",
        {
            "result": result,
            "rows": result["rows"],
            "first": result["rows"][0] if result["rows"] else None,
            "row": result["rows"][0] if result["rows"] else None,
            "scalar": next(iter(result["rows"][0].values())) if result["rows"] else None,
            "columns": result["columns"],
            "count": result["numRows"],
            "numrows": result["numRows"],
            "rowcount": result["rowCount"],
            "affected": {"numRows": result["numRows"], "rowCount": result["rowCount"]},
        },
    )
    return shaped, {
        "executor": "satellite_database",
        "connectorId": connector_id,
        "connectionId": connection_id,
        "adapter": config.get("adapter"),
        "operation": operation.operation,
    }


def database_operation(
    properties: Dict[str, Any],
    data: Dict[str, Any],
    extensions: Dict[str, Any],
    adapter: Optional[str] = None,
) -> SqlOperation:
    operation = normalize_operation_name(extension_value(properties, "operation") or extensions.get("operation") or "sql")
    if operation in {"select", "vectorsearch"}:
        return compile_portable_operation(operation, properties, data, extensions, adapter=adapter)

    procedure = (
        extension_value(properties, "procedure")
        or extension_value(properties, "procedureName")
        or extension_value(properties, "storedProcedure")
    )
    if operation in {"procedure", "call"}:
        procedure = procedure or extension_value(properties, "name") or extensions.get("name")

    query = extensions.get("query") or extensions.get("sql") or snake_get(properties, "body", "Body")
    raw_params = extensions.get("params") if "params" in extensions else extensions.get("parameters", [])
    params = normalize_params(render_template(raw_params, data))

    if procedure:
        procedure_name = str(render_template(procedure, data)).strip()
        if not procedure_name:
            raise ValueError("procedure name is required")
        if query:
            query = str(render_template(query, data))
        else:
            query = render_call_sql(procedure_name, params, adapter=adapter)
        return SqlOperation(query=query, params=params, procedure=procedure_name, operation="procedure")

    if not query:
        raise ValueError("query is required")
    return SqlOperation(query=str(render_template(query, data)), params=params, operation=operation)


def normalize_operation_name(operation: Any) -> str:
    normalized = str(operation or "sql").strip().lower()
    aliases = {
        "query": "sql",
        "raw": "sql",
        "rawsql": "sql",
        "raw_sql": "sql",
        "storedprocedure": "procedure",
        "stored_procedure": "procedure",
        "executeprocedure": "procedure",
        "execute_procedure": "procedure",
        "vector": "vectorsearch",
        "vector_search": "vectorsearch",
        "vector-search": "vectorsearch",
        "semanticsearch": "vectorsearch",
        "semantic_search": "vectorsearch",
    }
    return aliases.get(normalized.replace("-", "_"), aliases.get(normalized, normalized))


def normalize_adapter(adapter: Any) -> str:
    normalized = str(adapter or "mysql").strip().lower()
    return ADAPTER_ALIASES.get(normalized, normalized)


def compile_portable_operation(
    operation: str,
    properties: Dict[str, Any],
    data: Dict[str, Any],
    extensions: Dict[str, Any],
    adapter: Optional[str] = None,
) -> SqlOperation:
    spec = render_template(extensions.get(operation) or extensions, data)
    if not isinstance(spec, dict):
        raise ValueError(f"{operation} operation config must be an object")
    if operation == "select":
        return compile_select_operation(spec, adapter=adapter)
    if operation == "vectorsearch":
        return compile_vector_search_operation(spec, adapter)
    raise ValueError(f"unsupported database operation {operation}")


def compile_select_operation(spec: Dict[str, Any], adapter: Optional[str] = None) -> SqlOperation:
    table = require_identifier(spec.get("table") or spec.get("from"), "table")
    columns = render_columns(spec.get("columns") or spec.get("select") or ["*"])
    where_sql, where_params = render_where_clause(spec.get("where"))
    order_sql = render_order_by(spec.get("orderBy") or spec.get("order_by"))
    params: List[Any] = list(where_params)
    limit = spec.get("limit")
    offset = spec.get("offset")
    if normalize_adapter(adapter or "") == "mssql" and limit not in [None, ""] and offset in [None, ""]:
        query = f"SELECT TOP (?) {columns} FROM {table}{where_sql}{order_sql}"
        return SqlOperation(query=query, params=[int(limit), *params], operation="select")

    query = f"SELECT {columns} FROM {table}{where_sql}{order_sql}"
    if normalize_adapter(adapter or "") == "mssql" and offset not in [None, ""]:
        if not order_sql:
            query += " ORDER BY (SELECT 1)"
        query += " OFFSET ? ROWS"
        params.append(int(offset))
        if limit not in [None, ""]:
            query += " FETCH NEXT ? ROWS ONLY"
            params.append(int(limit))
        return SqlOperation(query=query, params=params, operation="select")

    if limit not in [None, ""]:
        query += " LIMIT ?"
        params.append(int(limit))
    if offset not in [None, ""]:
        query += " OFFSET ?"
        params.append(int(offset))
    return SqlOperation(query=query, params=params, operation="select")


def compile_vector_search_operation(spec: Dict[str, Any], adapter: Optional[str]) -> SqlOperation:
    if normalize_adapter(adapter or spec.get("adapter") or spec.get("provider") or "postgres") != "postgres":
        raise ValueError("vectorSearch currently requires PostgreSQL with pgvector")
    table = require_identifier(spec.get("table") or spec.get("from"), "table")
    vector_column = require_identifier(
        spec.get("vectorColumn") or spec.get("embeddingColumn") or spec.get("column") or "embedding",
        "vectorColumn",
    )
    vector = spec.get("vector") if "vector" in spec else spec.get("embedding", spec.get("queryVector"))
    if vector in [None, ""]:
        raise ValueError("vectorSearch requires vector")
    vector_param = pgvector_literal(vector)
    operator = vector_operator(spec.get("operator") or spec.get("metric") or spec.get("distance") or "cosine")
    distance_alias = require_identifier(spec.get("distanceAlias") or spec.get("scoreColumn") or "distance", "distanceAlias")
    columns = render_columns(spec.get("columns") or spec.get("select") or ["*"])
    where_sql, where_params = render_where_clause(spec.get("where"))
    limit = int(spec.get("limit") or spec.get("k") or spec.get("topK") or 10)
    distance_expr = f"{vector_column} {operator} ?::vector"
    query = (
        f"SELECT {columns}, {distance_expr} AS {distance_alias} "
        f"FROM {table}{where_sql} ORDER BY {distance_expr} LIMIT ?"
    )
    params = [vector_param, *where_params, vector_param, limit]
    return SqlOperation(query=query, params=params, operation="vectorSearch")


def render_columns(columns: Any) -> str:
    if columns == "*":
        return "*"
    if isinstance(columns, str):
        columns = [part.strip() for part in columns.split(",") if part.strip()]
    if not isinstance(columns, list) or not columns:
        raise ValueError("columns must be a non-empty list or comma-separated string")
    return ", ".join("*" if column == "*" else require_identifier(column, "column") for column in columns)


def render_where_clause(where: Any) -> Tuple[str, List[Any]]:
    if where in [None, "", {}]:
        return "", []
    if not isinstance(where, dict):
        raise ValueError("portable where clauses must be an object")
    parts = []
    params: List[Any] = []
    for raw_column, value in where.items():
        column = require_identifier(raw_column, "where column")
        if value is None:
            parts.append(f"{column} IS NULL")
        elif isinstance(value, list):
            if not value:
                parts.append("1 = 0")
            else:
                parts.append(f"{column} IN ({', '.join(['?'] * len(value))})")
                params.extend(value)
        else:
            parts.append(f"{column} = ?")
            params.append(value)
    return " WHERE " + " AND ".join(parts), params


def render_order_by(order_by: Any) -> str:
    if order_by in [None, "", []]:
        return ""
    items = order_by if isinstance(order_by, list) else [order_by]
    rendered = []
    for item in items:
        direction = "ASC"
        column = item
        if isinstance(item, dict):
            column = item.get("column") or item.get("field") or item.get("name")
            direction = str(item.get("direction") or item.get("dir") or "ASC").upper()
        elif isinstance(item, str):
            parts = item.strip().split()
            column = parts[0]
            if len(parts) > 1:
                direction = parts[1].upper()
        if direction not in {"ASC", "DESC"}:
            raise ValueError("orderBy direction must be ASC or DESC")
        rendered.append(f"{require_identifier(column, 'orderBy column')} {direction}")
    return " ORDER BY " + ", ".join(rendered)


def require_identifier(value: Any, label: str) -> str:
    identifier = str(value or "").strip()
    if not identifier:
        raise ValueError(f"{label} is required")
    parts = identifier.split(".")
    pattern = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
    for part in parts:
        unquoted = part.strip().strip("`\"[]")
        if not pattern.match(unquoted):
            raise ValueError(f"invalid SQL identifier for {label}: {identifier}")
    return ".".join(part.strip() for part in parts)


def vector_operator(metric: Any) -> str:
    normalized = str(metric or "cosine").strip().lower()
    operator = VECTOR_OPERATORS.get(normalized)
    if not operator:
        raise ValueError(f"unsupported vectorSearch operator {metric}")
    return operator


def pgvector_literal(vector: Any) -> str:
    if isinstance(vector, str):
        return vector
    if not isinstance(vector, list) or not vector:
        raise ValueError("vectorSearch vector must be a non-empty list or pgvector literal string")
    return json.dumps(vector, separators=(",", ":"))


def normalize_params(params: Any) -> Params:
    if params is None or params == "":
        return []
    if isinstance(params, str):
        params = json.loads(params)
    if isinstance(params, tuple):
        return params
    if isinstance(params, list):
        return params
    if isinstance(params, dict):
        return params
    raise ValueError("query params must be a list, tuple, or object")


def connector_id_from_properties(properties: Dict[str, Any], extensions: Dict[str, Any]) -> str:
    connector = snake_get(properties, "Connector", "connector", default={}) or {}
    connector_id = (
        snake_get(properties, "connectorId", "ConnectorId")
        or snake_get(connector, "id", "Id", "name", "Name")
        or extensions.get("connectorId")
        or extensions.get("connectionId")
        or snake_get(properties, "connectionId", "ConnectionId")
        or "default"
    )
    return str(connector_id)


def connection_id_from_properties(connector_id: str, extensions: Dict[str, Any]) -> str:
    return str(extensions.get("connectionId") or connector_id)


def database_connection_config(connector_id: str = "default") -> Dict[str, Any]:
    configs = parse_connection_configs(env("SATELLITE_DB_CONNECTIONS", ""))
    specific = parse_json_object(env(f"SATELLITE_DB_CONNECTION_{env_key(connector_id)}", ""))
    default_config = configs.get("default", {})
    connector_config = specific or configs.get(connector_id, {})
    config = {
        **default_env_config(),
        **default_config,
        **connector_config,
    }
    return normalize_connection_config(config)


def parse_connection_configs(raw: str) -> Dict[str, Dict[str, Any]]:
    if not raw:
        return {}
    parsed = json.loads(raw)
    if isinstance(parsed, dict):
        normalized = {}
        for key, value in parsed.items():
            if isinstance(value, dict):
                normalized[str(key)] = value
        return normalized
    if isinstance(parsed, list):
        normalized = {}
        for value in parsed:
            if not isinstance(value, dict):
                continue
            connector_id = value.get("id") or value.get("name") or value.get("connectorId") or value.get("connectionId")
            if connector_id:
                normalized[str(connector_id)] = value
        return normalized
    raise ValueError("SATELLITE_DB_CONNECTIONS must be a JSON object or list")


def parse_json_object(raw: str) -> Dict[str, Any]:
    if not raw:
        return {}
    parsed = json.loads(raw)
    if not isinstance(parsed, dict):
        raise ValueError("database connection env override must be a JSON object")
    return parsed


def default_env_config() -> Dict[str, Any]:
    return {
        "adapter": env("SATELLITE_DB_ADAPTER", env("SATELLITE_DB_PROVIDER", "mysql")),
        "host": env("DB_HOST", "db"),
        "port": env("DB_PORT", ""),
        "username": env("DB_USER", "root"),
        "password": env("DB_PASS", "root"),
        "database": env("DB_NAME", "chronicle_dev"),
        "pool": True,
    }


def normalize_connection_config(config: Dict[str, Any]) -> Dict[str, Any]:
    normalized = dict(config)
    adapter = normalize_adapter(normalized.get("adapter") or normalized.get("provider") or normalized.get("dialect") or "mysql")
    normalized["adapter"] = adapter
    if "server" in normalized and "host" not in normalized:
        normalized["host"] = normalized["server"]
    if "dbname" in normalized and "database" not in normalized:
        normalized["database"] = normalized["dbname"]
    if "user" in normalized and "username" not in normalized:
        normalized["username"] = normalized["user"]
    if "uid" in normalized and "username" not in normalized:
        normalized["username"] = normalized["uid"]
    if "pwd" in normalized and "password" not in normalized:
        normalized["password"] = normalized["pwd"]
    driver = normalized.get("driverImportName") or normalized.get("driverImport") or normalized.get("driver")
    normalized["driverImportName"] = normalize_driver_import_name(adapter, driver)
    if normalized["adapter"] == "sqlite":
        normalized["database"] = normalized.get("database") or normalized.get("path") or ":memory:"
        normalized.pop("port", None)
    else:
        if "port" not in normalized or normalized["port"] in [None, ""]:
            normalized["port"] = DEFAULT_PORTS.get(adapter, "")
        if normalized["port"] in [None, ""]:
            return normalized
        normalized["port"] = int(normalized["port"])
    return normalized


def normalize_driver_import_name(adapter: str, driver: Any = None) -> str:
    if driver not in [None, ""]:
        return DRIVER_ALIASES.get(str(driver).strip().lower(), str(driver).strip())
    return DRIVER_IMPORT_NAMES.get(adapter, adapter)


def run_sql(
    connector_id: Union[str, Dict[str, Any]],
    config: Any = None,
    query: Any = None,
    params: Any = None,
    procedure: Optional[str] = None,
    transaction_mode: str = "autocommit",
) -> Any:
    if isinstance(connector_id, dict):
        result = _run_sql(
            "default",
            normalize_connection_config(connector_id),
            str(config),
            normalize_params(query),
            procedure=procedure,
            transaction_mode=transaction_mode,
        )
        return result["rows"], result["columns"], result["numRows"]
    return _run_sql(
        connector_id,
        config,
        str(query),
        normalize_params(params),
        procedure=procedure,
        transaction_mode=transaction_mode,
    )


def _run_sql(
    connector_id: str,
    config: Dict[str, Any],
    query: str,
    params: Params,
    procedure: Optional[str] = None,
    transaction_mode: str = "autocommit",
) -> Dict[str, Any]:
    adapter = normalize_adapter(config.get("adapter", "mysql"))
    mode = normalize_transaction_mode(transaction_mode)
    conn = get_connection(connector_id, config)
    pooled = truthy(config.get("pool", True))
    configure_transaction(conn, adapter, mode)
    cursor = conn.cursor()
    try:
        if procedure:
            cursor = execute_procedure(cursor, adapter, procedure, params)
        else:
            translated, translated_params = translate_query(adapter, query, params)
            cursor.execute(translated, translated_params)
        rows = cursor.fetchall() if cursor.description else []
        columns = [description[0] for description in cursor.description or []]
        num_rows = cursor.rowcount if cursor.rowcount >= 0 else len(rows)
        finish_transaction(conn, adapter, mode, success=True)
        return {"rows": rows, "columns": columns, "numRows": num_rows}
    except Exception:
        finish_transaction(conn, adapter, mode, success=False)
        raise
    finally:
        try:
            cursor.close()
        except Exception:
            pass
        if not pooled:
            close_connection(conn)


def get_connection(connector_id: str, config: Dict[str, Any]) -> Any:
    if not truthy(config.get("pool", True)):
        return create_connection(config)
    fingerprint = connection_fingerprint(config)
    cached = DB_CONNECTION_CACHE.get(connector_id)
    if cached and cached[0] == fingerprint and connection_is_open(cached[1], normalize_adapter(config.get("adapter", "mysql"))):
        return cached[1]
    if cached:
        close_connection(cached[1])
    conn = create_connection(config)
    DB_CONNECTION_CACHE[connector_id] = (fingerprint, conn)
    return conn


def create_connection(config: Dict[str, Any]) -> Any:
    adapter = normalize_adapter(config.get("adapter", "mysql"))
    if adapter == "sqlite":
        conn = sqlite3.connect(config.get("database", ":memory:"))
        conn.isolation_level = None
        return conn
    if adapter == "mysql":
        driver = importlib.import_module(config.get("driverImportName") or DRIVER_IMPORT_NAMES[adapter])

        return driver.connect(
            host=config.get("host", "db"),
            port=int(config.get("port", 3306)),
            user=config.get("username") or config.get("user"),
            password=config.get("password"),
            database=config.get("database"),
            autocommit=True,
        )
    if adapter == "postgres":
        driver = importlib.import_module(config.get("driverImportName") or DRIVER_IMPORT_NAMES[adapter])

        return driver.connect(
            host=config.get("host", "db"),
            port=int(config.get("port", 5432)),
            user=config.get("username") or config.get("user"),
            password=config.get("password"),
            dbname=config.get("database"),
            autocommit=True,
        )
    if adapter == "mssql":
        driver = importlib.import_module(config.get("driverImportName") or DRIVER_IMPORT_NAMES[adapter])

        return driver.connect(
            server=config.get("host", "db"),
            port=str(config.get("port", 1433)),
            user=config.get("username") or config.get("user"),
            password=config.get("password"),
            database=config.get("database"),
            autocommit=True,
        )
    raise ValueError(f"unsupported database adapter {adapter}")


def close_cached_connections() -> None:
    for _, conn in list(DB_CONNECTION_CACHE.values()):
        close_connection(conn)
    DB_CONNECTION_CACHE.clear()


def close_connection(conn: Any) -> None:
    try:
        conn.close()
    except Exception:
        pass


def connection_fingerprint(config: Dict[str, Any]) -> str:
    pool_agnostic = {key: value for key, value in config.items() if key not in {"pool", "transactionMode"}}
    return json.dumps(pool_agnostic, sort_keys=True, default=str)


def connection_is_open(conn: Any, adapter: str) -> bool:
    if adapter == "sqlite":
        try:
            conn.execute("select 1")
            return True
        except Exception:
            return False
    closed = getattr(conn, "closed", None)
    if closed:
        return False
    ping = getattr(conn, "ping", None)
    if callable(ping):
        try:
            ping(reconnect=False)
        except TypeError:
            try:
                ping()
            except Exception:
                return False
        except Exception:
            return False
    return True


def normalize_transaction_mode(mode: str) -> str:
    normalized = str(mode or "autocommit").lower()
    if normalized in {"auto", "autocommit", "none"}:
        return "autocommit"
    if normalized in {"transaction", "commit", "tx"}:
        return "commit"
    if normalized in {"rollback", "dryrun", "dry_run", "test"}:
        return "rollback"
    raise ValueError(f"unsupported transactionMode {mode}")


def configure_transaction(conn: Any, adapter: str, mode: str) -> None:
    if adapter == "sqlite":
        conn.isolation_level = None
        if mode != "autocommit":
            conn.execute("BEGIN")
        return
    set_autocommit(conn, mode == "autocommit")


def set_autocommit(conn: Any, value: bool) -> None:
    autocommit = getattr(conn, "autocommit", None)
    if callable(autocommit):
        autocommit(value)
        return
    try:
        setattr(conn, "autocommit", value)
    except Exception:
        pass


def finish_transaction(conn: Any, adapter: str, mode: str, success: bool) -> None:
    if mode == "autocommit":
        return
    if success and mode == "commit":
        conn.commit()
    else:
        conn.rollback()
    if adapter != "sqlite":
        set_autocommit(conn, True)


def execute_procedure(cursor: Any, adapter: str, procedure: str, params: Params) -> Any:
    adapter = normalize_adapter(adapter)
    if adapter == "sqlite":
        raise ValueError("sqlite does not support stored procedures")
    if isinstance(params, dict):
        ordered_params = list(params.values())
    else:
        ordered_params = list(params)
    callproc = getattr(cursor, "callproc", None)
    if callable(callproc):
        callproc(procedure, ordered_params)
        return cursor
    call_sql = render_call_sql(procedure, ordered_params, adapter=adapter)
    translated, translated_params = translate_query(adapter, call_sql, ordered_params)
    cursor.execute(translated, translated_params)
    return cursor


def render_call_sql(procedure: str, params: Params, adapter: Optional[str] = None) -> str:
    procedure = require_identifier(procedure, "procedure")
    count = len(params) if not isinstance(params, dict) else len(params.keys())
    placeholders = ", ".join(["?"] * count)
    if normalize_adapter(adapter or "") == "mssql":
        return f"EXEC {procedure}" + (f" {placeholders}" if placeholders else "")
    return f"CALL {procedure}({placeholders})"


def translate_query(adapter: str, query: str, params: Params) -> Tuple[str, Params]:
    adapter = normalize_adapter(adapter)
    if adapter == "sqlite":
        return query, params
    if isinstance(params, dict):
        if count_qmarks(query):
            raise ValueError("named params cannot be used with ? placeholders")
        return translate_named_params(query), params
    translated = translate_positional_params(adapter, query)
    return translated, params


def translate_positional_params(adapter: str, query: str) -> str:
    adapter = normalize_adapter(adapter)
    translated = replace_qmark_placeholders(query, "%s")
    if adapter == "postgres":
        translated = re.sub(r"\$\d+", "%s", translated)
    return translated


def translate_named_params(query: str) -> str:
    if "%(" in query:
        return query
    return re.sub(r"(?<!:):([A-Za-z_][A-Za-z0-9_]*)", r"%(\1)s", query)


def replace_qmark_placeholders(query: str, replacement: str) -> str:
    output: List[str] = []
    quote: Optional[str] = None
    line_comment = False
    block_comment = False
    i = 0
    while i < len(query):
        char = query[i]
        nxt = query[i + 1] if i + 1 < len(query) else ""
        if line_comment:
            output.append(char)
            if char == "\n":
                line_comment = False
            i += 1
            continue
        if block_comment:
            output.append(char)
            if char == "*" and nxt == "/":
                output.append(nxt)
                block_comment = False
                i += 2
            else:
                i += 1
            continue
        if quote:
            output.append(char)
            if char == quote:
                if nxt == quote:
                    output.append(nxt)
                    i += 2
                    continue
                quote = None
            i += 1
            continue
        if char in {"'", '"', "`"}:
            quote = char
            output.append(char)
            i += 1
            continue
        if char == "-" and nxt == "-":
            line_comment = True
            output.extend([char, nxt])
            i += 2
            continue
        if char == "/" and nxt == "*":
            block_comment = True
            output.extend([char, nxt])
            i += 2
            continue
        output.append(replacement if char == "?" else char)
        i += 1
    return "".join(output)


def count_qmarks(query: str) -> int:
    return replace_qmark_placeholders(query, "\0").count("\0")


def ensure_sql_allowed(
    query: str,
    allow_write: bool,
    properties: Optional[Dict[str, Any]] = None,
    config: Optional[Dict[str, Any]] = None,
    procedure: Optional[str] = None,
) -> None:
    properties = properties or {}
    config = config or {}
    body = strip_trailing_semicolon(query.strip())
    if has_multiple_statements(body):
        raise ValueError("database service tasks allow only one SQL statement")
    statement = "call" if procedure else first_statement(body)
    allowed_statements = lower_set(
        extension_value(properties, "allowedStatements", None)
        or extension_value(properties, "allowStatements", None)
        or config.get("allowedStatements")
        or config.get("allowStatements")
    )
    if allowed_statements and statement not in allowed_statements:
        raise ValueError(f"SQL statement {statement} is not allowed for this connector")
    if not allow_write and statement not in READ_ONLY_STATEMENTS:
        raise ValueError("database service tasks are read-only unless allowWrite is true")

    allowed_tables = lower_set(
        extension_value(properties, "allowedTables", None)
        or extension_value(properties, "allowTables", None)
        or config.get("allowedTables")
        or config.get("allowTables")
    )
    denied_tables = lower_set(
        extension_value(properties, "deniedTables", None)
        or extension_value(properties, "denyTables", None)
        or config.get("deniedTables")
        or config.get("denyTables")
    )
    touched_tables = extract_table_names(body)
    if allowed_tables:
        disallowed = sorted(table for table in touched_tables if table not in allowed_tables)
        if disallowed:
            raise ValueError(f"SQL references tables outside connector policy: {', '.join(disallowed)}")
    denied = sorted(table for table in touched_tables if table in denied_tables)
    if denied:
        raise ValueError(f"SQL references denied tables: {', '.join(denied)}")


def strip_trailing_semicolon(query: str) -> str:
    stripped = query.rstrip()
    if stripped.endswith(";") and not has_multiple_statements(stripped[:-1]):
        return stripped[:-1].rstrip()
    return stripped


def has_multiple_statements(query: str) -> bool:
    return ";" in replace_semicolons_in_literals(query, "\0")


def replace_semicolons_in_literals(query: str, replacement: str) -> str:
    output: List[str] = []
    quote: Optional[str] = None
    line_comment = False
    block_comment = False
    i = 0
    while i < len(query):
        char = query[i]
        nxt = query[i + 1] if i + 1 < len(query) else ""
        if line_comment:
            output.append(replacement if char == ";" else char)
            if char == "\n":
                line_comment = False
            i += 1
            continue
        if block_comment:
            output.append(replacement if char == ";" else char)
            if char == "*" and nxt == "/":
                output.append(nxt)
                block_comment = False
                i += 2
            else:
                i += 1
            continue
        if quote:
            output.append(replacement if char == ";" else char)
            if char == quote:
                if nxt == quote:
                    output.append(nxt)
                    i += 2
                    continue
                quote = None
            i += 1
            continue
        if char in {"'", '"', "`"}:
            quote = char
            output.append(char)
            i += 1
            continue
        if char == "-" and nxt == "-":
            line_comment = True
            output.extend([char, nxt])
            i += 2
            continue
        if char == "/" and nxt == "*":
            block_comment = True
            output.extend([char, nxt])
            i += 2
            continue
        output.append(char)
        i += 1
    return "".join(output)


def first_statement(query: str) -> str:
    cleaned = re.sub(r"^\s*(?:--[^\n]*\n|/\*.*?\*/\s*)+", "", query, flags=re.DOTALL)
    match = re.match(r"\s*([A-Za-z]+)", cleaned)
    return match.group(1).lower() if match else ""


def extract_table_names(query: str) -> set:
    stripped = strip_sql_comments(query)
    tables = set()
    patterns = [
        r"\bfrom\s+([A-Za-z_][\w.$\[\]`\"]*)",
        r"\bjoin\s+([A-Za-z_][\w.$\[\]`\"]*)",
        r"\bupdate\s+([A-Za-z_][\w.$\[\]`\"]*)",
        r"\binsert\s+into\s+([A-Za-z_][\w.$\[\]`\"]*)",
        r"\bdelete\s+from\s+([A-Za-z_][\w.$\[\]`\"]*)",
        r"\btruncate\s+table\s+([A-Za-z_][\w.$\[\]`\"]*)",
        r"\balter\s+table\s+([A-Za-z_][\w.$\[\]`\"]*)",
        r"\bdrop\s+table\s+([A-Za-z_][\w.$\[\]`\"]*)",
        r"\bcreate\s+table\s+(?:if\s+not\s+exists\s+)?([A-Za-z_][\w.$\[\]`\"]*)",
    ]
    for pattern in patterns:
        for match in re.finditer(pattern, stripped, flags=re.IGNORECASE):
            tables.add(normalize_table_name(match.group(1)))
    return {table for table in tables if table}


def strip_sql_comments(query: str) -> str:
    query = re.sub(r"/\*.*?\*/", " ", query, flags=re.DOTALL)
    query = re.sub(r"--[^\n]*", " ", query)
    return query


def normalize_table_name(raw: str) -> str:
    table = raw.strip().strip("`\"[]").lower()
    if "." in table:
        table = table.split(".")[-1].strip("`\"[]")
    return table


def lower_set(value: Any) -> set:
    if value in [None, ""]:
        return set()
    if isinstance(value, str):
        try:
            parsed = json.loads(value)
            if isinstance(parsed, list):
                value = parsed
            else:
                value = [part.strip() for part in value.split(",")]
        except Exception:
            value = [part.strip() for part in value.split(",")]
    if isinstance(value, Iterable):
        return {str(item).strip().lower() for item in value if str(item).strip()}
    return {str(value).strip().lower()}


def truthy(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    return str(value).lower() in {"true", "1", "yes", "y", "on"}


def env_key(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9]", "_", str(value)).upper()
