/**
 * EngagementBurnControllerTest
 * -------------------------------------------------------------------------
 * Unit tests for EngagementBurnController.
 *
 * The controller reads Kantata (KimbleOne) managed-package objects with formula
 * fields (Complete__c, Hours_Consumed__c) and a 5-hop revenue-model relationship
 * that cannot be set through normal DML. Rather than insert fragile managed-package
 * records, these tests build the SObjects IN MEMORY via JSON.deserialize (which can
 * populate read-only / formula fields and parent relationships) and drive the pure
 * assemble()/computeAssignment()/classify() logic exposed through @TestVisible.
 *
 * The @AuraEnabled entry points are exercised against an empty org to cover the SOQL.
 */
@isTest
private class EngagementBurnControllerTest {

    // ===================== In-memory builders =====================

    private static Integer idCounter = 1;

    /** Deterministic, well-formed fake Id for an SObjectType (no DML needed). */
    private static Id fakeId(Schema.SObjectType t) {
        String suffix = String.valueOf(idCounter++);
        while (suffix.length() < 12) suffix = '0' + suffix;
        return Id.valueOf(t.getDescribe().getKeyPrefix() + suffix);
    }

    /** yyyy-MM-dd string N days from today (JSON-friendly Date literal). */
    private static String dstr(Integer daysFromToday) {
        Date d = Date.today().addDays(daysFromToday);
        return DateTime.newInstance(d.year(), d.month(), d.day(), 0, 0, 0).format('yyyy-MM-dd');
    }

    private static KimbleOne__DeliveryGroup__c mkGrp(Id gid, String name, Boolean onHold) {
        Map<String, Object> f = new Map<String, Object>{
            'Id' => gid, 'Name' => name, 'On_Hold__c' => onHold
        };
        return (KimbleOne__DeliveryGroup__c) JSON.deserialize(
            JSON.serialize(f), KimbleOne__DeliveryGroup__c.class);
    }

    /**
     * Build an ActivityAssignment with formula fields and the revenue-model chain set.
     * revModel: 'BillableEffortExpended' (T&M) | 'VariableAmountPerMilestone' (Fixed-bid)
     *           | 'None' (Non-revenue) | null (leaves the chain unset -> 'Other')
     */
    private static KimbleOne__ActivityAssignment__c mkAsg(
        Id grpId, Id asgId, String resource, String revModel,
        Integer startOffset, Integer endOffset,
        Decimal forecast, Decimal worked, Decimal remaining,
        Decimal complete, Decimal consumed, Decimal ehpw, Decimal revRate
    ) {
        Map<String, Object> f = new Map<String, Object>{
            'KimbleOne__DeliveryGroup__c'      => grpId,
            'KimbleOne__StartDate__c'          => dstr(startOffset),
            'KimbleOne__ForecastP3EndDate__c'  => dstr(endOffset),
            'KimbleOne__ForecastUsage__c'      => forecast,
            'KimbleOne__TotalActualHours__c'   => worked,
            'KimbleOne__ForecastRemainingUsage__c' => remaining,
            'Complete__c'                      => complete,
            'Hours_Consumed__c'                => consumed,
            'Estimated_Hours_Per_Week__c'      => ehpw,
            'KimbleOne__RevenueRate__c'        => revRate
        };
        if (asgId != null) {
            f.put('Id', asgId);
        }
        if (resource != null) {
            f.put('KimbleOne__Resource__r', new Map<String, Object>{ 'Name' => resource });
        }
        if (revModel != null) {
            f.put('KimbleOne__ResourcedActivity__r', new Map<String, Object>{
                'KimbleOne__DeliveryElement__r' => new Map<String, Object>{
                    'KimbleOne__Product__r' => new Map<String, Object>{
                        'KimbleOne__ProductDomain__r' => new Map<String, Object>{
                            'KimbleOne__RevenueGenerationModel__r' => new Map<String, Object>{
                                'Name' => revModel
                            }
                        }
                    }
                }
            });
        }
        return (KimbleOne__ActivityAssignment__c) JSON.deserialize(
            JSON.serialize(f), KimbleOne__ActivityAssignment__c.class);
    }

