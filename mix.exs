defmodule DryDev.Workflow.Umbrella.MixProject do
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
      test: ["cmd --app drydev_workflow mix test"]
    ]
  end

  defp releases do
    [
      drydev_workflow_server: [
        version: "0.1.0",
        applications: [
          drydev_workflow: :permanent,
          drydev_workflow_server: :permanent
        ],
        include_executables_for: [:unix, :windows]
      ]
    ]
  end
end
