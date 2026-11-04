CREATE VIEW rules.cal_bucket AS
SELECT s.agent_id, s.domain,
       least(floor(s.probability * 10), 9)::int AS bucket,
       count(*) AS n,
       avg(s.probability) AS mean_probability,
       avg(s.outcome::int::double precision) AS observed_frequency
FROM rules.cal_score s
WHERE s.is_final
GROUP BY s.agent_id, s.domain, least(floor(s.probability * 10), 9);

COMMENT ON VIEW rules.cal_bucket IS
  'Final forecasts of an agent in a domain fall into probability deciles, each with its count, mean probability and observed frequency.';
