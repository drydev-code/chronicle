from typing import Dict

from .app import Executor


def rest_ai_executors() -> Dict[str, Executor]:
    from .executors.rest_ai import execute_ai, execute_rest

    return {
        "rest": execute_rest,
        "http": execute_rest,
        "https": execute_rest,
        "ai": execute_ai,
        "llm": execute_ai,
    }


def database_executors() -> Dict[str, Executor]:
    from .executors.database import execute_database

    return {
        "database": execute_database,
        "db": execute_database,
        "sql": execute_database,
    }


def email_transform_executors() -> Dict[str, Executor]:
    from .executors.email_transform import execute_email, execute_transform

    return {
        "email": execute_email,
        "mail": execute_email,
        "transform": execute_transform,
        "echo": execute_transform,
        "map": execute_transform,
    }


def all_executors() -> Dict[str, Executor]:
    return {
        **rest_ai_executors(),
        **database_executors(),
        **email_transform_executors(),
    }
