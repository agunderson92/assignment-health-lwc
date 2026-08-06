# assignment-health-lwc
Salesforce LWC for Engagement and homepage to provide insight into burn rate and assignment health

# Workstream 2 — Engagement Burn LWCs (starter scaffold)

Two read-only Lightning Web Components backed by one Apex controller, reusing the
methodology validated in the `kantata-engagement-burn` skill. This is a drafting
starting point, not production-ready — see "Before production" below.

## What's here

- `classes/EngagementBurnController.cls` — read-only Apex. Two `@AuraEnabled(cacheable=true)` methods:
  - `getEngagementBurn(engagementId)` → one engagement + its assignment detail (for the record page).
  - `getMyPortfolio()` → the logged-in user's active engagements where they are EM, worst-first (rollup).
- `lwc/engagementBurnPanel/` — drops on the **Engagement (`KimbleOne__DeliveryGroup__c`) record page**. Shows the burn-to-date + projection table for that engagement.
- `lwc/myPortfolioBurn/` — drops on the **Home page** (or an App page). Shows the EM's active engagements, worst-first, each row navigates to the engagement.

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
