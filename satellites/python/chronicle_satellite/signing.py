import base64
import hashlib
import logging
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Dict, Iterable, List, Optional

from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding

from .core import env


SIGNATURE_HEADER = "Chronicle.Signature"
ALGORITHM_HEADER = "Chronicle.Signature.Algorithm"
FINGERPRINT_HEADER = "Chronicle.Signature.CertificateSha256"
ALGORITHM = "rsa-sha256"
LOGGER = logging.getLogger(__name__)


@dataclass(frozen=True)
class TrustedCertificate:
    path: str
    certificate: x509.Certificate
    fingerprint: str


def enabled() -> bool:
    return env("CHRONICLE_MESSAGE_SIGNING", env("AMQP_SIGNING_ENABLED", "false")).lower() == "true"


def require_signatures(message_type: Optional[str] = None, direction: str = "incoming") -> bool:
    if _truthy(env("CHRONICLE_REQUIRE_SIGNATURES", env("AMQP_REQUIRE_SIGNATURES", "false"))):
        return True

    normalized_type = (message_type or "").strip().lower()
    normalized_direction = (direction or "").strip().lower()

    required_directions = _csv(
        env("CHRONICLE_REQUIRE_SIGNATURE_DIRECTIONS", env("AMQP_REQUIRE_SIGNATURE_DIRECTIONS", ""))
    )
    if "*" in required_directions or "all" in required_directions or normalized_direction in required_directions:
        return True

    required_types = _csv(
        env("CHRONICLE_REQUIRE_SIGNATURE_MESSAGE_TYPES", env("AMQP_REQUIRE_SIGNATURE_MESSAGE_TYPES", ""))
    )
    return normalized_type != "" and any(
        required in ["*", "all"] or required == normalized_type or required in normalized_type
        for required in required_types
    )


def sign_headers(payload: bytes, message_type: Optional[str] = None, direction: str = "outgoing") -> Dict[str, str]:
    if not enabled():
        return {}

    key_path = env(
        "CHRONICLE_SIGNER_KEY",
        env("CHRONICLE_SIGNING_KEY", env("AMQP_SIGNER_PRIVATE_KEY_PATH", env("AMQP_SIGNING_PRIVATE_KEY_PATH"))),
    )
    cert_path = env(
        "CHRONICLE_SIGNER_CERT",
        env("CHRONICLE_SIGNING_CERT", env("AMQP_SIGNER_CERTIFICATE_PATH", env("AMQP_SIGNING_CERTIFICATE_PATH"))),
    )
    if not key_path:
        raise RuntimeError("message signing is enabled but no signing key path is configured")

    with open(key_path, "rb") as handle:
        private_key = serialization.load_pem_private_key(handle.read(), password=None)

    signature = private_key.sign(payload, padding.PKCS1v15(), hashes.SHA256())
    headers = {
        ALGORITHM_HEADER: ALGORITHM,
        SIGNATURE_HEADER: base64.b64encode(signature).decode("ascii"),
    }

    if cert_path:
        with open(cert_path, "rb") as handle:
            cert_bytes = handle.read()
        cert = x509.load_pem_x509_certificate(cert_bytes)
        _validate_certificate_dates(_trusted_certificate(cert_path, cert), context="signing")
        headers[FINGERPRINT_HEADER] = _fingerprint(cert)

    return headers


def verify_or_raise(
    payload: bytes,
    headers: Optional[Dict[str, object]],
    message_type: Optional[str] = None,
    direction: str = "incoming",
) -> None:
    required = require_signatures(message_type=message_type, direction=direction)
    headers = headers or {}
    signature_value = headers.get(SIGNATURE_HEADER)

    if not (enabled() or required or signature_value):
        return

    if not signature_value:
        if required:
            raise RuntimeError("missing Chronicle message signature")
        return

    if headers.get(ALGORITHM_HEADER) is None:
        raise RuntimeError("missing Chronicle message signature algorithm")
    if str(headers.get(ALGORITHM_HEADER)).lower() != ALGORITHM:
        raise RuntimeError("unsupported Chronicle message signature algorithm")

    try:
        signature = base64.b64decode(str(signature_value), validate=True)
    except Exception as exc:
        raise RuntimeError("invalid Chronicle message signature encoding") from exc

    trusted = _trusted_certificates(headers)
    if not trusted:
        raise RuntimeError("message signature verification requires trusted certificates")

    for trusted_cert in trusted:
        public_key = trusted_cert.certificate.public_key()
        try:
            public_key.verify(signature, payload, padding.PKCS1v15(), hashes.SHA256())
            _validate_certificate_dates(trusted_cert, context="trusted")
            return
        except InvalidSignature:
            continue

    raise RuntimeError("invalid Chronicle message signature")


