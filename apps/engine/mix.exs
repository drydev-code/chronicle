defmodule Chronicle.MixProject do
  use Mix.Project

  def project do
    [
      app: :engine,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      description:
        "Chronicle — strict BPMN 2.0 engine for Elixir/OTP. Event-sourced, " <>
          "actor-based, with DMN decision tables and JavaScript scripting.",
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix_pubsub, "~> 2.1"},
      {:ecto_sql, "~> 3.11"},
      {:myxql, "~> 0.7", optional: true},
      {:postgrex, "~> 0.19", optional: true},
      {:tds, "~> 2.3", optional: true},
      {:jason, "~> 1.4"},
      {:poolboy, "~> 1.5"},
      {:bbmustache, "~> 1.12"},
      {:elixir_uuid, "~> 1.2"},
      {:telemetry, "~> 1.2"},
      {:ex_machina, "~> 2.7", only: :test},
      {:mox, "~> 1.1", only: :test}
    ]
  end

  defp aliases do
    [
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["test"]
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/drydev/chronicle"},
      files: ~w(lib priv/js priv/repo/migrations mix.exs README.md LICENSE)
    ]
  end
end
