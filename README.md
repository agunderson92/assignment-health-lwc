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
  - `getEngagementsPage(managerUserId, accountId, pageSize, pageNumber)` → **all** active engagements, optionally filtered by manager and/or account, one page at a time (leadership view). Returns a `PagedEngagements` wrapper (`rows`, `totalCount`, `totalPages`, `pageNumber`, `pageSize`).
- `lwc/engagementBurnPanel/` — drops on the **Engagement (`KimbleOne__DeliveryGroup__c`) record page**. Shows the burn-to-date + projection table for that engagement.
- `lwc/myPortfolioBurn/` — drops on the **Home page** (or an App page). Shows the EM's active engagements, worst-first, each row navigates to the engagement.
- `lwc/allEngagementsBurn/` — drops on a **Home or App page for leadership**. Shows all active engagements with Account + Manager columns, filterable by Account and Engagement Manager (`lightning-record-picker`), paginated (20/page). Each row navigates to the engagement.
- `lwc/capBurndown/` — **leadership Home/App page**. Revenue-cap trending: one row per Resourced Activity that has a Usage Cap, filterable/paged/sortable, worst-first. Consumed $ and forecast $ vs the cap, with projected overage and a cap status.
- `lwc/engagementCaps/` — **Engagement record page**. The same cap trending scoped to the engagement being viewed (one row per capped activity on that engagement).

Sorting & navigation (all datatable widgets): columns are sortable (default sort = revenue at risk / % of cap, highest first; nulls last), and the row arrow opens the target record in a **new browser tab**. In the paged leadership widgets, client-side sort acts on the current page only.

### Revenue caps (`getEngagementCaps`, `getActivityCapsPage`)

The Usage Cap (`KimbleOne__UsageRevenueCap__c`) lives on the **Resourced Activity**, one cap per activity, and an engagement can have several. Cap trending is kept at **activity grain and never rolled up to the engagement** — aggregating would net a low-forecasting element against an over-forecasting one and hide the risk. Kimble already stores the actuals (`KimbleOne__ActualRevenue__c`, `KimbleOne__ActualUsageRevenueToCapFactor__c`) and forecast (`KimbleOne__ForecastP3Revenue__c`), so no revenue is recomputed from hours. Status is driven by **forecast ÷ cap**: `Over cap` (> 100% or already consumed), `At risk` (≥ 95%), `Watch` (≥ 85%), `Under-running` (< 70%), else `On track` — thresholds are constants (`CAP_ATRISK_PCT`, `CAP_WATCH_PCT`, `CAP_UNDER_PCT`), tune with Delivery Ops. Note: `ForecastP3Revenue` is total activity revenue; for activities with material expense revenue it slightly overstates the usage-cap comparison — refine with a usage-specific forecast field if that becomes an issue.

### Leadership paging / ordering design

`getEngagementsPage` computes burn **only for the engagements on the requested page**, so cost stays bounded no matter how many active engagements exist org-wide (this business runs hundreds of small T&E engagements). The trade-off: rows are ordered by soonest expected end date at the SOQL level (stable, pageable) and only the returned page is sorted worst-first — so a globally worst-first ranking across *all* pages is **not** available in this synchronous design (that would require computing every engagement's burn up front). Narrow with the Account / Manager filters to focus. A future enhancement could pre-rank via a scheduled/cached job if global worst-first ordering is needed. `OFFSET` is capped at 2000 (SOQL limit) — deep paging past that returns empty; filter instead.

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
