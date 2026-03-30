/**
 * DynamicQueryBuilderTest
 * ─────────────────────────────────────────────────────────────────────────────
 * Test class for DynamicQueryBuilder (Phase 2)
 * ─────────────────────────────────────────────────────────────────────────────
 */
@isTest
private class DynamicQueryBuilderTest {

    @TestSetup
    static void setupData() {
        Account acc = new Account(Name = 'Test Corp', Industry = 'Technology', AnnualRevenue = 5000000);
        insert acc;

        Contact con = new Contact(FirstName = 'John', LastName = 'Doe', Email = 'john@test.com', AccountId = acc.Id);
        insert con;

        Opportunity opp = new Opportunity(
            Name = 'Big Deal', StageName = 'Prospecting', Amount = 100000,
            CloseDate = Date.today().addDays(30), AccountId = acc.Id
        );
        insert opp;
    }

    // ── Parse query plan ────────────────────────────────────────────────────

    @isTest
    static void testParseQueryPlan_SimpleQuery() {
        String json = '{"queries":[{"objectName":"Account","fields":["Name","Industry"],"limitRows":10}]}';

        Test.startTest();
        DynamicQueryBuilder.QueryPlan plan = DynamicQueryBuilder.parseQueryPlan(json);
        Test.stopTest();

        System.assertEquals(1, plan.queries.size());
        System.assertEquals('Account', plan.queries[0].objectName);
        System.assertEquals(2, plan.queries[0].fields.size());
    }

    @isTest
    static void testParseQueryPlan_WithCodeFences() {
        String json = '```json\n{"queries":[{"objectName":"Account","fields":["Name"],"limitRows":5}]}\n```';

        Test.startTest();
        DynamicQueryBuilder.QueryPlan plan = DynamicQueryBuilder.parseQueryPlan(json);
        Test.stopTest();

        System.assertEquals(1, plan.queries.size());
    }

    @isTest
    static void testParseQueryPlan_WithParentTraversal() {
        String json = '{"queries":[{"objectName":"Opportunity","fields":["Name","Amount"],' +
            '"parentTraversals":[{"relationshipName":"Account","fields":["Name","Industry"]}],"limitRows":10}]}';

        Test.startTest();
        DynamicQueryBuilder.QueryPlan plan = DynamicQueryBuilder.parseQueryPlan(json);
        Test.stopTest();

        System.assertEquals(1, plan.queries[0].parentTraversals.size());
        System.assertEquals('Account', plan.queries[0].parentTraversals[0].relationshipName);
    }

    @isTest
    static void testParseQueryPlan_WithChildSubquery() {
        String json = '{"queries":[{"objectName":"Account","fields":["Name"],' +
            '"childSubqueries":[{"relationshipName":"Contacts","fields":["Name","Email"],"limitRows":5}],"limitRows":10}]}';

        Test.startTest();
        DynamicQueryBuilder.QueryPlan plan = DynamicQueryBuilder.parseQueryPlan(json);
        Test.stopTest();

        System.assertEquals(1, plan.queries[0].childSubqueries.size());
        System.assertEquals('Contacts', plan.queries[0].childSubqueries[0].relationshipName);
    }

    @isTest
    static void testParseQueryPlan_WithAggregate() {
        String json = '{"queries":[{"objectName":"Opportunity","fields":[],' +
            '"aggregate":{"function":"SUM","field":"Amount","groupByFields":["StageName"]},"limitRows":20}]}';

        Test.startTest();
        DynamicQueryBuilder.QueryPlan plan = DynamicQueryBuilder.parseQueryPlan(json);
        Test.stopTest();

        System.assertNotEquals(null, plan.queries[0].aggregate);
        System.assertEquals('SUM', plan.queries[0].aggregate.function_x);
    }

    @isTest
    static void testParseQueryPlan_BlankInput() {
        Boolean thrown = false;
        Test.startTest();
        try {
            DynamicQueryBuilder.parseQueryPlan('');
        } catch (DynamicQueryBuilder.QueryBuilderException e) {
            thrown = true;
        }
        Test.stopTest();
        System.assert(thrown);
    }