def _trusted_cert_paths() -> Iterable[str]:
    return _csv(env("CHRONICLE_TRUSTED_CERTS", env("AMQP_TRUSTED_CERTIFICATE_PATHS")))


def _trusted_certificates(headers: Dict[str, object]) -> List[TrustedCertificate]:
    header_fingerprint = _normalize_fingerprint(headers.get(FINGERPRINT_HEADER))
    pinned = _trusted_fingerprints()

    if header_fingerprint is not None and not _valid_fingerprint(header_fingerprint):
        raise RuntimeError("invalid Chronicle certificate fingerprint header")
    if header_fingerprint is not None and pinned and header_fingerprint not in pinned:
        raise RuntimeError(f"untrusted Chronicle certificate fingerprint {header_fingerprint}")

    certificates = []
    for path in _trusted_cert_paths():
        with open(path, "rb") as handle:
            cert = x509.load_pem_x509_certificate(handle.read())
        trusted = _trusted_certificate(path, cert)
        if pinned and trusted.fingerprint not in pinned:
            continue
        if header_fingerprint is not None and trusted.fingerprint != header_fingerprint:
            continue
        certificates.append(trusted)

    if header_fingerprint is not None and not certificates:
        raise RuntimeError(f"untrusted Chronicle certificate fingerprint {header_fingerprint}")

    return certificates


def _trusted_certificate(path: str, cert: x509.Certificate) -> TrustedCertificate:
    return TrustedCertificate(path=path, certificate=cert, fingerprint=_fingerprint(cert))


def _trusted_fingerprints() -> List[str]:
    return [
        normalized
        for normalized in (
            _normalize_fingerprint(value)
            for value in _csv(
                env(
                    "CHRONICLE_TRUSTED_CERT_FINGERPRINTS",
                    env("AMQP_TRUSTED_CERTIFICATE_FINGERPRINTS", ""),
                )
            )
        )
        if normalized
    ]


def _validate_certificate_dates(trusted_cert: TrustedCertificate, context: str) -> None:
    if not _truthy(env("CHRONICLE_VALIDATE_CERTIFICATE_DATES", env("AMQP_VALIDATE_CERTIFICATE_DATES", "true"))):
        return

    now = datetime.now(timezone.utc)
    not_before = _cert_not_before(trusted_cert.certificate)
    not_after = _cert_not_after(trusted_cert.certificate)

    if now < not_before:
        raise RuntimeError(
            f"{context} Chronicle certificate {trusted_cert.fingerprint} is not valid before {not_before.isoformat()}"
        )
    if now > not_after:
        raise RuntimeError(f"{context} Chronicle certificate {trusted_cert.fingerprint} expired at {not_after.isoformat()}")

    warning_days = int(env("CHRONICLE_CERTIFICATE_EXPIRY_WARNING_DAYS", env("AMQP_CERTIFICATE_EXPIRY_WARNING_DAYS", "30")))
    if not_after <= now + timedelta(days=warning_days):
        LOGGER.warning(
            "%s Chronicle certificate %s expires at %s",
            context,
            trusted_cert.fingerprint,
            not_after.isoformat(),
        )


def _cert_not_before(cert: x509.Certificate) -> datetime:
    value = getattr(cert, "not_valid_before_utc", None) or cert.not_valid_before.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def _cert_not_after(cert: x509.Certificate) -> datetime:
    value = getattr(cert, "not_valid_after_utc", None) or cert.not_valid_after.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def _fingerprint(cert: x509.Certificate) -> str:
    return hashlib.sha256(cert.public_bytes(serialization.Encoding.DER)).hexdigest()


def _normalize_fingerprint(value: object) -> Optional[str]:
    if value is None:
        return None
    return str(value).strip().lower().replace(":", "")


def _valid_fingerprint(value: str) -> bool:
    return len(value) == 64 and all(char in "0123456789abcdef" for char in value)


def _csv(value: str) -> List[str]:
    return [part.strip().lower() for part in (value or "").split(",") if part.strip()]


def _truthy(value: str) -> bool:
    return str(value).strip().lower() in {"1", "true", "yes", "on"}