    private static Map<Id, KimbleOne__DeliveryGroup__c> grpMap(KimbleOne__DeliveryGroup__c g) {
        return new Map<Id, KimbleOne__DeliveryGroup__c>{ g.Id => g };
    }

    // ===================== assemble(): rollup + status =====================

    @isTest
    static void engagementRollup_onTrack_phantom_asNeeded() {
        Id g = fakeId(KimbleOne__DeliveryGroup__c.SObjectType);
        Map<Id, KimbleOne__DeliveryGroup__c> grps = grpMap(mkGrp(g, 'Eng A', false));
        List<KimbleOne__ActivityAssignment__c> asgs = new List<KimbleOne__ActivityAssignment__c>{
            mkAsg(g, null, 'Jane', 'BillableEffortExpended', -60, 30, 100, 50, 50, 50, 50, 40, 200), // On track
            mkAsg(g, null, null,   'BillableEffortExpended', -60, 30, 80,  0,  80, 0,  null, 40, 200), // phantom -> Verify
            mkAsg(g, null, null,   'BillableEffortExpended', -60, 30, 0,   20, 0,  null, null, null, 200) // as-needed
        };

        Map<Id, EngagementBurnController.EngagementBurn> r =
            EngagementBurnController.assemble(grps.keySet(), grps, asgs, new Map<Id, Decimal>(), true, Date.today());

        EngagementBurnController.EngagementBurn e = r.get(g);
        System.assertEquals(3, e.resourceCount, 'all 3 assignments included');
        System.assertEquals(true, e.hasPhantom, 'phantom assignment flagged');
        System.assertEquals('Verify', e.status, 'worst material status is the phantom Verify');
        System.assertEquals('T&M', e.model, 'all assignments T&M -> single model');
        System.assertEquals(38.9, e.pctConsumed, '70 worked / 180 forecast');
    }

    @isTest
    static void assignment_fixedBid_overBurn_isAtRisk() {
        Id g = fakeId(KimbleOne__DeliveryGroup__c.SObjectType);
        Map<Id, KimbleOne__DeliveryGroup__c> grps = grpMap(mkGrp(g, 'Eng B', false));
        List<KimbleOne__ActivityAssignment__c> asgs = new List<KimbleOne__ActivityAssignment__c>{
            mkAsg(g, null, 'Bob', 'VariableAmountPerMilestone', -70, 20, 100, 90, 10, 60, 90, 40, 300)
        };

        EngagementBurnController.EngagementBurn e =
            EngagementBurnController.assemble(grps.keySet(), grps, asgs, new Map<Id, Decimal>(), true, Date.today()).get(g);

        System.assertEquals('At risk', e.status, 'variance 30 pts over-burn on fixed-bid');
        System.assertEquals('Fixed-bid', e.model);
        System.assertEquals(0, e.revenueAtRisk, 'fixed-bid carries no $ at risk');
    }

    @isTest
    static void assignment_paused_whenEngagementOnHold() {
        Id g = fakeId(KimbleOne__DeliveryGroup__c.SObjectType);
        Map<Id, KimbleOne__DeliveryGroup__c> grps = grpMap(mkGrp(g, 'Eng C', true));
        List<KimbleOne__ActivityAssignment__c> asgs = new List<KimbleOne__ActivityAssignment__c>{
            mkAsg(g, null, 'Cara', 'BillableEffortExpended', -60, 30, 100, 50, 50, 50, 50, 40, 200)
        };

        EngagementBurnController.EngagementBurn e =
            EngagementBurnController.assemble(grps.keySet(), grps, asgs, new Map<Id, Decimal>(), true, Date.today()).get(g);

        System.assertEquals('Paused', e.status);
    }

