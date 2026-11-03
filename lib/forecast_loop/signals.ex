defmodule ForecastLoop.Signals do
  @moduledoc "The signal catalog: register, list and look up signals."
  import Ecto.Query
  alias ForecastLoop.Repo
  alias ForecastLoop.Signals.Signal

  @doc """
  Registers a signal. The spec's system must be registered, and a derived spec's
  input signals must exist.
  """
  def register_signal(attrs) do
    cs = Signal.changeset(%Signal{}, attrs)

    cs =
      Ecto.Changeset.validate_change(cs, :source_spec, fn :source_spec, spec ->
        case ForecastLoop.Sources.module_for(spec) do
          {:ok, _} -> []
          {:error, reason} -> [source_spec: "has an unknown system: #{inspect(reason)}"]
        end
      end)

    Repo.insert(cs)
  end

  def get!(id), do: Repo.get!(Signal, id)
  def get_by_name(name), do: Repo.get_by(Signal, name: name)

  @doc "Lists signals. Options: `:domain`, `:kind`, `:pack`."
  def list_signals(opts \\ []) do
    Enum.reduce(opts, from(s in Signal, order_by: [s.domain, s.name]), fn
      {k, v}, q when k in [:domain, :kind, :pack] and not is_nil(v) ->
        where(q, [s], field(s, ^k) == ^v)

      _, q ->
        q
    end)
    |> Repo.all()
  end
end
