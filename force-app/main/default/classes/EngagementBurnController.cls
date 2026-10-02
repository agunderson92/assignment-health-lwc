/**
 * EngagementBurnController
 * -------------------------------------------------------------------------
 * Read-only burn / forecast-accuracy analysis for Kantata (KimbleOne) engagements,
 * powering two LWCs:
 *   - engagementBurnPanel  (record page)  -> getEngagementBurn(recordId)
 *   - myPortfolioBurn      (home page)     -> getMyPortfolio()
 *
 * Mirrors the methodology in the kantata-engagement-burn skill. Thresholds are
 * constants near the top and are STARTING VALUES pending Delivery Ops calibration.
 *
 * NOTE: starter scaffold. Needs a test class, a security review (FLS/CRUD),
 * and bulk/limit testing for EMs with very large portfolios before production.
 */
public with sharing class EngagementBurnController {

    // ---- Calibration constants (mirror the skill; tune with Delivery Ops) ----
    private static final Decimal BAND_ONTRACK   = 10;   // |variance| pts
    private static final Decimal BAND_WATCH     = 20;
    private static final Decimal LATE_STAGE_PCT = 85;   // bump severity at/after this % complete
    private static final Decimal TOO_EARLY_PCT  = 15;   // below this % complete -> Monitor, don't escalate
    private static final Decimal MIN_TENURE_WK  = 6;    // <6 wk tenure -> "new", run-rate over tenure not /6
    private static final Decimal FLOOR_FORECAST = 40;   // ignore tiny assignments when setting engagement status
    private static final Decimal RUN_RATE_WEEKS = 6;
    private static final Set<String> ACTIVE_FORECAST_STATUS =
        new Set<String>{ 'Closed Won (100%)', 'WAR (80%)' };

    // ===================== Wrapper types =====================
    public class AssignmentBurn {
        @AuraEnabled public String resource;
        @AuraEnabled public Decimal forecast;
        @AuraEnabled public Decimal worked;
        @AuraEnabled public Decimal remaining;
        @AuraEnabled public Decimal pctConsumed;   // Hours_Consumed__c
        @AuraEnabled public Decimal pctComplete;    // Complete__c
        @AuraEnabled public Decimal variance;       // consumed - complete (pts)
        @AuraEnabled public Decimal avgBurnLife;    // hrs/wk since start
        @AuraEnabled public Decimal runRate6wk;     // hrs/wk, trailing 42 days
        @AuraEnabled public Decimal pctBooked;      // runRate / Estimated_Hours_Per_Week
        @AuraEnabled public Decimal projUndelivered;// hrs (T&M revenue meaning; else utilization)
        @AuraEnabled public Decimal revenueAtRisk;  // $ (T&M only; null on fixed-bid/none)
        @AuraEnabled public String  model;          // 'T&M' | 'Fixed-bid' | 'Non-revenue' | 'Other'
        @AuraEnabled public String  status;         // On track | Watch | At risk | Monitor | Verify | As-needed | Paused
        @AuraEnabled public String  note;
    }

    public class EngagementBurn {
        @AuraEnabled public Id      engagementId;
        @AuraEnabled public String  name;
        @AuraEnabled public String  accountName;   // client account (leadership view)
        @AuraEnabled public String  managerName;   // engagement owner (leadership view)
        @AuraEnabled public String  status;
        @AuraEnabled public String  model;
        @AuraEnabled public Decimal pctConsumed;
        @AuraEnabled public Decimal pctComplete;
        @AuraEnabled public Decimal worked;
        @AuraEnabled public Decimal forecast;
        @AuraEnabled public Decimal runRate;         // sum of active run-rates
        @AuraEnabled public Decimal projUndeliveredHrs;
        @AuraEnabled public Decimal revenueAtRisk;   // $ across T&M assignments
        @AuraEnabled public Integer resourceCount;
        @AuraEnabled public Boolean hasPhantom;
        @AuraEnabled public List<AssignmentBurn> assignments;
    }

    // ===================== Public entry points =====================

    /** Record-page LWC: one engagement with its assignment detail. */
    @AuraEnabled(cacheable=true)
    public static EngagementBurn getEngagementBurn(Id engagementId) {
        Map<Id, EngagementBurn> byGrp = buildForGroups(new Set<Id>{ engagementId }, true);
        return byGrp.get(engagementId);
    }

    /** Home-page LWC: the logged-in user's active engagements where they are EM, worst-first (rollup only). */
    @AuraEnabled(cacheable=true)
    public static List<EngagementBurn> getMyPortfolio() {
        Id uid = UserInfo.getUserId();
        Set<Id> grpIds = activeEngagementIdsForEm(uid);
        Map<Id, EngagementBurn> byGrp = buildForGroups(grpIds, false);
        List<EngagementBurn> out = byGrp.values();
        out.sort(new WorstFirst());
        return out;
    }

    // ===================== Leadership (all engagements, filtered) =====================

    // Engagements are computed in chunks so that peak heap stays bounded even across the full
    // org-wide active set (each chunk's assignment rows fall out of scope before the next loads).
    // The full computed list is returned in one call; the LWC sorts and paginates client-side,
    // so ordering is global (not per-page) and paging/re-sorting is instant.
    private static final Integer ENGAGEMENT_CHUNK = 50;

    /**
     * Leadership LWC: every active engagement, optionally filtered by manager and/or account,
     * fully computed and returned worst-first. No server paging — the client pages the result.
     */
    @AuraEnabled(cacheable=true)
    public static List<EngagementBurn> getPortfolioAll(Id managerUserId, Id accountId) {
        Set<Id> ids = filteredActiveEngagementIds(managerUserId, accountId);
        Map<Id, EngagementBurn> all = new Map<Id, EngagementBurn>();

        List<Id> idList = new List<Id>(ids);
        for (Integer i = 0; i < idList.size(); i += ENGAGEMENT_CHUNK) {
            Set<Id> slice = new Set<Id>();
            for (Integer j = i; j < Math.min(i + ENGAGEMENT_CHUNK, idList.size()); j++) {
                slice.add(idList[j]);
            }
            all.putAll(buildForGroups(slice, false));
        }

        List<EngagementBurn> out = all.values();
        out.sort(new WorstFirst());
        return out;
    }

    /** Active-engagement Ids matching the optional manager / account filters. */
    private static Set<Id> filteredActiveEngagementIds(Id managerUserId, Id accountId) {
        Date today = Date.today();
        Set<String> statuses = ACTIVE_FORECAST_STATUS; // local bind for dynamic SOQL

        Set<Id> mgrIds;
        if (managerUserId != null) {
            mgrIds = activeEngagementIdsForEm(managerUserId);
            if (mgrIds.isEmpty()) return new Set<Id>();
        }

        String whereClause =
            'KimbleOne__ExpectedStartDate__c <= :today '
          + 'AND KimbleOne__ExpectedEndDate__c > :today '
          + 'AND KimbleOne__ForecastStatus__r.Name IN :statuses';
        if (accountId != null) whereClause += ' AND KimbleOne__Account__c = :accountId';
        if (mgrIds != null)    whereClause += ' AND Id IN :mgrIds';

        Set<Id> ids = new Set<Id>();
        for (KimbleOne__DeliveryGroup__c g : Database.query(
                'SELECT Id FROM KimbleOne__DeliveryGroup__c WHERE ' + whereClause)) {
            ids.add(g.Id);
        }
        return ids;
    }

    // ===================== Revenue-cap trending (activity grain) =====================
    //
    // The Usage Cap (KimbleOne__UsageRevenueCap__c) lives on the Resourced Activity, one cap
    // per activity, and an engagement can have several. We deliberately keep this at ACTIVITY
    // grain and never roll it up to the engagement: aggregating caps would net a low-forecasting
    // element against an over-forecasting one and hide the risk. Kimble stores the actuals and a
    // consumed-to-cap factor, so no revenue is recomputed from hours here.

    // Cap status threshold (tune with Delivery Ops). Forecast trending up to 100% of the cap is
    // healthy ("On track"); only a forecast that projects to EXCEED the cap is a risk.
    private static final Decimal CAP_UNDER_PCT = 70; // forecast below this % of cap -> Under-running

    public class ActivityCap {
        @AuraEnabled public Id      activityId;
        @AuraEnabled public String  activityName;
        @AuraEnabled public Id      engagementId;
        @AuraEnabled public String  engagementName;
        @AuraEnabled public String  accountName;
        @AuraEnabled public String  managerName;
        @AuraEnabled public String  elementName;
        @AuraEnabled public Decimal cap;          // $ Usage Cap
        @AuraEnabled public Decimal consumed;     // $ actual revenue to date
        @AuraEnabled public Decimal consumedPct;  // % of cap consumed
        @AuraEnabled public Decimal forecast;     // $ projected total revenue
        @AuraEnabled public Decimal forecastPct;  // % of cap projected
        @AuraEnabled public Decimal headroom;     // $ cap - forecast (negative = projected overage)
        @AuraEnabled public Decimal overage;      // $ max(forecast - cap, 0)
        @AuraEnabled public String  status;       // Over cap | At risk | Under-running | On track
    }

    private static final String CAP_FIELDS =
        'Id, Name, KimbleOne__UsageRevenueCap__c, KimbleOne__ActualRevenue__c, '
      + 'KimbleOne__ActualUsageRevenueToCapFactor__c, KimbleOne__ForecastP3Revenue__c, '
      + 'KimbleOne__DeliveryElement__r.Name, '
      + 'KimbleOne__DeliveryElement__r.KimbleOne__DeliveryGroup__c, '
      + 'KimbleOne__DeliveryElement__r.KimbleOne__DeliveryGroup__r.Name, '
      + 'KimbleOne__DeliveryElement__r.KimbleOne__DeliveryGroup__r.KimbleOne__Account__r.Name, '
      + 'KimbleOne__DeliveryElement__r.KimbleOne__DeliveryGroup__r.Owner.Name';

    /** Record-page LWC: capped activities for a single engagement, worst-first. */
    @AuraEnabled(cacheable=true)
    public static List<ActivityCap> getEngagementCaps(Id engagementId) {
        List<KimbleOne__ResourcedActivity__c> ras = Database.query(
            'SELECT ' + CAP_FIELDS + ' FROM KimbleOne__ResourcedActivity__c '
          + 'WHERE KimbleOne__UsageRevenueCap__c > 0 '
          + '  AND KimbleOne__DeliveryElement__r.KimbleOne__DeliveryGroup__c = :engagementId '
          + 'ORDER BY KimbleOne__UsageRevenueCap__c DESC');
        List<ActivityCap> caps = buildCaps(ras);
        caps.sort(new CapWorstFirst());
        return caps;
    }

    /** Home-page LWC: capped activities on the logged-in user's active engagements (owner or EM actor). */
    @AuraEnabled(cacheable=true)
    public static List<ActivityCap> getMyCaps() {
        Set<Id> grpIds = activeEngagementIdsForEm(UserInfo.getUserId());
        if (grpIds.isEmpty()) return new List<ActivityCap>();
        List<KimbleOne__ResourcedActivity__c> ras = Database.query(
            'SELECT ' + CAP_FIELDS + ' FROM KimbleOne__ResourcedActivity__c '
          + 'WHERE KimbleOne__UsageRevenueCap__c > 0 '
          + '  AND KimbleOne__DeliveryElement__r.KimbleOne__DeliveryGroup__c IN :grpIds '
          + 'ORDER BY KimbleOne__UsageRevenueCap__c DESC');
        List<ActivityCap> caps = buildCaps(ras);
        caps.sort(new CapWorstFirst());
        return caps;
    }

    /**
     * Leadership LWC: all capped activities on active engagements, optionally filtered by
     * manager and/or account, worst-first. Capped activities are a small subset, so the full
     * set is returned in one call and the client sorts / paginates it.
     */
    @AuraEnabled(cacheable=true)
    public static List<ActivityCap> getAllActivityCaps(Id managerUserId, Id accountId) {
        Date today = Date.today();
        Set<String> statuses = ACTIVE_FORECAST_STATUS;

        Set<Id> mgrIds;
        if (managerUserId != null) {
            mgrIds = activeEngagementIdsForEm(managerUserId);
            if (mgrIds.isEmpty()) return new List<ActivityCap>();
        }

        String grp = 'KimbleOne__DeliveryElement__r.KimbleOne__DeliveryGroup__r.';
        String whereClause =
            'KimbleOne__UsageRevenueCap__c > 0 '
          + 'AND ' + grp + 'KimbleOne__ExpectedStartDate__c <= :today '
          + 'AND ' + grp + 'KimbleOne__ExpectedEndDate__c > :today '
          + 'AND ' + grp + 'KimbleOne__ForecastStatus__r.Name IN :statuses';
        if (accountId != null) whereClause += ' AND ' + grp + 'KimbleOne__Account__c = :accountId';
        if (mgrIds != null)    whereClause += ' AND KimbleOne__DeliveryElement__r.KimbleOne__DeliveryGroup__c IN :mgrIds';

        List<KimbleOne__ResourcedActivity__c> ras = Database.query(
            'SELECT ' + CAP_FIELDS + ' FROM KimbleOne__ResourcedActivity__c WHERE ' + whereClause
          + ' ORDER BY KimbleOne__UsageRevenueCap__c DESC NULLS LAST');

        List<ActivityCap> caps = buildCaps(ras);
        caps.sort(new CapWorstFirst());
        return caps;
    }

    @TestVisible
    private static List<ActivityCap> buildCaps(List<KimbleOne__ResourcedActivity__c> ras) {
        List<ActivityCap> out = new List<ActivityCap>();
        for (KimbleOne__ResourcedActivity__c ra : ras) {
            Decimal cap      = ra.KimbleOne__UsageRevenueCap__c;
            Decimal consumed = ra.KimbleOne__ActualRevenue__c;
            Decimal forecast = ra.KimbleOne__ForecastP3Revenue__c;
            Decimal factor   = ra.KimbleOne__ActualUsageRevenueToCapFactor__c;

            ActivityCap c = new ActivityCap();
            c.activityId   = ra.Id;
            c.activityName = ra.Name;

            KimbleOne__DeliveryElement__c el = ra.KimbleOne__DeliveryElement__r;
            if (el != null) {
                c.elementName   = el.Name;
                c.engagementId  = el.KimbleOne__DeliveryGroup__c;
                KimbleOne__DeliveryGroup__c g = el.KimbleOne__DeliveryGroup__r;
                if (g != null) {
                    c.engagementName = g.Name;
                    c.accountName = g.KimbleOne__Account__r != null ? g.KimbleOne__Account__r.Name : null;
                    c.managerName = g.Owner != null ? g.Owner.Name : null;
                }
            }

            c.cap      = cap == null ? null : cap.setScale(0);
            c.consumed = consumed == null ? null : consumed.setScale(0);
            c.forecast = forecast == null ? null : forecast.setScale(0);
            c.consumedPct = (factor != null) ? (factor * 100).setScale(1)
                : (cap != null && cap > 0 && consumed != null ? (consumed / cap * 100).setScale(1) : null);
            c.forecastPct = (cap != null && cap > 0 && forecast != null)
                ? (forecast / cap * 100).setScale(1) : null;
            c.headroom = (cap != null && forecast != null) ? (cap - forecast).setScale(0) : null;
            c.overage  = (cap != null && forecast != null) ? Math.max(forecast - cap, 0).setScale(0) : 0;
            c.status   = classifyCap(cap, forecast, consumed);
            out.add(c);
        }
        return out;
    }

    @TestVisible
    private static String classifyCap(Decimal cap, Decimal forecast, Decimal consumed) {
        if (cap == null || cap <= 0) return 'On track';
        Decimal fPct = forecast == null ? 0 : forecast / cap * 100;
        Decimal cPct = consumed == null ? 0 : consumed / cap * 100;
        if (cPct >= 100)          return 'Over cap';      // cap already fully consumed
        if (fPct > 100)           return 'At risk';       // projected to EXCEED the cap
        if (fPct < CAP_UNDER_PCT) return 'Under-running'; // leaving cap unspent
        return 'On track';                                // trending to full use (<=100%) is healthy
    }

    @TestVisible
    private static Integer capSev(String s) {
        if (s == 'Over cap')      return 3;
        if (s == 'At risk')       return 2;
        if (s == 'Under-running') return 1;
        return 0; // On track
    }

    // worst-first for caps: severity, then higher projected % of cap
    public class CapWorstFirst implements Comparator<ActivityCap> {
        public Integer compare(ActivityCap x, ActivityCap y) {
            Integer d = capSev(y.status) - capSev(x.status);
            if (d != 0) return d;
            Decimal fx = x.forecastPct == null ? 0 : x.forecastPct;
            Decimal fy = y.forecastPct == null ? 0 : y.forecastPct;
            return fy > fx ? 1 : (fy < fx ? -1 : 0);
        }
    }

    // ===================== Core builder =====================

    private static Map<Id, EngagementBurn> buildForGroups(Set<Id> grpIds, Boolean includeAssignments) {
        Map<Id, EngagementBurn> result = new Map<Id, EngagementBurn>();
        if (grpIds == null || grpIds.isEmpty()) return result;
        Date today = Date.today();

        // Engagement headers
        Map<Id, KimbleOne__DeliveryGroup__c> grps = new Map<Id, KimbleOne__DeliveryGroup__c>([
            SELECT Id, Name, On_Hold__c, KimbleOne__Account__r.Name, Owner.Name
            FROM KimbleOne__DeliveryGroup__c
            WHERE Id IN :grpIds
        ]);

        // Currently-running assignments (forecast end in the future); carve-outs applied below
        List<KimbleOne__ActivityAssignment__c> asgs = [
            SELECT Id, KimbleOne__DeliveryGroup__c, KimbleOne__Resource__r.Name,
                   KimbleOne__StartDate__c, KimbleOne__ForecastP3EndDate__c,
                   KimbleOne__ForecastUsage__c, KimbleOne__TotalActualHours__c, KimbleOne__TotalActualUsage__c,
                   KimbleOne__ForecastRemainingUsage__c, Complete__c, Hours_Consumed__c,
                   Estimated_Hours_Per_Week__c, KimbleOne__RevenueRate__c,
                   KimbleOne__ResourcedActivity__r.KimbleOne__DeliveryElement__r.KimbleOne__Product__r.KimbleOne__ProductDomain__r.KimbleOne__RevenueGenerationModel__r.Name
            FROM KimbleOne__ActivityAssignment__c
            WHERE KimbleOne__DeliveryGroup__c IN :grpIds
              AND KimbleOne__ForecastP3EndDate__c >= :today
        ];

        // Trailing-42-day run-rate per assignment (day-level TimePeriod date)
        Map<Id, Decimal> recentHrs = new Map<Id, Decimal>();
        if (!asgs.isEmpty()) {
            Set<Id> asgIds = new Map<Id, SObject>(asgs).keySet();
            Date cutoff = today.addDays(-42);
            for (AggregateResult ar : [
                SELECT KimbleOne__ActivityAssignment__c aid, SUM(KimbleOne__EntryUnitsInHours__c) hrs
                FROM KimbleOne__TimeEntry__c
                WHERE KimbleOne__ActivityAssignment__c IN :asgIds
                  AND KimbleOne__TimePeriod__r.KimbleOne__StartDate__c >= :cutoff
                GROUP BY KimbleOne__ActivityAssignment__c
            ]) {
                recentHrs.put((Id) ar.get('aid'), (Decimal) ar.get('hrs'));
            }
        }

        return assemble(grpIds, grps, asgs, recentHrs, includeAssignments, today);
    }

    /**
     * Pure in-memory assembly of the engagement rollups from already-queried data.
     * Split out from the SOQL so the classification/rollup logic is unit-testable
     * without inserting managed-package records. Referenced by tests via @TestVisible.
     */
    @TestVisible
    private static Map<Id, EngagementBurn> assemble(
        Set<Id> grpIds,
        Map<Id, KimbleOne__DeliveryGroup__c> grps,
        List<KimbleOne__ActivityAssignment__c> asgs,
        Map<Id, Decimal> recentHrs,
        Boolean includeAssignments,
        Date today
    ) {
        Map<Id, EngagementBurn> result = new Map<Id, EngagementBurn>();
        if (recentHrs == null) recentHrs = new Map<Id, Decimal>();

        // Seed engagement wrappers
        for (Id gid : grpIds) {
            if (!grps.containsKey(gid)) continue;
            KimbleOne__DeliveryGroup__c g = grps.get(gid);
            EngagementBurn e = new EngagementBurn();
            e.engagementId = gid;
            e.name = g.Name;
            e.accountName = g.KimbleOne__Account__r != null ? g.KimbleOne__Account__r.Name : null;
            e.managerName = g.Owner != null ? g.Owner.Name : null;
            e.assignments = new List<AssignmentBurn>();
            e.forecast = 0; e.worked = 0; e.runRate = 0;
            e.projUndeliveredHrs = 0; e.revenueAtRisk = 0;
            e.hasPhantom = false;
            result.put(gid, e);
        }

        // Track worst child + forecast-weighted %complete numerator per engagement
        Map<Id, Decimal> completeNumer = new Map<Id, Decimal>();
        Map<Id, String> worstStatus = new Map<Id, String>();
        // Distinct revenue models seen per engagement (for the engagement-level rollup)
        Map<Id, Set<String>> modelsByGrp = new Map<Id, Set<String>>();

        for (KimbleOne__ActivityAssignment__c a : asgs) {
            EngagementBurn e = result.get(a.KimbleOne__DeliveryGroup__c);
            if (e == null) continue;
            Boolean paused = grps.get(a.KimbleOne__DeliveryGroup__c).On_Hold__c == true;

            AssignmentBurn b = computeAssignment(a, recentHrs.get(a.Id), paused, today);

            // Roll up only real, non-empty, non-phantom, forecasted work into burn totals
            if (b.status == 'Verify') e.hasPhantom = true;
            e.forecast  += (a.KimbleOne__ForecastUsage__c == null ? 0 : a.KimbleOne__ForecastUsage__c);
            e.worked    += (a.KimbleOne__TotalActualHours__c == null ? 0 : a.KimbleOne__TotalActualHours__c);
            if (b.runRate6wk != null) e.runRate += b.runRate6wk;
            if (b.projUndelivered != null) e.projUndeliveredHrs += b.projUndelivered;
            if (b.revenueAtRisk != null) e.revenueAtRisk += b.revenueAtRisk;

            Decimal fc = (a.KimbleOne__ForecastUsage__c == null ? 0 : a.KimbleOne__ForecastUsage__c);
            completeNumer.put(e.engagementId,
                (completeNumer.containsKey(e.engagementId) ? completeNumer.get(e.engagementId) : 0)
                + (b.pctComplete == null ? 0 : b.pctComplete) * fc);

            // worst-child status, ignoring immaterial assignments
            if (fc >= FLOOR_FORECAST) {
                String cur = worstStatus.get(e.engagementId);
                worstStatus.put(e.engagementId, worseOf(cur, b.status));
            }

            // collect the revenue models present on this engagement's assignments
            if (b.model != null && b.model != 'Other') {
                if (!modelsByGrp.containsKey(e.engagementId)) {
                    modelsByGrp.put(e.engagementId, new Set<String>());
                }
                modelsByGrp.get(e.engagementId).add(b.model);
            }

            if (includeAssignments) e.assignments.add(b);
        }

        // Finalize engagement rollups
        for (EngagementBurn e : result.values()) {
            e.resourceCount = e.assignments != null ? e.assignments.size() : null;
            e.model = rollupModel(modelsByGrp.get(e.engagementId));
            e.pctConsumed = e.forecast > 0 ? (e.worked / e.forecast * 100).setScale(1) : null;
            e.pctComplete = e.forecast > 0 && completeNumer.containsKey(e.engagementId)
                ? (completeNumer.get(e.engagementId) / e.forecast).setScale(1) : null;
            e.projUndeliveredHrs = e.projUndeliveredHrs == null ? null : e.projUndeliveredHrs.setScale(0);
            e.revenueAtRisk = e.revenueAtRisk == null ? null : e.revenueAtRisk.setScale(0);
            e.runRate = e.runRate == null ? null : e.runRate.setScale(1);
            String s = worstStatus.get(e.engagementId);
            if (e.hasPhantom && (s == null || sev(s) < sev('Watch'))) s = 'Watch'; // phantom keeps it visible
            e.status = s == null ? 'On track' : s;
        }
        return result;
    }

    // ===================== Per-assignment math + classification =====================

    @TestVisible
    private static AssignmentBurn computeAssignment(
        KimbleOne__ActivityAssignment__c a, Decimal recent42, Boolean paused, Date today
    ) {
        AssignmentBurn b = new AssignmentBurn();
        b.resource    = a.KimbleOne__Resource__r != null ? a.KimbleOne__Resource__r.Name : '(unnamed)';
        b.forecast    = nz(a.KimbleOne__ForecastUsage__c);
        b.worked      = nz(a.KimbleOne__TotalActualHours__c);
        b.remaining   = nz(a.KimbleOne__ForecastRemainingUsage__c);
        b.pctConsumed = a.Hours_Consumed__c;
        b.pctComplete = a.Complete__c;
        b.model       = mapModel(a);

        Decimal weeksElapsed = a.KimbleOne__StartDate__c == null
            ? 0 : Math.max(a.KimbleOne__StartDate__c.daysBetween(today) / 7.0, 0.1);
        Decimal weeksRemaining = a.KimbleOne__ForecastP3EndDate__c == null
            ? 0 : Math.max(today.daysBetween(a.KimbleOne__ForecastP3EndDate__c) / 7.0, 0);

        b.avgBurnLife = weeksElapsed > 0 ? (b.worked / weeksElapsed).setScale(1) : null;

        // run-rate: /6, but for <6wk tenure divide by tenure (avoid understating a new start)
        Decimal denom = weeksElapsed < MIN_TENURE_WK ? Math.max(weeksElapsed, 1) : RUN_RATE_WEEKS;
        b.runRate6wk = ((recent42 == null ? 0 : recent42) / denom).setScale(1);

        Decimal booked = nz(a.Estimated_Hours_Per_Week__c);
        b.pctBooked = booked > 0 ? (b.runRate6wk / booked * 100).setScale(0) : null;

        b.variance = (b.pctConsumed != null && b.pctComplete != null)
            ? (b.pctConsumed - b.pctComplete).setScale(1) : null;

        // projections at current pace
        Decimal projTotal = b.worked + b.runRate6wk * weeksRemaining;
        b.projUndelivered = Math.max(b.forecast - projTotal, 0).setScale(0);
        Decimal projConsumptionPct = b.forecast > 0 ? (projTotal / b.forecast * 100) : null;

        // revenue at risk only meaningful for T&M
        if (b.model == 'T&M' && a.KimbleOne__RevenueRate__c != null) {
            b.revenueAtRisk = (b.projUndelivered * a.KimbleOne__RevenueRate__c).setScale(0);
        }

        b.status = classify(b, paused, weeksElapsed, projConsumptionPct);
        return b;
    }

    @TestVisible
    private static String classify(
        AssignmentBurn b, Boolean paused, Decimal weeksElapsed, Decimal projConsumptionPct
    ) {
        if (paused) return 'Paused';
        // as-needed: no forecast but real actuals
        if (b.forecast == 0 && b.worked > 0) { b.note = 'As-needed (no forecast)'; return 'As-needed'; }
        // phantom / never-activated: forecast but nothing logged
        if (b.forecast > 0 && b.worked == 0) {
            b.note = (b.model == 'Fixed-bid')
                ? 'No effort logged — delivery/recognition flag (fixed-bid)'
                : 'No effort logged — verify staffing / phantom';
            return 'Verify';
        }
        // too early / new resource
        if ((b.pctComplete != null && b.pctComplete < TOO_EARLY_PCT) || weeksElapsed < MIN_TENURE_WK) {
            b.note = 'Early / short tenure — monitor';
            return 'Monitor';
        }
        if (b.variance == null) return 'On track';

        // Fixed-bid: risk direction flips — over-burn erodes margin; under-burn is not revenue risk
        if (b.model == 'Fixed-bid') {
            Decimal over = b.variance; // positive = over-burn
            if (over > BAND_WATCH) return 'At risk';
            if (over > BAND_ONTRACK) return 'Watch';
            return 'On track';
        }

        // T&M (and default): symmetric bands on |variance|
        Decimal mag = Math.abs(b.variance);
        String base = mag <= BAND_ONTRACK ? 'On track' : (mag <= BAND_WATCH ? 'Watch' : 'At risk');
        // over-burn cap-breach override (projected to exceed forecast with time remaining)
        if (b.variance > 0 && projConsumptionPct != null && projConsumptionPct > 100) base = worseOf(base, 'At risk');
        // under-burn: escalate if a lot of forecast projects undelivered
        if (b.variance < 0 && b.forecast > 0 && (b.projUndelivered / b.forecast) > 0.15) base = worseOf(base, 'At risk');
        // late-stage bump
        if (b.pctComplete != null && b.pctComplete >= LATE_STAGE_PCT) base = bump(base);
        return base;
    }

    // ===================== Helpers =====================

    private static Decimal nz(Decimal d) { return d == null ? 0 : d; }

    @TestVisible
    private static String mapModel(KimbleOne__ActivityAssignment__c a) {
        String gen;
        try {
            gen = a.KimbleOne__ResourcedActivity__r
                   .KimbleOne__DeliveryElement__r
                   .KimbleOne__Product__r
                   .KimbleOne__ProductDomain__r
                   .KimbleOne__RevenueGenerationModel__r.Name;
        } catch (Exception e) { gen = null; }
        if (gen == 'BillableEffortExpended') return 'T&M';
        if (gen == 'VariableAmountPerMilestone') return 'Fixed-bid';
        if (gen == 'None') return 'Non-revenue';
        return 'Other';
    }

    /** Roll the distinct per-assignment models up to a single engagement-level label. */
    @TestVisible
    private static String rollupModel(Set<String> models) {
        if (models == null || models.isEmpty()) return null;
        if (models.size() == 1) return new List<String>(models)[0];
        return 'Mixed';
    }

    // severity ordering for status rollups
    @TestVisible
    private static Integer sev(String s) {
        if (s == 'At risk') return 4;
        if (s == 'Watch' || s == 'Verify' || s == 'Monitor') return 3;
        if (s == 'As-needed') return 2;
        if (s == 'Paused') return 1;
        return 0; // On track
    }
    private static String worseOf(String a, String b) {
        if (a == null) return b;
        return sev(a) >= sev(b) ? a : b;
    }
    private static String bump(String s) {
        if (s == 'On track') return 'Watch';
        if (s == 'Watch') return 'At risk';
        return s;
    }

    // worst-first sort for the portfolio
    public class WorstFirst implements Comparator<EngagementBurn> {
        public Integer compare(EngagementBurn x, EngagementBurn y) {
            Integer d = sev(y.status) - sev(x.status);
            if (d != 0) return d;
            Decimal rx = x.revenueAtRisk == null ? 0 : x.revenueAtRisk;
            Decimal ry = y.revenueAtRisk == null ? 0 : y.revenueAtRisk;
            return ry > rx ? 1 : (ry < rx ? -1 : 0);
        }
    }

    private static Set<Id> activeEngagementIdsForEm(Id uid) {
        Date today = Date.today();
        Set<Id> ids = new Set<Id>();
        for (KimbleOne__DeliveryGroup__c g : [
            SELECT Id FROM KimbleOne__DeliveryGroup__c
            WHERE OwnerId = :uid
              AND KimbleOne__ExpectedStartDate__c <= :today
              AND KimbleOne__ExpectedEndDate__c > :today
              AND KimbleOne__ForecastStatus__r.Name IN :ACTIVE_FORECAST_STATUS
        ]) ids.add(g.Id);
        for (KimbleOne__DeliveryGroupActor__c a : [
            SELECT KimbleOne__DeliveryGroup__c FROM KimbleOne__DeliveryGroupActor__c
            WHERE KimbleOne__User__c = :uid
              AND KimbleOne__ActorRole__r.Name = 'Engagement Manager'
              AND KimbleOne__DeliveryGroup__r.KimbleOne__ExpectedStartDate__c <= :today
              AND KimbleOne__DeliveryGroup__r.KimbleOne__ExpectedEndDate__c > :today
              AND KimbleOne__DeliveryGroup__r.KimbleOne__ForecastStatus__r.Name IN :ACTIVE_FORECAST_STATUS
        ]) ids.add(a.KimbleOne__DeliveryGroup__c);
        return ids;
    }
}
