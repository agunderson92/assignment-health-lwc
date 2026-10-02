# assignment-health-lwc
Salesforce LWC for Engagement and homepage to provide insight into burn rate and assignment health

# Workstream 2 — Engagement Burn LWCs (starter scaffold)

Two read-only Lightning Web Components backed by one Apex controller, reusing the
methodology validated in the `kantata-engagement-burn` skill. This is a drafting
starting point, not production-ready — see "Before production" below.

## What's here

- `classes/EngagementBurnController.cls` — read-only Apex. Three `@AuraEnabled(cacheable=true)` methods:
  - `getEngagementBurn(engagementId)` → one engagement + its assignment detail (for the record page).
  - `getMyPortfolio()` → the logged-in user's active engagements where they are EM, worst-first (rollup).
  - `getPortfolioAll(managerUserId, accountId)` → **all** active engagements, optionally filtered by manager and/or account, fully computed and returned worst-first (leadership view). The client sorts and paginates.
- `lwc/engagementBurnPanel/` — drops on the **Engagement (`KimbleOne__DeliveryGroup__c`) record page**. Shows the burn-to-date + projection table for that engagement.
- `lwc/myPortfolioBurn/` — drops on the **Home page** (or an App page). Shows the EM's active engagements, worst-first, each row navigates to the engagement.
- `lwc/allEngagementsBurn/` — drops on a **Home or App page for leadership**. Shows all active engagements with Account + Manager columns, filterable by Account and Engagement Manager (`lightning-record-picker`), sorted globally and paginated 20/page client-side. Each row navigates to the engagement.
- `lwc/capBurndown/` — **leadership Home/App page**. Revenue-cap trending: one row per Resourced Activity that has a Usage Cap, filterable, globally sorted, paginated. Consumed $ and forecast $ vs the cap, with projected overage and a cap status. Includes the same color-coded **"% of cap used" bar chart** across the full filtered set (scrollable).
- `lwc/engagementCaps/` — **Engagement record page**. The same cap trending scoped to the engagement being viewed, plus a color-coded **"% of cap used" bar chart** (one bar per element: green ≤ 50%, yellow 50–80%, red > 80%).
- `lwc/myCaps/` — **Home page** (or App page). Capped activities on the logged-in user's active engagements where they are EM (owner or Delivery Actor) — the cap analogue of `myPortfolioBurn`. Includes the same color-coded **"% of cap used" bar chart**.

Sorting & navigation (all datatable widgets): columns are sortable (default sort = revenue at risk / % of cap, highest first; nulls last), and the row arrow opens the target record in a **new browser tab**. The leadership widgets fetch the full filtered result set once and sort + paginate **client-side**, so ordering is global across all pages (not per-page) and paging / re-sorting is instant.

### Revenue caps (`getEngagementCaps`, `getAllActivityCaps`, `getMyCaps`)

The Usage Cap (`KimbleOne__UsageRevenueCap__c`) lives on the **Resourced Activity**, one cap per activity, and an engagement can have several. Cap trending is kept at **activity grain and never rolled up to the engagement** — aggregating would net a low-forecasting element against an over-forecasting one and hide the risk. Kimble already stores the actuals (`KimbleOne__ActualRevenue__c`, `KimbleOne__ActualUsageRevenueToCapFactor__c`) and forecast (`KimbleOne__ForecastP3Revenue__c`), so no revenue is recomputed from hours.

Status (a forecast trending *up to* 100% of the cap is healthy; only a forecast that projects to **exceed** it is a risk):
- **Over cap** — the cap is already fully consumed (consumed ≥ 100%).
- **At risk** — forecast projects to **exceed** the cap (forecast > 100%, cap not yet consumed).
- **Under-running** — forecast < `CAP_UNDER_PCT` (70%) of the cap (leaving cap unspent).
- **On track** — forecast is 70–100% of the cap.

