defmodule Chronicle.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases()
    ]
  end

  defp deps, do: []

  defp aliases do
    [
      setup: ["deps.get", "cmd mix ecto.setup"],
      test: ["cmd --app engine mix test"]
    ]
  end

  defp releases do
    [
      chronicle: [
        version: "0.1.0",
        applications: [
          engine: :load,
          server: :permanent
        ],
        include_executables_for: [:unix, :windows]
      ]
    ]
  end
end
