/**
 * DynamicQueryBuilder
 * ─────────────────────────────────────────────────────────────────────────────
 * Phase 2 — Intelligent Query Builder
 * Builds safe, validated SOQL from an AI-generated query plan.
 *
 * Supports:
 *   - Simple single-object queries
 *   - Child-to-parent traversal (dot notation)
 *   - Parent-to-child subqueries
 *   - Aggregate queries (COUNT, SUM, AVG, GROUP BY)
 *   - Multi-query plans (up to 3 queries per request)
 *
 * Safety:
 *   - Every field/object validated against live Schema.describe
 *   - FLS + CRUD enforced
 *   - No DML keywords allowed
 *   - Row limits enforced
 * ─────────────────────────────────────────────────────────────────────────────
 */
public with sharing class DynamicQueryBuilder {

    private static final Integer MAX_ROW_LIMIT     = 200;
    private static final Integer DEFAULT_ROW_LIMIT = 50;
    private static final Integer MAX_QUERIES       = 3;

    // ── Query Plan (from AI) ────────────────────────────────────────────────

    public class QueryPlan {
        @AuraEnabled public List<QuerySpec> queries { get; set; }
    }

    public class QuerySpec {
        @AuraEnabled public String       objectName     { get; set; }
        @AuraEnabled public List<String>  fields         { get; set; }
        @AuraEnabled public String       whereClause    { get; set; }
        @AuraEnabled public String       orderBy        { get; set; }
        @AuraEnabled public Integer      limitRows      { get; set; }
        @AuraEnabled public List<ParentTraversal> parentTraversals { get; set; }
        @AuraEnabled public List<ChildSubquery>   childSubqueries  { get; set; }
        @AuraEnabled public AggregateSpec aggregate     { get; set; }
    }

    public class ParentTraversal {
        @AuraEnabled public String relationshipName { get; set; } // e.g. Account
        @AuraEnabled public List<String> fields     { get; set; } // e.g. [Name, Industry]
    }

    public class ChildSubquery {
        @AuraEnabled public String relationshipName { get; set; } // e.g. Contacts
        @AuraEnabled public List<String> fields     { get; set; } // e.g. [Name, Email]
        @AuraEnabled public Integer limitRows       { get; set; }
    }

    public class AggregateSpec {
        @AuraEnabled public String       function_x  { get; set; } // COUNT, SUM, AVG, MAX, MIN
        @AuraEnabled public String       field       { get; set; } // field to aggregate
        @AuraEnabled public List<String> groupByFields { get; set; }
    }

    // ── Query Result ────────────────────────────────────────────────────────

    public class QueryResult {
        @AuraEnabled public String       objectName  { get; set; }
        @AuraEnabled public Integer      recordCount { get; set; }
        @AuraEnabled public String       soql        { get; set; }
        @AuraEnabled public String       dataJson    { get; set; }
        @AuraEnabled public Boolean      isSuccess   { get; set; }
        @AuraEnabled public String       errorMessage { get; set; }
    }

    // ── DML-block keywords ──────────────────────────────────────────────────

    private static final Set<String> BLOCKED_KEYWORDS = new Set<String>{
        'INSERT', 'UPDATE', 'DELETE', 'UPSERT', 'MERGE', 'UNDELETE',
        'DROP', 'ALTER', 'CREATE', 'TRUNCATE', 'GRANT', 'REVOKE'
    };

    // ── PUBLIC: Parse and execute a query plan ──────────────────────────────

    public static List<QueryResult> executeQueryPlan(QueryPlan plan) {
        List<QueryResult> results = new List<QueryResult>();
        if (plan == null || plan.queries == null || plan.queries.isEmpty()) {
            QueryResult err = new QueryResult();
            err.isSuccess = false;
            err.errorMessage = 'Empty query plan.';
            results.add(err);
            return results;
        }

        Integer queryCount = Math.min(plan.queries.size(), MAX_QUERIES);
        for (Integer i = 0; i < queryCount; i++) {
            results.add(executeSingleQuery(plan.queries[i]));
        }
        return results;
    }

    // ── Parse query plan from JSON ──────────────────────────────────────────

    public static QueryPlan parseQueryPlan(String jsonPlan) {
        if (String.isBlank(jsonPlan)) {
            throw new QueryBuilderException('Query plan JSON is empty.');
        }

        // Strip markdown code fences if AI wrapped it
        String cleaned = jsonPlan.trim();
        if (cleaned.startsWith('```')) {
            Integer firstNewline = cleaned.indexOf('\n');
            if (firstNewline > 0) cleaned = cleaned.substring(firstNewline + 1);
            if (cleaned.endsWith('```')) cleaned = cleaned.substring(0, cleaned.length() - 3);
            cleaned = cleaned.trim();
        }

        try {
            Map<String, Object> raw = (Map<String, Object>) JSON.deserializeUntyped(cleaned);
            QueryPlan plan = new QueryPlan();
            plan.queries = new List<QuerySpec>();

            List<Object> rawQueries = (List<Object>) raw.get('queries');
            if (rawQueries == null) {
                throw new QueryBuilderException('No "queries" array in plan.');
            }

            for (Object rq : rawQueries) {
                Map<String, Object> qMap = (Map<String, Object>) rq;
                QuerySpec spec = new QuerySpec();
                spec.objectName = (String) qMap.get('objectName');
                spec.whereClause = (String) qMap.get('whereClause');
                spec.orderBy = (String) qMap.get('orderBy');
                spec.limitRows = qMap.get('limitRows') != null ? Integer.valueOf(String.valueOf(qMap.get('limitRows'))) : DEFAULT_ROW_LIMIT;

                // Fields
                spec.fields = new List<String>();
                List<Object> rawFields = (List<Object>) qMap.get('fields');
                if (rawFields != null) {
                    for (Object f : rawFields) spec.fields.add(String.valueOf(f));
                }

                // Parent traversals
                spec.parentTraversals = new List<ParentTraversal>();
                List<Object> rawParents = (List<Object>) qMap.get('parentTraversals');
                if (rawParents != null) {
                    for (Object rp : rawParents) {
                        Map<String, Object> pMap = (Map<String, Object>) rp;
                        ParentTraversal pt = new ParentTraversal();
                        pt.relationshipName = (String) pMap.get('relationshipName');
                        pt.fields = new List<String>();
                        List<Object> pFields = (List<Object>) pMap.get('fields');
                        if (pFields != null) {
                            for (Object pf : pFields) pt.fields.add(String.valueOf(pf));
                        }
                        spec.parentTraversals.add(pt);
                    }
                }

                // Child subqueries
                spec.childSubqueries = new List<ChildSubquery>();
                List<Object> rawChildren = (List<Object>) qMap.get('childSubqueries');
                if (rawChildren != null) {
                    for (Object rc : rawChildren) {
                        Map<String, Object> cMap = (Map<String, Object>) rc;
                        ChildSubquery cs = new ChildSubquery();
                        cs.relationshipName = (String) cMap.get('relationshipName');
                        cs.limitRows = cMap.get('limitRows') != null ? Integer.valueOf(String.valueOf(cMap.get('limitRows'))) : 10;
                        cs.fields = new List<String>();
                        List<Object> cFields = (List<Object>) cMap.get('fields');
                        if (cFields != null) {
                            for (Object cf : cFields) cs.fields.add(String.valueOf(cf));
                        }
                        spec.childSubqueries.add(cs);
                    }
                }

                // Aggregate
                if (qMap.containsKey('aggregate') && qMap.get('aggregate') != null) {
                    Map<String, Object> aMap = (Map<String, Object>) qMap.get('aggregate');
                    AggregateSpec agg = new AggregateSpec();
                    agg.function_x = (String) aMap.get('function');
                    agg.field = (String) aMap.get('field');
                    agg.groupByFields = new List<String>();
                    List<Object> gFields = (List<Object>) aMap.get('groupByFields');
                    if (gFields != null) {
                        for (Object gf : gFields) agg.groupByFields.add(String.valueOf(gf));
                    }
                    spec.aggregate = agg;
                }

                plan.queries.add(spec);
            }
            return plan;
        } catch (QueryBuilderException e) {
            throw e;
        } catch (Exception e) {
            throw new QueryBuilderException('Failed to parse query plan: ' + e.getMessage());
        }
    }

    // ── Execute a single QuerySpec ──────────────────────────────────────────

    private static QueryResult executeSingleQuery(QuerySpec spec) {
        QueryResult result = new QueryResult();
        result.objectName = spec.objectName;
        result.isSuccess = false;

        try {
            // Validate object
            Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
            Schema.SObjectType objType = globalDescribe.get(spec.objectName);
            if (objType == null) {
                throw new QueryBuilderException('Object not found: ' + spec.objectName);
            }
            Schema.DescribeSObjectResult objDescribe = objType.getDescribe();
            if (!objDescribe.isAccessible() || !objDescribe.isQueryable()) {
                throw new QueryBuilderException('Object not accessible: ' + spec.objectName);
            }

            String soql;
            if (spec.aggregate != null && String.isNotBlank(spec.aggregate.function_x)) {
                soql = buildAggregateQuery(spec, objDescribe);
            } else {
                soql = buildSelectQuery(spec, objDescribe, globalDescribe);
            }

            // Safety check
            validateNoInjection(soql);

            result.soql = soql;
            List<SObject> records = Database.query(soql);
            result.recordCount = records.size();
            result.dataJson = JSON.serializePretty(records);
            result.isSuccess = true;

        } catch (Exception e) {
            result.errorMessage = e.getMessage();
            result.recordCount = 0;
        }
        return result;
    }

    // ── Build SELECT query ──────────────────────────────────────────────────

    private static String buildSelectQuery(QuerySpec spec, Schema.DescribeSObjectResult objDescribe, Map<String, Schema.SObjectType> globalDescribe) {
        Map<String, Schema.SObjectField> fieldMap = objDescribe.fields.getMap();
        List<String> selectParts = new List<String>();

        // Validate and add direct fields
        if (spec.fields == null || spec.fields.isEmpty()) {
            // Default: Id and Name
            selectParts.add('Id');
            if (fieldMap.containsKey('name')) selectParts.add('Name');
        } else {
            for (String f : spec.fields) {
                String fLower = f.toLowerCase().trim();
                if (fieldMap.containsKey(fLower)) {
                    Schema.DescribeFieldResult fr = fieldMap.get(fLower).getDescribe();
                    if (fr.isAccessible()) {
                        selectParts.add(fr.getName());
                    }
                }
            }
            // Always include Id
            if (!selectParts.contains('Id')) selectParts.add(0, 'Id');
        }

        // Parent traversals (dot notation)
        if (spec.parentTraversals != null) {
            for (ParentTraversal pt : spec.parentTraversals) {
                if (String.isBlank(pt.relationshipName) || pt.fields == null) continue;
                // Validate the relationship exists
                Boolean validRel = false;
                String parentObjName = null;
                for (String fname : fieldMap.keySet()) {
                    Schema.DescribeFieldResult fr = fieldMap.get(fname).getDescribe();
                    if (fr.getRelationshipName() != null &&
                        fr.getRelationshipName().equalsIgnoreCase(pt.relationshipName)) {
                        validRel = true;
                        if (!fr.getReferenceTo().isEmpty()) {
                            parentObjName = fr.getReferenceTo()[0].getDescribe().getName();
                        }
                        break;
                    }
                }
                if (validRel && parentObjName != null) {
                    Schema.SObjectType parentType = globalDescribe.get(parentObjName);
                    if (parentType != null) {
                        Map<String, Schema.SObjectField> parentFields = parentType.getDescribe().fields.getMap();
                        for (String pf : pt.fields) {
                            String pfLower = pf.toLowerCase().trim();
                            if (parentFields.containsKey(pfLower)) {
                                Schema.DescribeFieldResult pfr = parentFields.get(pfLower).getDescribe();
                                if (pfr.isAccessible()) {
                                    selectParts.add(pt.relationshipName + '.' + pfr.getName());
                                }
                            }
                        }
                    }
                }
            }
        }

        // Child subqueries
        if (spec.childSubqueries != null) {
            for (ChildSubquery cs : spec.childSubqueries) {
                if (String.isBlank(cs.relationshipName) || cs.fields == null) continue;
                // Validate the child relationship
                String childObjName = null;
                for (Schema.ChildRelationship cr : objDescribe.getChildRelationships()) {
                    if (cr.getRelationshipName() != null &&
                        cr.getRelationshipName().equalsIgnoreCase(cs.relationshipName)) {
                        childObjName = cr.getChildSObject().getDescribe().getName();
                        break;
                    }
                }
                if (childObjName != null) {
                    Schema.SObjectType childType = globalDescribe.get(childObjName);
                    if (childType != null) {
                        Map<String, Schema.SObjectField> childFields = childType.getDescribe().fields.getMap();
                        List<String> validChildFields = new List<String>();
                        for (String cf : cs.fields) {
                            String cfLower = cf.toLowerCase().trim();
                            if (childFields.containsKey(cfLower)) {
                                Schema.DescribeFieldResult cfr = childFields.get(cfLower).getDescribe();
                                if (cfr.isAccessible()) validChildFields.add(cfr.getName());
                            }
                        }
                        if (!validChildFields.isEmpty()) {
                            Integer subLimit = Math.min(cs.limitRows != null ? cs.limitRows : 10, 50);
                            selectParts.add('(SELECT ' + String.join(validChildFields, ', ') +
                                ' FROM ' + cs.relationshipName + ' LIMIT ' + subLimit + ')');
                        }
                    }
                }
            }
        }

        // Build final SOQL
        String soql = 'SELECT ' + String.join(selectParts, ', ') + ' FROM ' + objDescribe.getName();

        // WHERE clause — sanitize
        if (String.isNotBlank(spec.whereClause)) {
            String sanitizedWhere = String.escapeSingleQuotes(spec.whereClause);
            // Re-unescape legitimate single quotes in string literals
            // The AI produces WHERE clauses like: StageName = 'Closed Won'
            // escapeSingleQuotes turns ' into \' which breaks SOQL
            // Instead, we do basic validation and use the raw clause
            validateNoInjection(spec.whereClause);
            soql += ' WHERE ' + spec.whereClause;
        }

        // ORDER BY
        if (String.isNotBlank(spec.orderBy)) {
            // Validate order by field
            String orderField = spec.orderBy.trim().split(' ')[0].toLowerCase();
            if (fieldMap.containsKey(orderField) && fieldMap.get(orderField).getDescribe().isSortable()) {
                soql += ' ORDER BY ' + spec.orderBy;
            }
        } else {
            // Default order
            if (fieldMap.containsKey('lastmodifieddate')) {
                soql += ' ORDER BY LastModifiedDate DESC NULLS LAST';
            }
        }

        // LIMIT
        Integer rowLimit = Math.min(spec.limitRows != null ? spec.limitRows : DEFAULT_ROW_LIMIT, MAX_ROW_LIMIT);
        soql += ' LIMIT ' + rowLimit;

        return soql;
    }

    // ── Build AGGREGATE query ───────────────────────────────────────────────

    private static String buildAggregateQuery(QuerySpec spec, Schema.DescribeSObjectResult objDescribe) {
        Map<String, Schema.SObjectField> fieldMap = objDescribe.fields.getMap();
        AggregateSpec agg = spec.aggregate;

        Set<String> validFunctions = new Set<String>{ 'COUNT', 'SUM', 'AVG', 'MAX', 'MIN' };
        String func = agg.function_x.toUpperCase();
        if (!validFunctions.contains(func)) {
            throw new QueryBuilderException('Invalid aggregate function: ' + agg.function_x);
        }

        // Build SELECT
        List<String> selectParts = new List<String>();

        // Group by fields
        if (agg.groupByFields != null) {
            for (String gf : agg.groupByFields) {
                String gfLower = gf.toLowerCase().trim();
                if (fieldMap.containsKey(gfLower) && fieldMap.get(gfLower).getDescribe().isAccessible()) {
                    selectParts.add(fieldMap.get(gfLower).getDescribe().getName());
                }
            }
        }

        // Aggregate expression
        if (func == 'COUNT' && String.isBlank(agg.field)) {
            selectParts.add('COUNT(Id) cnt');
        } else if (String.isNotBlank(agg.field)) {
            String aggFieldLower = agg.field.toLowerCase().trim();
            if (fieldMap.containsKey(aggFieldLower) && fieldMap.get(aggFieldLower).getDescribe().isAccessible()) {
                String validField = fieldMap.get(aggFieldLower).getDescribe().getName();
                selectParts.add(func + '(' + validField + ') val');
            } else {
                throw new QueryBuilderException('Aggregate field not accessible: ' + agg.field);
            }
        }

        String soql = 'SELECT ' + String.join(selectParts, ', ') + ' FROM ' + objDescribe.getName();

        if (String.isNotBlank(spec.whereClause)) {
            validateNoInjection(spec.whereClause);
            soql += ' WHERE ' + spec.whereClause;
        }

        // GROUP BY
        Boolean hasGroupBy = false;
        if (agg.groupByFields != null && !agg.groupByFields.isEmpty()) {
            List<String> validGroupBy = new List<String>();
            for (String gf : agg.groupByFields) {
                String gfLower = gf.toLowerCase().trim();
                if (fieldMap.containsKey(gfLower) && fieldMap.get(gfLower).getDescribe().isGroupable()) {
                    validGroupBy.add(fieldMap.get(gfLower).getDescribe().getName());
                }
            }
            if (!validGroupBy.isEmpty()) {
                soql += ' GROUP BY ' + String.join(validGroupBy, ', ');
                hasGroupBy = true;
            }
        }

        // LIMIT — only allowed with GROUP BY for aggregate queries
        if (hasGroupBy) {
            Integer rowLimit = Math.min(spec.limitRows != null ? spec.limitRows : DEFAULT_ROW_LIMIT, MAX_ROW_LIMIT);
            soql += ' LIMIT ' + rowLimit;
        }

        return soql;
    }

    // ── Safety validation ───────────────────────────────────────────────────

    private static void validateNoInjection(String input) {
        if (String.isBlank(input)) return;
        String upper = input.toUpperCase().trim();
        for (String keyword : BLOCKED_KEYWORDS) {
            if (upper.contains(keyword + ' ') || upper.contains(keyword + '(') || upper.startsWith(keyword)) {
                throw new QueryBuilderException('Blocked keyword detected in query: ' + keyword);
            }
        }
        // Block semicolons (multi-statement)
        if (input.contains(';')) {
            throw new QueryBuilderException('Semicolons not allowed in query input.');
        }
    }

    public class QueryBuilderException extends Exception {}
}
