defmodule ForecastLoop.SQLFilesTest do
  use ExUnit.Case, async: true

  alias ForecastLoop.SQLFiles

  test "splits on top-level semicolons only" do
    sql = """
    -- a comment; with a semicolon
    CREATE VIEW a AS SELECT 'x;y' AS s;
    /* block; comment */
    CREATE FUNCTION f() RETURNS int LANGUAGE sql AS $$ SELECT 1; $$;
    CREATE FUNCTION g() RETURNS int LANGUAGE plpgsql AS $fn$ BEGIN RETURN 2; END; $fn$;
    COMMENT ON VIEW a IS 'it''s; fine';
    -- trailing comment only
    """

    assert [a, f, g, c] = SQLFiles.statements(sql)
    assert a =~ "SELECT 'x;y' AS s"
    assert f =~ "$$ SELECT 1; $$"
    assert g =~ "RETURN 2; END; $fn$"
    assert c =~ "'it''s; fine'"
  end

  test "every manifest file exists" do
    for path <- SQLFiles.manifest() do
      assert File.exists?(Path.join(:code.priv_dir(:forecast_loop), path)), path
    end
  end
end
