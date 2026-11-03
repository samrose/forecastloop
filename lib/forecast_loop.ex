defmodule ForecastLoop do
  @moduledoc """
  ForecastLoop is a computational-futurology application: a forecast ledger and a
  model registry, driven by a rule layer of PostgreSQL views. A nightly batch runs
  this loop:

      narrative exploration → model construction → probabilistic forecasting →
      Forecast Integrity Protocol validation → predictability-collapse detection →
      model revision → repeat

  ## Attribution

  The framework that this application implements is Peter Rothman's
  *Computational Futurology*: the Computational Predictability Hypothesis, the
  seven principles, the Forecast Integrity Protocol (FIP), predictability collapse
  as `H(Future) − H(Future | Present)`, and the loop above. Peter Rothman is
  Lecturer in Computational Futurology at UC Santa Cruz. Source: "Computational
  Futurology: Moving Beyond 20th-Century Foresight", LinkedIn, 10 March 2026,
  <https://www.linkedin.com/pulse/computational-futurology-moving-beyond-20th-century-peter-rothman-gxonc/>.

  The design and code of this application, and any errors in how it interprets
  the framework, are ours and not his.
  """
end
