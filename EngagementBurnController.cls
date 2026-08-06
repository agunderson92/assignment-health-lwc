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

    // ===================== Core builder =====================

    private static Map<Id, EngagementBurn> buildForGroups(Set<Id> grpIds, Boolean includeAssignments) {
        Map<Id, EngagementBurn> result = new Map<Id, EngagementBurn>();
        if (grpIds == null || grpIds.isEmpty()) return result;
        Date today = Date.today();

        // Engagement headers
        Map<Id, KimbleOne__DeliveryGroup__c> grps = new Map<Id, KimbleOne__DeliveryGroup__c>([
            SELECT Id, Name, On_Hold__c
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

        // Seed engagement wrappers
        for (Id gid : grpIds) {
            if (!grps.containsKey(gid)) continue;
            EngagementBurn e = new EngagementBurn();
            e.engagementId = gid;
            e.name = grps.get(gid).Name;
            e.assignments = new List<AssignmentBurn>();
            e.forecast = 0; e.worked = 0; e.runRate = 0;
            e.projUndeliveredHrs = 0; e.revenueAtRisk = 0;
            e.hasPhantom = false;
            result.put(gid, e);
        }

        // Track worst child + forecast-weighted %complete numerator per engagement
        Map<Id, Decimal> completeNumer = new Map<Id, Decimal>();
        Map<Id, String> worstStatus = new Map<Id, String>();

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

            if (includeAssignments) e.assignments.add(b);
        }

        // Finalize engagement rollups
        for (EngagementBurn e : result.values()) {
            e.resourceCount = e.assignments != null ? e.assignments.size() : null;
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

    // severity ordering for status rollups
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
