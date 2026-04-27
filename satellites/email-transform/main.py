from chronicle_satellite.app import ChronicleSatellite
from chronicle_satellite.registry import email_transform_executors


def build_satellite() -> ChronicleSatellite:
    return ChronicleSatellite(
        email_transform_executors(),
        default_topics="email,mail,transform,echo,map",
        default_queue="Chronicle.Satellite.EmailTransform",
        name="Chronicle email/transform satellite",
    )


def main() -> None:
    build_satellite().run_forever()


if __name__ == "__main__":
    main()
