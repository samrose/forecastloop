defmodule ForecastLoop.SQLFiles do
  @moduledoc """
  Loads the SQL that lives in files: the rule views (`priv/rules/<group>/<name>.sql`),
  helper functions and derived-series operations (`priv/sql/**`).

  `priv/rules/manifest.txt` lists the files in load order, one path relative to
  `priv/` on each line. `reload!/1` drops the `fl`, `derive` and `rules` schemas and
  recreates them from the files. Only the newest migration reloads (see
  docs/adr/0011), so a fresh database always loads the files against the final
  table schema.
  """

  @managed_schemas ~w(fl derive rules)

  @doc "Paths (relative to `priv/`) from the manifest, in load order."
  @spec manifest() :: [String.t()]
  def manifest do
    priv_path("rules/manifest.txt")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  end

  @doc "Drops and recreates the managed schemas from the files. `execute` runs one statement."
  @spec reload!((String.t() -> term())) :: :ok
  def reload!(execute) do
    for schema <- @managed_schemas, do: execute.("DROP SCHEMA IF EXISTS #{schema} CASCADE")
    for schema <- @managed_schemas, do: execute.("CREATE SCHEMA #{schema}")

    for path <- manifest(), stmt <- statements(File.read!(priv_path(path))) do
      execute.(stmt)
    end

    :ok
  end

  @doc """
  Runs `reload!/1` from migration `module` only when it is the newest migration
  file. Earlier migrations skip, because the files now describe the final schema.
  """
  @spec reload_if_latest(module(), (String.t() -> term())) :: :ok | :skipped
  def reload_if_latest(module, execute) do
    if latest_migration?(module), do: reload!(execute), else: :skipped
  end

  @doc "Drops the managed schemas. Used by `down` of a reloading migration."
  @spec drop!((String.t() -> term())) :: :ok
  def drop!(execute) do
    for schema <- @managed_schemas, do: execute.("DROP SCHEMA IF EXISTS #{schema} CASCADE")
    :ok
  end

  defp latest_migration?(module) do
    files = Path.wildcard(priv_path("repo/migrations/*.exs"))
    latest = files |> Enum.map(&Path.basename/1) |> Enum.max()
    suffix = module |> Module.split() |> List.last() |> Macro.underscore()
    String.ends_with?(latest, "_" <> suffix <> ".exs")
  end

  defp priv_path(rel), do: Path.join(:code.priv_dir(:forecast_loop), rel)

  @doc """
  Splits SQL text into statements on top-level semicolons. It respects
  single-quoted strings, double-quoted identifiers, `--` and `/* */` comments, and
  dollar-quoted bodies such as `$$ ... $$` or `$fn$ ... $fn$`.
  """
  @spec statements(String.t()) :: [String.t()]
  def statements(sql) do
    sql
    |> scan(:normal, [], [])
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(strip_comments(&1) == ""))
  end

  # scan(rest, state, current_reversed_iodata, done_reversed)
  defp scan(<<>>, _state, cur, done), do: Enum.reverse([flush(cur) | done])

  defp scan(<<";", rest::binary>>, :normal, cur, done),
    do: scan(rest, :normal, [], [flush(cur) | done])

  defp scan(<<"--", rest::binary>>, :normal, cur, done),
    do: scan(rest, :line_comment, ["--" | cur], done)

  defp scan(<<"/*", rest::binary>>, :normal, cur, done),
    do: scan(rest, :block_comment, ["/*" | cur], done)

  defp scan(<<"'", rest::binary>>, :normal, cur, done),
    do: scan(rest, :single, ["'" | cur], done)

  defp scan(<<"\"", rest::binary>>, :normal, cur, done),
    do: scan(rest, :double, ["\"" | cur], done)

  defp scan(<<"$", rest::binary>> = all, :normal, cur, done) do
    case Regex.run(~r/^\$([A-Za-z_][A-Za-z0-9_]*)?\$/, all) do
      [tag | _] ->
        scan(
          binary_part(all, byte_size(tag), byte_size(all) - byte_size(tag)),
          {:dollar, tag},
          [tag | cur],
          done
        )

      nil ->
        scan(rest, :normal, ["$" | cur], done)
    end
  end

  defp scan(<<"\n", rest::binary>>, :line_comment, cur, done),
    do: scan(rest, :normal, ["\n" | cur], done)

  defp scan(<<"*/", rest::binary>>, :block_comment, cur, done),
    do: scan(rest, :normal, ["*/" | cur], done)

  defp scan(<<"''", rest::binary>>, :single, cur, done),
    do: scan(rest, :single, ["''" | cur], done)

  defp scan(<<"'", rest::binary>>, :single, cur, done), do: scan(rest, :normal, ["'" | cur], done)

  defp scan(<<"\"", rest::binary>>, :double, cur, done),
    do: scan(rest, :normal, ["\"" | cur], done)

  defp scan(bin, {:dollar, tag} = state, cur, done) do
    if String.starts_with?(bin, tag) do
      size = byte_size(tag)
      scan(binary_part(bin, size, byte_size(bin) - size), :normal, [tag | cur], done)
    else
      <<c::utf8, rest::binary>> = bin
      scan(rest, state, [<<c::utf8>> | cur], done)
    end
  end

  defp scan(<<c::utf8, rest::binary>>, state, cur, done),
    do: scan(rest, state, [<<c::utf8>> | cur], done)

  defp flush(cur), do: cur |> Enum.reverse() |> IO.iodata_to_binary()

  defp strip_comments(stmt) do
    stmt
    |> String.replace(~r/--[^\n]*/, "")
    |> String.replace(~r/\/\*.*?\*\//s, "")
    |> String.trim()
  end
end
