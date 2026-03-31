/**
 * AIToolUseAgent
 * ─────────────────────────────────────────────────────────────────────────────
 * Single-conversation AI Agent with Function Calling / Tool Use
 *
 * Instead of 2 separate AI calls (planner + analyst), this uses ONE
 * AI conversation where the AI has tools to access Salesforce data:
 *
 *   - query_salesforce(soql)    → runs validated SOQL, returns records
 *   - describe_object(name)     → returns fields + relationships
 *   - get_schema_summary()      → returns cached org schema overview
 *
 * The AI decides what it needs, calls tools, gets results back in the
 * same conversation, and generates the final answer. This is the same
 * pattern used by Agentforce, GPT Actions, and Claude Tools.
 *
 * Flow:
 *   1. Send user question + tool definitions to AI
 *   2. AI responds with tool_calls (or final answer)
 *   3. Execute tool calls in Apex (SOQL, describe)
 *   4. Send tool results back to AI
 *   5. Repeat until AI gives final text answer (max 5 rounds)
 * ─────────────────────────────────────────────────────────────────────────────
 */
public with sharing class AIToolUseAgent {

    private static final Integer MAX_TOOL_ROUNDS  = 5;
    private static final Integer MAX_SOQL_ROWS    = 200;
    private static final Integer MAX_RESULT_CHARS = 20000;

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

    // ── AI Config ───────────────────────────────────────────────────────────

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
            throw new AgentException('AI configuration not found. Ensure OpenAI_Config exists in Custom Metadata.');
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

    // ── Tool definitions (sent to AI) ───────────────────────────────────────

    private static List<Object> getToolDefinitions() {
        List<Object> tools = new List<Object>();

        // Tool 1: query_salesforce
        tools.add(new Map<String, Object>{
            'type' => 'function',
            'function' => new Map<String, Object>{
                'name' => 'query_salesforce',
                'description' => 'Execute a SOQL query against Salesforce and return records as JSON. Use this to fetch real data. Always validate field names against the schema first. Use LIMIT to keep results manageable. Examples: SELECT Name, Amount FROM Opportunity WHERE StageName = \'Closed Won\' LIMIT 20',
                'parameters' => new Map<String, Object>{
                    'type' => 'object',
                    'properties' => new Map<String, Object>{
                        'soql' => new Map<String, Object>{
                            'type' => 'string',
                            'description' => 'The SOQL query to execute'
                        }
                    },
                    'required' => new List<String>{ 'soql' }
                }
            }
        });

        // Tool 2: describe_object
        tools.add(new Map<String, Object>{
            'type' => 'function',
            'function' => new Map<String, Object>{
                'name' => 'describe_object',
                'description' => 'Get the fields, data types, and relationships for a specific Salesforce object. Use this to discover field names before querying. Returns field API names, types, and parent/child relationships.',
                'parameters' => new Map<String, Object>{
                    'type' => 'object',
                    'properties' => new Map<String, Object>{
                        'object_name' => new Map<String, Object>{
                            'type' => 'string',
                            'description' => 'The API name of the Salesforce object (e.g. Account, Opportunity, Custom_Object__c)'
                        }
                    },
                    'required' => new List<String>{ 'object_name' }
                }
            }
        });

        // Tool 3: get_schema_summary
        tools.add(new Map<String, Object>{
            'type' => 'function',
            'function' => new Map<String, Object>{
                'name' => 'get_schema_summary',
                'description' => 'Get an overview of all available Salesforce objects with their key fields and relationships. Use this first to understand what data is available before querying.',
                'parameters' => new Map<String, Object>{
                    'type' => 'object',
                    'properties' => new Map<String, Object>{}
                }
            }
        });

        return tools;
    }

    // ── SYSTEM PROMPT ───────────────────────────────────────────────────────

    private static String getSystemPrompt() {
        return
            'You are a Salesforce AI Agent with direct access to a Salesforce org through tools.\n\n' +
            'WORKFLOW:\n' +
            '1. First call get_schema_summary to understand what objects/fields exist\n' +
            '2. If you need more detail on an object, call describe_object\n' +
            '3. Call query_salesforce to fetch actual data\n' +
            '4. Analyze the results and provide a clear, insightful answer\n\n' +
            'RULES:\n' +
            '- Always verify field names exist before using them in SOQL\n' +
            '- Use LIMIT in queries (default 50, max 200)\n' +
            '- Use parent relationship dot notation for related data (e.g. Account.Name)\n' +
            '- Use child subqueries when needed (e.g. SELECT Id, (SELECT Id FROM Contacts) FROM Account)\n' +
            '- For date filters use: TODAY, LAST_N_DAYS:30, THIS_MONTH, THIS_QUARTER, etc.\n' +
            '- If a query fails, read the error and fix the SOQL\n\n' +
            'RESPONSE STYLE:\n' +
            '- Use ## headings, markdown tables, bullet points, blockquotes\n' +
            '- Use **bold** for emphasis and `code` for field/object names\n' +
            '- Use emojis as visual anchors: ✅ ⚠️ 💰 📅 🏆 👉 ❗\n' +
            '- Format currency as $X,XXX and dates as Mon DD YYYY\n' +
            '- End with ## ✅ What I can help with next\n' +
            '- Never expose raw JSON or SOQL to the user\n' +
            '- Be specific with actual names and numbers';
    }

    // ── PRIMARY ENTRY POINT ─────────────────────────────────────────────────

    @AuraEnabled
    public static AgentResponse handleQuestion(String userQuestion, String conversationJson) {
        AgentResponse resp = new AgentResponse();
        resp.isSuccess = false;
        resp.totalRecords = 0;

        try {
            if (String.isBlank(userQuestion)) {
                throw new AgentException('Please ask a question.');
            }

            AIConfig cfg = loadConfig();
            resp.modelUsed = cfg.model;

            // Build messages
            List<Object> messages = new List<Object>();
            messages.add(new Map<String, String>{ 'role' => 'system', 'content' => getSystemPrompt() });

            // Add conversation history (last 2 turns)
            if (String.isNotBlank(conversationJson)) {
                try {
                    List<Object> history = (List<Object>) JSON.deserializeUntyped(conversationJson);
                    Integer start = Math.max(0, history.size() - 4);
                    for (Integer i = start; i < history.size(); i++) {
                        messages.add(history[i]);
                    }
                } catch (Exception e) {
                    // Skip bad history
                }
            }

            messages.add(new Map<String, String>{ 'role' => 'user', 'content' => userQuestion });

            // Tool-use loop
            Set<String> queriedObjects = new Set<String>();
            Integer totalRecords = 0;
            List<String> debugSoqls = new List<String>();

            for (Integer round = 0; round < MAX_TOOL_ROUNDS; round++) {
                // Check governor limits
                if (Limits.getCallouts() >= Limits.getLimitCallouts() - 1) {
                    throw new AgentException('Callout limit reached. Please try a simpler question.');
                }

                // Call AI
                Map<String, Object> aiResponse = callAI(cfg, messages);

                // Check if AI wants to call tools
                List<Object> toolCalls = (List<Object>) aiResponse.get('tool_calls');
                String content = (String) aiResponse.get('content');
                String finishReason = (String) aiResponse.get('finish_reason');

                if (toolCalls != null && !toolCalls.isEmpty()) {
                    // AI wants to use tools — add the assistant message with tool_calls
                    Map<String, Object> assistantMsg = new Map<String, Object>{
                        'role' => 'assistant',
                        'content' => content
                    };
                    assistantMsg.put('tool_calls', toolCalls);
                    messages.add(assistantMsg);

                    // Execute each tool call and add results
                    for (Object tc : toolCalls) {
                        Map<String, Object> toolCall = (Map<String, Object>) tc;
                        String toolCallId = (String) toolCall.get('id');
                        Map<String, Object> function_x = (Map<String, Object>) toolCall.get('function');
                        String funcName = (String) function_x.get('name');
                        String funcArgs = (String) function_x.get('arguments');

                        String toolResult = executeToolCall(funcName, funcArgs, queriedObjects, debugSoqls);

                        // Count records from query results
                        if (funcName == 'query_salesforce' && toolResult.contains('"totalSize"')) {
                            try {
                                Map<String, Object> qResult = (Map<String, Object>) JSON.deserializeUntyped(toolResult);
                                if (qResult.containsKey('totalSize')) {
                                    totalRecords += Integer.valueOf(String.valueOf(qResult.get('totalSize')));
                                }
                            } catch (Exception e) { /* skip */ }
                        }

                        messages.add(new Map<String, Object>{
                            'role' => 'tool',
                            'tool_call_id' => toolCallId,
                            'content' => toolResult
                        });
                    }
                    // Continue the loop — AI will process tool results
                } else {
                    // AI gave a final text answer (no more tool calls)
                    resp.answer = content != null ? content : '';
                    resp.isSuccess = true;
                    break;
                }
            }

            // If we exhausted rounds without a final answer
            if (!resp.isSuccess && String.isBlank(resp.errorMessage)) {
                resp.answer = 'I gathered the data but ran out of processing rounds. Here is what I found so far.';
                resp.isSuccess = true;
            }

            resp.queriedObjects = String.join(new List<String>(queriedObjects), ', ');
            resp.totalRecords = totalRecords;
            resp.debugInfo = String.join(debugSoqls, ' | ');

        } catch (AgentException e) {
            resp.errorMessage = e.getMessage();
        } catch (Exception e) {
            resp.errorMessage = 'Unexpected error: ' + e.getMessage();
        }
        return resp;
    }

    // ── Execute a tool call ─────────────────────────────────────────────────

    private static String executeToolCall(String funcName, String argsJson, Set<String> queriedObjects, List<String> debugSoqls) {
        try {
            Map<String, Object> args = String.isNotBlank(argsJson)
                ? (Map<String, Object>) JSON.deserializeUntyped(argsJson)
                : new Map<String, Object>();

            if (funcName == 'query_salesforce') {
                return executeQuery((String) args.get('soql'), queriedObjects, debugSoqls);
            } else if (funcName == 'describe_object') {
                return executeDescribe((String) args.get('object_name'));
            } else if (funcName == 'get_schema_summary') {
                return executeGetSchema();
            } else {
                return '{"error": "Unknown tool: ' + funcName + '"}';
            }
        } catch (Exception e) {
            return '{"error": "' + String.escapeSingleQuotes(e.getMessage()) + '"}';
        }
    }

    // ── Tool: query_salesforce ───────────────────────────────────────────────

    private static String executeQuery(String soql, Set<String> queriedObjects, List<String> debugSoqls) {
        if (String.isBlank(soql)) return '{"error": "SOQL query is required"}';

        // Safety: block DML keywords
        String upper = soql.toUpperCase().trim();
        for (String keyword : new List<String>{ 'INSERT', 'UPDATE', 'DELETE', 'UPSERT', 'MERGE' }) {
            if (upper.startsWith(keyword)) {
                return '{"error": "Only SELECT queries are allowed"}';
            }
        }
        if (soql.contains(';')) {
            return '{"error": "Semicolons not allowed in queries"}';
        }

        // Force LIMIT if missing
        if (!upper.contains(' LIMIT ')) {
            soql += ' LIMIT 50';
        }

        // Cap LIMIT
        Integer limitIdx = upper.lastIndexOf(' LIMIT ');
        if (limitIdx > 0) {
            String limitPart = soql.substring(limitIdx + 7).trim();
            try {
                Integer limitVal = Integer.valueOf(limitPart);
                if (limitVal > MAX_SOQL_ROWS) {
                    soql = soql.substring(0, limitIdx) + ' LIMIT ' + MAX_SOQL_ROWS;
                }
            } catch (Exception e) { /* keep as is */ }
        }

        debugSoqls.add(soql);

        // Extract object name for tracking
        String fromObj = extractObjectName(upper);
        if (String.isNotBlank(fromObj)) queriedObjects.add(fromObj);

        // Execute
        try {
            List<SObject> records = Database.query(soql);
            String result = JSON.serializePretty(records);

            // Truncate if too large
            if (result.length() > MAX_RESULT_CHARS) {
                result = result.substring(0, MAX_RESULT_CHARS) + '\n... (truncated, ' + records.size() + ' total records)';
            }

            return '{"totalSize": ' + records.size() + ', "records": ' + result + '}';
        } catch (Exception e) {
            return '{"error": "SOQL Error: ' + String.escapeSingleQuotes(e.getMessage()) + '", "soql": "' + String.escapeSingleQuotes(soql) + '"}';
        }
    }

    private static String extractObjectName(String upperSoql) {
        Integer fromIdx = upperSoql.indexOf(' FROM ');
        if (fromIdx < 0) return null;
        String afterFrom = upperSoql.substring(fromIdx + 6).trim();
        // Take first word after FROM
        Integer spaceIdx = afterFrom.indexOf(' ');
        return spaceIdx > 0 ? afterFrom.substring(0, spaceIdx) : afterFrom;
    }

    // ── Tool: describe_object ───────────────────────────────────────────────

    private static String executeDescribe(String objectName) {
        if (String.isBlank(objectName)) return '{"error": "Object name is required"}';

        try {
            SchemaService.ObjectDetail detail = SchemaService.describeObject(objectName);

            // Build compact response
            List<String> fieldLines = new List<String>();
            for (SchemaService.FieldDetail f : detail.fields) {
                String line = f.apiName + ' (' + f.dataType + ')';
                if (f.isFilterable) line += ' [filterable]';
                fieldLines.add(line);
            }

            List<String> parentLines = new List<String>();
            for (SchemaService.ParentRelationship p : detail.parentRelationships) {
                parentLines.add(p.relationshipName + ' -> ' + p.parentObject + ' (via ' + p.fieldName + ')');
            }

            List<String> childLines = new List<String>();
            for (SchemaService.ChildRelationship c : detail.childRelationships) {
                childLines.add(c.relationshipName + ' -> ' + c.childObject + ' (via ' + c.foreignKeyField + ')');
            }

            Map<String, Object> result = new Map<String, Object>{
                'object' => detail.apiName,
                'label' => detail.label,
                'isCustom' => detail.isCustom,
                'fields' => fieldLines,
                'parentRelationships' => parentLines,
                'childRelationships' => childLines
            };
            return JSON.serialize(result);
        } catch (Exception e) {
            return '{"error": "' + String.escapeSingleQuotes(e.getMessage()) + '"}';
        }
    }

    // ── Tool: get_schema_summary ────────────────────────────────────────────

    private static String executeGetSchema() {
        return SchemaRefreshJob.getCachedSchema();
    }

    // ── AI HTTP call ────────────────────────────────────────────────────────

    private static Map<String, Object> callAI(AIConfig cfg, List<Object> messages) {
        Map<String, Object> body = new Map<String, Object>{
            'model'       => cfg.model,
            'max_tokens'  => cfg.maxTokens,
            'temperature' => 0.3,
            'messages'    => messages,
            'tools'       => getToolDefinitions()
        };

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

        Map<String, Object> choice = (Map<String, Object>) choices[0];
        Map<String, Object> message = (Map<String, Object>) choice.get('message');

        // Return content + tool_calls + finish_reason
        Map<String, Object> result = new Map<String, Object>();
        result.put('content', message.get('content'));
        result.put('tool_calls', message.get('tool_calls'));
        result.put('finish_reason', choice.get('finish_reason'));
        return result;
    }

    public class AgentException extends Exception {}
}