    @isTest
    static void tAndM_underBurn_escalates_and_mixedModel_and_revenueAtRisk() {
        Id g = fakeId(KimbleOne__DeliveryGroup__c.SObjectType);
        Id a1 = fakeId(KimbleOne__ActivityAssignment__c.SObjectType);
        Map<Id, KimbleOne__DeliveryGroup__c> grps = grpMap(mkGrp(g, 'Eng D', false));
        List<KimbleOne__ActivityAssignment__c> asgs = new List<KimbleOne__ActivityAssignment__c>{
            mkAsg(g, a1, 'D1', 'BillableEffortExpended',   -60, 60, 100, 40, 60, 60, 40, 40, 200), // under-burn
            mkAsg(g, null, 'D2', 'VariableAmountPerMilestone', -60, 30, 50, 45, 40, 40, 90, 20, 0)  // fixed-bid
        };
        Map<Id, Decimal> recent = new Map<Id, Decimal>{ a1 => 0 }; // no recent burn -> big projected undelivered

        EngagementBurnController.EngagementBurn e =
            EngagementBurnController.assemble(grps.keySet(), grps, asgs, recent, true, Date.today()).get(g);

        System.assertEquals('Mixed', e.model, 'T&M + Fixed-bid rolls up to Mixed');
        System.assertEquals('At risk', e.status);
        // T&M projected undelivered = 100 - 40 = 60 hrs * $200 = $12,000
        System.assertEquals(12000, e.revenueAtRisk, 'T&M $ at risk rolled up');
    }

    @isTest
    static void tooEarly_isMonitor() {
        Id g = fakeId(KimbleOne__DeliveryGroup__c.SObjectType);
        Map<Id, KimbleOne__DeliveryGroup__c> grps = grpMap(mkGrp(g, 'Eng E', false));
        List<KimbleOne__ActivityAssignment__c> asgs = new List<KimbleOne__ActivityAssignment__c>{
            mkAsg(g, null, 'Eve', 'BillableEffortExpended', -60, 30, 100, 10, 90, 10, 10, 40, 200) // 10% complete
        };

        EngagementBurnController.EngagementBurn e =
            EngagementBurnController.assemble(grps.keySet(), grps, asgs, new Map<Id, Decimal>(), true, Date.today()).get(g);

        System.assertEquals('Monitor', e.status);
    }

    @isTest
    static void newResource_runRateOverTenure_andPctBooked() {
        Id g = fakeId(KimbleOne__DeliveryGroup__c.SObjectType);
        Id a = fakeId(KimbleOne__ActivityAssignment__c.SObjectType);
        Map<Id, KimbleOne__DeliveryGroup__c> grps = grpMap(mkGrp(g, 'Eng F', false));
        List<KimbleOne__ActivityAssignment__c> asgs = new List<KimbleOne__ActivityAssignment__c>{
            mkAsg(g, a, 'Finn', 'BillableEffortExpended', -14, 30, 100, 20, 80, 30, 20, 40, 200) // 2 wk tenure
        };
        Map<Id, Decimal> recent = new Map<Id, Decimal>{ a => 20 };

        EngagementBurnController.EngagementBurn e =
            EngagementBurnController.assemble(grps.keySet(), grps, asgs, recent, true, Date.today()).get(g);

        EngagementBurnController.AssignmentBurn b = e.assignments[0];
        System.assertEquals(10, b.runRate6wk, '20 hrs / 2 wk tenure (not / 6)');
        System.assertEquals(25, b.pctBooked, '10 run-rate / 40 booked');
        System.assertEquals('Monitor', b.status, '<6 wk tenure monitors');
    }

    @isTest
    static void lateStage_bumpsSeverity() {
        Id g = fakeId(KimbleOne__DeliveryGroup__c.SObjectType);
        Map<Id, KimbleOne__DeliveryGroup__c> grps = grpMap(mkGrp(g, 'Eng G', false));
        List<KimbleOne__ActivityAssignment__c> asgs = new List<KimbleOne__ActivityAssignment__c>{
            mkAsg(g, null, 'Gus', 'BillableEffortExpended', -60, 10, 100, 95, 5, 90, 95, 40, 200) // 90% complete
        };

        EngagementBurnController.EngagementBurn e =
            EngagementBurnController.assemble(grps.keySet(), grps, asgs, new Map<Id, Decimal>(), true, Date.today()).get(g);

        System.assertEquals('Watch', e.status, 'On track bumped to Watch at late stage');
    }

