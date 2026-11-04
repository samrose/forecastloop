defmodule EDivisive do
  @moduledoc """
  E-Divisive change-point detection (Matteson and James, "A Nonparametric Approach
  for Multiple Change Point Analysis of Multivariate Data", JASA 2014), for a
  univariate series.

  Written for ForecastLoop because the module that the build prompt calls
  "provided" was not supplied (see docs/adr/0014). Replace this file with the
  provided module when it is available, and keep `detect/2`'s contract.

  ## Method

  For a segment X of length n and a split point t, with A = X[0, t) and
  B = X[t, n), the divergence statistic is

      Q(t) = (m k / n) * ( 2/(m k) Σ|a-b|^α − 1/C(m,2) Σ|a-a'|^α − 1/C(k,2) Σ|b-b'|^α )

  where m = t and k = n − t. The method splits hierarchically: at each step it
  takes the segment and split point with the largest Q, then runs a permutation
  test within that segment. It stops when the p-value exceeds `:sig_level`.
  Each step is a separate test, so false positives add up; the default
  `:sig_level` is 0.01 (with 199 permutations the smallest p-value is 0.005).
  This version fixes the end of each candidate interval at the segment end (the
  κ = n simplification).

  All Q(t) for one segment come from one 2-D prefix sum of the distance matrix,
  computed with Nx.

  ## Determinism

  Permutations use the `:seed` option, so the same input and options give the same
  result. ForecastLoop needs this so that a batch rerun writes nothing new.
  """
  import Nx.Defn

  @defaults [min_size: 8, sig_level: 0.01, permutations: 199, alpha: 1.0, seed: 42]

  @type change_point :: %{index: non_neg_integer(), statistic: float(), p_value: float()}

  @doc "The default options."
  def defaults, do: @defaults

  @doc """
  Detects change points in `series` (a list of numbers or a 1-D tensor).

  Returns change points sorted by index. `index` is the position of the first
  value of the new regime.

  Options: `:min_size` (minimum segment length, ≥ 2), `:sig_level`,
  `:permutations`, `:alpha` (distance exponent in (0, 2)), `:seed`.
  """
  @spec detect([number()] | Nx.Tensor.t(), keyword()) :: [change_point()]
  def detect(series, opts \\ []) do
    opts = Keyword.validate!(opts, @defaults)
    x = series |> to_list() |> Enum.map(&(&1 * 1.0))
    min_size = max(opts[:min_size], 2)

    if length(x) < 2 * min_size do
      []
    else
      rand = :rand.seed_s(:exsss, {opts[:seed], 17, 29})
      split([{0, length(x)}], x, min_size, opts, rand, [])
    end
  end

  defp to_list(%Nx.Tensor{} = t), do: Nx.to_flat_list(t)
  defp to_list(list) when is_list(list), do: list

  defp split(segments, x, min_size, opts, rand, found) do
    candidates =
      for {from, to} <- segments, to - from >= 2 * min_size do
        seg = Enum.slice(x, from, to - from)
        {tau, q} = best_split(seg, min_size, opts[:alpha])
        {from, to, tau, q}
      end

    case Enum.max_by(candidates, &elem(&1, 3), fn -> nil end) do
      nil ->
        Enum.sort_by(found, & &1.index)

      {from, to, tau, q} ->
        seg = Enum.slice(x, from, to - from)
        {p, rand} = p_value(seg, q, min_size, opts, rand)

        if p > opts[:sig_level] do
          Enum.sort_by(found, & &1.index)
        else
          cp = %{index: from + tau, statistic: q, p_value: p}
          segments = List.delete(segments, {from, to}) ++ [{from, from + tau}, {from + tau, to}]
          split(segments, x, min_size, opts, rand, [cp | found])
        end
    end
  end

  # Permutation test: the share of shuffled segments whose best Q is at least q.
  defp p_value(seg, q, min_size, opts, rand) do
    r = opts[:permutations]

    {hits, rand} =
      Enum.reduce(1..r, {0, rand}, fn _, {hits, rand} ->
        {shuffled, rand} = shuffle(seg, rand)
        {_tau, qp} = best_split(shuffled, min_size, opts[:alpha])
        {if(qp >= q, do: hits + 1, else: hits), rand}
      end)

    {(hits + 1) / (r + 1), rand}
  end

  defp shuffle(list, rand) do
    {keyed, rand} =
      Enum.map_reduce(list, rand, fn v, rand ->
        {u, rand} = :rand.uniform_s(rand)
        {{u, v}, rand}
      end)

    {keyed |> Enum.sort() |> Enum.map(&elem(&1, 1)), rand}
  end

  @doc false
  # Best split point (offset in the segment) and its statistic.
  def best_split(seg, min_size, alpha) do
    t = Nx.tensor(seg, type: :f64)

    # EXLA compiles q_values once for each segment length and caches it, so the
    # permutations of one segment reuse one compiled function.
    q =
      Nx.Defn.jit_apply(&q_values/2, [t, [alpha: alpha * 1.0, min_size: min_size]],
        compiler: EXLA
      )
      |> Nx.to_flat_list()

    # Masked positions come back as the atom :neg_infinity, and atoms sort above
    # numbers in Erlang term order, so keep only the numeric values.
    q
    |> Enum.with_index()
    |> Enum.filter(fn {v, _} -> is_float(v) end)
    |> Enum.max_by(fn {v, _} -> v end)
    |> then(fn {v, tau} -> {tau, v} end)
  end

  @doc false
  # Q(t) for t = 0..n; positions outside [min_size, n - min_size] are -infinity.
  defn q_values(x, opts \\ []) do
    alpha = opts[:alpha]
    min_size = opts[:min_size]
    n = Nx.axis_size(x, 0)

    d = Nx.pow(Nx.abs(Nx.new_axis(x, 1) - Nx.new_axis(x, 0)), alpha)
    s = d |> Nx.cumulative_sum(axis: 0) |> Nx.cumulative_sum(axis: 1)
    # s[i, j] = sum of d[0:i, 0:j]
    s = Nx.pad(s, 0.0, [{1, 0, 0}, {1, 0, 0}])

    diag = Nx.take_diagonal(s)
    total = s[n][n]
    row_n = s[n]
    col_n = s[[.., n]]

    within_left = diag
    within_right = total - col_n - row_n + diag
    cross = col_n - diag

    tau = Nx.iota({n + 1}, type: :f64)
    m = tau
    k = n - tau
    valid = tau >= min_size and tau <= n - min_size

    safe_m = Nx.select(valid, m, 2.0)
    safe_k = Nx.select(valid, k, 2.0)

    e =
      2.0 * cross / (safe_m * safe_k) - within_left / (safe_m * (safe_m - 1.0)) -
        within_right / (safe_k * (safe_k - 1.0))

    Nx.select(valid, safe_m * safe_k / n * e, Nx.Constants.neg_infinity(:f64))
  end
end
