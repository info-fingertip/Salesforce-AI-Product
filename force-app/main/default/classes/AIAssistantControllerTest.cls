/**
 * AIAssistantControllerTest
 * ─────────────────────────────────────────────────────────────────────────────
 * Test class for AIAssistantController
 * Coverage target: 80%+
 * Uses mock HTTP callout — does NOT make real OpenAI calls in tests
 * ─────────────────────────────────────────────────────────────────────────────
 */
@isTest
private class AIAssistantControllerTest {

    // ── Mock HTTP response for OpenAI callout ──
    private class OpenAIMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setStatusCode(200);
            res.setBody('{"choices":[{"message":{"role":"assistant","content":"Test AI response: You have 2 open opportunities totalling $150,000."}}],"usage":{"total_tokens":120}}');
            return res;
        }
    }

    // ── Mock that returns an error ──
    private class OpenAIErrorMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(401);
            res.setBody('{"error":{"message":"Invalid API key"}}');
            return res;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test: ask a valid question about Opportunity
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testAskAI_Opportunity_Success() {
        // Insert test data
        Account acc = new Account(Name = 'Test Account');
        insert acc;

        Opportunity opp1 = new Opportunity(
            Name = 'Deal Alpha', StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30), Amount = 50000, AccountId = acc.Id
        );
        Opportunity opp2 = new Opportunity(
            Name = 'Deal Beta', StageName = 'Closed Won',
            CloseDate = Date.today().addDays(-10), Amount = 100000, AccountId = acc.Id
        );
        insert new List<Opportunity>{ opp1, opp2 };

        Test.setMock(HttpCalloutMock.class, new OpenAIMock());

        Test.startTest();
        AIAssistantController.AIResponse resp =
            AIAssistantController.askAI('Opportunity', 'Summarise my open deals', null);
        Test.stopTest();

        System.assertEquals(true,  resp.isSuccess, 'Should succeed');
        System.assertNotEquals(null, resp.answer,  'Answer should not be null');
        System.assertEquals('Opportunity', resp.objectName, 'Object name should match');
        System.assert(resp.recordCount >= 0, 'Record count should be non-negative');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test: ask about Lead object
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testAskAI_Lead_Success() {
        Lead lead1 = new Lead(FirstName='John', LastName='Doe', Company='Acme', Status='Open - Not Contacted', Email='john@acme.com');
        Lead lead2 = new Lead(FirstName='Jane', LastName='Smith', Company='Beta Corp', Status='Working - Contacted', Email='jane@beta.com');
        insert new List<Lead>{ lead1, lead2 };

        Test.setMock(HttpCalloutMock.class, new OpenAIMock());

        Test.startTest();
        AIAssistantController.AIResponse resp =
            AIAssistantController.askAI('Lead', 'Which leads have not been contacted?', 'Status = \'Open - Not Contacted\'');
        Test.stopTest();

        System.assertEquals(true, resp.isSuccess);
        System.assertNotEquals(null, resp.answer);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test: OpenAI returns error
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testAskAI_OpenAIError() {
        Test.setMock(HttpCalloutMock.class, new OpenAIErrorMock());

        Test.startTest();
        AIAssistantController.AIResponse resp =
            AIAssistantController.askAI('Account', 'Tell me about my accounts', null);
        Test.stopTest();

        System.assertEquals(false, resp.isSuccess, 'Should fail on API error');
        System.assert(resp.errorMessage.contains('401') || resp.errorMessage.contains('OpenAI'), 'Error message should mention OpenAI or status code');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test: blank object name
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testAskAI_BlankObject() {
        Test.startTest();
        AIAssistantController.AIResponse resp =
            AIAssistantController.askAI('', 'Any question', null);
        Test.stopTest();

        System.assertEquals(false, resp.isSuccess);
        System.assert(resp.errorMessage.contains('Object name'));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test: blank question
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testAskAI_BlankQuestion() {
        Test.startTest();
        AIAssistantController.AIResponse resp =
            AIAssistantController.askAI('Opportunity', '', null);
        Test.stopTest();

        System.assertEquals(false, resp.isSuccess);
        System.assert(resp.errorMessage.contains('Question'));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test: getAvailableObjects returns standard objects
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testGetAvailableObjects() {
        Test.startTest();
        List<AIAssistantController.ObjectInfo> objects =
            AIAssistantController.getAvailableObjects();
        Test.stopTest();

        System.assert(objects.size() > 0, 'Should return at least one object');
        Boolean hasAccount = false;
        for (AIAssistantController.ObjectInfo obj : objects) {
            if (obj.apiName == 'Account') { hasAccount = true; break; }
        }
        System.assert(hasAccount, 'Account should be in the list');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test: Account query with mock
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testAskAI_Account_WithRecords() {
        Account a1 = new Account(Name='Alpha Corp', Industry='Technology', AnnualRevenue=5000000);
        Account a2 = new Account(Name='Beta Inc',   Industry='Finance',    AnnualRevenue=2000000);
        insert new List<Account>{ a1, a2 };

        Test.setMock(HttpCalloutMock.class, new OpenAIMock());

        Test.startTest();
        AIAssistantController.AIResponse resp =
            AIAssistantController.askAI('Account', 'Which accounts are in Technology?', 'Industry = \'Technology\'');
        Test.stopTest();

        System.assertEquals(true, resp.isSuccess);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test: Case object
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testAskAI_Case() {
        Case c1 = new Case(Subject='Login issue', Status='New',    Priority='High');
        Case c2 = new Case(Subject='Billing query', Status='Open', Priority='Medium');
        insert new List<Case>{ c1, c2 };

        Test.setMock(HttpCalloutMock.class, new OpenAIMock());

        Test.startTest();
        AIAssistantController.AIResponse resp =
            AIAssistantController.askAI('Case', 'Show me high priority cases', 'Priority = \'High\'');
        Test.stopTest();

        System.assertEquals(true, resp.isSuccess);
        System.assert(resp.recordCount >= 0);
    }
}