    @isTest
    static void overBurn_capBreach_override_isAtRisk() {
        Id g = fakeId(KimbleOne__DeliveryGroup__c.SObjectType);
        Id a = fakeId(KimbleOne__ActivityAssignment__c.SObjectType);
        Map<Id, KimbleOne__DeliveryGroup__c> grps = grpMap(mkGrp(g, 'Eng H', false));
        List<KimbleOne__ActivityAssignment__c> asgs = new List<KimbleOne__ActivityAssignment__c>{
            // variance only +5 (base On track) but projected consumption > 100% -> At risk override
            mkAsg(g, a, 'Hana', 'BillableEffortExpended', -42, 42, 100, 80, 20, 75, 80, 40, 200)
        };
        Map<Id, Decimal> recent = new Map<Id, Decimal>{ a => 60 }; // run-rate 10/wk * 6 wk remaining -> projects past 100%

        EngagementBurnController.EngagementBurn e =
            EngagementBurnController.assemble(grps.keySet(), grps, asgs, recent, true, Date.today()).get(g);

        System.assertEquals('At risk', e.status);
    }

    @isTest
    static void nonRevenue_nullVariance_isOnTrack_andOtherModelRollsUpNull() {
        Id g1 = fakeId(KimbleOne__DeliveryGroup__c.SObjectType);
        Map<Id, KimbleOne__DeliveryGroup__c> grps1 = grpMap(mkGrp(g1, 'Eng I', false));
        List<KimbleOne__ActivityAssignment__c> asgs1 = new List<KimbleOne__ActivityAssignment__c>{
            mkAsg(g1, null, 'Ivy', 'None', -60, 30, 100, 50, 50, null, null, 40, 0) // no % data -> null variance
        };
        EngagementBurnController.EngagementBurn e1 =
            EngagementBurnController.assemble(grps1.keySet(), grps1, asgs1, new Map<Id, Decimal>(), true, Date.today()).get(g1);
        System.assertEquals('Non-revenue', e1.model);
        System.assertEquals('On track', e1.status);
        System.assertEquals(null, e1.assignments[0].variance);

        // Unmapped revenue model -> 'Other', which is excluded from the engagement rollup -> null model
        Id g2 = fakeId(KimbleOne__DeliveryGroup__c.SObjectType);
        Map<Id, KimbleOne__DeliveryGroup__c> grps2 = grpMap(mkGrp(g2, 'Eng J', false));
        List<KimbleOne__ActivityAssignment__c> asgs2 = new List<KimbleOne__ActivityAssignment__c>{
            mkAsg(g2, null, 'Jo', null, -60, 30, 100, 50, 50, 50, 50, 40, 200) // no chain -> 'Other'
        };
        EngagementBurnController.EngagementBurn e2 =
            EngagementBurnController.assemble(grps2.keySet(), grps2, asgs2, new Map<Id, Decimal>(), false, Date.today()).get(g2);
        System.assertEquals(null, e2.model, 'Unmapped model is not surfaced at the engagement level');
        System.assertEquals('Other', EngagementBurnController.mapModel(asgs2[0]));
    }

    // ===================== Pure helpers =====================

    @isTest
    static void helpers_severity_and_modelRollup() {
        System.assertEquals(4, EngagementBurnController.sev('At risk'));
        System.assertEquals(3, EngagementBurnController.sev('Watch'));
        System.assertEquals(3, EngagementBurnController.sev('Verify'));
        System.assertEquals(3, EngagementBurnController.sev('Monitor'));
        System.assertEquals(2, EngagementBurnController.sev('As-needed'));
        System.assertEquals(1, EngagementBurnController.sev('Paused'));
        System.assertEquals(0, EngagementBurnController.sev('On track'));

        System.assertEquals(null,    EngagementBurnController.rollupModel(null));
        System.assertEquals(null,    EngagementBurnController.rollupModel(new Set<String>()));
        System.assertEquals('T&M',   EngagementBurnController.rollupModel(new Set<String>{ 'T&M' }));
        System.assertEquals('Mixed', EngagementBurnController.rollupModel(new Set<String>{ 'T&M', 'Fixed-bid' }));
    }

