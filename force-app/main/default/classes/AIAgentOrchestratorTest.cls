/**
 * AIAgentOrchestratorTest
 * ─────────────────────────────────────────────────────────────────────────────
 * Test class for AIAgentOrchestrator (Phase 3)
 * Uses mock HTTP callouts for both AI calls (planner + analyst)
 * ─────────────────────────────────────────────────────────────────────────────
 */
@isTest
private class AIAgentOrchestratorTest {

    // ── Mock: Returns a valid query plan then a valid analysis ──
    private class SuccessMock implements HttpCalloutMock {
        private Integer callCount = 0;

        public HTTPResponse respond(HTTPRequest req) {
            callCount++;
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setStatusCode(200);

            if (callCount == 1) {
                // First call: Query planner — return a query plan
                String plan = '{"queries":[{"objectName":"Account","fields":["Id","Name","Industry","AnnualRevenue"],"whereClause":null,"orderBy":"Name ASC","limitRows":20,"parentTraversals":[],"childSubqueries":[],"aggregate":null}]}';
                res.setBody('{"choices":[{"message":{"role":"assistant","content":' +
                    JSON.serialize(plan) + '}}]}');
            } else {
                // Second call: Data analyst
                res.setBody('{"choices":[{"message":{"role":"assistant","content":"## Account Summary\\n\\nHere are your accounts with their details.\\n\\n| Account | Industry | Revenue |\\n|---------|----------|---------|\\n| Test Corp | Technology | $5,000,000 |\\n\\n## \\u2705 What I can help with next\\n- Show contacts for these accounts\\n- Break down revenue by industry"}}]}');
            }
            return res;
        }
    }

    // ── Mock: Planner returns bad plan, retry succeeds ──
    private class RetryMock implements HttpCalloutMock {
        private Integer callCount = 0;

        public HTTPResponse respond(HTTPRequest req) {
            callCount++;
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setStatusCode(200);

            if (callCount == 1) {
                // First planner call — returns plan with invalid field
                String plan = '{"queries":[{"objectName":"Account","fields":["Id","Name","FakeField__xyz"],"limitRows":10}]}';
                res.setBody('{"choices":[{"message":{"role":"assistant","content":' +
                    JSON.serialize(plan) + '}}]}');
            } else if (callCount == 2) {
                // Retry planner call — returns fixed plan
                String plan = '{"queries":[{"objectName":"Account","fields":["Id","Name","Industry"],"limitRows":10}]}';
                res.setBody('{"choices":[{"message":{"role":"assistant","content":' +
                    JSON.serialize(plan) + '}}]}');
            } else {
                // Data analyst call
                res.setBody('{"choices":[{"message":{"role":"assistant","content":"Here are your accounts."}}]}');
            }
            return res;
        }
    }

    // ── Mock: AI service error ──
    private class ErrorMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(500);
            res.setBody('{"error":{"message":"Internal server error"}}');
            return res;
        }
    }

    // ── Mock: Multi-object query ──
    private class MultiObjectMock implements HttpCalloutMock {
        private Integer callCount = 0;

        public HTTPResponse respond(HTTPRequest req) {
            callCount++;
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setStatusCode(200);

            if (callCount == 1) {
                String plan = '{"queries":[' +
                    '{"objectName":"Account","fields":["Id","Name","Industry"],"limitRows":5},' +
                    '{"objectName":"Opportunity","fields":["Id","Name","Amount","StageName"],"limitRows":5}' +
                    ']}';
                res.setBody('{"choices":[{"message":{"role":"assistant","content":' +
                    JSON.serialize(plan) + '}}]}');
            } else {
                res.setBody('{"choices":[{"message":{"role":"assistant","content":"Combined analysis of accounts and opportunities."}}]}');
            }
            return res;
        }
    }

    @TestSetup
    static void setupData() {
        Account acc = new Account(Name = 'Test Corp', Industry = 'Technology', AnnualRevenue = 5000000);
        insert acc;
        Contact con = new Contact(FirstName = 'Jane', LastName = 'Smith', Email = 'jane@test.com', AccountId = acc.Id);
        insert con;
        Opportunity opp = new Opportunity(
            Name = 'Big Deal', StageName = 'Prospecting', Amount = 100000,
            CloseDate = Date.today().addDays(30), AccountId = acc.Id
        );
        insert opp;
    }

    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void testHandleQuestion_Success() {
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        Test.startTest();
        AIAgentOrchestrator.AgentResponse resp =
            AIAgentOrchestrator.handleQuestion('Show me all accounts with their industry', null);
        Test.stopTest();

        System.assertEquals(true, resp.isSuccess, 'Should succeed: ' + resp.errorMessage);
        System.assertNotEquals(null, resp.answer);
        System.assert(resp.totalRecords >= 0);
        System.assertNotEquals(null, resp.queriedObjects);
        System.assertNotEquals(null, resp.modelUsed);
    }

    @isTest
    static void testHandleQuestion_WithConversationHistory() {
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        String history = '[{"role":"user","content":"Show me all accounts"},{"role":"assistant","content":"Here are your accounts."}]';

        Test.startTest();
        AIAgentOrchestrator.AgentResponse resp =
            AIAgentOrchestrator.handleQuestion('Now filter by technology industry', history);
        Test.stopTest();

        System.assertEquals(true, resp.isSuccess, 'Should succeed with history: ' + resp.errorMessage);
    }

    @isTest
    static void testHandleQuestion_BlankQuestion() {
        Test.startTest();
        AIAgentOrchestrator.AgentResponse resp =
            AIAgentOrchestrator.handleQuestion('', null);
        Test.stopTest();

        System.assertEquals(false, resp.isSuccess);
        System.assert(resp.errorMessage.contains('ask a question'));
    }

    @isTest
    static void testHandleQuestion_AIServiceError() {
        Test.setMock(HttpCalloutMock.class, new ErrorMock());

        Test.startTest();
        AIAgentOrchestrator.AgentResponse resp =
            AIAgentOrchestrator.handleQuestion('Show me all accounts', null);
        Test.stopTest();

        System.assertEquals(false, resp.isSuccess);
        System.assertNotEquals(null, resp.errorMessage);
    }

    @isTest
    static void testHandleQuestion_MultiObjectQuery() {
        Test.setMock(HttpCalloutMock.class, new MultiObjectMock());

        Test.startTest();
        AIAgentOrchestrator.AgentResponse resp =
            AIAgentOrchestrator.handleQuestion('Compare accounts and opportunities', null);
        Test.stopTest();

        System.assertEquals(true, resp.isSuccess, 'Multi-object should succeed: ' + resp.errorMessage);
    }

    @isTest
    static void testHandleQuestion_DebugInfoPopulated() {
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        Test.startTest();
        AIAgentOrchestrator.AgentResponse resp =
            AIAgentOrchestrator.handleQuestion('List all accounts', null);
        Test.stopTest();

        System.assertNotEquals(null, resp.debugInfo, 'Debug info should contain SOQL');
    }

    @isTest
    static void testAgentResponse_DataClass() {
        AIAgentOrchestrator.AgentResponse resp = new AIAgentOrchestrator.AgentResponse();
        resp.answer = 'test';
        resp.queriedObjects = 'Account';
        resp.totalRecords = 5;
        resp.isSuccess = true;
        resp.errorMessage = null;
        resp.debugInfo = 'SELECT Id FROM Account';
        resp.modelUsed = 'gpt-4o-mini';

        System.assertEquals('test', resp.answer);
        System.assertEquals(5, resp.totalRecords);
    }
}
