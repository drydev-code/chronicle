import sys
import types
import unittest
from pathlib import Path
from unittest.mock import patch


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from chronicle_satellite.ai.service import execute_ai_task  # noqa: E402


class AIServiceTests(unittest.TestCase):
    def test_http_provider_preserves_openai_compatible_path_and_metadata(self) -> None:
        calls = []

        def rest_executor(properties, data, executor_name):
            calls.append(properties)
            model = properties["body"]["model"]
            if model == "bad-model":
                raise RuntimeError("model unavailable")
            return (
                {
                    "choices": [{"message": {"content": "hello Ada"}, "finish_reason": "stop"}],
                    "usage": {"prompt_tokens": 4, "completion_tokens": 2, "total_tokens": 6},
                    "model": model,
                },
                {"executor": executor_name, "status": 200, "attempts": 1},
            )

        result, meta = execute_ai_task(
            {
                "endpoint": "https://example.test/v1/chat/completions",
                "extensions": {
                    "prompt": "Say hello to {{name}}",
                    "models": ["bad-model", "good-model"],
                    "resultPath": "text",
                },
            },
            {"name": "Ada"},
            rest_executor,
        )

        self.assertEqual(result, "hello Ada")
        self.assertEqual([call["body"]["model"] for call in calls], ["bad-model", "good-model"])
        self.assertEqual(calls[1]["body"]["messages"][0]["content"], "Say hello to Ada")
        self.assertEqual(calls[1]["extensions"]["retry"]["retries"], 2)
        self.assertTrue(calls[1]["extensions"]["retry"]["retryUnsafe"])
        self.assertEqual(meta["provider"], "http")
        self.assertEqual(meta["model"], "good-model")
        self.assertEqual(meta["tokens"], {"prompt": 4, "completion": 2, "total": 6})

    def test_structured_output_json_is_parsed_and_validated(self) -> None:
        def rest_executor(properties, data, executor_name):
            return (
                {
                    "choices": [{"message": {"content": '{"answer":"approved","score":7}'}}],
                    "model": "mock",
                },
                {"executor": executor_name, "status": 200},
            )

        result, meta = execute_ai_task(
            {
                "endpoint": "https://example.test/v1/chat/completions",
                "extensions": {
                    "model": "mock",
                    "prompt": "Classify {{ticket}}",
                    "resultPath": "json.answer",
                    "schema": {
                        "type": "object",
                        "required": ["answer", "score"],
                        "properties": {
                            "answer": {"type": "string"},
                            "score": {"type": "integer"},
                        },
                    },
                },
            },
            {"ticket": "A-1"},
            rest_executor,
        )

        self.assertEqual(result, "approved")
        self.assertEqual(meta["model"], "mock")

    def test_structured_output_rejects_invalid_json(self) -> None:
        def rest_executor(properties, data, executor_name):
            return (
                {"choices": [{"message": {"content": '{"answer": true}'}}], "model": "mock"},
                {"executor": executor_name, "status": 200},
            )

        with self.assertRaisesRegex(ValueError, "expected type string|schema validation"):
            execute_ai_task(
                {
                    "endpoint": "https://example.test/v1/chat/completions",
                    "extensions": {
                        "model": "mock",
                        "prompt": "Classify",
                        "schema": {
                            "type": "object",
                            "required": ["answer"],
                            "properties": {"answer": {"type": "string"}},
                        },
                    },
                },
                {},
                rest_executor,
            )

    def test_http_provider_config_builds_endpoint_and_bearer_auth(self) -> None:
        captured = {}

        def rest_executor(properties, data, executor_name):
            captured.update(properties)
            return (
                {"choices": [{"message": {"content": "ok"}}], "model": "mock"},
                {"executor": executor_name, "status": 200},
            )

        result, meta = execute_ai_task(
            {
                "extensions": {
                    "provider": "http",
                    "model": "mock",
                    "prompt": "Hello",
                    "providerConfig": {"baseUrl": "https://ai.example.test/v1", "apiKey": "secret"},
                    "resultPath": "text",
                }
            },
            {},
            rest_executor,
        )

        self.assertEqual(result, "ok")
        self.assertEqual(captured["endpoint"], "https://ai.example.test/v1/chat/completions")
        self.assertEqual(captured["extensions"]["auth"], {"type": "bearer", "token": "secret"})
        self.assertEqual(meta["provider"], "http")

    def test_litellm_embeddings_provider(self) -> None:
        fake = types.SimpleNamespace()
        captured = {}

        def embedding(**kwargs):
            captured.update(kwargs)
            return {
                "data": [{"embedding": [0.1, 0.2, 0.3]}],
                "usage": {"prompt_tokens": 3, "total_tokens": 3},
                "model": kwargs["model"],
            }

        fake.embedding = embedding
        fake.completion = lambda **kwargs: self.fail("completion should not be called")

        with patch.dict(sys.modules, {"litellm": fake}):
            result, meta = execute_ai_task(
                {
                    "extensions": {
                        "provider": "litellm",
                        "operation": "embeddings",
                        "model": "text-embedding-test",
                        "input": "Embed {{name}}",
                        "resultPath": "embeddings.0",
                        "providerConfig": {"apiKey": "secret", "baseUrl": "https://ai.example.test"},
                    }
                },
                {"name": "Ada"},
                self.unused_rest_executor,
            )

        self.assertEqual(result, [0.1, 0.2, 0.3])
        self.assertEqual(captured["input"], "Embed Ada")
        self.assertEqual(captured["api_key"], "secret")
        self.assertEqual(captured["api_base"], "https://ai.example.test")
        self.assertEqual(meta["provider"], "litellm")
        self.assertEqual(meta["tokens"], {"prompt": 3, "total": 3})

    def test_litellm_retries_rate_limits(self) -> None:
        fake = types.SimpleNamespace()
        attempts = {"count": 0}

        class RateLimitError(Exception):
            status_code = 429

        def completion(**kwargs):
            attempts["count"] += 1
            if attempts["count"] == 1:
                raise RateLimitError("rate limit")
            return {"choices": [{"message": {"content": "ok"}}], "model": kwargs["model"]}

        fake.completion = completion
        fake.embedding = lambda **kwargs: self.fail("embedding should not be called")

        with patch.dict(sys.modules, {"litellm": fake}), patch("chronicle_satellite.ai.service.time.sleep") as sleep:
            result, meta = execute_ai_task(
                {
                    "extensions": {
                        "provider": "litellm",
                        "model": "chat-test",
                        "prompt": "Hello",
                        "maxRetries": 1,
                    }
                },
                {},
                self.unused_rest_executor,
            )

        self.assertEqual(result["text"], "ok")
        self.assertEqual(attempts["count"], 2)
        sleep.assert_called_once()
        self.assertEqual(meta["model"], "chat-test")

    def unused_rest_executor(self, properties, data, executor_name):
        raise AssertionError("REST executor should not be called")


if __name__ == "__main__":
    unittest.main()
