from ..app import ChronicleSatellite
from ..registry import email_transform_executors


DEFAULT_TOPICS = "email,mail,transform,echo,map"


def build_satellite() -> ChronicleSatellite:
    return ChronicleSatellite(
        email_transform_executors(),
        default_topics=DEFAULT_TOPICS,
        default_queue="Chronicle.Satellite.EmailTransform",
        name="Chronicle email/transform satellite",
    )


def main() -> None:
    build_satellite().run_forever()


if __name__ == "__main__":
    main()
