-- Per (agent, domain), over final forecasts. Murphy decomposition over decile buckets:
--   reliability = sum_k n_k (pbar_k - obar_k)^2 / N
--   resolution  = sum_k n_k (obar_k - obar)^2 / N
--   uncertainty = obar (1 - obar)
-- Brier ~= reliability - resolution + uncertainty (exact when each bucket holds one
-- probability). skill = 1 - mean_brier / uncertainty: the Brier skill score against
-- always forecasting the base rate obar of the same questions.
CREATE VIEW rules.cal_summary AS
WITH totals AS (
  SELECT agent_id, domain, count(*) AS n, avg(brier) AS mean_brier, avg(log_score) AS mean_log_score,
         avg(outcome::int::double precision) AS base_rate
  FROM rules.cal_score WHERE is_final
  GROUP BY agent_id, domain
),
parts AS (
  SELECT b.agent_id, b.domain,
         sum(b.n * power(b.mean_probability - b.observed_frequency, 2)) AS rel_sum,
         sum(b.n * power(b.observed_frequency - t.base_rate, 2)) AS res_sum
  FROM rules.cal_bucket b JOIN totals t USING (agent_id, domain)
  GROUP BY b.agent_id, b.domain
)
SELECT t.agent_id, a.name AS agent_name, a.kind AS agent_kind, t.domain, t.n,
       t.mean_brier, t.mean_log_score, t.base_rate,
       p.rel_sum / t.n AS reliability,
       p.res_sum / t.n AS resolution,
       t.base_rate * (1 - t.base_rate) AS uncertainty,
       CASE WHEN t.base_rate * (1 - t.base_rate) > 0
            THEN 1 - t.mean_brier / (t.base_rate * (1 - t.base_rate)) END AS skill
FROM totals t
JOIN parts p USING (agent_id, domain)
JOIN agents a ON a.id = t.agent_id;

COMMENT ON VIEW rules.cal_summary IS
  'An agent''s calibration in a domain is its mean Brier and log score, its skill against the base rate, and the Murphy decomposition of its final forecasts.';
