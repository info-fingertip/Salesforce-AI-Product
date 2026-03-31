/**
 * AIToolUseAgentTest
 * ─────────────────────────────────────────────────────────────────────────────
 * Test class for AIToolUseAgent (Tool Use / Function Calling approach)
 * ─────────────────────────────────────────────────────────────────────────────
 */
@isTest
private class AIToolUseAgentTest {

    // ── Mock: AI calls get_schema_summary, then query_salesforce, then responds ──
    private class ToolUseMock implements HttpCalloutMock {
        private Integer callCount = 0;

        public HTTPResponse respond(HTTPRequest req) {
            callCount++;
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setStatusCode(200);

            if (callCount == 1) {
                // First call: AI wants to use get_schema_summary tool
                res.setBody('{' +
                    '"choices": [{' +
                    '  "message": {' +
                    '    "role": "assistant",' +
                    '    "content": null,' +
                    '    "tool_calls": [{' +
                    '      "id": "call_1",' +
                    '      "type": "function",' +
                    '      "function": {' +
                    '        "name": "get_schema_summary",' +
                    '        "arguments": "{}"' +
                    '      }' +
                    '    }]' +
                    '  },' +
                    '  "finish_reason": "tool_calls"' +
                    '}]}');
            } else if (callCount == 2) {
                // Second call: AI wants to query
                res.setBody('{' +
                    '"choices": [{' +
                    '  "message": {' +
                    '    "role": "assistant",' +
                    '    "content": null,' +
                    '    "tool_calls": [{' +
                    '      "id": "call_2",' +
                    '      "type": "function",' +
                    '      "function": {' +
                    '        "name": "query_salesforce",' +
                    '        "arguments": "{\\"soql\\": \\"SELECT Id, Name, Industry FROM Account LIMIT 10\\"}"' +
                    '      }' +
                    '    }]' +
                    '  },' +
                    '  "finish_reason": "tool_calls"' +
                    '}]}');
            } else {
                // Third call: AI gives final answer
                res.setBody('{' +
                    '"choices": [{' +
                    '  "message": {' +
                    '    "role": "assistant",' +
                    '    "content": "## Top Accounts\\n\\nHere are your accounts with their details.\\n\\n| Account | Industry |\\n|---------|----------|\\n| Test Corp | Technology |"' +
                    '  },' +
                    '  "finish_reason": "stop"' +
                    '}]}');
            }
            return res;
        }
    }

    // ── Mock: AI responds directly without tool calls ──
    private class DirectAnswerMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setStatusCode(200);
            res.setBody('{' +
                '"choices": [{' +
                '  "message": {' +
                '    "role": "assistant",' +
                '    "content": "I can help you with Salesforce data. What would you like to know?"' +
                '  },' +
                '  "finish_reason": "stop"' +
                '}]}');
            return res;
        }
    }

    // ── Mock: AI service error ──
    private class ErrorMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(500);
            res.setBody('{"error":{"message":"Server error"}}');
            return res;
        }
    }

    @TestSetup
    static void setupData() {
        Account acc = new Account(Name = 'Test Corp', Industry = 'Technology', AnnualRevenue = 5000000);
        insert acc;
        Contact con = new Contact(FirstName = 'Jane', LastName = 'Smith', Email = 'jane@test.com', AccountId = acc.Id);
        insert con;
    }

    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void testHandleQuestion_WithToolUse() {
        Test.setMock(HttpCalloutMock.class, new ToolUseMock());

        Test.startTest();
        AIToolUseAgent.AgentResponse resp =
            AIToolUseAgent.handleQuestion('Show me all accounts', null);
        Test.stopTest();

        System.assertEquals(true, resp.isSuccess, 'Should succeed: ' + resp.errorMessage);
        System.assertNotEquals(null, resp.answer, 'Answer should not be null');
        System.assert(resp.answer.contains('Accounts') || resp.answer.contains('accounts') || resp.answer.contains('Account'),
            'Answer should mention accounts');
    }

    @isTest
    static void testHandleQuestion_DirectAnswer() {
        Test.setMock(HttpCalloutMock.class, new DirectAnswerMock());

        Test.startTest();
        AIToolUseAgent.AgentResponse resp =
            AIToolUseAgent.handleQuestion('Hello, what can you do?', null);
        Test.stopTest();

        System.assertEquals(true, resp.isSuccess);
        System.assertNotEquals(null, resp.answer);
    }

    @isTest
    static void testHandleQuestion_BlankQuestion() {
        Test.startTest();
        AIToolUseAgent.AgentResponse resp =
            AIToolUseAgent.handleQuestion('', null);
        Test.stopTest();

        System.assertEquals(false, resp.isSuccess);
        System.assert(resp.errorMessage.contains('ask a question'));
    }

    @isTest
    static void testHandleQuestion_AIError() {
        Test.setMock(HttpCalloutMock.class, new ErrorMock());

        Test.startTest();
        AIToolUseAgent.AgentResponse resp =
            AIToolUseAgent.handleQuestion('Show me accounts', null);
        Test.stopTest();

        System.assertEquals(false, resp.isSuccess);
        System.assertNotEquals(null, resp.errorMessage);
    }

    @isTest
    static void testHandleQuestion_WithConversation() {
        Test.setMock(HttpCalloutMock.class, new DirectAnswerMock());
        String history = '[{"role":"user","content":"Show accounts"},{"role":"assistant","content":"Here are accounts."}]';

        Test.startTest();
        AIToolUseAgent.AgentResponse resp =
            AIToolUseAgent.handleQuestion('Now filter by technology', history);
        Test.stopTest();

        System.assertEquals(true, resp.isSuccess);
    }

    @isTest
    static void testResponseDataClass() {
        AIToolUseAgent.AgentResponse resp = new AIToolUseAgent.AgentResponse();
        resp.answer = 'test';
        resp.queriedObjects = 'Account';
        resp.totalRecords = 5;
        resp.isSuccess = true;
        resp.debugInfo = 'SELECT Id FROM Account';
        resp.modelUsed = 'gpt-4o-mini';

        System.assertEquals('test', resp.answer);
        System.assertEquals(5, resp.totalRecords);
    }
}
