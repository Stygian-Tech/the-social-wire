# Sports Topic V1

Sports shares Wire canonical articles, moderation and retractions, the consolidated
Projection Pool, and fenced Coordinator. It does not select only Wire front-page
winners. Postgres owns catalog snapshots, analyses, generations, immutable
personalized snapshots, and optional event caches. Redis is disposable.

Sports analysis batches use a nonblocking transaction lock shared across Projection
Pool replicas. An overlapping cycle skips immediately; each accepted batch commits
on one connection, and rollback restores its sweep position. This bounds duplicate
work without reducing shared ingestion capacity.

## Activation

Set `SPORTS_FEED_MODE=off|shadow|api|visible` consistently on App View, Gateway,
Coordinator, and Projection Pool. Default `off` creates no Sports analysis or
provider work. `shadow` analyzes and generates without article serving; `api`
serves without navigation; `visible` exposes navigation when usable coverage exists.
Use `SPORTS_CURSOR_HMAC_SECRET` or the existing Wire cursor signing secret.

Run schema changes through Database Migrator before dependent services. Required
Sports migrations: `20261003010000_sports_feed.sql` and
`20261004010000_sports_standings.sql`. Deployment ordering remains
Migrator-owned, not a Gateway pre-deploy migration.

Development rollout proceeds shadow → API → visible after deterministic resolution,
ranking, moderation and pagination checks and a bounded shared-service pressure
check. No Production deployment or provider subscription purchase is part of this
change. Capability endpoints report unavailable states while the feature is gated.

## Coverage

The reviewed identity catalog includes global sports and competitions, major US
professional teams and women's competitions, football/cricket/F1 teams, distinct
NCAA school and sport-specific team identities, and identity-only athlete/driver
references. The initial NCAA catalog is a reviewed subset; it is not every Division
I program. Provider imports expand reviewed competition teams and rosters without
requiring a per-athlete hand-authored catalog. Search and named feeds expose active
supported identities only. Team-only feeds never fill with unrelated global news.

