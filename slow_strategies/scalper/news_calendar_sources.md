# news_calendar_sources.md

Companion to `news_calendar.csv` (PREREG section 2.3.4 high-impact news exclusion, +/-10 min). Date fetched for every row: 2026-10-14 (UTC date of fetch session). Coverage 2026-10-19 00:00 UTC to 2027-01-31 23:59 UTC.

## Event-set definition used

PREREG (PREREG_e7c54b0.md, section 2.3.4, lines 96-99) says only 'scheduled high-impact economic announcement' and does not enumerate events, so the coordinator-supplied set was used:

- USD (symbol ALL = EURUSD and USDJPY): FOMC rate decision (statement) and press conference start; Employment Situation (NFP); CPI; Personal Income and Outlays (PCE, BEA); GDP advance/second/third (BEA); Advance Retail Sales (Census).
- EUR (symbol EURUSD): ECB monetary policy decision and press conference start; Euro area flash HICP (Eurostat).
- JPY (symbol USDJPY): BoJ policy decision (statement time not fixed; see flag below); Japan national CPI (Tokyo-area CPI is NOT included).
- US/EU/JP holidays are not events. Same-timestamp BEA releases (GDP + Personal Income and Outlays) are merged into one row; the CSV has exactly one row per table row below.

## Event table

