[
  import_deps: [:ecto, :ecto_sql, :phoenix],
  inputs: [
    "mix.exs",
    "config/*.exs",
    "apps/*/mix.exs",
    "apps/*/lib/**/*.{ex,exs}",
    "apps/*/test/**/*.{ex,exs}",
    "apps/*/priv/*/seeds.exs"
  ]
]