    @isTest
    static void testParseQueryPlan_InvalidJson() {
        Boolean thrown = false;
        Test.startTest();
        try {
            DynamicQueryBuilder.parseQueryPlan('not valid json');
        } catch (DynamicQueryBuilder.QueryBuilderException e) {
            thrown = true;
        }
        Test.stopTest();
        System.assert(thrown);
    }

    // ── Execute query plan ──────────────────────────────────────────────────

    @isTest
    static void testExecuteQueryPlan_SimpleAccountQuery() {
        String json = '{"queries":[{"objectName":"Account","fields":["Name","Industry","AnnualRevenue"],"limitRows":10}]}';
        DynamicQueryBuilder.QueryPlan plan = DynamicQueryBuilder.parseQueryPlan(json);

        Test.startTest();
        List<DynamicQueryBuilder.QueryResult> results = DynamicQueryBuilder.executeQueryPlan(plan);
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(true, results[0].isSuccess);
        System.assert(results[0].recordCount > 0);
        System.assert(results[0].soql.contains('Account'));
    }

    @isTest
    static void testExecuteQueryPlan_WithParentTraversal() {
        String json = '{"queries":[{"objectName":"Opportunity","fields":["Name","Amount","StageName"],' +
            '"parentTraversals":[{"relationshipName":"Account","fields":["Name","Industry"]}],"limitRows":10}]}';
        DynamicQueryBuilder.QueryPlan plan = DynamicQueryBuilder.parseQueryPlan(json);

        Test.startTest();
        List<DynamicQueryBuilder.QueryResult> results = DynamicQueryBuilder.executeQueryPlan(plan);
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess);
        System.assert(results[0].soql.contains('Account.Name'));
    }

    @isTest
    static void testExecuteQueryPlan_WithChildSubquery() {
        String json = '{"queries":[{"objectName":"Account","fields":["Name"],' +
            '"childSubqueries":[{"relationshipName":"Contacts","fields":["FirstName","LastName","Email"],"limitRows":5}],"limitRows":10}]}';
        DynamicQueryBuilder.QueryPlan plan = DynamicQueryBuilder.parseQueryPlan(json);

        Test.startTest();
        List<DynamicQueryBuilder.QueryResult> results = DynamicQueryBuilder.executeQueryPlan(plan);
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess);
        System.assert(results[0].soql.contains('FROM Contacts'));
    }

    @isTest
    static void testExecuteQueryPlan_AggregateCount() {
        String json = '{"queries":[{"objectName":"Account","fields":[],' +
            '"aggregate":{"function":"COUNT","field":"","groupByFields":["Industry"]},"limitRows":20}]}';
        DynamicQueryBuilder.QueryPlan plan = DynamicQueryBuilder.parseQueryPlan(json);

        Test.startTest();
        List<DynamicQueryBuilder.QueryResult> results = DynamicQueryBuilder.executeQueryPlan(plan);
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess);
        System.assert(results[0].soql.contains('COUNT'));
    }

    @isTest
    static void testExecuteQueryPlan_AggregateSum() {
        String json = '{"queries":[{"objectName":"Opportunity","fields":[],' +
            '"aggregate":{"function":"SUM","field":"Amount","groupByFields":["StageName"]},"limitRows":20}]}';
        DynamicQueryBuilder.QueryPlan plan = DynamicQueryBuilder.parseQueryPlan(json);

        Test.startTest();
        List<DynamicQueryBuilder.QueryResult> results = DynamicQueryBuilder.executeQueryPlan(plan);
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess);
        System.assert(results[0].soql.contains('SUM'));
    }

    @isTest
    static void testExecuteQueryPlan_WithWhereClause() {
        String json = '{"queries":[{"objectName":"Account","fields":["Name","Industry"],' +
            '"whereClause":"Industry = \'Technology\'","limitRows":10}]}';
        DynamicQueryBuilder.QueryPlan plan = DynamicQueryBuilder.parseQueryPlan(json);

        Test.startTest();
        List<DynamicQueryBuilder.QueryResult> results = DynamicQueryBuilder.executeQueryPlan(plan);
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess);
    }

    @isTest
    static void testExecuteQueryPlan_WithOrderBy() {
        String json = '{"queries":[{"objectName":"Account","fields":["Name","AnnualRevenue"],' +
            '"orderBy":"AnnualRevenue DESC","limitRows":10}]}';
        DynamicQueryBuilder.QueryPlan plan = DynamicQueryBuilder.parseQueryPlan(json);

        Test.startTest();
        List<DynamicQueryBuilder.QueryResult> results = DynamicQueryBuilder.executeQueryPlan(plan);
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess);
    }

    @isTest
    static void testExecuteQueryPlan_InvalidObject() {
        String json = '{"queries":[{"objectName":"FakeObject__xyz","fields":["Name"],"limitRows":10}]}';
        DynamicQueryBuilder.QueryPlan plan = DynamicQueryBuilder.parseQueryPlan(json);

        Test.startTest();
        List<DynamicQueryBuilder.QueryResult> results = DynamicQueryBuilder.executeQueryPlan(plan);
        Test.stopTest();

        System.assertEquals(false, results[0].isSuccess);
        System.assert(results[0].errorMessage.contains('not found'));
    }

    @isTest
    static void testExecuteQueryPlan_NullPlan() {
        Test.startTest();
        List<DynamicQueryBuilder.QueryResult> results = DynamicQueryBuilder.executeQueryPlan(null);
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(false, results[0].isSuccess);
    }

    @isTest
    static void testExecuteQueryPlan_MultipleQueries() {
        String json = '{"queries":[' +
            '{"objectName":"Account","fields":["Name"],"limitRows":5},' +
            '{"objectName":"Contact","fields":["FirstName","LastName"],"limitRows":5}' +
            ']}';
        DynamicQueryBuilder.QueryPlan plan = DynamicQueryBuilder.parseQueryPlan(json);

        Test.startTest();
        List<DynamicQueryBuilder.QueryResult> results = DynamicQueryBuilder.executeQueryPlan(plan);
        Test.stopTest();

        System.assertEquals(2, results.size());
        System.assertEquals(true, results[0].isSuccess);
        System.assertEquals(true, results[1].isSuccess);
    }

    @isTest
    static void testExecuteQueryPlan_NoFields_DefaultsToIdName() {
        String json = '{"queries":[{"objectName":"Account","fields":[],"limitRows":5}]}';
        DynamicQueryBuilder.QueryPlan plan = DynamicQueryBuilder.parseQueryPlan(json);

        Test.startTest();
        List<DynamicQueryBuilder.QueryResult> results = DynamicQueryBuilder.executeQueryPlan(plan);
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess);
        System.assert(results[0].soql.contains('Id'));
    }

    // ── Security tests ──────────────────────────────────────────────────────

    @isTest
    static void testExecuteQueryPlan_BlocksDMLKeywords() {
        String json = '{"queries":[{"objectName":"Account","fields":["Name"],' +
            '"whereClause":"Name = \'test\'; DELETE FROM Account","limitRows":10}]}';
        DynamicQueryBuilder.QueryPlan plan = DynamicQueryBuilder.parseQueryPlan(json);

        Test.startTest();
        List<DynamicQueryBuilder.QueryResult> results = DynamicQueryBuilder.executeQueryPlan(plan);
        Test.stopTest();

        System.assertEquals(false, results[0].isSuccess);
    }

    @isTest
    static void testExecuteQueryPlan_InvalidAggregateFunction() {
        String json = '{"queries":[{"objectName":"Account","fields":[],' +
            '"aggregate":{"function":"DESTROY","field":"Name","groupByFields":[]},"limitRows":10}]}';
        DynamicQueryBuilder.QueryPlan plan = DynamicQueryBuilder.parseQueryPlan(json);

        Test.startTest();
        List<DynamicQueryBuilder.QueryResult> results = DynamicQueryBuilder.executeQueryPlan(plan);
        Test.stopTest();

        System.assertEquals(false, results[0].isSuccess);
    }

    @isTest
    static void testExecuteQueryPlan_RowLimitCapped() {
        String json = '{"queries":[{"objectName":"Account","fields":["Name"],"limitRows":9999}]}';
        DynamicQueryBuilder.QueryPlan plan = DynamicQueryBuilder.parseQueryPlan(json);

        Test.startTest();
        List<DynamicQueryBuilder.QueryResult> results = DynamicQueryBuilder.executeQueryPlan(plan);
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess);
        System.assert(results[0].soql.contains('LIMIT 200'), 'Should cap at 200');
    }
}
