import os
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

from chronicle_satellite import signing


class SigningTests(unittest.TestCase):
    def test_signs_and_verifies_with_trusted_certificate(self):
        with tempfile.TemporaryDirectory() as tmp:
            key_path, cert_path = write_certificate_pair(Path(tmp), "signer")

            with patch.dict(
                os.environ,
                {
                    "CHRONICLE_MESSAGE_SIGNING": "true",
                    "CHRONICLE_SIGNING_KEY": str(key_path),
                    "CHRONICLE_SIGNING_CERT": str(cert_path),
                    "CHRONICLE_TRUSTED_CERTS": str(cert_path),
                },
                clear=True,
            ):
                payload = b'{"hello":"world"}'
                headers = signing.sign_headers(payload)

                self.assertIn(signing.FINGERPRINT_HEADER, headers)
                signing.verify_or_raise(payload, headers)

    def test_rejects_tampered_payloads(self):
        with tempfile.TemporaryDirectory() as tmp:
            key_path, cert_path = write_certificate_pair(Path(tmp), "signer")

            with patch.dict(
                os.environ,
                {
                    "CHRONICLE_MESSAGE_SIGNING": "true",
                    "CHRONICLE_SIGNING_KEY": str(key_path),
                    "CHRONICLE_SIGNING_CERT": str(cert_path),
                    "CHRONICLE_TRUSTED_CERTS": str(cert_path),
                },
                clear=True,
            ):
                headers = signing.sign_headers(b"original")

                with self.assertRaisesRegex(RuntimeError, "invalid Chronicle message signature"):
                    signing.verify_or_raise(b"tampered", headers)

    def test_rejects_missing_signature_when_required_by_message_type(self):
        with patch.dict(
            os.environ,
            {"CHRONICLE_REQUIRE_SIGNATURE_MESSAGE_TYPES": "ServiceTaskExecutionRequestedEvent"},
            clear=True,
        ):
            with self.assertRaisesRegex(RuntimeError, "missing Chronicle message signature"):
                signing.verify_or_raise(
                    b"payload",
                    {},
                    message_type="Chronicle.Messages.Workflow+ServiceTaskExecutionRequestedEvent",
                    direction="incoming",
                )

    def test_rejects_wrong_trusted_certificate(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            key_path, cert_path = write_certificate_pair(directory, "signer")
            _wrong_key_path, wrong_cert_path = write_certificate_pair(directory, "wrong")

            with patch.dict(
                os.environ,
                {
                    "CHRONICLE_MESSAGE_SIGNING": "true",
                    "CHRONICLE_SIGNING_KEY": str(key_path),
                    "CHRONICLE_SIGNING_CERT": str(cert_path),
                    "CHRONICLE_TRUSTED_CERTS": str(wrong_cert_path),
                },
                clear=True,
            ):
                headers = signing.sign_headers(b"payload")

                with self.assertRaisesRegex(RuntimeError, "untrusted Chronicle certificate fingerprint"):
                    signing.verify_or_raise(b"payload", headers)

    def test_rejects_unpinned_certificate_fingerprint(self):
        with tempfile.TemporaryDirectory() as tmp:
            key_path, cert_path = write_certificate_pair(Path(tmp), "signer")

            with patch.dict(
                os.environ,
                {
                    "CHRONICLE_MESSAGE_SIGNING": "true",
                    "CHRONICLE_SIGNING_KEY": str(key_path),
                    "CHRONICLE_SIGNING_CERT": str(cert_path),
                    "CHRONICLE_TRUSTED_CERTS": str(cert_path),
                    "CHRONICLE_TRUSTED_CERT_FINGERPRINTS": "0" * 64,
                },
                clear=True,
            ):
                headers = signing.sign_headers(b"payload")

                with self.assertRaisesRegex(RuntimeError, "untrusted Chronicle certificate fingerprint"):
                    signing.verify_or_raise(b"payload", headers)

    def test_rejects_expired_trusted_certificate(self):
        with tempfile.TemporaryDirectory() as tmp:
            key_path, cert_path = write_certificate_pair(
                Path(tmp),
                "expired",
                not_before=datetime.now(timezone.utc) - timedelta(days=10),
                not_after=datetime.now(timezone.utc) - timedelta(days=1),
            )

            with patch.dict(
                os.environ,
                {
                    "CHRONICLE_MESSAGE_SIGNING": "true",
                    "CHRONICLE_SIGNING_KEY": str(key_path),
                    "CHRONICLE_SIGNING_CERT": str(cert_path),
                    "CHRONICLE_TRUSTED_CERTS": str(cert_path),
                    "CHRONICLE_VALIDATE_CERTIFICATE_DATES": "false",
                },
                clear=True,
            ):
                headers = signing.sign_headers(b"payload")

            with patch.dict(
                os.environ,
                {
                    "CHRONICLE_MESSAGE_SIGNING": "true",
                    "CHRONICLE_TRUSTED_CERTS": str(cert_path),
                },
                clear=True,
            ):
                with self.assertRaisesRegex(RuntimeError, "expired at"):
                    signing.verify_or_raise(b"payload", headers)


def write_certificate_pair(
    directory: Path,
    name: str,
    not_before: datetime | None = None,
    not_after: datetime | None = None,
) -> tuple[Path, Path]:
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subject = issuer = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, f"chronicle-{name}")])
    now = datetime.now(timezone.utc)

    certificate = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(private_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(not_before or now - timedelta(minutes=1))
        .not_valid_after(not_after or now + timedelta(days=365))
        .sign(private_key, hashes.SHA256())
    )

    key_path = directory / f"{name}-key.pem"
    cert_path = directory / f"{name}-cert.pem"
    key_path.write_bytes(
        private_key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.TraditionalOpenSSL,
            serialization.NoEncryption(),
        )
    )
    cert_path.write_bytes(certificate.public_bytes(serialization.Encoding.PEM))
    return key_path, cert_path


if __name__ == "__main__":
    unittest.main()
