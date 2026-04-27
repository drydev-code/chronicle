import json
import os
import sys
import unittest
from pathlib import Path
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from chronicle_satellite.executors import database


class DatabaseExecutorTests(unittest.TestCase):
    def tearDown(self):
        database.close_cached_connections()

    def test_connector_specific_config_overrides_default(self):
        config = {
            "default": {"adapter": "sqlite", "database": ":memory:", "allowedTables": ["customers"]},
            "tenant-db": {"database": "tenant.sqlite", "allowedTables": ["orders"]},
        }
        with mock.patch.dict(os.environ, {"SATELLITE_DB_CONNECTIONS": json.dumps(config)}, clear=True):
            resolved = database.database_connection_config("tenant-db")

        self.assertEqual(resolved["adapter"], "sqlite")
        self.assertEqual(resolved["database"], "tenant.sqlite")
        self.assertEqual(resolved["allowedTables"], ["orders"])

    def test_provider_aliases_default_ports_and_driver_imports(self):
        cases = [
            ({"provider": "postgresql"}, "postgres", 5432, "psycopg"),
            ({"adapter": "pgvector"}, "postgres", 5432, "psycopg"),
            ({"adapter": "mariadb"}, "mysql", 3306, "pymysql"),
            ({"dialect": "microsoft_sql_server"}, "mssql", 1433, "pymssql"),
        ]

        for config, adapter, port, driver in cases:
            with self.subTest(config=config):
                resolved = database.normalize_connection_config(config)

                self.assertEqual(resolved["adapter"], adapter)
                self.assertEqual(resolved["port"], port)
                self.assertEqual(resolved["driverImportName"], driver)

    def test_connection_config_uses_adapter_specific_default_port_from_env(self):
        with mock.patch.dict(os.environ, {"SATELLITE_DB_ADAPTER": "postgres"}, clear=True):
            resolved = database.database_connection_config("default")

        self.assertEqual(resolved["adapter"], "postgres")
        self.assertEqual(resolved["port"], 5432)

    def test_sqlite_query_uses_connector_cache_and_result_modes(self):
        config = {"default": {"adapter": "sqlite", "database": ":memory:"}}
        with mock.patch.dict(os.environ, {"SATELLITE_DB_CONNECTIONS": json.dumps(config)}, clear=True):
            database.execute_database(
                {
                    "connectorId": "database-main",
                    "extensions": {
                        "connectionId": "default",
                        "query": "create table customers(id integer primary key, name text)",
                        "allowWrite": True,
                    },
                },
                {},
            )
            database.execute_database(
                {
                    "connectorId": "database-main",
                    "extensions": {
                        "connectionId": "default",
                        "query": "insert into customers(id, name) values(?, ?)",
                        "params": [1, "Ada"],
                        "allowWrite": True,
                    },
                },
                {},
            )
            result, meta = database.execute_database(
                {
                    "connectorId": "database-main",
                    "extensions": {
                        "connectionId": "default",
                        "query": "select name from customers where id = ?",
                        "params": [1],
                        "resultMode": "scalar",
                    },
                },
                {},
            )

        self.assertEqual(result, "Ada")
        self.assertEqual(meta["connectorId"], "database-main")
        self.assertEqual(meta["connectionId"], "default")
        self.assertEqual(meta["adapter"], "sqlite")

    def test_read_only_policy_blocks_writes_unless_allowed(self):
        with self.assertRaisesRegex(ValueError, "read-only"):
            database.ensure_sql_allowed("insert into customers(name) values('Ada')", allow_write=False)

        database.ensure_sql_allowed("insert into customers(name) values('Ada')", allow_write=True)

    def test_allowed_tables_policy_blocks_other_tables(self):
        properties = {"extensions": {"allowedTables": ["customers"]}}

        database.ensure_sql_allowed("select * from customers", allow_write=False, properties=properties)
        with self.assertRaisesRegex(ValueError, "outside connector policy"):
            database.ensure_sql_allowed("select * from invoices", allow_write=False, properties=properties)

    def test_allows_semicolon_inside_literals_but_not_multiple_statements(self):
        database.ensure_sql_allowed("select ';' as marker", allow_write=False)

        with self.assertRaisesRegex(ValueError, "only one SQL statement"):
            database.ensure_sql_allowed("select 1; select 2", allow_write=False)

    def test_transaction_rollback_mode_discards_write(self):
        config = {"default": {"adapter": "sqlite", "database": ":memory:"}}
        with mock.patch.dict(os.environ, {"SATELLITE_DB_CONNECTIONS": json.dumps(config)}, clear=True):
            database.execute_database(
                {
                    "extensions": {
                        "query": "create table audit(id integer)",
                        "allowWrite": True,
                    }
                },
                {},
            )
            database.execute_database(
                {
                    "extensions": {
                        "query": "insert into audit(id) values(?)",
                        "params": [1],
                        "allowWrite": True,
                        "transactionMode": "rollback",
                    }
                },
                {},
            )
            result, _ = database.execute_database(
                {
                    "extensions": {
                        "query": "select count(*) as count from audit",
                        "resultMode": "scalar",
                    }
                },
                {},
            )

        self.assertEqual(result, 0)

    def test_dialect_positional_param_translation(self):
        query = "select '?' as literal, name from users where id = ? and note = ?"

        for adapter in ["mysql", "mariadb", "postgres", "pg", "mssql", "sqlserver"]:
            with self.subTest(adapter=adapter):
                translated, params = database.translate_query(adapter, query, [1, "ok"])
                self.assertEqual(translated, "select '?' as literal, name from users where id = %s and note = %s")
                self.assertEqual(params, [1, "ok"])

        sqlite_query, _ = database.translate_query("sqlite", query, [1, "ok"])
        self.assertEqual(sqlite_query, query)

    def test_postgres_numbered_param_translation(self):
        translated, params = database.translate_query("postgres", "select * from users where id = $1 and name = ?", [7, "Ada"])

        self.assertEqual(translated, "select * from users where id = %s and name = %s")
        self.assertEqual(params, [7, "Ada"])

    def test_named_param_translation_for_server_dialects(self):
        translated, params = database.translate_query("postgres", "select * from users where id = :id", {"id": 7})

        self.assertEqual(translated, "select * from users where id = %(id)s")
        self.assertEqual(params, {"id": 7})

    def test_named_params_reject_qmark_placeholders(self):
        with self.assertRaisesRegex(ValueError, "named params"):
            database.translate_query("mysql", "select * from users where id = ?", {"id": 7})

    def test_portable_select_operation_compiles_query(self):
        extensions = {
            "operation": "select",
            "table": "users",
            "columns": ["id", "name"],
            "where": {"tenant_id": "acme", "status": ["active", "trial"], "deleted_at": None},
            "orderBy": [{"column": "created_at", "direction": "desc"}],
            "limit": 5,
            "offset": 10,
        }

        operation = database.database_operation({"extensions": extensions}, {}, extensions, adapter="postgres")

        self.assertEqual(
            operation.query,
            "SELECT id, name FROM users WHERE tenant_id = ? AND status IN (?, ?) AND deleted_at IS NULL "
            "ORDER BY created_at DESC LIMIT ? OFFSET ?",
        )
        self.assertEqual(operation.params, ["acme", "active", "trial", 5, 10])
        self.assertEqual(operation.operation, "select")

    def test_portable_select_operation_compiles_mssql_top(self):
        extensions = {
            "operation": "select",
            "table": "users",
            "columns": ["id"],
            "where": {"tenant_id": "acme"},
            "limit": 5,
        }

        operation = database.database_operation({"extensions": extensions}, {}, extensions, adapter="mssql")

        self.assertEqual(operation.query, "SELECT TOP (?) id FROM users WHERE tenant_id = ?")
        self.assertEqual(operation.params, [5, "acme"])
        translated, params = database.translate_query("mssql", operation.query, operation.params)
        self.assertEqual(translated, "SELECT TOP (%s) id FROM users WHERE tenant_id = %s")
        self.assertEqual(params, [5, "acme"])

    def test_portable_procedure_operation_compiles_mssql_exec(self):
        extensions = {"operation": "procedure", "name": "dbo.refresh_customer", "params": [42, "force"]}

        operation = database.database_operation({"extensions": extensions}, {}, extensions, adapter="mssql")

        self.assertEqual(operation.query, "EXEC dbo.refresh_customer ?, ?")
        self.assertEqual(operation.procedure, "dbo.refresh_customer")
        self.assertEqual(operation.params, [42, "force"])

    def test_procedure_uses_callproc_when_available(self):
        cursor = FakeProcedureCursor()

        returned = database.execute_procedure(cursor, "mysql", "refresh_customer", [42])

        self.assertIs(returned, cursor)
        self.assertEqual(cursor.called_with, ("refresh_customer", [42]))

    def test_procedure_fallback_uses_adapter_call_syntax(self):
        cursor = FakeExecuteCursor()

        database.execute_procedure(cursor, "mssql", "dbo.refresh_customer", [42])

        self.assertEqual(cursor.executed, ("EXEC dbo.refresh_customer %s", [42]))

    def test_postgres_vector_search_compiles_pgvector_operator(self):
        extensions = {
            "operation": "vectorSearch",
            "table": "documents",
            "columns": ["id", "title"],
            "vectorColumn": "embedding",
            "vector": [0.1, 0.2],
            "where": {"tenant_id": "acme"},
            "limit": 3,
            "operator": "cosine",
        }

        operation = database.database_operation({"extensions": extensions}, {}, extensions, adapter="postgres")

        self.assertEqual(
            operation.query,
            "SELECT id, title, embedding <=> ?::vector AS distance FROM documents WHERE tenant_id = ? "
            "ORDER BY embedding <=> ?::vector LIMIT ?",
        )
        self.assertEqual(operation.params, ["[0.1,0.2]", "acme", "[0.1,0.2]", 3])
        translated, translated_params = database.translate_query("postgres", operation.query, operation.params)
        self.assertEqual(
            translated,
            "SELECT id, title, embedding <=> %s::vector AS distance FROM documents WHERE tenant_id = %s "
            "ORDER BY embedding <=> %s::vector LIMIT %s",
        )
        self.assertEqual(translated_params, operation.params)

    def test_vector_search_operator_aliases(self):
        for metric, operator in [("l2", "<->"), ("inner-product", "<#>"), ("inner_product", "<#>")]:
            with self.subTest(metric=metric):
                compiled = database.compile_vector_search_operation(
                    {"table": "items", "vectorColumn": "embedding", "vector": [1, 2, 3], "metric": metric},
                    "pgvector",
                )

                self.assertIn(f"embedding {operator} ?::vector", compiled.query)

    def test_vector_search_rejects_non_postgres_adapter(self):
        with self.assertRaisesRegex(ValueError, "PostgreSQL"):
            database.compile_vector_search_operation(
                {"table": "items", "vectorColumn": "embedding", "vector": [1, 2, 3]},
                "mysql",
            )

    def test_run_sql_translates_query_for_fake_provider_cursor(self):
        conn = FakeConnection(FakeExecuteCursor(rows=[("Ada",)], columns=["name"]))
        config = database.normalize_connection_config({"adapter": "postgres", "pool": False})

        with mock.patch.object(database, "get_connection", return_value=conn):
            result = database._run_sql("default", config, "select name from users where id = ?", [1])

        self.assertEqual(result, {"rows": [("Ada",)], "columns": ["name"], "numRows": 1})
        self.assertEqual(conn.cursor_obj.executed, ("select name from users where id = %s", [1]))

    def test_legacy_run_sql_signature_returns_tuple(self):
        rows, columns, num_rows = database.run_sql(
            {"adapter": "sqlite", "database": ":memory:", "pool": False},
            "select ? as value",
            [5],
        )

        self.assertEqual(rows, [(5,)])
        self.assertEqual(columns, ["value"])
        self.assertEqual(num_rows, 1)


class FakeProcedureCursor:
    description = [("ok",)]
    rowcount = 1

    def __init__(self):
        self.called_with = None

    def callproc(self, name, params):
        self.called_with = (name, params)


class FakeExecuteCursor:
    def __init__(self, rows=None, columns=None):
        self.rows = rows or []
        self.description = [(column,) for column in columns] if columns else None
        self.rowcount = len(self.rows)
        self.executed = None
        self.closed = False

    def execute(self, query, params):
        self.executed = (query, params)

    def fetchall(self):
        return self.rows

    def close(self):
        self.closed = True


class FakeConnection:
    closed = False

    def __init__(self, cursor):
        self.cursor_obj = cursor
        self.autocommit = True
        self.committed = False
        self.rolled_back = False

    def cursor(self):
        return self.cursor_obj

    def commit(self):
        self.committed = True

    def rollback(self):
        self.rolled_back = True

    def close(self):
        self.closed = True


if __name__ == "__main__":
    unittest.main()