| utc_time | symbol | event | local time + zone | source URL(s) | date fetched |
|---|---|---|---|---|---|
| 2026.10.22 23:30 | USDJPY | Japan national CPI, ref Sep 2026 | 08:30 JST (UTC+9) on 2026-10-23 | https://www.stat.go.jp/english/data/cpi/1582.html ; https://www.stat.go.jp/english/data/cpi/1585.html | 2026-10-14 |
| 2026.10.28 18:00 | ALL | FOMC rate decision / statement | 14:00 EDT (UTC-4) on 2026-10-28 | https://www.federalreserve.gov/monetarypolicy/fomccalendars.htm ; https://www.federalreserve.gov/newsevents/pressreleases/monetary20240809a.htm ; https://www.federalreserve.gov/newsevents/2026-october.htm | 2026-10-14 |
| 2026.10.28 18:30 | ALL | FOMC press conference start | 14:30 EDT (UTC-4) on 2026-10-28 | https://www.federalreserve.gov/monetarypolicy/fomccalendars.htm ; https://www.federalreserve.gov/newsevents/pressreleases/monetary20240809a.htm ; https://www.federalreserve.gov/newsevents/2026-october.htm | 2026-10-14 |
| 2026.10.29 12:30 | ALL | GDP Advance Q3 2026 + Personal Income and Outlays Sep 2026 | 08:30 EDT (UTC-4) on 2026-10-29 | https://www.bea.gov/news/schedule | 2026-10-14 |
| 2026.10.29 13:15 | EURUSD | ECB monetary policy decision | 14:15 CET (UTC+1) on 2026-10-29 | https://www.ecb.europa.eu/press/calendars/mgcgc/html/index.en.html ; https://www.ecb.europa.eu/press/pr/date/2022/html/ecb.pr220627~73acedf868.en.html | 2026-10-14 |
| 2026.10.29 13:45 | EURUSD | ECB press conference start | 14:45 CET (UTC+1) on 2026-10-29 | https://www.ecb.europa.eu/press/calendars/mgcgc/html/index.en.html ; https://www.ecb.europa.eu/press/pr/date/2022/html/ecb.pr220627~73acedf868.en.html | 2026-10-14 |
| 2026.10.30 02:40 | USDJPY | BoJ policy decision, FLAGGED window-row (statement time not fixed; typical 11:30-12:30 JST) | 11:40 JST (UTC+9) on 2026-10-30 | https://www.boj.or.jp/en/mopo/mpmsche_minu/index.htm ; https://www.boj.or.jp/en/about/calendar/index.htm | 2026-10-14 |
| 2026.10.30 03:00 | USDJPY | BoJ policy decision, FLAGGED window-row (statement time not fixed; typical 11:30-12:30 JST) | 12:00 JST (UTC+9) on 2026-10-30 | https://www.boj.or.jp/en/mopo/mpmsche_minu/index.htm ; https://www.boj.or.jp/en/about/calendar/index.htm | 2026-10-14 |
| 2026.10.30 03:20 | USDJPY | BoJ policy decision, FLAGGED window-row (statement time not fixed; typical 11:30-12:30 JST) | 12:20 JST (UTC+9) on 2026-10-30 | https://www.boj.or.jp/en/mopo/mpmsche_minu/index.htm ; https://www.boj.or.jp/en/about/calendar/index.htm | 2026-10-14 |
| 2026.11.04 10:00 | EURUSD | Eurostat flash HICP euro area, ref Oct 2026 | 11:00 CET (UTC+1) on 2026-11-04 | https://ec.europa.eu/eurostat/news/euro-indicators/release-calendar ; https://ec.europa.eu/eurostat/o/calendars/eventsJson ; https://ec.europa.eu/eurostat/about-us/impartiality-protocol | 2026-10-14 |
| 2026.11.06 13:30 | ALL | Employment Situation (NFP), ref Oct 2026 | 08:30 EST (UTC-5) on 2026-11-06 | https://www.bls.gov/schedule/news_release/empsit.htm ; https://www.bls.gov/schedule/news_release/ | 2026-10-14 |
| 2026.11.10 13:30 | ALL | US CPI, ref Oct 2026 | 08:30 EST (UTC-5) on 2026-11-10 | https://www.bls.gov/schedule/news_release/cpi.htm ; https://www.bls.gov/schedule/news_release/ | 2026-10-14 |
| 2026.11.17 13:30 | ALL | Advance Retail Sales, ref Oct 2026 | 08:30 EST (UTC-5) on 2026-11-17 | https://www.census.gov/retail/release_schedule.html | 2026-10-14 |
| 2026.11.19 23:30 | USDJPY | Japan national CPI, ref Oct 2026 | 08:30 JST (UTC+9) on 2026-11-20 | https://www.stat.go.jp/english/data/cpi/1582.html ; https://www.stat.go.jp/english/data/cpi/1585.html | 2026-10-14 |
| 2026.11.25 13:30 | ALL | GDP Second Estimate Q3 2026 + Personal Income and Outlays Oct 2026 | 08:30 EST (UTC-5) on 2026-11-25 | https://www.bea.gov/news/schedule | 2026-10-14 |
| 2026.12.01 10:00 | EURUSD | Eurostat flash HICP euro area, ref Nov 2026 | 11:00 CET (UTC+1) on 2026-12-01 | https://ec.europa.eu/eurostat/news/euro-indicators/release-calendar ; https://ec.europa.eu/eurostat/o/calendars/eventsJson ; https://ec.europa.eu/eurostat/about-us/impartiality-protocol | 2026-10-14 |
| 2026.12.04 13:30 | ALL | Employment Situation (NFP), ref Nov 2026 | 08:30 EST (UTC-5) on 2026-12-04 | https://www.bls.gov/schedule/news_release/empsit.htm ; https://www.bls.gov/schedule/news_release/ | 2026-10-14 |
| 2026.12.09 19:00 | ALL | FOMC rate decision / statement | 14:00 EST (UTC-5) on 2026-12-09 | https://www.federalreserve.gov/monetarypolicy/fomccalendars.htm ; https://www.federalreserve.gov/newsevents/pressreleases/monetary20240809a.htm ; https://www.federalreserve.gov/newsevents/2026-december.htm | 2026-10-14 |
| 2026.12.09 19:30 | ALL | FOMC press conference start | 14:30 EST (UTC-5) on 2026-12-09 | https://www.federalreserve.gov/monetarypolicy/fomccalendars.htm ; https://www.federalreserve.gov/newsevents/pressreleases/monetary20240809a.htm ; https://www.federalreserve.gov/newsevents/2026-december.htm | 2026-10-14 |
| 2026.12.10 13:30 | ALL | US CPI, ref Nov 2026 | 08:30 EST (UTC-5) on 2026-12-10 | https://www.bls.gov/schedule/news_release/cpi.htm ; https://www.bls.gov/schedule/news_release/ | 2026-10-14 |
| 2026.12.16 13:30 | ALL | Advance Retail Sales, ref Nov 2026 | 08:30 EST (UTC-5) on 2026-12-16 | https://www.census.gov/retail/release_schedule.html | 2026-10-14 |
| 2026.12.17 13:15 | EURUSD | ECB monetary policy decision | 14:15 CET (UTC+1) on 2026-12-17 | https://www.ecb.europa.eu/press/calendars/mgcgc/html/index.en.html ; https://www.ecb.europa.eu/press/pr/date/2022/html/ecb.pr220627~73acedf868.en.html | 2026-10-14 |
| 2026.12.17 13:45 | EURUSD | ECB press conference start | 14:45 CET (UTC+1) on 2026-12-17 | https://www.ecb.europa.eu/press/calendars/mgcgc/html/index.en.html ; https://www.ecb.europa.eu/press/pr/date/2022/html/ecb.pr220627~73acedf868.en.html | 2026-10-14 |
| 2026.12.17 23:30 | USDJPY | Japan national CPI, ref Nov 2026 | 08:30 JST (UTC+9) on 2026-12-18 | https://www.stat.go.jp/english/data/cpi/1582.html ; https://www.stat.go.jp/english/data/cpi/1585.html | 2026-10-14 |
| 2026.12.18 02:40 | USDJPY | BoJ policy decision, FLAGGED window-row (statement time not fixed; typical 11:30-12:30 JST) | 11:40 JST (UTC+9) on 2026-12-18 | https://www.boj.or.jp/en/mopo/mpmsche_minu/index.htm ; https://www.boj.or.jp/en/about/calendar/index.htm | 2026-10-14 |
| 2026.12.18 03:00 | USDJPY | BoJ policy decision, FLAGGED window-row (statement time not fixed; typical 11:30-12:30 JST) | 12:00 JST (UTC+9) on 2026-12-18 | https://www.boj.or.jp/en/mopo/mpmsche_minu/index.htm ; https://www.boj.or.jp/en/about/calendar/index.htm | 2026-10-14 |
| 2026.12.18 03:20 | USDJPY | BoJ policy decision, FLAGGED window-row (statement time not fixed; typical 11:30-12:30 JST) | 12:20 JST (UTC+9) on 2026-12-18 | https://www.boj.or.jp/en/mopo/mpmsche_minu/index.htm ; https://www.boj.or.jp/en/about/calendar/index.htm | 2026-10-14 |
| 2026.12.23 13:30 | ALL | GDP Third Estimate Q3 2026 + Personal Income and Outlays Nov 2026 | 08:30 EST (UTC-5) on 2026-12-23 | https://www.bea.gov/news/schedule | 2026-10-14 |
| 2027.01.08 13:30 | ALL | Employment Situation (NFP), ref Dec 2026 | 08:30 EST (UTC-5) on 2027-01-08 | https://www.bls.gov/schedule/news_release/empsit.htm ; https://www.bls.gov/schedule/news_release/ | 2026-10-14 |
| 2027.01.13 13:30 | ALL | US CPI, ref Dec 2026 | 08:30 EST (UTC-5) on 2027-01-13 | https://www.bls.gov/schedule/news_release/cpi.htm ; https://www.bls.gov/schedule/news_release/ | 2026-10-14 |
| 2027.01.15 13:30 | ALL | Advance Retail Sales, ref Dec 2026 | 08:30 EST (UTC-5) on 2027-01-15 | https://www.census.gov/economic-indicators/calendar-listview.html | 2026-10-14 |
| 2027.01.21 23:30 | USDJPY | Japan national CPI, ref Dec 2026 | 08:30 JST (UTC+9) on 2027-01-22 | https://www.stat.go.jp/english/data/cpi/1582.html ; https://www.stat.go.jp/english/data/cpi/1585.html | 2026-10-14 |
| 2027.01.22 02:40 | USDJPY | BoJ policy decision, FLAGGED window-row (statement time not fixed; typical 11:30-12:30 JST) | 11:40 JST (UTC+9) on 2027-01-22 | https://www.boj.or.jp/en/mopo/mpmsche_minu/index.htm ; https://www.boj.or.jp/en/about/calendar/index.htm | 2026-10-14 |
| 2027.01.22 03:00 | USDJPY | BoJ policy decision, FLAGGED window-row (statement time not fixed; typical 11:30-12:30 JST) | 12:00 JST (UTC+9) on 2027-01-22 | https://www.boj.or.jp/en/mopo/mpmsche_minu/index.htm ; https://www.boj.or.jp/en/about/calendar/index.htm | 2026-10-14 |
| 2027.01.22 03:20 | USDJPY | BoJ policy decision, FLAGGED window-row (statement time not fixed; typical 11:30-12:30 JST) | 12:20 JST (UTC+9) on 2027-01-22 | https://www.boj.or.jp/en/mopo/mpmsche_minu/index.htm ; https://www.boj.or.jp/en/about/calendar/index.htm | 2026-10-14 |
| 2027.01.27 19:00 | ALL | FOMC rate decision / statement [2027 date tentative per Fed; times per standing practice] | 14:00 EST (UTC-5) on 2027-01-27 | https://www.federalreserve.gov/monetarypolicy/fomccalendars.htm ; https://www.federalreserve.gov/newsevents/pressreleases/monetary20240809a.htm | 2026-10-14 |
| 2027.01.27 19:30 | ALL | FOMC press conference start [2027 date tentative per Fed; times per standing practice] | 14:30 EST (UTC-5) on 2027-01-27 | https://www.federalreserve.gov/monetarypolicy/fomccalendars.htm ; https://www.federalreserve.gov/newsevents/pressreleases/monetary20240809a.htm | 2026-10-14 |
| 2027.01.28 13:30 | ALL | GDP Advance Q4 2026 + Personal Income and Outlays Dec 2026 | 08:30 EST (UTC-5) on 2027-01-28 | https://www.bea.gov/news/schedule/next-year | 2026-10-14 |

