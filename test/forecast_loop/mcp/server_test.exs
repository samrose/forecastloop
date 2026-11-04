defmodule ForecastLoop.MCP.ServerTest do
  use ForecastLoop.DataCase, async: false

  alias ForecastLoop.Batch.Act
  alias ForecastLoop.MCP.Server

  @moduletag :capture_log

  defp call(name, args) do
    %{"result" => %{"content" => [%{"type" => "text", "text" => text}], "isError" => err}} =
      Server.handle(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => args}
      })

    {if(err, do: :error, else: :ok), Jason.decode!(text)}
  end

  describe "protocol" do
    test "initialize, ping, tools/list, notifications and errors" do
      assert %{
               "result" => %{
                 "protocolVersion" => "2025-06-18",
                 "capabilities" => %{"tools" => _},
                 "serverInfo" => %{"name" => "forecast_loop"}
               }
             } =
               Server.handle(%{
                 "jsonrpc" => "2.0",
                 "id" => 1,
                 "method" => "initialize",
                 "params" => %{"protocolVersion" => "2025-06-18"}
               })

      assert %{"id" => 2, "result" => %{}} =
               Server.handle(%{"jsonrpc" => "2.0", "id" => 2, "method" => "ping"})

      assert Server.handle(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}) == nil

      %{"result" => %{"tools" => tools}} =
        Server.handle(%{"jsonrpc" => "2.0", "id" => 3, "method" => "tools/list"})

      names = Enum.map(tools, & &1["name"])

      for t <-
            ~w(list_packs install_pack list_sources preview_spec register_signal list_signals list_knowledge assert_knowledge
                  list_gaps create_question create_template list_questions submit_forecast resolve_question calibration_report
                  list_work_items query) do
        assert t in names
      end

      assert Enum.all?(tools, &(&1["inputSchema"]["type"] == "object"))

      assert %{"error" => %{"code" => -32_601}} =
               Server.handle(%{"jsonrpc" => "2.0", "id" => 4, "method" => "nope"})

      assert %{"error" => %{"code" => -32_700}} = Server.handle_line("{not json")
    end

    test "stdio: one JSON message per line in, one per line out" do
      {:ok, input} =
        StringIO.open(
          ~s({"jsonrpc":"2.0","id":7,"method":"ping"}\n{"jsonrpc":"2.0","method":"notifications/initialized"}\n)
        )

      {:ok, output} = StringIO.open("")
      :ok = Server.run(input, output)
      {_, out} = StringIO.contents(output)
      assert [line] = String.split(out, "\n", trim: true)
      assert %{"id" => 7, "result" => %{}} = Jason.decode!(line)
    end
  end

  describe "Forecast Integrity Protocol" do
    test "create_question refuses a question without all four FIP fields" do
      base = %{
        "title" => "T",
        "event_definition" => "E",
        "resolution_condition" => %{"type" => "manual"},
        "deadline" => "2027-01-01T00:00:00Z",
        "domain" => "d",
        "author" => "alice"
      }

      for f <- ~w(event_definition resolution_condition deadline domain) do
        assert {:error, %{"error" => [msg]}} = call("create_question", Map.delete(base, f))
        assert msg =~ "#{f} is required"
      end

      assert {:error, %{"error" => %{"resolution_condition" => [_]}}} =
               call("create_question", %{base | "resolution_condition" => %{"type" => "vibes"}})

      assert {:ok, %{"status" => "review", "id" => _}} = call("create_question", base)
    end

    test "the author cannot review their own question" do
      {:ok, q} =
        call("create_question", %{
          "title" => "T",
          "event_definition" => "E",
          "resolution_condition" => %{"type" => "manual"},
          "deadline" => "2027-01-01T00:00:00Z",
          "domain" => "d",
          "author" => "alice"
        })

      assert {:error, %{"error" => "the reviewer must not be the question's author"}} =
               call("review_question", %{"question_id" => q["id"], "reviewer" => "alice"})

      assert {:ok, %{"reviewed_by_id" => _}} =
               call("review_question", %{"question_id" => q["id"], "reviewer" => "bob"})
    end
  end

  test "arguments are validated against the schema" do
    assert {:error, %{"error" => errors}} =
             call("submit_forecast", %{
               "question_id" => "x",
               "agent" => "a",
               "probability" => 1.5,
               "rationale" => "r",
               "extra" => 1
             })

    assert "arguments.question_id must be of type integer" in errors
    assert "arguments.probability must be at most 1" in errors
    assert "arguments.extra is not a known field" in errors

    assert {:error, %{"error" => [_]}} =
             call("assert_knowledge", %{
               "predicate" => "made_up",
               "subject" => "a",
               "object" => "b",
               "author" => "x"
             })
  end

  test "a person and Claude run the loop through the tools" do
    {:ok, _} =
      call("assert_knowledge", %{
        "predicate" => "min_history",
        "subject" => "d",
        "object" => "5",
        "author" => "alice"
      })

    assert {:ok, [%{"predicate" => "min_history"}]} =
             call("list_knowledge", %{"predicate" => "min_history"})

    {:ok, sig} =
      call("register_signal", %{
        "name" => "s",
        "kind" => "series",
        "domain" => "d",
        "author" => "alice",
        "source_spec" => %{
          "system" => "csv",
          "path" => "test/fixtures/sources/monthly_v1.csv",
          "fields" => %{"effective_at" => "DATE", "value" => "VALUE"}
        }
      })

    assert {:ok, [_ | _] = rows} =
             call("preview_spec", %{
               "spec" => %{
                 "system" => "csv",
                 "path" => "test/fixtures/sources/monthly_v1.csv",
                 "fields" => %{"effective_at" => "DATE", "value" => "VALUE"}
               }
             })

    assert hd(rows)["value"] == 4.0

    {:ok, q} =
      call("create_question", %{
        "title" => "Above 4.5?",
        "event_definition" => "E",
        "deadline" => "2027-01-01T00:00:00Z",
        "domain" => "d",
        "author" => "alice",
        "resolution_condition" => %{
          "type" => "series",
          "signal_id" => sig["id"],
          "op" => ">=",
          "value" => 4.5,
          "at" => "end_of_window"
        }
      })

    assert {:error, %{"error" => msg}} =
             call("submit_forecast", %{
               "question_id" => q["id"],
               "agent" => "claude",
               "probability" => 0.3,
               "rationale" => "r"
             })

    assert msg =~ "is review"

    {:ok, _} = call("review_question", %{"question_id" => q["id"], "reviewer" => "bob"})
    ForecastLoop.Batch.set_as_of(DateTime.utc_now())
    Act.run(nil, DateTime.utc_now())

    assert {:ok, [%{"status" => "live"}]} = call("list_questions", %{"domain" => "d"})

    assert {:ok, %{"probability" => 0.3}} =
             call("submit_forecast", %{
               "question_id" => q["id"],
               "agent" => "claude",
               "probability" => 0.3,
               "rationale" => "Below trend."
             })

    assert {:ok, %{"outcome" => false}} =
             call("resolve_question", %{
               "question_id" => q["id"],
               "outcome" => false,
               "source" => "manual check",
               "resolved_by" => "alice"
             })

    # The rule views report as of batch_context.as_of, which the next batch run moves past the resolution.
    ForecastLoop.Batch.set_as_of(DateTime.add(DateTime.utc_now(), 1))
    ForecastLoop.Scores.refresh()

    assert {:ok,
            %{
              "summary" => [%{"agent_name" => "claude", "domain" => "d", "n" => 1}],
              "buckets" => [%{"bucket" => 3}]
            }} = call("calibration_report", %{"agent" => "claude"})

    assert {:ok,
            %{"columns" => ["forecast_id" | _], "rows" => [_], "sql" => "SELECT * FROM cal_score"}} =
             call("query", %{"sql" => "SELECT * FROM cal_score"})

    assert {:error, %{"error" => denied}} =
             call("query", %{"sql" => "SELECT * FROM public.agents"})

    assert denied =~ "permission denied"
  end

  test "packs, sources, gaps and work items" do
    assert {:ok, %{"available" => avail}} = call("list_packs", %{})
    assert "regional_economy" in avail

    assert {:ok, %{"pack" => "regional_economy"}} =
             call("install_pack", %{"name" => "regional_economy"})

    assert {:ok, %{"name" => "my_pack", "origin" => "builder"}} =
             call("create_pack", %{"name" => "my_pack", "title" => "Mine", "author" => "alice"})

    assert {:ok, systems} = call("list_sources", %{})
    assert Enum.any?(systems, &(&1["system"] == "http_csv"))
    assert {:ok, []} = call("list_gaps", %{})
    assert {:ok, []} = call("list_work_items", %{"kind" => "gap"})
  end
end