Note: `ForecastP3Revenue` is total activity revenue; for activities with material expense revenue it slightly overstates the usage-cap comparison — refine with a usage-specific forecast field if that becomes an issue. The `engagementCaps` chart colors bars by **% of cap *used*** (consumed ÷ cap): green ≤ 50%, yellow 50–80%, red > 80% — a separate visual scale from the status above.

### Leadership sorting / scale design

The leadership widgets need a **global** sort (correct ordering across every page, not just the visible one), which means every matching row must be computed before sorting. `getPortfolioAll` therefore computes the whole filtered active set and returns it in one cacheable call; the LWC sorts and paginates client-side, so re-sorting and paging are instant and always global.

To keep the server call within the synchronous heap limit (~6 MB), engagements are computed in **chunks** of `ENGAGEMENT_CHUNK` (50): each chunk's assignment rows fall out of scope before the next chunk loads, so peak heap stays bounded even across the full org-wide active set (~500 engagements / ~5–6k assignments measured). `getAllActivityCaps` needs no chunking — capped activities are a small subset (dozens) and read straight from queryable fields. If the active-engagement volume grows by an order of magnitude, revisit this (e.g. move the compute to a scheduled job that caches per-engagement burn, then query/sort that).

## How it maps to the methodology

- % complete / % consumed come straight from the `Complete__c` / `Hours_Consumed__c` formula fields — no recomputation.
- Trailing run-rate = one aggregate over `KimbleOne__TimeEntry__c` (day-level `KimbleOne__TimePeriod__r.KimbleOne__StartDate__c`, hours from `KimbleOne__EntryUnitsInHours__c`), last 42 days ÷ 6 (÷ tenure for <6-week resources).
- Revenue model via the 5-hop path to `KimbleOne__RevenueGenerationModel__r.Name` → T&M (BillableEffortExpended) shows $ at risk; Fixed-bid (VariableAmountPerMilestone) flips risk to over-burn and shows no $; None = utilization only.
- Carve-outs: currently-running only (`ForecastP3EndDate >= today`), phantom (forecast>0/actual=0) → "Verify", as-needed (forecast=0/actual>0), too-early / <6wk → "Monitor", ~40-hr floor for engagement status.
- EM resolution: Owner OR `KimbleOne__DeliveryGroupActor__c` with `KimbleOne__ActorRole__r.Name = 'Engagement Manager'`. Active filter: `ExpectedStartDate <= today < ExpectedEndDate` AND `ForecastStatus.Name IN ('Closed Won (100%)','WAR (80%)')`.

## Thresholds (tune with Delivery Ops)

Constants at the top of the Apex: `BAND_ONTRACK=10`, `BAND_WATCH=20`, `LATE_STAGE_PCT=85`,
`TOO_EARLY_PCT=15`, `MIN_TENURE_WK=6`, `FLOOR_FORECAST=40`. These mirror the skill's starting values.

## Before production

- **Test class** (needed for deploy; aim for the phantom / as-needed / fixed-bid / rollup branches).
- **Security**: enforce FLS/CRUD (`WITH SECURITY_ENFORCED` or `Security.stripInaccessible`); `with sharing` is set but confirm EMs can see the engagements they manage.
- **Limits at scale**: the time-entry aggregate is bounded to a user's active-engagement assignments; for an EM with a very large book, batch the assignment-Id set or cap the window.
- **Status coloring**: rows use `slds-text-color_*` on the status cell; for full RAG chips build a custom datatable cell or use `getRowActions`/a custom column component.
- **Fixed-bid over-burn thresholds** and the timesheet-lag as-of choice are still open in the skill — reflect whatever the team lands on.

## Deploy (sfdx example)

Place under your DX source tree (`force-app/main/default/classes` and `.../lwc`) and:

```
sf project deploy start -d force-app/main/default/classes/EngagementBurnController.cls
sf project deploy start -d force-app/main/default/lwc/engagementBurnPanel -d force-app/main/default/lwc/myPortfolioBurn
```

Then add **engagementBurnPanel** to the Engagement record page and **myPortfolioBurn** to a Home page via the Lightning App Builder.
