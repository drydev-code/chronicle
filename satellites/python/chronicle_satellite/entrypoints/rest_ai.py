from ..app import ChronicleSatellite
from ..registry import rest_ai_executors


DEFAULT_TOPICS = "rest,http,https,ai,llm"


def build_satellite() -> ChronicleSatellite:
    return ChronicleSatellite(
        rest_ai_executors(),
        default_topics=DEFAULT_TOPICS,
        default_queue="Chronicle.Satellite.RestAi",
        name="Chronicle REST/AI satellite",
    )


def main() -> None:
    build_satellite().run_forever()


if __name__ == "__main__":
    main()