Reviewed people use Wikidata identity references, not inferred current team or
image rights. Verified references include [Hamilton](https://www.wikidata.org/wiki/Q9673),
[Verstappen](https://www.wikidata.org/wiki/Q2239218),
[Wilson](https://www.wikidata.org/wiki/Q21623331),
[Williams](https://www.wikidata.org/wiki/Q11459),
[Messi](https://www.wikidata.org/wiki/Q615),
[James](https://www.wikidata.org/wiki/Q36159), and
[Kohli](https://www.wikidata.org/wiki/Q213854).

## Optional Provider Data

Reference and roster import requires all of:

- Server-only `THESPORTSDB_API_KEY`.
- `SPORTS_PROVIDER_RIGHTS_CONFIRMED=true` after recording applicable plan, storage,
  display and attribution review in TSW-40. This assertion is not the review evidence.
- `SPORTS_REVIEWED_COMPETITIONS`: JSON mapping reviewed opaque internal competition
  IDs to verified numeric TheSportsDB league IDs.
- Snapshot-level projection invalidation, verified before enabling provider imports.
  Analysis revisions use the full snapshot hash, and the projector rebuilds its
  entity index when that revision changes. Existing analyses remain available;
  the projector rebuilds prior catalog revisions in bounded batches. Validate this
  path before importing newly reviewed competition rosters.

Scores and schedules additionally require `SPORTS_EVENTS_ENABLED=true`, default
false. This controls shared event polling, independently of news and reference
imports. A viewer's **Hide Scores** does not affect shared provider polling. No
client receives the provider key, OAuth credentials, or another viewer's interests.

`SPORTS_REVIEWED_SEASONS` is a JSON map of internal competition IDs to a reviewed
season (`2026` or `2026-2027`). It enables hourly, bounded full-season schedules
in addition to next/recent fixture refresh. `SPORTS_REVIEWED_STANDINGS` is a JSON
array of those competition IDs with separately verified league-table coverage.
The documented TheSportsDB table endpoint is V1 and limited to featured football
leagues; do not add NCAA, motorsport, DCI, or other unsupported competitions by
assumption. Its server-only key appears in the provider request path; never log
that path or return it as attribution. [Provider endpoint documentation](https://www.thesportsdb.com/documentation)

Tables retain provider-reported ranks and statistics, never rankings reconstructed
from the fixture cache. `getSportsEvents` includes optional standings and a
`schedulesStatus` distinguishing unavailable coverage from successful empty data.
Each table carries season, source, freshness and degradation. Failed refreshes
preserve prior snapshots for up to 72 hours. **Hide Scores** suppresses the entire
standings presentation as well as fixture scores and result indicators.

Provider table descriptions flow automatically into optional row zones on each
hourly refresh. Current places are not guaranteed outcomes, and no universal
points threshold is calculated. The reviewed 2026/27 EPL bottom-three and EFL
Championship promotion/play-off places can also hydrate retained pre-zone tables,
only when the full expected rank set is present. Championship play-offs cover
places 3–8 from 2026/27, per the [official EFL format change](https://www.efl.com/news/2026/march/05/efl-statement--sky-bet-championship-play-off-format/).
League One and League Two use current provider annotations rather than guessed
rules. Reviewed Development coverage now includes 38 competitions and 13 current
standings tables; see `docs/provider-review/thesportsdb-standings-2026-10-04.json`.
Coverage review happens before enabling a competition; regular label refresh then
needs no per-event manual action. An official-site scraping pipeline has not been
implemented, and future season rule changes still require review before activation.


The intended budget is the $20/month Small Business tier; purchasing it remains
an operator action. Coverage must be checked for each competition. Do not advertise
all sports as live or promise cricket, rugby, NCAA, and motorsport live coverage.
Preserve attribution and timestamps. Generic icons avoid third-party artwork rights.
See [pricing](https://www.thesportsdb.com/docs_pricing.php),
[terms](https://www.thesportsdb.com/docs_terms_of_use.php), and
[documented V2 endpoints](https://www.thesportsdb.com/documentation).

Requests are shared and bounded by Coordinator cycles, rather than per reader or
feed. Daily reference/roster refresh, hourly schedule refresh, and five-minute active
event refresh retain last-successful snapshots during failure. Enabling a very large
competition map requires measuring refresh queue latency before visibility.

Event status and standings zone payloads use `v2` refresh claim keys. The cutover
queues one ordinary bounded refresh per reviewed resource while retaining existing
successful payloads and claim history. Reference, roster, and full-season schedule
keys keep their existing cadence; no claim resets or direct database writes are needed.

## Preferences and Acceptance

`app.thesocialwire.sports.selection` records store `reference`, `action=follow|mute`,
`createdAt`, and `updatedAt`; record key is hexadecimal SHA-256 of the opaque
reference. A change from follow to mute replaces one record. Clients write directly
to the viewer PDS with OAuth DPoP. Existing sessions need reauthorization for the
new collection write scope before saving acceptance.

Interests and exclusions are public, express no affiliation, and may be copied.
Removal deletes the PDS record and app-owned derived state; downstream copies
cannot be retracted. A direct team/person follow overrides a broader sport or
competition mute, while an explicitly muted team/person wins.

`showSports` defaults true; `hideSportsScores` defaults false. Every preference
writer preserves both. Hide Scores removes event scores/results only; headlines and
images may reveal results. Article taps open the publisher directly. Native News
keeps the existing four configurable primary slots.

Acceptance must include authenticated PDS write/remove/reconcile, feed refresh and
continuation handoff, direct publisher opening, light/dark appearance, responsive
web and iOS, and hidden scores. Passing unit suites does not establish authenticated
or provider-enabled acceptance. Record deployment IDs, actual coverage, failures,
pressure measurements, and remaining gates in TSW-40.
