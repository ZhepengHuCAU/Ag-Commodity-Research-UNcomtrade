---
name: uncomtrade-downloader
description: Download UN Comtrade commodity trade data by HS code, annual or monthly period, reporter-country scope, partner-country scope, and import/export flow. Use when a user asks to retrieve, refresh, compare, or validate UN Comtrade bilateral trade data, including country rankings and national import-export time series.
---

# UN Comtrade Downloader

Use `scripts/Download-UnComtrade.ps1` to download reported commodity trade data from the current UN Comtrade Plus service and to create analysis-ready CSV files and validation charts.

## Request details

Confirm or infer these parameters before running:

- `HsCode`: one or more HS commodity codes, comma-separated.
- `Period`: annual `YYYY` values or monthly `YYYYMM` values, comma-separated.
- `Frequency`: `A` for annual or `M` for monthly.
- `Reporters`: `all`, ISO3 codes such as `CHN,USA`, country names shown by UN Comtrade, or M49 codes.
- `Partners`: `all`, `world`, ISO3 codes that appear in the selected data availability, or M49 codes.
- `Flows`: `M`, `X`, or `M,X`.

Treat the reporter as the country reporting the statistics. Treat `partner=World` records as reporter totals. Never sum bilateral partner rows to create a country total because a World row may already be present. UN Comtrade commonly flags World totals as aggregate/derived; preserve that official total for rankings and time series, and expose its flags in the summary CSV.

## Run

Run from the directory where the user wants results written. Use the script path in this skill. Prefer the default `reported-nonaggregate` quality filter for rankings and charts; retain the raw file for transparency.

```powershell
& "$PSScriptRoot/scripts/Download-UnComtrade.ps1" `
  -HsCode 151800 `
  -Period '2024,2025' `
  -Frequency A `
  -Reporters 'CHN,USA' `
  -Partners all `
  -Flows 'M,X' `
  -TimeSeriesReporter CHN
```

For an all-reporter ranking, use `-Reporters all`. Warn that this triggers one request per currently available reporter and can take several minutes. For monthly data, require periods such as `202501,202502`; do not accept bare years.

## Deliverables and checks

Inspect `run_metadata.json`, `download_errors.csv`, `empty_result_reporter_periods.csv`, and `data_availability.csv` before drawing conclusions. The script writes:

- raw records and a cleaned standardized CSV;
- World-total country summaries;
- top-10 importer/exporter CSV files and tonnage/value bar charts;
- optional selected-country import/export time-series CSV and charts.

For `TimeSeriesReporter=CHN`, exclude the latest requested period from the validation chart by default and annotate the exclusion. Keep the latest period in raw download files. Pass `-IncludeLatestChinaValidationPeriod` only when the latest China period is intentionally part of the validation.

State the exact extraction date, HS codes, frequency, periods, quality filter, and whether data are reported or derived. Explain that missing data, download errors, and empty responses are not zero trade, and that UN Comtrade can revise released data. For comparisons with another source, compare like-for-like: reporter, flow, partner scope, HS revision, period, and quantity definition.

If the top-10 chart contains a coverage caution, call it a ranking among successfully returned reporter-periods, not a complete world ranking. Use `empty_result_reporter_periods.csv` to re-query important countries individually.

## Boundaries

The default downloader uses the current UN Comtrade Plus web service without a user API key. It refreshes the web-session token periodically and after an empty response, but the service interface can change. For unusually large or production-scale extraction, recommend the official subscription API or bulk files and preserve the downloaded raw records and run metadata.
