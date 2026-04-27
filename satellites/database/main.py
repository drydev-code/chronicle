from chronicle_satellite.app import ChronicleSatellite
from chronicle_satellite.registry import database_executors


def build_satellite() -> ChronicleSatellite:
    return ChronicleSatellite(
        database_executors(),
        default_topics="database,db,sql",
        default_queue="Chronicle.Satellite.Database",
        name="Chronicle database satellite",
    )


def main() -> None:
    build_satellite().run_forever()


if __name__ == "__main__":
    main()
