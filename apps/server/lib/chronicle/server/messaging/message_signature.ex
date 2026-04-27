defmodule Chronicle.Server.Messaging.MessageSignature do
  @moduledoc """
  X.509-oriented RSA-SHA256 signatures for Chronicle AMQP payloads.

  Signing is opt-in through `config :server, :amqp_signing`. The verifier accepts
  trusted X.509 certificates with optional SHA-256 fingerprint pins. Public keys
  in PEM form remain supported for tests and early integrations that do not yet
  distribute certificates.
  """

  require Logger

  @algorithm "rsa-sha256"
  @signature_header "Chronicle.Signature"
  @algorithm_header "Chronicle.Signature.Algorithm"
  @fingerprint_header "Chronicle.Signature.CertificateSha256"
  @default_expiry_warning_days 30

  def sign_if_configured(payload, opts \\ []) when is_binary(payload) do
    config = Application.get_env(:server, :amqp_signing, [])

    if Keyword.get(config, :enabled, false) do
      sign(payload, Keyword.merge(config, opts))
    else
      %{}
    end
  end

  def verify_if_required(payload, headers, opts \\ []) when is_binary(payload) do
    config = Application.get_env(:server, :amqp_signing, [])
    opts = Keyword.merge(config, opts)

    cond do
      required?(opts) ->
        verify(payload, headers, opts)

      signature_present?(headers) ->
        verify(payload, headers, opts)

      true ->
        :unsigned
    end
  end

  def required?(context \\ []) do
    config =
      :server
      |> Application.get_env(:amqp_signing, [])
      |> Keyword.merge(List.wrap(context))

    Keyword.get(config, :require_signatures, false) ||
      required_direction?(config) ||
      required_message_type?(config) ||
      required_context?(config)
  end

  def sign(payload, opts) when is_binary(payload) do
    private_key = opts |> pem_source(:private_key) |> decode_private_key!()
    signer_cert = pem_source(opts, :certificate)
    signature = :public_key.sign(payload, :sha256, private_key)

    %{
      @algorithm_header => @algorithm,
      @signature_header => Base.encode64(signature)
    }
    |> maybe_put_fingerprint(signer_cert)
  end

  def verify(payload, headers, opts) when is_binary(payload) do
    with {:ok, signature} <- signature(headers),
         :ok <- verify_algorithm(headers),
         {:ok, trusted} <- trusted_material(headers, opts) do
      verify_with_trust(payload, signature, trusted, opts)
    else
      {:error, _} = error -> error
    end
  end

  def signature_headers do
    %{
      signature: @signature_header,
      algorithm: @algorithm_header,
      certificate_fingerprint: @fingerprint_header
    }
  end

  defp signature_present?(headers) do
    headers
    |> header_map()
    |> Map.has_key?(@signature_header)
  end

  defp signature(headers) do
    case Map.get(header_map(headers), @signature_header) do
      value when is_binary(value) ->
        Base.decode64(value)

      _ ->
        {:error, :missing_signature}
    end
  end

  defp verify_algorithm(headers) do
    case Map.get(header_map(headers), @algorithm_header) do
      @algorithm -> :ok
      nil -> {:error, :missing_signature_algorithm}
      _ -> {:error, :unsupported_signature_algorithm}
    end
  end

  defp trusted_material(headers, opts) do
    opts = List.wrap(opts)
    header_fingerprint = header_fingerprint(headers)
    pinned_fingerprints = trusted_fingerprints(opts)

    with :ok <- validate_header_fingerprint(header_fingerprint),
         :ok <- validate_pinned_header(header_fingerprint, pinned_fingerprints) do
      certificates =
        opts
        |> trusted_certificate_pems()
        |> Enum.flat_map(&decode_trusted_certificates/1)
        |> filter_pinned_certificates(pinned_fingerprints)
        |> filter_header_certificate(header_fingerprint)

      public_keys =
        if header_fingerprint || pinned_fingerprints != [] do
          []
        else
          opts
          |> trusted_public_keys()
          |> Enum.flat_map(&decode_public_keys/1)
          |> Enum.map(&%{type: :public_key, public_key: &1})
        end

      trusted = certificates ++ public_keys

      cond do
        trusted != [] ->
          {:ok, trusted}

        header_fingerprint ->
          {:error, {:untrusted_certificate_fingerprint, header_fingerprint}}

        true ->
          {:error, :missing_trusted_key}
      end
    end
  end

  defp decode_private_key!(nil), do: raise(ArgumentError, "missing AMQP signing private key")

  defp decode_private_key!(pem) do
    pem
    |> pem_entries()
    |> Enum.find_value(fn entry ->
      case :public_key.pem_entry_decode(entry) do
        {:RSAPrivateKey, _, _, _, _, _, _, _, _, _, _} = key -> key
        {:PrivateKeyInfo, _, _} = key -> key
        _ -> nil
      end
    end) || raise ArgumentError, "AMQP signing private key PEM did not contain a private key"
  end

  defp decode_trusted_certificates(nil), do: []

  defp decode_trusted_certificates(pem) do
    pem
    |> pem_entries()
    |> Enum.flat_map(fn
      {:Certificate, der, _} ->
        [
          %{
            type: :certificate,
            der: der,
            fingerprint: certificate_fingerprint(der),
            public_key: certificate_public_key(der),
            validity: certificate_validity(der)
          }
        ]

      _ ->
        []
    end)
  end

  defp decode_public_keys(nil), do: []

  defp decode_public_keys(pem) do
    pem
    |> pem_entries()
    |> Enum.flat_map(fn entry ->
      case :public_key.pem_entry_decode(entry) do
        {:RSAPublicKey, _, _} = key -> [key]
        {:SubjectPublicKeyInfo, _, _} = key -> [key]
        _ -> []
      end
    end)
  end

  defp maybe_put_fingerprint(headers, nil), do: headers

  defp maybe_put_fingerprint(headers, pem) do
    fingerprint =
      pem
      |> pem_entries()
      |> Enum.find_value(fn
        {:Certificate, der, _} -> certificate_fingerprint(der)
        _ -> nil
      end)

    if fingerprint, do: Map.put(headers, @fingerprint_header, fingerprint), else: headers
  end

  defp certificate_fingerprint(der), do: :crypto.hash(:sha256, der) |> Base.encode16(case: :lower)

  defp certificate_public_key(der) do
    {:OTPCertificate, tbs_certificate, _signature_algorithm, _signature} =
      :public_key.pkix_decode_cert(der, :otp)

    subject_public_key_info = elem(tbs_certificate, 7)

    case subject_public_key_info do
      {:OTPSubjectPublicKeyInfo, _algorithm, public_key} -> public_key
      {:SubjectPublicKeyInfo, _algorithm, public_key} -> public_key
    end
  end

  defp certificate_validity(der) do
    {:OTPCertificate, tbs_certificate, _signature_algorithm, _signature} =
      :public_key.pkix_decode_cert(der, :otp)

    case elem(tbs_certificate, 5) do
      {:Validity, not_before, not_after} ->
        {asn1_time_to_datetime(not_before), asn1_time_to_datetime(not_after)}

      _ ->
        {nil, nil}
    end
  end

  defp verify_with_trust(payload, signature, trusted, opts) do
    result =
      Enum.reduce_while(trusted, :invalid_signature, fn material, _acc ->
        if :public_key.verify(payload, :sha256, signature, material.public_key) do
          case validate_certificate(material, opts) do
            :ok -> {:halt, :ok}
            {:error, _} = error -> {:halt, error}
          end
        else
          {:cont, :invalid_signature}
        end
      end)

    case result do
      :ok -> :ok
      :invalid_signature -> {:error, :invalid_signature}
      {:error, _} = error -> error
    end
  end

  defp validate_certificate(%{type: :public_key}, _opts), do: :ok

  defp validate_certificate(%{fingerprint: fingerprint, validity: {not_before, not_after}}, opts) do
    validate_dates = Keyword.get(List.wrap(opts), :validate_certificate_dates, true)
    now = Keyword.get(List.wrap(opts), :now, DateTime.utc_now())

    cond do
      validate_dates && not_before && DateTime.compare(now, not_before) == :lt ->
        {:error, {:certificate_not_yet_valid, fingerprint}}

      validate_dates && not_after && DateTime.compare(now, not_after) == :gt ->
        {:error, {:certificate_expired, fingerprint}}

      true ->
        maybe_warn_expiring_certificate(fingerprint, not_after, now, opts)
        :ok
    end
  end

  defp maybe_warn_expiring_certificate(_fingerprint, nil, _now, _opts), do: :ok

  defp maybe_warn_expiring_certificate(fingerprint, not_after, now, opts) do
    warning_days =
      opts
      |> List.wrap()
      |> Keyword.get(:certificate_expiry_warning_days, @default_expiry_warning_days)

    if warning_days && DateTime.compare(not_after, DateTime.add(now, warning_days, :day)) != :gt do
      Logger.warning(
        "Chronicle AMQP trusted certificate #{fingerprint} expires at #{DateTime.to_iso8601(not_after)}"
      )
    end
  end

  defp pem_source(opts, key) do
    opts = List.wrap(opts)
    signer = Keyword.get(opts, :signer, []) |> List.wrap()

    Keyword.get(signer, :"#{key}_pem") ||
      Keyword.get(opts, :"#{key}_pem") ||
      read_pem_path(Keyword.get(signer, :"#{key}_path") || Keyword.get(opts, :"#{key}_path"))
  end

  defp read_pem_path(nil), do: nil
  defp read_pem_path(path), do: File.read!(path)

  defp trusted_certificate_pems(opts) do
    trust = Keyword.get(opts, :trust, []) |> List.wrap()

    certificate_pems =
      List.wrap(Keyword.get(trust, :certificates, [])) ++
        List.wrap(Keyword.get(trust, :certificate_pems, [])) ++
        List.wrap(Keyword.get(opts, :trusted_certificates, [])) ++
        List.wrap(Keyword.get(opts, :trusted_certificate_pems, []))

    certificate_paths =
      List.wrap(Keyword.get(trust, :certificate_paths, [])) ++
        List.wrap(Keyword.get(opts, :trusted_certificate_paths, [])) ++
        List.wrap(Keyword.get(opts, :trusted_certificate_path, []))

    certificate_pems ++ Enum.map(certificate_paths, &File.read!/1)
  end

  defp trusted_public_keys(opts) do
    opts
    |> Keyword.get(:trusted_public_keys, [])
    |> List.wrap()
  end

  defp trusted_fingerprints(opts) do
    trust = Keyword.get(opts, :trust, []) |> List.wrap()

    (List.wrap(Keyword.get(trust, :certificate_fingerprints, [])) ++
       List.wrap(Keyword.get(opts, :trusted_certificate_fingerprints, [])) ++
       List.wrap(Keyword.get(opts, :pinned_certificate_fingerprints, [])))
    |> Enum.flat_map(&split_fingerprint_value/1)
    |> Enum.map(&normalize_fingerprint/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp split_fingerprint_value(value) when is_binary(value),
    do: String.split(value, ",", trim: true)

  defp split_fingerprint_value(value), do: List.wrap(value)

  defp filter_pinned_certificates(certificates, []), do: certificates

  defp filter_pinned_certificates(certificates, pinned_fingerprints) do
    Enum.filter(certificates, &(&1.fingerprint in pinned_fingerprints))
  end

  defp filter_header_certificate(certificates, nil), do: certificates

  defp filter_header_certificate(certificates, fingerprint) do
    Enum.filter(certificates, &(&1.fingerprint == fingerprint))
  end

  defp header_fingerprint(headers) do
    headers
    |> header_map()
    |> Map.get(@fingerprint_header)
    |> normalize_fingerprint()
  end

  defp validate_header_fingerprint(nil), do: :ok

  defp validate_header_fingerprint(fingerprint) do
    if String.match?(fingerprint, ~r/\A[0-9a-f]{64}\z/) do
      :ok
    else
      {:error, :invalid_certificate_fingerprint}
    end
  end

  defp validate_pinned_header(nil, _pinned_fingerprints), do: :ok
  defp validate_pinned_header(_fingerprint, []), do: :ok

  defp validate_pinned_header(fingerprint, pinned_fingerprints) do
    if fingerprint in pinned_fingerprints do
      :ok
    else
      {:error, {:untrusted_certificate_fingerprint, fingerprint}}
    end
  end

  defp normalize_fingerprint(nil), do: nil

  defp normalize_fingerprint(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(":", "")
    |> String.trim()
  end

  defp asn1_time_to_datetime({_type, value}) do
    value
    |> to_string()
    |> String.trim()
    |> String.trim_trailing("Z")
    |> parse_asn1_time_digits()
  end

  defp asn1_time_to_datetime(_), do: nil

  defp parse_asn1_time_digits(<<yy::binary-size(2), rest::binary-size(10)>>) do
    year = String.to_integer(yy)
    year = if year < 50, do: 2000 + year, else: 1900 + year
    parse_datetime(year, rest)
  end

  defp parse_asn1_time_digits(<<year::binary-size(4), rest::binary-size(10)>>) do
    parse_datetime(String.to_integer(year), rest)
  end

  defp parse_asn1_time_digits(_), do: nil

  defp parse_datetime(
         year,
         <<month::binary-size(2), day::binary-size(2), hour::binary-size(2),
           minute::binary-size(2), second::binary-size(2)>>
       ) do
    with {:ok, date} <-
           Date.new(year, String.to_integer(month), String.to_integer(day)),
         {:ok, time} <-
           Time.new(String.to_integer(hour), String.to_integer(minute), String.to_integer(second)),
         {:ok, datetime} <- DateTime.new(date, time, "Etc/UTC") do
      datetime
    else
      _ -> nil
    end
  end

  defp required_direction?(config) do
    direction = config |> Keyword.get(:direction) |> normalize_requirement_value()

    config
    |> requirement_values([:require_signature_directions, :required_signature_directions])
    |> Enum.any?(&(&1 in ["*", "all", direction]))
  end

  defp required_message_type?(config) do
    message_type = config |> Keyword.get(:message_type) |> normalize_requirement_value()

    message_type != nil &&
      config
      |> requirement_values([:require_signature_message_types, :required_signature_message_types])
      |> Enum.any?(&message_type_matches?(message_type, &1))
  end

  defp required_context?(config) do
    direction = config |> Keyword.get(:direction) |> normalize_requirement_value()
    message_type = config |> Keyword.get(:message_type) |> normalize_requirement_value()

    config
    |> Keyword.get(:require_signatures_for, [])
    |> Enum.any?(fn
      {required_direction, requirement} ->
        normalize_requirement_value(required_direction) in ["*", "all", direction] &&
          requirement_matches?(requirement, message_type)

      requirement ->
        requirement_matches?(requirement, message_type)
    end)
  end

  defp requirement_matches?(true, _message_type), do: true
  defp requirement_matches?(:all, _message_type), do: true
  defp requirement_matches?("*", _message_type), do: true
  defp requirement_matches?("all", _message_type), do: true

  defp requirement_matches?(requirements, message_type) do
    requirements
    |> List.wrap()
    |> Enum.flat_map(&split_requirement_value/1)
    |> Enum.map(&normalize_requirement_value/1)
    |> Enum.any?(&message_type_matches?(message_type, &1))
  end

  defp requirement_values(config, keys) do
    keys
    |> Enum.flat_map(fn key -> Keyword.get(config, key, []) |> List.wrap() end)
    |> Enum.flat_map(&split_requirement_value/1)
    |> Enum.map(&normalize_requirement_value/1)
  end

  defp split_requirement_value(value) when is_binary(value),
    do: String.split(value, ",", trim: true)

  defp split_requirement_value(value), do: List.wrap(value)

  defp normalize_requirement_value(nil), do: nil

  defp normalize_requirement_value(value),
    do: value |> to_string() |> String.trim() |> String.downcase()

  defp message_type_matches?(_message_type, nil), do: false
  defp message_type_matches?(_message_type, "*"), do: true
  defp message_type_matches?(_message_type, "all"), do: true
  defp message_type_matches?(nil, _requirement), do: false

  defp message_type_matches?(message_type, requirement) do
    message_type == requirement || String.contains?(message_type, requirement)
  end

  defp pem_entries(pem) when is_binary(pem), do: :public_key.pem_decode(pem)

  defp header_map(headers) when is_map(headers), do: headers

  defp header_map(headers) when is_list(headers) do
    Map.new(headers, fn
      {key, _type, value} -> {key, value}
      {key, value} -> {key, value}
    end)
  end

  defp header_map(_), do: %{}
end
