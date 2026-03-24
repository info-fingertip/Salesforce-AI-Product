/**
 * AIAssistantController
 * ─────────────────────────────────────────────────────────────────────────────
 * Native Salesforce AI Assistant — Apex orchestrator
 * All configuration (endpoint, API key, model) loaded from
 * Custom Metadata: AI_Config__mdt (record: OpenAI_Config)
 *
 * NO secrets in source code — safe to commit to GitHub
 *
 * Org    : orgfarm-d6dfa7a89e-dev-ed.develop.my.salesforce.com
 * API    : v66.0
 * ─────────────────────────────────────────────────────────────────────────────
 */
public with sharing class AIAssistantController {

    private static final Integer SOQL_ROW_LIMIT = 20;

    // ── Load config from Custom Metadata ──────────────────────────────────────
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
            throw new AIAssistantException(
                'AI configuration not found. ' +
                'Go to Setup > Custom Metadata Types > AI Config > Manage Records ' +
                'and ensure a record named OpenAI_Config exists.'
            );
        }

        AI_Config__mdt rec = rows[0];

        if (String.isBlank(rec.API_Key__c) || rec.API_Key__c == 'YOUR_OPENAI_API_KEY_HERE') {
            throw new AIAssistantException(
                'OpenAI API key not set. ' +
                'Go to Setup > Custom Metadata Types > AI Config > OpenAI_Config ' +
                'and enter your real API key in the API Key field.'
            );
        }

        AIConfig cfg   = new AIConfig();
        cfg.endpoint   = String.isNotBlank(rec.Endpoint__c)
                            ? rec.Endpoint__c
                            : 'https://api.openai.com/v1/chat/completions';
        cfg.apiKey     = rec.API_Key__c;
        cfg.model      = String.isNotBlank(rec.Model__c) ? rec.Model__c : 'gpt-4o-mini';
        cfg.maxTokens  = rec.Max_Tokens__c != null ? Integer.valueOf(rec.Max_Tokens__c) : 1000;
        return cfg;
    }

    // ── Response wrapper ──────────────────────────────────────────────────────
    public class AIResponse {
        @AuraEnabled public String  answer      { get; set; }
        @AuraEnabled public String  objectName  { get; set; }
        @AuraEnabled public Integer recordCount { get; set; }
        @AuraEnabled public Boolean isSuccess   { get; set; }
        @AuraEnabled public String  errorMessage { get; set; }
    }

    // ── Object metadata wrappers ──────────────────────────────────────────────
    public class ObjectInfo {
        @AuraEnabled public String label   { get; set; }
        @AuraEnabled public String apiName { get; set; }
        @AuraEnabled public List<FieldInfo> fields { get; set; }
    }

    public class FieldInfo {
        @AuraEnabled public String label   { get; set; }
        @AuraEnabled public String apiName { get; set; }
        @AuraEnabled public String type    { get; set; }
    }

    // ── PRIMARY METHOD ────────────────────────────────────────────────────────
    @AuraEnabled
    public static AIResponse askAI(String objectApiName, String userQuestion, String filters) {
        AIResponse resp = new AIResponse();
        resp.isSuccess  = false;

        try {
            if (String.isBlank(objectApiName)) throw new AIAssistantException('Object name is required.');
            if (String.isBlank(userQuestion))  throw new AIAssistantException('Question is required.');

            List<String> fieldNames = getQueryableFields(objectApiName);
            if (fieldNames.isEmpty()) throw new AIAssistantException('No accessible fields found on ' + objectApiName);

            String soql = buildSOQL(objectApiName, fieldNames, filters);
            List<SObject> records = Database.query(soql);
            resp.recordCount = records.size();
            resp.objectName  = objectApiName;

            String recordsJson = JSON.serializePretty(records);
            resp.answer        = callOpenAI(objectApiName, userQuestion, recordsJson, records.size());
            resp.isSuccess     = true;

        } catch (AIAssistantException e) {
            resp.errorMessage = e.getMessage();
        } catch (Exception e) {
            resp.errorMessage = 'Unexpected error: ' + e.getMessage();
        }
        return resp;
    }

    // ── GET AVAILABLE OBJECTS ─────────────────────────────────────────────────
    @AuraEnabled(cacheable=true)
    public static List<ObjectInfo> getAvailableObjects() {
        List<ObjectInfo> result = new List<ObjectInfo>();

        List<String> objectNames = new List<String>{
            'Account', 'Contact', 'Lead', 'Opportunity', 'Case',
            'Task', 'Event', 'Campaign', 'Contract', 'Order',
            'Product2', 'Quote', 'Asset', 'User'
        };

        Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
        for (String name : globalDescribe.keySet()) {
            if (name.endsWith('__c')) objectNames.add(name);
        }

        for (String objName : objectNames) {
            try {
                Schema.SObjectType objType = globalDescribe.get(objName);
                if (objType == null) continue;
                Schema.DescribeSObjectResult dr = objType.getDescribe();
                if (!dr.isQueryable() || !dr.isAccessible()) continue;

                ObjectInfo info = new ObjectInfo();
                info.label   = dr.getLabel();
                info.apiName = dr.getName();
                info.fields  = new List<FieldInfo>();

                Map<String, Schema.SObjectField> fieldMap = dr.fields.getMap();
                Integer cnt = 0;
                for (String fname : fieldMap.keySet()) {
                    if (cnt >= 25) break;
                    Schema.DescribeFieldResult fr = fieldMap.get(fname).getDescribe();
                    if (!fr.isAccessible()) continue;
                    FieldInfo fi = new FieldInfo();
                    fi.label   = fr.getLabel();
                    fi.apiName = fr.getName();
                    fi.type    = String.valueOf(fr.getType());
                    info.fields.add(fi);
                    cnt++;
                }
                result.add(info);
            } catch (Exception e) { }
        }

        // Sort alphabetically by label
        List<String> sortKeys = new List<String>();
        Map<String, ObjectInfo> keyMap = new Map<String, ObjectInfo>();
        for (ObjectInfo obj : result) {
            String key = obj.label + '~~' + obj.apiName;
            sortKeys.add(key);
            keyMap.put(key, obj);
        }
        sortKeys.sort();
        List<ObjectInfo> sorted = new List<ObjectInfo>();
        for (String key : sortKeys) sorted.add(keyMap.get(key));
        return sorted;
    }

    // ── BUILD SOQL ────────────────────────────────────────────────────────────
    private static String buildSOQL(String objectApiName, List<String> fields, String filters) {
        String soql = 'SELECT ' + String.join(fields, ', ') + ' FROM ' + String.escapeSingleQuotes(objectApiName);
        if (String.isNotBlank(filters)) soql += ' WHERE ' + filters;
        soql += ' ORDER BY LastModifiedDate DESC NULLS LAST LIMIT ' + SOQL_ROW_LIMIT;
        return soql;
    }

    // ── GET QUERYABLE FIELDS ──────────────────────────────────────────────────
    private static List<String> getQueryableFields(String objectApiName) {
        List<String> fieldNames = new List<String>();
        Set<String> priorityFields = new Set<String>{
            'Id', 'Name', 'CreatedDate', 'LastModifiedDate',
            'Status', 'StageName', 'Amount', 'CloseDate',
            'LeadSource', 'Industry', 'Type', 'Subject',
            'Description', 'Priority', 'OwnerId', 'AccountId',
            'Email', 'Phone', 'Title', 'Company',
            'AnnualRevenue', 'NumberOfEmployees', 'Rating',
            'ForecastCategoryName', 'Probability',
            'BillingCity', 'BillingState', 'BillingCountry',
            'Website', 'NumberOfEmployees'
        };

        Schema.SObjectType objType = Schema.getGlobalDescribe().get(objectApiName);
        if (objType == null) return fieldNames;

        Map<String, Schema.SObjectField> fieldMap = objType.getDescribe().fields.getMap();

        for (String pf : priorityFields) {
            if (fieldMap.containsKey(pf.toLowerCase())) {
                Schema.DescribeFieldResult fr = fieldMap.get(pf.toLowerCase()).getDescribe();
                if (fr.isAccessible()) fieldNames.add(fr.getName());
            }
        }
        for (String fname : fieldMap.keySet()) {
            if (fieldNames.size() >= 25) break;
            Schema.DescribeFieldResult fr = fieldMap.get(fname).getDescribe();
            if (fr.isAccessible() && !fieldNames.contains(fr.getName())) fieldNames.add(fr.getName());
        }
        return fieldNames;
    }

    // ── CALL OPENAI ───────────────────────────────────────────────────────────
    private static String callOpenAI(String objectName, String question, String recordsJson, Integer count) {
        AIConfig cfg = loadConfig();

        String systemPrompt =
            'You are an expert Salesforce CRM data analyst. Respond exactly like ChatGPT — natural, rich, and contextual.\n\n' +
            'RESPONSE STYLE:\n' +
            '- Analyse the question carefully and respond with only what is relevant\n' +
            '- Use ## headings to organise sections (e.g. ## 💰 Accounts with Revenue, ## ⚠️ Missing Data)\n' +
            '- Use markdown tables ONLY when listing multiple records side by side\n' +
            '- Use bullet points (- item) for lists\n' +
            '- Use > for a key highlight or standout number\n' +
            '- Use a code block (``` code ```) when showing calculations or formulas\n' +
            '- Add contextual emojis as visual anchors: ✅ confirmed facts, ⚠️ warnings, 💰 revenue, 📅 dates, 🏆 top performer, 👉 conclusions, ❗ missing data\n' +
            '- Format currency as $X,XXX,XXX and dates as Mon DD YYYY\n' +
            '- Do NOT use **bold** or *italic* markdown\n' +
            '- At the end of every response add a ## ✅ What I can help you next section with 3-4 bullet suggestions\n' +
            '- Only add SHOW_CHART on its own line if the data has meaningful numeric comparison that a bar chart would visualise well\n\n' +
            'Never mention JSON. Be specific with actual names and numbers.';

        String userPrompt =
            'Salesforce object: ' + objectName + '\n' +
            'Records retrieved: ' + count + '\n\n' +
            'Data:\n' + recordsJson + '\n\n' +
            'Question: ' + question;

        Map<String, Object> body = new Map<String, Object>{
            'model'       => cfg.model,
            'max_tokens'  => cfg.maxTokens,
            'temperature' => 0.3,
            'messages'    => new List<Object>{
                new Map<String, String>{ 'role' => 'system', 'content' => systemPrompt },
                new Map<String, String>{ 'role' => 'user',   'content' => userPrompt }
            }
        };

        HttpRequest req = new HttpRequest();
        req.setEndpoint(cfg.endpoint);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Authorization', 'Bearer ' + cfg.apiKey);
        req.setBody(JSON.serialize(body));
        req.setTimeout(30000);

        HttpResponse res = new Http().send(req);

        if (res.getStatusCode() != 200) {
            throw new AIAssistantException('OpenAI error (' + res.getStatusCode() + '): ' + res.getBody());
        }

        Map<String, Object> parsed  = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> choices        = (List<Object>) parsed.get('choices');
        if (choices == null || choices.isEmpty()) throw new AIAssistantException('No response from OpenAI.');

        Map<String, Object> msg = (Map<String, Object>)((Map<String, Object>) choices[0]).get('message');
        return (String) msg.get('content');
    }

    public class AIAssistantException extends Exception {}
}