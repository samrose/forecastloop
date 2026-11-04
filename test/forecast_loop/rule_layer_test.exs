defmodule ForecastLoop.RuleLayerTest do
  @moduledoc "Checks the rule layer's conventions (naming, comments, files) and the core's domain purity."
  use ForecastLoop.DataCase, async: true

  alias ForecastLoop.{Rules, SQLFiles}

  test "every view in the rules schema follows the naming convention" do
    bad = Enum.reject(Rules.views(), &Regex.match?(~r/^(k|gap|loop|cal)_[a-z0-9_]+$/, &1))
    assert bad == []

    %{rows: other} =
      Repo.query!("""
      SELECT c.relname, c.relkind FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'rules' AND c.relkind NOT IN ('v', 'm')
      """)

    assert other == [], "the rules schema holds only views"
  end

  test "every rules view has a comment" do
    missing = for %{name: n, comment: c} <- Rules.catalog(), c in [nil, ""], do: n
    assert missing == []
  end

  test "every rules view is defined in priv/rules/<group>/<name>.sql and listed in the manifest" do
    manifest = SQLFiles.manifest()

    for view <- Rules.views() do
      [group | _] = String.split(view, "_", parts: 2)
      path = "rules/#{group}/#{view}.sql"
      assert path in manifest, "#{path} is not in the manifest"
      assert File.read!(Path.join(:code.priv_dir(:forecast_loop), path)) =~ "rules.#{view}"
    end

    for "rules/" <> _ = path <- manifest do
      assert Path.basename(path, ".sql") in Rules.views(), "#{path} defines no view"
    end
  end

  test "every gap view has subject_id and detail columns" do
    for view <- Rules.views("gap") do
      %{columns: cols} = Repo.query!(~s(SELECT * FROM rules."#{view}" LIMIT 0))
      assert "subject_id" in cols and "detail" in cols, view
    end
  end

  describe "core purity" do
    # Words that belong to domain packs. A pack adds its own words in
    # priv/packs/<name>/vocabulary.txt; the test reads them all.
    @base_words ~w(incident deploy severity sev1 sev2 unemployment county labor_force permit
                   github incident_io incidentio fred bls payroll revenue election)

    defp pack_words do
      Path.wildcard("priv/packs/*/vocabulary.txt")
      |> Enum.flat_map(&(&1 |> File.read!() |> String.split(~r/\s+/, trim: true)))
      |> Enum.concat(Path.wildcard("priv/packs/*") |> Enum.map(&Path.basename/1))
    end

    defp core_files do
      (Path.wildcard("lib/forecast_loop/**/*.{ex,exs}") ++
         Path.wildcard("lib/forecast_loop_web/**/*.{ex,exs,heex}") ++
         ["lib/forecast_loop.ex"] ++
         Path.wildcard("priv/rules/**/*.sql") ++
         Path.wildcard("priv/sql/**/*.sql") ++ Path.wildcard("priv/repo/**/*.exs"))
      |> Enum.reject(&String.starts_with?(&1, "lib/forecast_loop/packs/"))
    end

    test "no pack vocabulary appears in the core" do
      words = Enum.uniq(@base_words ++ pack_words())

      pattern =
        Regex.compile!("\\b(" <> Enum.map_join(words, "|", &Regex.escape/1) <> ")s?\\b", "i")

      hits =
        for file <- core_files(),
            {line, n} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
            Regex.match?(pattern, line),
            do: "#{file}:#{n}: #{String.trim(line)}"

      assert hits == [], "pack vocabulary in the core:\n" <> Enum.join(hits, "\n")
    end
  end
end
