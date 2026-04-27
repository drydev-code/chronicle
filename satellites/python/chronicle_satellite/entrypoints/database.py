from ..app import ChronicleSatellite
from ..registry import database_executors


DEFAULT_TOPICS = "database,db,sql"


def build_satellite() -> ChronicleSatellite:
    return ChronicleSatellite(
        database_executors(),
        default_topics=DEFAULT_TOPICS,
        default_queue="Chronicle.Satellite.Database",
        name="Chronicle database satellite",
    )


def main() -> None:
    build_satellite().run_forever()


if __name__ == "__main__":
    main()
