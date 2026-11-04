# Pack: regional_economy

This pack forecasts public economic series for Ingham County (Lansing), Michigan. It shows that the ForecastLoop core works for a domain with no events, only monthly series from public publishers.

## Signals

| Signal | Source | What it measures |
| --- | --- | --- |
| `ingham_unemployment_rate` | FRED `MIINGH5URN` | Unemployment rate, Ingham County, not seasonally adjusted (BLS LAUS). |
| `ingham_labor_force` | FRED `MIINGH5LFN` | Civilian labor force, Ingham County. |
| `mi_building_permits` | FRED `MIBPPRIV` | New private housing units authorized by building permits, Michigan. |
| `mi_business_applications` | FRED `BABATOTALSAMI` | Business applications, Michigan, seasonally adjusted. The pack uses these as the count of new business registrations. |
| `ingham_unemployment_rate_bls` | CSV file you supply | The same LAUS series from BLS, the original publisher. |

All FRED signals use the generic `http_csv` source. No private API or key is necessary.

Two limits apply to the data:

- **Permits are state-level.** FRED has no monthly building-permit series for the county or for the Lansing metro area. It has only an annual county series (`BPPRIV026065`).
- **The BLS signal has no download.** BLS has no plain CSV download. Save the series `LAUCN260650000000003` as `priv/packs/regional_economy/data/LAUCN260650000000003.csv` with the columns `DATE,VALUE`. Until you do, each run opens a `refresh_failed` work item for this signal. That work item is the system's request for the data.

**Publication lag.** FRED's CSV gives no publication dates. Each signal sets `publication_lag`, which is when a month's value is assumed to have become known (for example `P1M30D` after the month starts). A later revision is stamped with the real fetch time. These lags are approximate.

## Derived series

- `ingham_unemployment_3m_change`: the rate minus the rate 3 months earlier.
- `mi_permits_quarterly`: permits summed by calendar quarter. A quarter appears only when its last month is published.
- `mi_permits_quarterly_yoy`: the quarterly sum minus the same quarter one year earlier.

## Templates

- `ingham_unemployment_above`: "Is the Ingham County unemployment rate above 4.5% for the last month of the quarter?" Change `params.x` to move the threshold.
- `mi_permits_beat_prior_year`: "Do Michigan building permits in the quarter exceed the same quarter one year earlier?"

## Knowledge facts

| Fact | Meaning |
| --- | --- |
| `entity_alias` "Ingham County, MI" → "Ingham County" | Two spellings name one place. |
| `entity_attr` Ingham County → `state=Michigan` | The county is in Michigan. The domain rule follows this link. |
| `entity_attr` → `fips=…` | FIPS codes, for reference. |
| `entity_domain` Ingham County, Michigan → `regional_economy` | Observations about these places belong to this domain. |
| `min_history` regional_economy → 24 | Two years of points before base-rate models run. |
| `same_as` FRED rate ↔ BLS rate | One series from two publishers. BLS ranks first. A difference above 0.05 points opens a `gap_source_conflict` work item. |

## Fixtures

`fixtures/*.csv` are the four FRED CSV downloads, recorded on 2026-11-03. The end-to-end test serves them in place of the network. The October 2025 values are empty in the source data.