## Flags and assumptions (read before use)

1. BoJ: the BoJ release calendar lists the statement time as 'undecided' (https://www.boj.or.jp/en/about/calendar/index.htm). Recent statements went out 11:46-12:22 JST (Mar 19, Apr 28, Jul 31 2026 statements, boj.or.jp). Each BoJ end-day (2026-10-30, 2026-12-18, 2027-01-22) is therefore encoded as three rows at 11:40, 12:00, 12:20 JST (02:40, 03:00, 03:20 UTC) so the +/-10 min rule covers 11:30-12:30 JST continuously. These rows are a window encoding, not a published time. The Governor's press conference time is not stated by any fetched official page and is NOT included. All BoJ and Japan CPI rows fall outside the 07:00-16:00 UTC trading session anyway.
2. FOMC 2027-01-27: date listed by federalreserve.gov but 'tentative until confirmed at the meeting immediately preceding it'. The Fed's January 2027 monthly calendar page (newsevents/2027-january.htm) returned 404 at fetch time; 14:00 / 14:30 ET come from the Fed's standing practice statement (monetary20240809a.htm). The Dec 9, 2026 calendar page footer says 'last updated June 24, 2025'.
3. Eurostat: the official calendar (JSON feed https://ec.europa.eu/eurostat/o/calendars/eventsJson, used by the release-calendar page) gives dates only (entries are all-day). 11:00 CET/CEST is Eurostat's stated first-release time (impartiality protocol: 'publish Eurostat first data releases at 11 am CET'). The calendar was published only through 2026-12-18 at fetch time.
4. BLS, BEA and Census pages show times such as '08:30 AM'. BLS states 'All times on calendar are Eastern Time'. BEA and Census pages do not state the zone in the fetched text; Eastern is assumed (standard for both agencies).
5. The Census retail_schedule page (https://www.census.gov/retail/release_schedule.html) lists Dec 2026 data as 'To be announced'; the Census economic-indicators calendar (retcal) lists Jan 15, 2027 08:30 AM for it and is the source used for that row. Re-check if US government operations are disrupted; BLS/BEA/Census dates can slip.
6. Japan CPI dates cross-checked against the Statistics Bureau rule 'Friday of the week including the 19th, 08:30 JST' (Q&A C-1): Oct 23, Nov 20, Dec 18 2026 and Jan 22 2027 all satisfy it. The schedule page 'Last Update' is 2026-01-23.
7. ECB times: decision 14:15 CET/CEST, press conference 14:45 CET/CEST (ECB press release of 2022-06-27, in force since 21 July 2022). Day 2 of each meeting is the decision day (ECB calendar: 'Day 2, followed by press conference').

## Unconfirmed (left out of the CSV)

- Eurostat flash HICP for Dec 2026 (would publish early Jan 2027): not in the official calendar at fetch time (calendar ends 2026-12-18). Likely ~2027-01-05/06 but NOT confirmed.
- BoJ Governor press conference time on 2026-10-30, 2026-12-18, 2027-01-22: not published in fetched official pages.
- Exact BoJ statement release time (only the typical window is encoded, see flag 1).
- Any release after the 2027-01-31 coverage end, and ECB meeting 2027-02-04 (outside coverage).

## DST rules applied

- US (America/New_York): EDT = UTC-4 until 2026-11-01 02:00 local; EST = UTC-5 from 2026-11-01. Rows on 2026-10-28 and 2026-10-29 use UTC-4; all later rows use UTC-5.
- EU (Europe/Berlin for CET/CEST, same rules as Frankfurt/Luxembourg): CEST = UTC+2 until 2026-10-25 03:00 local; CET = UTC+1 from 2026-10-25. All ECB and Eurostat rows here are after that date, so CET UTC+1 (14:15 -> 13:15 UTC, 14:45 -> 13:45 UTC, 11:00 -> 10:00 UTC).
- Japan (Asia/Tokyo): JST = UTC+9, no DST. 08:30 JST = 23:30 UTC on the previous calendar day.
- Conversion done with Python zoneinfo (IANA tz database) and sanity-checked against the manual offsets above.
