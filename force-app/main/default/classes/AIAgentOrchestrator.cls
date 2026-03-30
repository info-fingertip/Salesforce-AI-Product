/**
 * AIAgentOrchestrator
 * ─────────────────────────────────────────────────────────────────────────────
 * Phase 3 + 5 — The AI Agent Brain
 *
 * Two-pass AI architecture:
 *   Pass 1 (Query Planner): User question + org schema → structured query plan (JSON)
 *   Pass 2 (Data Analyst):  User question + actual data → human-readable answer
 *
 * Features:
 *   - No manual object selection — fully autonomous
 *   - Schema-aware query planning
 *   - Multi-object, parent/child, aggregate query support
 *   - Conversation memory for follow-up questions
 *   - Token budget management for large data sets
 *   - Error recovery with one retry on query failure
 *   - Governor limit awareness
 * ─────────────────────────────────────────────────────────────────────────────
 */
public with sharing class AIAgentOrchestrator {

    private static final Integer MAX_DATA_CHARS      = 25000; // ~6k tokens
    private static final Integer MAX_SCHEMA_CHARS    = 15000; // ~3.5k tokens
    private static final Integer MAX_RETRY           = 1;

    // ── Cached schema (per-transaction) ─────────────────────────────────────
    private static String cachedSchemaSummary;

    // ── Response wrapper ────────────────────────────────────────────────────

    public class AgentResponse {
        @AuraEnabled public String  answer         { get; set; }
        @AuraEnabled public String  queriedObjects { get; set; }
        @AuraEnabled public Integer totalRecords   { get; set; }
        @AuraEnabled public Boolean isSuccess      { get; set; }
        @AuraEnabled public String  errorMessage   { get; set; }
        @AuraEnabled public String  debugInfo      { get; set; }
        @AuraEnabled public String  modelUsed      { get; set; }
    }

    // ── AI Config (reused from existing controller) ─────────────────────────

    private class AIConfig {
        String endpoint;
        String apiKey;
        String model;
        Integer maxTokens;
    }

    private static AIConfig loadConfig() {
        List<AI_Config__mdt> rows = [
            SELECT Endpoint__c, API_Key__c, Model__c, Max_Tokens__c
            FROM   AI_Config__mdt
            WHERE  DeveloperName = 'OpenAI_Config'
            LIMIT  1
        ];

        if (rows.isEmpty()) {
            throw new AgentException(
                'AI configuration not found. Go to Setup > Custom Metadata Types > AI Config and ensure OpenAI_Config exists.'
            );
        }

        AI_Config__mdt rec = rows[0];
        if (String.isBlank(rec.API_Key__c) || rec.API_Key__c == 'YOUR_OPENAI_API_KEY_HERE') {
            throw new AgentException('OpenAI API key not configured.');
        }

        AIConfig cfg   = new AIConfig();
        cfg.endpoint   = String.isNotBlank(rec.Endpoint__c) ? rec.Endpoint__c : 'https://api.openai.com/v1/chat/completions';
        cfg.apiKey     = rec.API_Key__c;
        cfg.model      = String.isNotBlank(rec.Model__c) ? rec.Model__c : 'gpt-4o-mini';
        cfg.maxTokens  = rec.Max_Tokens__c != null ? Integer.valueOf(rec.Max_Tokens__c) : 2000;
        return cfg;
    }

    // ── PRIMARY ENTRY POINT ─────────────────────────────────────────────────

    /**
     * Handles a user question with full autonomy.
     * No object selection required — the agent figures it out.
     *
     * @param userQuestion     The natural language question
     * @param conversationJson JSON array of previous messages for context (nullable)
     * @return AgentResponse with the AI's answer
     */
    @AuraEnabled
    public static AgentResponse handleQuestion(String userQuestion, String conversationJson) {
        AgentResponse resp = new AgentResponse();
        resp.isSuccess = false;
        resp.totalRecords = 0;

        try {
            if (String.isBlank(userQuestion)) {
                throw new AgentException('Please ask a question.');
            }

            // Check governor limits before starting
            checkGovernorLimits();

            AIConfig cfg = loadConfig();
            resp.modelUsed = cfg.model;

            // ── Step A: Get schema summary (cached per transaction) ──
            String schemaSummary = getSchemaWithBudget();

            // ── Step B: Build conversation context ──
            List<Map<String, String>> conversationHistory = parseConversation(conversationJson);

            // ── Step C: AI Call #1 — Query Planner ──
            String queryPlanJson = callQueryPlanner(cfg, schemaSummary, userQuestion, conversationHistory);

            // ── Step D: Parse and execute the query plan ──
            DynamicQueryBuilder.QueryPlan plan = DynamicQueryBuilder.parseQueryPlan(queryPlanJson);
            List<DynamicQueryBuilder.QueryResult> queryResults = DynamicQueryBuilder.executeQueryPlan(plan);

            // Check if any query failed — retry once
            Boolean hasFailure = false;
            for (DynamicQueryBuilder.QueryResult qr : queryResults) {
                if (!qr.isSuccess) { hasFailure = true; break; }
            }

            if (hasFailure) {
                checkGovernorLimits();
                // Retry: Feed error back to planner
                String errorFeedback = buildErrorFeedback(queryResults);
                queryPlanJson = callQueryPlannerWithRetry(cfg, schemaSummary, userQuestion, conversationHistory, errorFeedback);
                plan = DynamicQueryBuilder.parseQueryPlan(queryPlanJson);
                queryResults = DynamicQueryBuilder.executeQueryPlan(plan);
            }

            // ── Step E: Collect results ──
            List<String> objectNames = new List<String>();
            Integer totalRecords = 0;
            String combinedData = buildCombinedData(queryResults, objectNames);
            for (DynamicQueryBuilder.QueryResult qr : queryResults) {
                if (qr.isSuccess) totalRecords += qr.recordCount;
            }

            resp.queriedObjects = String.join(objectNames, ', ');
            resp.totalRecords = totalRecords;

            // ── Step F: AI Call #2 — Data Analyst ──
            checkGovernorLimits();
            resp.answer = callDataAnalyst(cfg, userQuestion, combinedData, totalRecords, conversationHistory);
            resp.isSuccess = true;

            // Debug info
            List<String> soqls = new List<String>();
            for (DynamicQueryBuilder.QueryResult qr : queryResults) {
                if (qr.soql != null) soqls.add(qr.soql);
            }
            resp.debugInfo = String.join(soqls, ' | ');

        } catch (AgentException e) {
            resp.errorMessage = e.getMessage();
        } catch (Exception e) {
            resp.errorMessage = 'Unexpected error: ' + e.getMessage();
        }
        return resp;
    }

    // ── Schema with token budget ────────────────────────────────────────────

    private static String getSchemaWithBudget() {
        if (cachedSchemaSummary != null) return cachedSchemaSummary;

        String full = SchemaService.getCompactSchemaSummary();

        // Truncate if too large
        if (full.length() > MAX_SCHEMA_CHARS) {
            full = full.substring(0, MAX_SCHEMA_CHARS) + '\n... (schema truncated for token budget)';
        }

        cachedSchemaSummary = full;
        return full;
    }

    // ── Parse conversation history ──────────────────────────────────────────

    private static List<Map<String, String>> parseConversation(String conversationJson) {
        List<Map<String, String>> history = new List<Map<String, String>>();
        if (String.isBlank(conversationJson)) return history;

        try {
            List<Object> raw = (List<Object>) JSON.deserializeUntyped(conversationJson);
            for (Object item : raw) {
                Map<String, Object> msg = (Map<String, Object>) item;
                Map<String, String> entry = new Map<String, String>();
                entry.put('role', String.valueOf(msg.get('role')));
                entry.put('content', String.valueOf(msg.get('content')));
                history.add(entry);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Failed to parse conversation: ' + e.getMessage());
        }

        // Limit conversation context to last 6 messages (~3 turns)
        while (history.size() > 6) {
            history.remove(0);
        }
        return history;
    }

    // ── AI Call #1: Query Planner ────────────────────────────────────────────

    private static String callQueryPlanner(AIConfig cfg, String schema, String question, List<Map<String, String>> history) {
        String systemPrompt =
            'You are a Salesforce SOQL query planner. Given an org schema and a user question, ' +
            'you must determine which objects, fields, and relationships to query.\n\n' +
            'RESPOND WITH ONLY A JSON OBJECT in this exact format:\n' +
            '{\n' +
            '  "queries": [\n' +
            '    {\n' +
            '      "objectName": "ObjectApiName",\n' +
            '      "fields": ["Field1", "Field2"],\n' +
            '      "whereClause": "optional SOQL WHERE condition or null",\n' +
            '      "orderBy": "FieldName DESC or null",\n' +
            '      "limitRows": 50,\n' +
            '      "parentTraversals": [\n' +
            '        {"relationshipName": "Account", "fields": ["Name", "Industry"]}\n' +
            '      ],\n' +
            '      "childSubqueries": [\n' +
            '        {"relationshipName": "Contacts", "fields": ["Name", "Email"], "limitRows": 10}\n' +
            '      ],\n' +
            '      "aggregate": null\n' +
            '    }\n' +
            '  ]\n' +
            '}\n\n' +
            'For aggregate queries use:\n' +
            '"aggregate": {"function": "COUNT|SUM|AVG|MAX|MIN", "field": "FieldName", "groupByFields": ["Field1"]}\n' +
            'When using aggregate, set fields to [] (empty).\n\n' +
            'RULES:\n' +
            '- Use ONLY objects and fields that exist in the schema below\n' +
            '- Use parent traversals (dot notation) when the user asks about related parent data\n' +
            '- Use child subqueries when the user asks about related child records\n' +
            '- Maximum 3 queries per plan\n' +
            '- Use WHERE clauses to filter data relevant to the question\n' +
            '- For date filters use Salesforce date literals: TODAY, LAST_N_DAYS:30, THIS_MONTH, etc.\n' +
            '- Always include Id and Name (or Subject/Title) in fields\n' +
            '- Do NOT wrap the JSON in markdown code fences\n' +
            '- Do NOT include any explanation, ONLY the JSON\n\n' +
            'ORG SCHEMA:\n' + schema;

        String userPrompt = question;

        List<Object> messages = new List<Object>();
        messages.add(new Map<String, String>{ 'role' => 'system', 'content' => systemPrompt });

        // Add conversation history for context
        for (Map<String, String> msg : history) {
            messages.add(msg);
        }

        messages.add(new Map<String, String>{ 'role' => 'user', 'content' => userPrompt });

        Map<String, Object> body = new Map<String, Object>{
            'model'       => cfg.model,
            'max_tokens'  => 800,
            'temperature' => 0.1,
            'messages'    => messages
        };

        return callAI(cfg, body);
    }

    // ── AI Call #1 Retry: with error feedback ───────────────────────────────

    private static String callQueryPlannerWithRetry(AIConfig cfg, String schema, String question, List<Map<String, String>> history, String errorFeedback) {
        String systemPrompt =
            'You are a Salesforce SOQL query planner. Your previous query plan had errors. ' +
            'Fix the errors and generate a corrected plan.\n\n' +
            'RESPOND WITH ONLY A JSON OBJECT in the same format as before.\n\n' +
            'PREVIOUS ERRORS:\n' + errorFeedback + '\n\n' +
            'RULES:\n' +
            '- Use ONLY objects and fields that exist in the schema\n' +
            '- Fix any invalid field names or object names\n' +
            '- Do NOT include any explanation, ONLY the JSON\n\n' +
            'ORG SCHEMA:\n' + schema;

        List<Object> messages = new List<Object>();
        messages.add(new Map<String, String>{ 'role' => 'system', 'content' => systemPrompt });
        messages.add(new Map<String, String>{ 'role' => 'user', 'content' => question });

        Map<String, Object> body = new Map<String, Object>{
            'model'       => cfg.model,
            'max_tokens'  => 800,
            'temperature' => 0.1,
            'messages'    => messages
        };

        return callAI(cfg, body);
    }

    // ── AI Call #2: Data Analyst ─────────────────────────────────────────────

    private static String callDataAnalyst(AIConfig cfg, String question, String data, Integer totalRecords, List<Map<String, String>> history) {
        String systemPrompt =
            'You are an expert Salesforce CRM data analyst. Analyse the provided data and answer the user\'s question.\n\n' +
            'RESPONSE STYLE:\n' +
            '- Respond naturally and conversationally, like a helpful expert colleague\n' +
            '- Use ## headings to organise sections\n' +
            '- Use markdown tables when listing multiple records side by side\n' +
            '- Use bullet points for lists and summaries\n' +
            '- Use > blockquotes for key highlights or standout numbers\n' +
            '- Use ```code blocks``` when showing calculations, formulas, or SOQL\n' +
            '- Use **bold** for emphasis and key terms\n' +
            '- Use *italic* for secondary emphasis\n' +
            '- Add contextual emojis as visual anchors: ✅ ⚠️ 💰 📅 🏆 👉 ❗\n' +
            '- Format currency as $X,XXX,XXX and dates as Mon DD YYYY\n' +
            '- At the end add a ## ✅ What I can help with next section with 3-4 suggestions\n' +
            '- Be specific with actual names and numbers from the data\n' +
            '- Never mention JSON, SOQL, or technical internals\n' +
            '- If data is empty, say so clearly and suggest what might help';

        String userPrompt =
            'Records retrieved: ' + totalRecords + '\n\n' +
            'Data:\n' + data + '\n\n' +
            'Question: ' + question;

        List<Object> messages = new List<Object>();
        messages.add(new Map<String, String>{ 'role' => 'system', 'content' => systemPrompt });

        // Conversation history
        for (Map<String, String> msg : history) {
            messages.add(msg);
        }

        messages.add(new Map<String, String>{ 'role' => 'user', 'content' => userPrompt });

        Map<String, Object> body = new Map<String, Object>{
            'model'       => cfg.model,
            'max_tokens'  => cfg.maxTokens,
            'temperature' => 0.3,
            'messages'    => messages
        };

        return callAI(cfg, body);
    }

    // ── Generic AI call ─────────────────────────────────────────────────────

    private static String callAI(AIConfig cfg, Map<String, Object> body) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(cfg.endpoint);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Authorization', 'Bearer ' + cfg.apiKey);
        req.setBody(JSON.serialize(body));
        req.setTimeout(60000);

        HttpResponse res = new Http().send(req);

        if (res.getStatusCode() != 200) {
            throw new AgentException('AI service error (' + res.getStatusCode() + '): ' + res.getBody());
        }

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> choices = (List<Object>) parsed.get('choices');
        if (choices == null || choices.isEmpty()) {
            throw new AgentException('No response from AI service.');
        }

        Map<String, Object> msg = (Map<String, Object>)((Map<String, Object>) choices[0]).get('message');
        return (String) msg.get('content');
    }

    // ── Build combined data string ──────────────────────────────────────────

    private static String buildCombinedData(List<DynamicQueryBuilder.QueryResult> queryResults, List<String> objectNames) {
        List<String> dataParts = new List<String>();
        Integer totalChars = 0;

        for (DynamicQueryBuilder.QueryResult qr : queryResults) {
            if (!qr.isSuccess || String.isBlank(qr.dataJson)) continue;

            objectNames.add(qr.objectName);
            String section = '--- ' + qr.objectName + ' (' + qr.recordCount + ' records) ---\n';

            String dataChunk = qr.dataJson;
            // Truncate individual results if too large
            if (totalChars + dataChunk.length() > MAX_DATA_CHARS) {
                Integer remaining = MAX_DATA_CHARS - totalChars;
                if (remaining > 500) {
                    dataChunk = dataChunk.substring(0, remaining) + '\n... (data truncated for token budget)';
                } else {
                    dataChunk = '(data omitted — token budget exceeded)';
                }
            }

            dataParts.add(section + dataChunk);
            totalChars += section.length() + dataChunk.length();
        }

        if (dataParts.isEmpty()) {
            return 'No data retrieved. The query returned zero results.';
        }
        return String.join(dataParts, '\n\n');
    }

    // ── Build error feedback for retry ──────────────────────────────────────

    private static String buildErrorFeedback(List<DynamicQueryBuilder.QueryResult> results) {
        List<String> errors = new List<String>();
        for (DynamicQueryBuilder.QueryResult qr : results) {
            if (!qr.isSuccess) {
                errors.add('Query on ' + qr.objectName + ' failed: ' + qr.errorMessage +
                    (qr.soql != null ? ' | SOQL: ' + qr.soql : ''));
            }
        }
        return String.join(errors, '\n');
    }

    // ── Governor limit checks ───────────────────────────────────────────────

    private static void checkGovernorLimits() {
        // SOQL queries: need at least 10 remaining
        if (Limits.getQueries() > Limits.getLimitQueries() - 10) {
            throw new AgentException('Approaching SOQL query governor limit. Please try a simpler question.');
        }
        // Callouts: need at least 2 remaining (planner + analyst)
        if (Limits.getCallouts() > Limits.getLimitCallouts() - 2) {
            throw new AgentException('Approaching callout governor limit. Please try again in a new transaction.');
        }
        // CPU time: warn if over 80%
        if (Limits.getCpuTime() > Limits.getLimitCpuTime() * 0.8) {
            throw new AgentException('Approaching CPU time limit. Please try a simpler question.');
        }
    }

    public class AgentException extends Exception {}
}