    @isTest
    static void classify_nullVariance_isOnTrack() {
        // forecast>0, worked>0, but no % data -> variance null -> On track
        EngagementBurnController.AssignmentBurn b = new EngagementBurnController.AssignmentBurn();
        b.forecast = 100;
        b.worked = 50;
        System.assertEquals('On track', EngagementBurnController.classify(b, false, 8, null));
    }

    @isTest
    static void worstFirst_sortsByStatusThenRevenue() {
        EngagementBurnController.EngagementBurn watch = new EngagementBurnController.EngagementBurn();
        watch.status = 'Watch'; watch.revenueAtRisk = 100;
        EngagementBurnController.EngagementBurn risk = new EngagementBurnController.EngagementBurn();
        risk.status = 'At risk'; risk.revenueAtRisk = 50;
        List<EngagementBurnController.EngagementBurn> l =
            new List<EngagementBurnController.EngagementBurn>{ watch, risk };
        l.sort(new EngagementBurnController.WorstFirst());
        System.assertEquals('At risk', l[0].status, 'worst status first');

        EngagementBurnController.EngagementBurn lo = new EngagementBurnController.EngagementBurn();
        lo.status = 'Watch'; lo.revenueAtRisk = 10;
        EngagementBurnController.EngagementBurn hi = new EngagementBurnController.EngagementBurn();
        hi.status = 'Watch'; hi.revenueAtRisk = 90;
        List<EngagementBurnController.EngagementBurn> l2 =
            new List<EngagementBurnController.EngagementBurn>{ lo, hi };
        l2.sort(new EngagementBurnController.WorstFirst());
        System.assertEquals(90, l2[0].revenueAtRisk, 'ties break on higher $ at risk');
    }

    // ===================== @AuraEnabled entry points (SOQL coverage) =====================

    @isTest
    static void entryPoints_runAgainstEmptyOrg() {
        Test.startTest();
        EngagementBurnController.EngagementBurn e =
            EngagementBurnController.getEngagementBurn(fakeId(KimbleOne__DeliveryGroup__c.SObjectType));
        List<EngagementBurnController.EngagementBurn> portfolio = EngagementBurnController.getMyPortfolio();
        Test.stopTest();

        System.assertEquals(null, e, 'no matching engagement -> null');
        System.assertNotEquals(null, portfolio, 'portfolio query returns a (possibly empty) list');
    }

    // ===================== Leadership paged entry point =====================

    @isTest
    static void page_emptyOrg_returnsZeroAndNormalizesParams() {
        Test.startTest();
        // pageSize null -> default 20; pageNumber 0 -> clamped to 1
        EngagementBurnController.PagedEngagements p =
            EngagementBurnController.getEngagementsPage(null, null, null, 0);
        Test.stopTest();

        System.assertEquals(20, p.pageSize, 'null pageSize defaults to 20');
        System.assertEquals(1, p.pageNumber, 'pageNumber < 1 clamps to 1');
        System.assertEquals(0, p.totalCount, 'no active engagements in test context');
        System.assertEquals(0, p.rows.size(), 'no rows');
    }

    @isTest
    static void page_pageSizeIsCapped() {
        Test.startTest();
        EngagementBurnController.PagedEngagements p =
            EngagementBurnController.getEngagementsPage(null, null, 999, 1);
        Test.stopTest();
        System.assertEquals(50, p.pageSize, 'oversized page size is capped at the max');
    }

