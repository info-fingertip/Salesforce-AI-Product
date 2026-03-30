/**
 * ConversationMemoryTest
 * ─────────────────────────────────────────────────────────────────────────────
 * Test class for ConversationMemory (Phase 5)
 * ─────────────────────────────────────────────────────────────────────────────
 */
@isTest
private class ConversationMemoryTest {

    @isTest
    static void testBuildContext_ValidMessages() {
        String json = '[' +
            '{"role":"user","content":"Show me all accounts"},' +
            '{"role":"assistant","content":"Here are your accounts."},' +
            '{"role":"user","content":"Filter by technology"}' +
            ']';

        Test.startTest();
        List<ConversationMemory.ConversationMessage> messages = ConversationMemory.buildContext(json);
        Test.stopTest();

        System.assertEquals(3, messages.size());
        System.assertEquals('user', messages[0].role);
        System.assertEquals('assistant', messages[1].role);
    }

    @isTest
    static void testBuildContext_EmptyJson() {
        Test.startTest();
        List<ConversationMemory.ConversationMessage> messages = ConversationMemory.buildContext('');
        Test.stopTest();

        System.assertEquals(0, messages.size());
    }

    @isTest
    static void testBuildContext_NullJson() {
        Test.startTest();
        List<ConversationMemory.ConversationMessage> messages = ConversationMemory.buildContext(null);
        Test.stopTest();

        System.assertEquals(0, messages.size());
    }

    @isTest
    static void testBuildContext_InvalidJson() {
        Test.startTest();
        List<ConversationMemory.ConversationMessage> messages = ConversationMemory.buildContext('not json');
        Test.stopTest();

        System.assertEquals(0, messages.size());
    }

    @isTest
    static void testBuildContext_TruncatesLongMessages() {
        // Build a message longer than 2000 chars
        String longContent = '';
        for (Integer i = 0; i < 250; i++) longContent += '12345678';
        String json = '[{"role":"user","content":"' + longContent + '"}]';

        Test.startTest();
        List<ConversationMemory.ConversationMessage> messages = ConversationMemory.buildContext(json);
        Test.stopTest();

        System.assertEquals(1, messages.size());
        System.assert(messages[0].content.length() <= 2020, 'Should be truncated');
        System.assert(messages[0].content.endsWith('... (trimmed)'));
    }

    @isTest
    static void testBuildContext_LimitsTotalMessages() {
        // Build 20 messages — should keep only last 10
        List<String> parts = new List<String>();
        for (Integer i = 0; i < 20; i++) {
            String role = Math.mod(i, 2) == 0 ? 'user' : 'assistant';
            parts.add('{"role":"' + role + '","content":"Message ' + i + '"}');
        }
        String json = '[' + String.join(parts, ',') + ']';

        Test.startTest();
        List<ConversationMemory.ConversationMessage> messages = ConversationMemory.buildContext(json);
        Test.stopTest();

        System.assert(messages.size() <= 10, 'Should limit to 10 messages, got: ' + messages.size());
    }

    @isTest
    static void testBuildContext_SkipsInvalidRoles() {
        String json = '[' +
            '{"role":"user","content":"Valid"},' +
            '{"role":"system","content":"Should be skipped"},' +
            '{"role":"assistant","content":"Also valid"}' +
            ']';

        Test.startTest();
        List<ConversationMemory.ConversationMessage> messages = ConversationMemory.buildContext(json);
        Test.stopTest();

        System.assertEquals(2, messages.size());
    }

    @isTest
    static void testToAIMessages() {
        List<ConversationMemory.ConversationMessage> input = new List<ConversationMemory.ConversationMessage>();
        ConversationMemory.ConversationMessage m1 = new ConversationMemory.ConversationMessage();
        m1.role = 'user';
        m1.content = 'Hello';
        input.add(m1);

        ConversationMemory.ConversationMessage m2 = new ConversationMemory.ConversationMessage();
        m2.role = 'assistant';
        m2.content = 'Hi there!';
        input.add(m2);

        Test.startTest();
        List<Map<String, String>> result = ConversationMemory.toAIMessages(input);
        Test.stopTest();

        System.assertEquals(2, result.size());
        System.assertEquals('user', result[0].get('role'));
        System.assertEquals('Hello', result[0].get('content'));
    }

    @isTest
    static void testSummarize_WithMessages() {
        String json = '[' +
            '{"role":"user","content":"Show me all opportunities"},' +
            '{"role":"assistant","content":"Here are 15 opportunities."}' +
            ']';

        Test.startTest();
        String summary = ConversationMemory.summarize(json);
        Test.stopTest();

        System.assert(summary.contains('CONVERSATION CONTEXT'));
        System.assert(summary.contains('User:'));
        System.assert(summary.contains('AI:'));
    }

    @isTest
    static void testSummarize_EmptyReturnsEmpty() {
        Test.startTest();
        String summary = ConversationMemory.summarize('');
        Test.stopTest();

        System.assertEquals('', summary);
    }

    @isTest
    static void testSummarize_TruncatesLongContent() {
        String longContent = '';
        for (Integer i = 0; i < 50; i++) longContent += '1234567890';
        String json = '[{"role":"user","content":"' + longContent + '"}]';

        Test.startTest();
        String summary = ConversationMemory.summarize(json);
        Test.stopTest();

        System.assert(summary.contains('...'), 'Long content should be truncated in summary');
    }
}
