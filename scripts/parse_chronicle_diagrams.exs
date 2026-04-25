path =
  System.get_env("CHRONICLE_TEST_DIAGRAMS") ||
    raise "Set CHRONICLE_TEST_DIAGRAMS to a directory containing Chronicle diagram JSON files"

files = Path.wildcard(Path.join(path, "**/*.json"))

results =
  Enum.map(files, fn file ->
    case Chronicle.Engine.Diagrams.Parser.parse(File.read!(file)) do
      {:ok, _} -> {:ok, file}
      {:error, {:unsupported_node_type, type, reason}} -> {:unsupported, type, reason, file}
      {:error, reason} -> {:error, reason, file}
    end
  end)

ok = Enum.count(results, &match?({:ok, _}, &1))
unsupported = Enum.count(results, &match?({:unsupported, _, _, _}, &1))
errors = Enum.count(results, &match?({:error, _, _}, &1))

IO.puts("files=#{length(files)} ok=#{ok} unsupported=#{unsupported} errors=#{errors}")

results
|> Enum.reject(&match?({:ok, _}, &1))
|> Enum.each(&IO.inspect/1)

if errors > 0 do
  System.halt(1)
end
