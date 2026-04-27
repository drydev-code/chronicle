defmodule Chronicle.Server.Messaging.MessageSignatureTest do
  use ExUnit.Case, async: true

  alias Chronicle.Server.Messaging.MessageSignature

  test "signs and verifies payloads with trusted public keys" do
    {private_pem, public_pem} = key_pair_pems()
    payload = ~s({"hello":"world"})

    headers = MessageSignature.sign(payload, private_key_pem: private_pem)

    assert :ok =
             MessageSignature.verify(payload, headers, trusted_public_keys: [public_pem])
  end

  test "rejects tampered payloads" do
    {private_pem, public_pem} = key_pair_pems()
    headers = MessageSignature.sign("original", private_key_pem: private_pem)

    assert {:error, :invalid_signature} =
             MessageSignature.verify("tampered", headers, trusted_public_keys: [public_pem])
  end

  test "signs and verifies payloads with x509 certificate files" do
    payload = ~s({"hello":"certificate"})

    headers =
      MessageSignature.sign(payload,
        private_key_path: fixture_path("dev-chronicle-key.pem"),
        certificate_path: fixture_path("dev-chronicle-cert.pem")
      )

    assert :ok =
             MessageSignature.verify(payload, headers,
               trusted_certificate_paths: [fixture_path("dev-chronicle-cert.pem")]
             )
  end

  test "supports separate signer and trust config with certificate fingerprint pinning" do
    payload = ~s({"hello":"pinned"})

    headers =
      MessageSignature.sign(payload,
        signer: [
          private_key_path: fixture_path("dev-chronicle-key.pem"),
          certificate_path: fixture_path("dev-chronicle-cert.pem")
        ]
      )

    fingerprint = headers[MessageSignature.signature_headers().certificate_fingerprint]

    assert :ok =
             MessageSignature.verify(payload, headers,
               trust: [
                 certificate_paths: [fixture_path("dev-chronicle-cert.pem")],
                 certificate_fingerprints: [String.upcase(fingerprint)]
               ]
             )

    assert {:error, {:untrusted_certificate_fingerprint, ^fingerprint}} =
             MessageSignature.verify(payload, headers,
               trust: [
                 certificate_paths: [fixture_path("dev-chronicle-cert.pem")],
                 certificate_fingerprints: [String.duplicate("0", 64)]
               ]
             )
  end

  test "rejects missing signatures when required by message type" do
    assert {:error, :missing_signature} =
             MessageSignature.verify_if_required("payload", %{},
               message_type: "Chronicle.Messages.Workflow+ServiceTaskExecutedEvent",
               direction: :incoming,
               require_signature_message_types: ["servicetaskexecutedevent"],
               trusted_certificate_paths: [fixture_path("dev-chronicle-cert.pem")]
             )
  end

  test "rejects signatures verified against the wrong certificate" do
    {private_pem, _public_pem} = key_pair_pems()
    headers = MessageSignature.sign("payload", private_key_pem: private_pem)

    assert {:error, :invalid_signature} =
             MessageSignature.verify("payload", headers,
               trusted_certificate_paths: [fixture_path("dev-chronicle-cert.pem")]
             )
  end

  test "rejects expired certificates" do
    payload = "payload"

    headers =
      MessageSignature.sign(payload,
        private_key_path: fixture_path("dev-chronicle-key.pem"),
        certificate_path: fixture_path("dev-chronicle-cert.pem")
      )

    fingerprint = headers[MessageSignature.signature_headers().certificate_fingerprint]

    assert {:error, {:certificate_expired, ^fingerprint}} =
             MessageSignature.verify(payload, headers,
               trusted_certificate_paths: [fixture_path("dev-chronicle-cert.pem")],
               now: ~U[2037-01-01 00:00:00Z]
             )
  end

  test "rejects malformed certificate fingerprint headers" do
    {private_pem, public_pem} = key_pair_pems()

    headers =
      "payload"
      |> MessageSignature.sign(private_key_pem: private_pem)
      |> Map.put(MessageSignature.signature_headers().certificate_fingerprint, "not-a-sha256")

    assert {:error, :invalid_certificate_fingerprint} =
             MessageSignature.verify("payload", headers, trusted_public_keys: [public_pem])
  end

  defp fixture_path(name) do
    Path.expand("../../../../../../config/certs/#{name}", __DIR__)
  end

  defp key_pair_pems do
    private_key = :public_key.generate_key({:rsa, 2048, 65_537})
    {:RSAPrivateKey, _, modulus, public_exponent, _, _, _, _, _, _, _} = private_key

    public_key = {:RSAPublicKey, modulus, public_exponent}

    {
      :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, private_key)]),
      :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPublicKey, public_key)])
    }
  end
end