    @isTest
    static void page_accountFilter_buildsClauseAndReturnsEmpty() {
        Id fakeAccount = fakeId(Account.SObjectType);
        Test.startTest();
        EngagementBurnController.PagedEngagements p =
            EngagementBurnController.getEngagementsPage(null, fakeAccount, 20, 1);
        Test.stopTest();
        System.assertEquals(0, p.totalCount);
        System.assertEquals(0, p.rows.size());
    }

    @isTest
    static void page_managerFilter_noEngagementsShortCircuits() {
        Id fakeManager = fakeId(User.SObjectType);
        Test.startTest();
        EngagementBurnController.PagedEngagements p =
            EngagementBurnController.getEngagementsPage(fakeManager, null, 20, 1);
        Test.stopTest();
        System.assertEquals(0, p.totalCount, 'manager with no active engagements -> empty page');
        System.assertEquals(0, p.totalPages);
    }

    // ===================== Revenue-cap trending =====================

    // Note: Owner is a polymorphic relationship and cannot be set via JSON.deserialize,
    // so managerName (g.Owner.Name) is not exercised here — same reason mkGrp omits it.
    private static KimbleOne__ResourcedActivity__c mkRA(
        Id raId, String activityName, Id engagementId, String engagementName,
        String accountName, String elementName,
        Decimal cap, Decimal actual, Decimal factor, Decimal forecast
    ) {
        Map<String, Object> f = new Map<String, Object>{
            'KimbleOne__UsageRevenueCap__c'               => cap,
            'KimbleOne__ActualRevenue__c'                 => actual,
            'KimbleOne__ActualUsageRevenueToCapFactor__c' => factor,
            'KimbleOne__ForecastP3Revenue__c'             => forecast
        };
        if (raId != null) f.put('Id', raId);
        if (activityName != null) f.put('Name', activityName);

        Map<String, Object> g = new Map<String, Object>{ 'Name' => engagementName };
        if (accountName != null) g.put('KimbleOne__Account__r', new Map<String, Object>{ 'Name' => accountName });

        Map<String, Object> el = new Map<String, Object>{
            'Name' => elementName,
            'KimbleOne__DeliveryGroup__r' => g
        };
        if (engagementId != null) el.put('KimbleOne__DeliveryGroup__c', engagementId);
        f.put('KimbleOne__DeliveryElement__r', el);

        return (KimbleOne__ResourcedActivity__c) JSON.deserialize(
            JSON.serialize(f), KimbleOne__ResourcedActivity__c.class);
    }

    @isTest
    static void classifyCap_allBands() {
        System.assertEquals('On track',      EngagementBurnController.classifyCap(null, 50, 50), 'no cap');
        System.assertEquals('Over cap',      EngagementBurnController.classifyCap(100000, 130000, 40000), 'forecast > cap');
        System.assertEquals('Over cap',      EngagementBurnController.classifyCap(100000, 90000, 100000), 'already consumed the cap');
        System.assertEquals('At risk',       EngagementBurnController.classifyCap(100000, 96000, 50000));
        System.assertEquals('Watch',         EngagementBurnController.classifyCap(100000, 88000, 50000));
        System.assertEquals('Under-running', EngagementBurnController.classifyCap(100000, 60000, 30000));
        System.assertEquals('On track',      EngagementBurnController.classifyCap(100000, 78000, 40000));
    }

    @isTest
    static void capSeverity_ordering() {
        System.assertEquals(4, EngagementBurnController.capSev('Over cap'));
        System.assertEquals(3, EngagementBurnController.capSev('At risk'));
        System.assertEquals(2, EngagementBurnController.capSev('Watch'));
        System.assertEquals(1, EngagementBurnController.capSev('Under-running'));
        System.assertEquals(0, EngagementBurnController.capSev('On track'));
    }

