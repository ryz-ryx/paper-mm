# News calendar: independent verification (P4 / T3)

- Built by: `calendar-builder` agent (2026-10-14), file `news_calendar.csv` v1 (38 rows, sha256 `fdc716e15f498647180707bb2d7e9364a39aefdf378a35a94f6ec648cc0ed59c`).
- Verified by: `calendar-verifier` agent (did not build the file), 2026-10-14 ~17:15 UTC, read-only, every row re-checked against the official source page (WebFetch).
- Result on v1: **0 OVERTURNED**, 26 CONFIRMED, 11 ESTIMATE, 1 UNVERIFIABLE, 1 missing event (see below). Format PASS: ASCII, LF only, no BOM, header `utc_time,symbol`, 2 fields per row, sorted, no duplicates.
- v2 (this commit): v1 + 39 margin/estimate rows proposed by the verifier, 77 rows, sha256 `31a37b668509d16d70ec3aaac3a314385075c051c867ad6161b8de15e99a90d5`. No v1 row was removed or changed.

The EA blocks entries within +/-10 min (inclusive) of each row for the matching symbol (`ALL` = both). Only rows inside the session 07:00-16:00 UTC Mon-Fri affect trading.

## DST rules applied
US EDT (UTC-4) until 2026-11-01 02:00 local, then EST (UTC-5). EU CEST until 2026-10-25 01:00 UTC, then CET (UTC+1). Japan JST (UTC+9), no DST.

## v1 rows: decisions

| Row (UTC) | Symbol | Event | Decision | Source |
|---|---|---|---|---|
| 2026.10.22 23:30 | USDJPY | Japan national CPI (Sep), 08:30 JST Oct 23 | CONFIRMED | stat.go.jp/english/data/cpi/1582.html, 1585.html |
| 2026.10.28 18:00 | ALL | FOMC statement 14:00 EDT | CONFIRMED | federalreserve.gov/monetarypolicy/fomccalendars.htm; time: monetary20240809a |
| 2026.10.28 18:30 | ALL | FOMC press conference 14:30 EDT | CONFIRMED | same |
| 2026.10.29 12:30 | ALL | GDP advance Q3 + Personal Income Sep, 08:30 EDT | CONFIRMED (ET assumed, not printed) | bea.gov/news/schedule |
| 2026.10.29 13:15 | EURUSD | ECB decision 14:15 CET | CONFIRMED | ecb.europa.eu calendar + ecb.pr220627 |
| 2026.10.29 13:45 | EURUSD | ECB press conference 14:45 CET | CONFIRMED | same |
| 2026.10.30 02:40, 03:00, 03:20 | USDJPY | BoJ MPM statement | **ESTIMATE** (statement time "undecided") | boj.or.jp/en/mopo/mpmsche_minu/index.htm |
| 2026.11.04 10:00 | EURUSD | Euro area flash HICP | CONFIRMED date, **ESTIMATE time** (11:00 CET from Eurostat impartiality protocol) | Eurostat release page "Next release: 4 November 2026" |
| 2026.11.06 13:30 | ALL | Employment Situation (Oct) | CONFIRMED | bls.gov/schedule/news_release/empsit.htm |
| 2026.11.10 13:30 | ALL | CPI (Oct) | CONFIRMED | bls.gov/schedule/news_release/cpi.htm |
| 2026.11.17 13:30 | ALL | Advance retail sales (Oct) | CONFIRMED | census.gov/retail/release_schedule.html |
| 2026.11.19 23:30 | USDJPY | Japan national CPI (Oct) | CONFIRMED | stat.go.jp 1582 |
| 2026.11.25 13:30 | ALL | GDP second Q3 + Personal Income Oct | CONFIRMED | bea.gov/news/schedule |
| 2026.12.01 10:00 | EURUSD | Euro area flash HICP | **UNVERIFIABLE** (Eurostat dynamic calendar feed returned empty) | ec.europa.eu/eurostat release calendar |
| 2026.12.04 13:30 | ALL | Employment Situation (Nov) | CONFIRMED | bls.gov empsit |
| 2026.12.09 19:00 | ALL | FOMC statement 14:00 EST | CONFIRMED | federalreserve.gov |
| 2026.12.09 19:30 | ALL | FOMC press conference | CONFIRMED | same |
| 2026.12.10 13:30 | ALL | CPI (Nov) | CONFIRMED | bls.gov cpi |
| 2026.12.16 13:30 | ALL | Advance retail sales (Nov) | CONFIRMED | census.gov |
| 2026.12.17 13:15 | EURUSD | ECB decision | CONFIRMED | ecb.europa.eu |
| 2026.12.17 13:45 | EURUSD | ECB press conference | CONFIRMED | same |
| 2026.12.17 23:30 | USDJPY | Japan national CPI (Nov) | CONFIRMED | stat.go.jp 1582 |
| 2026.12.18 02:40, 03:00, 03:20 | USDJPY | BoJ MPM statement | **ESTIMATE** | boj.or.jp mpmsche |
| 2026.12.23 13:30 | ALL | GDP third Q3 + Personal Income Nov | CONFIRMED | bea.gov |
| 2027.01.08 13:30 | ALL | Employment Situation (Dec) | CONFIRMED | bls.gov empsit |
| 2027.01.13 13:30 | ALL | CPI (Dec) | CONFIRMED | bls.gov cpi |
| 2027.01.15 13:30 | ALL | Advance retail sales (Dec) | CONFIRMED | census.gov/economic-indicators/calendar-listview.html |
| 2027.01.21 23:30 | USDJPY | Japan national CPI (Dec) | CONFIRMED | stat.go.jp 1582 |
| 2027.01.22 02:40, 03:00, 03:20 | USDJPY | BoJ MPM statement | **ESTIMATE** | boj.or.jp mpmsche |
| 2027.01.27 19:00, 19:30 | ALL | FOMC (2027 dates tentative) | **ESTIMATE (tentative)** | federalreserve.gov ("tentative until confirmed at the preceding meeting") |
| 2027.01.28 13:30 | ALL | GDP advance Q4 + Personal Income Dec | CONFIRMED | bea.gov/news/schedule/next-year |

Missing from v1: euro area flash HICP for December 2026 (due early January 2027; date not yet published by Eurostat). Precedent: 2026-01-07, 2025-01-03.

## v2 margin rows added (all marked ESTIMATE; conservative: they only add blocked minutes)

| Rows | Purpose | In session? |
|---|---|---|
| 2026.10.30 / 2026.12.18 / 2027.01.22 at 02:20, 03:40, 04:00 USDJPY | BoJ statement window widened to 02:10-04:10 UTC (11:10-13:10 JST) | no |
| 2026.10.30 / 2026.12.18 / 2027.01.22 at 06:30, 06:50, 07:10 USDJPY | BoJ Governor press conference (~15:30 JST, unpublished); blocks to 07:20 UTC | 07:10 rows yes |
| 2026.11.04 09:50, 10:10 EURUSD; 2026.12.01 09:50, 10:10 EURUSD | Eurostat 11:00 CET time estimate widened to +/-20 min | yes |
| 2026.11.30 10:00, 2026.12.02 10:00 EURUSD | insurance for the unverifiable 2026-12-01 flash HICP date | yes |
| 2027.01.04 .. 2027.01.08 at 09:50, 10:00, 10:10 EURUSD | December 2026 flash HICP, date unpublished: all candidate days blocked 09:40-10:20 UTC | yes |

Test window coverage: start no earlier than 2026-10-22; hard stop = start + 8 weeks (>= 2026-12-17). The calendar covers 2026-10-22 .. 2027-01-31.
