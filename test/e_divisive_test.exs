defmodule EDivisiveTest do
  use ExUnit.Case, async: true

  # Deterministic noise in [-0.5, 0.5).
  defp noise(n, seed) do
    {xs, _} =
      Enum.map_reduce(1..n, :rand.seed_s(:exsss, {seed, 1, 2}), fn _, s ->
        {u, s} = :rand.uniform_s(s)
        {u - 0.5, s}
      end)

    xs
  end

  test "finds a planted mean shift" do
    xs = Enum.take(noise(30, 1), 30) ++ Enum.map(noise(30, 2), &(&1 + 3.0))
    assert [%{index: i, p_value: p, statistic: q}] = EDivisive.detect(xs)
    assert i in 29..31
    assert p <= 0.05 and q > 0
  end

  test "finds two shifts" do
    xs =
      noise(25, 1) ++ Enum.map(noise(25, 2), &(&1 + 3.0)) ++ Enum.map(noise(25, 3), &(&1 - 2.0))

    assert [%{index: i}, %{index: j}] = EDivisive.detect(xs)
    assert i in 24..26 and j in 49..51
  end

  test "finds nothing in noise without a shift" do
    assert EDivisive.detect(noise(60, 7)) == []
  end

  test "a series shorter than two minimum segments has no change points" do
    assert EDivisive.detect([1, 2, 3], min_size: 2) == []
    assert EDivisive.detect([], []) == []
  end

  test "is deterministic for the same seed, and accepts a tensor" do
    xs = noise(20, 4) ++ Enum.map(noise(20, 5), &(&1 + 2.0))
    assert EDivisive.detect(xs) == EDivisive.detect(xs)
    # A tensor is read as given; an f64 tensor holds the same values as the list.
    assert EDivisive.detect(Nx.tensor(xs, type: :f64)) == EDivisive.detect(xs)
  end

  test "q_values matches the definition at one split" do
    xs = [1.0, 2.0, 4.0, 10.0, 11.0, 13.0]

    q =
      EDivisive.q_values(Nx.tensor(xs, type: :f64), alpha: 1.0, min_size: 2) |> Nx.to_flat_list()

    {a, b} = Enum.split(xs, 3)
    cross = for(x <- a, y <- b, do: abs(x - y)) |> Enum.sum()
    wa = for(x <- a, y <- a, do: abs(x - y)) |> Enum.sum()
    wb = for(x <- b, y <- b, do: abs(x - y)) |> Enum.sum()
    e = 2 * cross / 9 - wa / 6 - wb / 6
    assert_in_delta Enum.at(q, 3), 3 * 3 / 6 * e, 1.0e-9
    assert Enum.at(q, 1) == :neg_infinity
  end
end
