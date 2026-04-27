from ..app import ChronicleSatellite, DEFAULT_TOPICS
from ..registry import all_executors


def build_satellite() -> ChronicleSatellite:
    return ChronicleSatellite(all_executors(), default_topics=DEFAULT_TOPICS, name="Chronicle all-purpose satellite")


def main() -> None:
    build_satellite().run_forever()


if __name__ == "__main__":
    main()