    @isTest
    static void buildCaps_mapsFieldsAndDerives() {
        Id raId = fakeId(KimbleOne__ResourcedActivity__c.SObjectType);
        Id engId = fakeId(KimbleOne__DeliveryGroup__c.SObjectType);
        List<KimbleOne__ResourcedActivity__c> ras = new List<KimbleOne__ResourcedActivity__c>{
            mkRA(raId, 'Config Activity', engId, 'BlueKC SOW', 'BlueKC', 'T&M Element',
                 100000, 95000, 0.95, 98000)
        };
        List<EngagementBurnController.ActivityCap> caps = EngagementBurnController.buildCaps(ras);
        EngagementBurnController.ActivityCap c = caps[0];

        System.assertEquals(raId, c.activityId);
        System.assertEquals(engId, c.engagementId, 'engagement id carried for nav');
        System.assertEquals('BlueKC SOW', c.engagementName);
        System.assertEquals('BlueKC', c.accountName);
        System.assertEquals('T&M Element', c.elementName);
        System.assertEquals(95.0, c.consumedPct, 'from the to-cap factor');
        System.assertEquals(98.0, c.forecastPct, 'forecast / cap');
        System.assertEquals(2000, c.headroom, 'cap - forecast');
        System.assertEquals(0, c.overage, 'not projected over');
        System.assertEquals('At risk', c.status);
    }

    @isTest
    static void buildCaps_overCapShowsOverage() {
        List<KimbleOne__ResourcedActivity__c> ras = new List<KimbleOne__ResourcedActivity__c>{
            mkRA(null, 'A', null, 'Eng', null, 'El', 100000, 50000, 0.5, 120000)
        };
        EngagementBurnController.ActivityCap c = EngagementBurnController.buildCaps(ras)[0];
        System.assertEquals('Over cap', c.status);
        System.assertEquals(20000, c.overage, 'forecast - cap');
        System.assertEquals(-20000, c.headroom, 'negative headroom = projected breach');
    }

    @isTest
    static void capWorstFirst_sorts() {
        EngagementBurnController.ActivityCap watch = new EngagementBurnController.ActivityCap();
        watch.status = 'Watch'; watch.forecastPct = 88;
        EngagementBurnController.ActivityCap over = new EngagementBurnController.ActivityCap();
        over.status = 'Over cap'; over.forecastPct = 120;
        List<EngagementBurnController.ActivityCap> l =
            new List<EngagementBurnController.ActivityCap>{ watch, over };
        l.sort(new EngagementBurnController.CapWorstFirst());
        System.assertEquals('Over cap', l[0].status, 'worst status first');

        EngagementBurnController.ActivityCap lo = new EngagementBurnController.ActivityCap();
        lo.status = 'Watch'; lo.forecastPct = 86;
        EngagementBurnController.ActivityCap hi = new EngagementBurnController.ActivityCap();
        hi.status = 'Watch'; hi.forecastPct = 90;
        List<EngagementBurnController.ActivityCap> l2 =
            new List<EngagementBurnController.ActivityCap>{ lo, hi };
        l2.sort(new EngagementBurnController.CapWorstFirst());
        System.assertEquals(90, l2[0].forecastPct, 'ties break on higher projected % of cap');
    }

    @isTest
    static void capEntryPoints_runAgainstEmptyOrg() {
        Test.startTest();
        List<EngagementBurnController.ActivityCap> single =
            EngagementBurnController.getEngagementCaps(fakeId(KimbleOne__DeliveryGroup__c.SObjectType));
        EngagementBurnController.PagedActivityCaps page =
            EngagementBurnController.getActivityCapsPage(null, null, null, 0);
        EngagementBurnController.PagedActivityCaps capped =
            EngagementBurnController.getActivityCapsPage(null, null, 999, 1);
        EngagementBurnController.PagedActivityCaps mgr =
            EngagementBurnController.getActivityCapsPage(fakeId(User.SObjectType), null, 20, 1);
        Test.stopTest();

        System.assertNotEquals(null, single);
        System.assertEquals(0, single.size());
        System.assertEquals(20, page.pageSize, 'null size defaults to 20');
        System.assertEquals(1, page.pageNumber, 'page 0 clamps to 1');
        System.assertEquals(0, page.totalCount);
        System.assertEquals(50, capped.pageSize, 'size capped at max');
        System.assertEquals(0, mgr.totalCount, 'manager with no engagements short-circuits');
    }
}
