/**
 * SchemaService
 * ─────────────────────────────────────────────────────────────────────────────
 * Phase 1 — Schema Discovery Engine
 * Dynamically discovers the org's data model at runtime:
 *   - All accessible objects (standard + custom)
 *   - Fields, data types, picklist values
 *   - Parent (lookup/master-detail) and child relationships
 *   - Compact schema summary for AI prompt injection
 *
 * This class contains NO AI calls, NO SOQL execution, NO DML.
 * It is a pure metadata-read utility.
 * ─────────────────────────────────────────────────────────────────────────────
 */
public with sharing class SchemaService {

    // ── Data Classes ────────────────────────────────────────────────────────

    public class ObjectSummary {
        @AuraEnabled public String  label      { get; set; }
        @AuraEnabled public String  apiName    { get; set; }
        @AuraEnabled public Boolean isCustom   { get; set; }
        @AuraEnabled public Boolean isQueryable { get; set; }
    }

    public class ObjectDetail {
        @AuraEnabled public String  label      { get; set; }
        @AuraEnabled public String  apiName    { get; set; }
        @AuraEnabled public Boolean isCustom   { get; set; }
        @AuraEnabled public List<FieldDetail>        fields              { get; set; }
        @AuraEnabled public List<ParentRelationship>  parentRelationships { get; set; }
        @AuraEnabled public List<ChildRelationship>   childRelationships  { get; set; }
    }

    public class FieldDetail {
        @AuraEnabled public String  label        { get; set; }
        @AuraEnabled public String  apiName      { get; set; }
        @AuraEnabled public String  dataType     { get; set; }
        @AuraEnabled public Integer length       { get; set; }
        @AuraEnabled public Boolean isRequired   { get; set; }
        @AuraEnabled public Boolean isCustom     { get; set; }
        @AuraEnabled public Boolean isFilterable { get; set; }
        @AuraEnabled public Boolean isSortable   { get; set; }
        @AuraEnabled public List<String> picklistValues { get; set; }
    }

    public class ParentRelationship {
        @AuraEnabled public String fieldName        { get; set; } // e.g. AccountId
        @AuraEnabled public String parentObject     { get; set; } // e.g. Account
        @AuraEnabled public String relationshipName { get; set; } // e.g. Account (for dot notation Account.Name)
    }

    public class ChildRelationship {
        @AuraEnabled public String childObject      { get; set; } // e.g. Contact
        @AuraEnabled public String relationshipName { get; set; } // e.g. Contacts (for subquery)
        @AuraEnabled public String foreignKeyField  { get; set; } // e.g. AccountId
    }

    public class RelationshipInfo {
        @AuraEnabled public String direction        { get; set; } // 'child-to-parent' or 'parent-to-child'
        @AuraEnabled public String relationshipName { get; set; }
        @AuraEnabled public String foreignKeyField  { get; set; }
        @AuraEnabled public String traversalPath    { get; set; } // dot notation or subquery hint
        @AuraEnabled public String parentObject     { get; set; }
        @AuraEnabled public String childObject      { get; set; }
    }

    // ── Constants ───────────────────────────────────────────────────────────

    private static final Integer MAX_FIELDS_PER_OBJECT   = 50;
    private static final Integer MAX_PICKLIST_VALUES     = 20;
    private static final Integer SUMMARY_MAX_FIELDS      = 12;
    private static final Integer SUMMARY_MAX_CHILDREN    = 5;

    // Core business objects to include in schema summary (lightweight — avoids full org scan)
    private static final List<String> CORE_OBJECTS = new List<String>{
        'Account', 'Contact', 'Lead', 'Opportunity', 'Case',
        'Task', 'Event', 'Campaign', 'Contract', 'Order',
        'Product2', 'Quote', 'Asset', 'User', 'OpportunityLineItem',
        'CampaignMember', 'Pricebook2', 'PricebookEntry'
    };

    // Objects to always skip (system/internal objects not useful for business queries)
    private static final Set<String> SKIP_OBJECTS = new Set<String>{
        'ApexClass', 'ApexTrigger', 'ApexPage', 'ApexComponent',
        'AsyncApexJob', 'CronTrigger', 'CronJobDetail',
        'LoginHistory', 'SetupAuditTrail', 'SetupEntityAccess',
        'PermissionSet', 'PermissionSetAssignment', 'Profile',
        'UserRole', 'GroupMember', 'QueueSobject',
        'ContentVersion', 'ContentDocument', 'ContentDocumentLink',
        'FeedItem', 'FeedComment', 'EntitySubscription',
        'EmailMessage', 'EmailTemplate',
        'DuplicateRecordItem', 'DuplicateRecordSet',
        'RecordType', 'BusinessHours', 'Holiday',
        'ApexLog', 'TraceFlag', 'DebugLevel',
        'StaticResource', 'Document', 'Folder',
        'Dashboard', 'Report', 'ReportType',
        'ListView', 'CustomPermission', 'ConnectedApplication',
        'OauthToken', 'SessionPermSetActivation',
        'FieldPermissions', 'ObjectPermissions',
        'UserPreference', 'UserAppInfo', 'UserAppMenuCustomization'
    };

    // ── 1.1  getAllObjects() ─────────────────────────────────────────────────

    /**
     * Returns every accessible & queryable object in the org.
     * Includes standard objects, custom objects, and managed package objects.
     * Filters out system/internal objects that are not useful for business queries.
     */
    @AuraEnabled(cacheable=true)
    public static List<ObjectSummary> getAllObjects() {
        List<ObjectSummary> results = new List<ObjectSummary>();
        Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();

        for (String objName : globalDescribe.keySet()) {
            // Skip known system objects
            if (SKIP_OBJECTS.contains(objName)) continue;

            try {
                Schema.DescribeSObjectResult dr = globalDescribe.get(objName).getDescribe();

                // Must be accessible and queryable
                if (!dr.isAccessible() || !dr.isQueryable()) continue;

                // Skip objects that start with system prefixes
                String name = dr.getName();
                if (name.startsWith('AIInsight') ||
                    name.startsWith('AIRecord') ||
                    name.startsWith('FlowInterview') ||
                    name.startsWith('SetupEntity') ||
                    name.endsWith('__History') ||
                    name.endsWith('__Tag') ||
                    name.endsWith('__Share') ||
                    name.endsWith('__Feed') ||
                    name.endsWith('__ChangeEvent')) {
                    continue;
                }

                ObjectSummary summary   = new ObjectSummary();
                summary.label           = dr.getLabel();
                summary.apiName         = name;
                summary.isCustom        = dr.isCustom();
                summary.isQueryable     = true;
                results.add(summary);
            } catch (Exception e) {
                // Skip objects that throw errors during describe
                System.debug(LoggingLevel.WARN, 'SchemaService.getAllObjects: Skipping ' + objName + ' — ' + e.getMessage());
            }
        }

        // Sort alphabetically by label
        return sortByLabel(results);
    }

    /**
     * Sort ObjectSummary list by label using a map-based approach.
     * Apex List.sort() requires items to implement Comparable, so we use key-based sorting.
     */
    private static List<ObjectSummary> sortByLabel(List<ObjectSummary> items) {
        Map<String, ObjectSummary> keyMap = new Map<String, ObjectSummary>();
        List<String> keys = new List<String>();

        for (ObjectSummary item : items) {
            String key = item.label + '|' + item.apiName;
            keys.add(key);
            keyMap.put(key, item);
        }
        keys.sort();

        List<ObjectSummary> sorted = new List<ObjectSummary>();
        for (String key : keys) {
            sorted.add(keyMap.get(key));
        }
        return sorted;
    }

    // ── 1.2  describeObject() ───────────────────────────────────────────────

    /**
     * Deep-dives into a single object: all accessible fields + all relationships.
     * @param objectApiName  API name of the object (e.g. 'Account', 'My_Object__c')
     * @return ObjectDetail with fields, parent relationships, and child relationships
     */
    @AuraEnabled(cacheable=true)
    public static ObjectDetail describeObject(String objectApiName) {
        if (String.isBlank(objectApiName)) {
            throw new SchemaServiceException('Object API name is required.');
        }

        Schema.SObjectType objType = Schema.getGlobalDescribe().get(objectApiName);
        if (objType == null) {
            throw new SchemaServiceException('Object not found: ' + objectApiName);
        }

        Schema.DescribeSObjectResult dr = objType.getDescribe();
        if (!dr.isAccessible()) {
            throw new SchemaServiceException('Object not accessible: ' + objectApiName);
        }

        ObjectDetail detail     = new ObjectDetail();
        detail.label            = dr.getLabel();
        detail.apiName          = dr.getName();
        detail.isCustom         = dr.isCustom();
        detail.fields           = new List<FieldDetail>();
        detail.parentRelationships = new List<ParentRelationship>();
        detail.childRelationships  = new List<ChildRelationship>();

        // ── Fields ──
        Map<String, Schema.SObjectField> fieldMap = dr.fields.getMap();
        Integer fieldCount = 0;

        for (String fname : fieldMap.keySet()) {
            if (fieldCount >= MAX_FIELDS_PER_OBJECT) break;

            Schema.DescribeFieldResult fr = fieldMap.get(fname).getDescribe();
            if (!fr.isAccessible()) continue;

            FieldDetail fd      = new FieldDetail();
            fd.label            = fr.getLabel();
            fd.apiName          = fr.getName();
            fd.dataType         = String.valueOf(fr.getType());
            fd.length           = fr.getLength();
            fd.isRequired       = !fr.isNillable() && fr.isCreateable();
            fd.isCustom         = fr.isCustom();
            fd.isFilterable     = fr.isFilterable();
            fd.isSortable       = fr.isSortable();
            fd.picklistValues   = new List<String>();

            // Capture picklist values
            if (fr.getType() == Schema.DisplayType.PICKLIST ||
                fr.getType() == Schema.DisplayType.MULTIPICKLIST) {
                List<Schema.PicklistEntry> entries = fr.getPicklistValues();
                Integer pvCount = 0;
                for (Schema.PicklistEntry pe : entries) {
                    if (pe.isActive()) {
                        fd.picklistValues.add(pe.getValue());
                        pvCount++;
                        if (pvCount >= MAX_PICKLIST_VALUES) break;
                    }
                }
            }

            // Detect parent relationship (lookup / master-detail)
            if (fr.getType() == Schema.DisplayType.REFERENCE) {
                List<Schema.SObjectType> refs = fr.getReferenceTo();
                if (!refs.isEmpty()) {
                    String relName = fr.getRelationshipName();
                    for (Schema.SObjectType refType : refs) {
                        ParentRelationship pr = new ParentRelationship();
                        pr.fieldName          = fr.getName();
                        pr.parentObject       = refType.getDescribe().getName();
                        pr.relationshipName   = relName;
                        detail.parentRelationships.add(pr);
                    }
                }
            }

            detail.fields.add(fd);
            fieldCount++;
        }

        // ── Child relationships ──
        List<Schema.ChildRelationship> childRels = dr.getChildRelationships();
        for (Schema.ChildRelationship cr : childRels) {
            String relName = cr.getRelationshipName();
            if (String.isBlank(relName)) continue; // skip unnamed relationships

            Schema.DescribeSObjectResult childDescribe = cr.getChildSObject().getDescribe();
            String childName = childDescribe.getName();

            // Skip system child objects
            if (childName.endsWith('__History') ||
                childName.endsWith('__Tag') ||
                childName.endsWith('__Share') ||
                childName.endsWith('__Feed') ||
                childName.endsWith('__ChangeEvent') ||
                childName.startsWith('FeedItem') ||
                childName.startsWith('EntitySubscription')) {
                continue;
            }

            if (!childDescribe.isAccessible() || !childDescribe.isQueryable()) continue;

            ChildRelationship childRel = new ChildRelationship();
            childRel.childObject       = childName;
            childRel.relationshipName  = relName;
            childRel.foreignKeyField   = cr.getField().getDescribe().getName();
            detail.childRelationships.add(childRel);
        }

        return detail;
    }

    // ── 1.3  getRelationshipPath() ──────────────────────────────────────────

    /**
     * Finds how two objects are connected and returns traversal info for SOQL.
     * Checks both directions: A→B (child-to-parent) and B→A (parent-to-child).
     *
     * @param objectA  First object API name
     * @param objectB  Second object API name
     * @return RelationshipInfo with direction, relationship name, and SOQL traversal path
     */
    @AuraEnabled(cacheable=true)
    public static List<RelationshipInfo> getRelationshipPath(String objectA, String objectB) {
        if (String.isBlank(objectA) || String.isBlank(objectB)) {
            throw new SchemaServiceException('Both object API names are required.');
        }

        List<RelationshipInfo> results = new List<RelationshipInfo>();

        Schema.SObjectType typeA = Schema.getGlobalDescribe().get(objectA);
        Schema.SObjectType typeB = Schema.getGlobalDescribe().get(objectB);
        if (typeA == null) throw new SchemaServiceException('Object not found: ' + objectA);
        if (typeB == null) throw new SchemaServiceException('Object not found: ' + objectB);

        Schema.DescribeSObjectResult drA = typeA.getDescribe();
        Schema.DescribeSObjectResult drB = typeB.getDescribe();

        // ── Check A → B  (A has a lookup to B = child-to-parent) ──
        Map<String, Schema.SObjectField> fieldsA = drA.fields.getMap();
        for (String fname : fieldsA.keySet()) {
            Schema.DescribeFieldResult fr = fieldsA.get(fname).getDescribe();
            if (fr.getType() != Schema.DisplayType.REFERENCE) continue;
            if (!fr.isAccessible()) continue;

            for (Schema.SObjectType refType : fr.getReferenceTo()) {
                if (refType.getDescribe().getName().equalsIgnoreCase(objectB)) {
                    RelationshipInfo ri  = new RelationshipInfo();
                    ri.direction         = 'child-to-parent';
                    ri.relationshipName  = fr.getRelationshipName();
                    ri.foreignKeyField   = fr.getName();
                    ri.parentObject      = objectB;
                    ri.childObject       = objectA;
                    // e.g. querying FROM Opportunity, traverse Account.Name
                    ri.traversalPath     = fr.getRelationshipName() + '.[FieldName]';
                    results.add(ri);
                }
            }
        }

        // ── Check B → A  (B has a lookup to A = A is parent, B is child → parent-to-child from A) ──
        Map<String, Schema.SObjectField> fieldsB = drB.fields.getMap();
        for (String fname : fieldsB.keySet()) {
            Schema.DescribeFieldResult fr = fieldsB.get(fname).getDescribe();
            if (fr.getType() != Schema.DisplayType.REFERENCE) continue;
            if (!fr.isAccessible()) continue;

            for (Schema.SObjectType refType : fr.getReferenceTo()) {
                if (refType.getDescribe().getName().equalsIgnoreCase(objectA)) {
                    // Find the child relationship name from A's perspective
                    String childRelName = null;
                    for (Schema.ChildRelationship cr : drA.getChildRelationships()) {
                        if (cr.getChildSObject().getDescribe().getName().equalsIgnoreCase(objectB)
                            && cr.getField().getDescribe().getName().equalsIgnoreCase(fr.getName())) {
                            childRelName = cr.getRelationshipName();
                            break;
                        }
                    }

                    if (String.isNotBlank(childRelName)) {
                        RelationshipInfo ri  = new RelationshipInfo();
                        ri.direction         = 'parent-to-child';
                        ri.relationshipName  = childRelName;
                        ri.foreignKeyField   = fr.getName();
                        ri.parentObject      = objectA;
                        ri.childObject       = objectB;
                        // e.g. (SELECT Id, Name FROM Contacts)
                        ri.traversalPath     = '(SELECT [Fields] FROM ' + childRelName + ')';
                        results.add(ri);
                    }
                }
            }
        }

        return results;
    }

    // ── 1.4  getCompactSchemaSummary() ──────────────────────────────────────

    /**
     * Produces a token-efficient text summary of the org schema for AI prompt injection.
     *
     * PERFORMANCE: Only describes CORE_OBJECTS + custom objects (__c).
     * Does NOT scan the entire org. This keeps CPU time under 2 seconds
     * instead of 10+ seconds for a full org scan.
     *
     * @return Compact multi-line string describing the org's data model
     */
    @AuraEnabled(cacheable=true)
    public static String getCompactSchemaSummary() {
        Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();

        // Build target list: core objects + custom objects
        Set<String> targetObjects = new Set<String>();
        for (String obj : CORE_OBJECTS) {
            targetObjects.add(obj.toLowerCase());
        }
        // Add custom objects (cheap — just checking key suffix, no describe)
        for (String objName : globalDescribe.keySet()) {
            if (objName.endsWith('__c')) {
                targetObjects.add(objName);
            }
        }

        List<String> lines = new List<String>();
        lines.add('ORG SCHEMA SUMMARY');
        lines.add('==================');

        for (String objKey : targetObjects) {
            Schema.SObjectType sType = globalDescribe.get(objKey);
            if (sType == null) continue;

            try {
                Schema.DescribeSObjectResult dr = sType.getDescribe();
                if (!dr.isAccessible() || !dr.isQueryable()) continue;

                String objName = dr.getName();

                // ── Collect key fields (limited) ──
                List<String> fieldNames = new List<String>();
                Map<String, Schema.SObjectField> fieldMap = dr.fields.getMap();
                Integer fCount = 0;

                Set<String> prioritySet = new Set<String>{
                    'name', 'subject', 'title', 'status', 'stagename',
                    'amount', 'closedate', 'email', 'phone', 'industry',
                    'type', 'priority', 'annualrevenue', 'leadsource',
                    'rating', 'probability', 'company'
                };

                // Priority fields first
                for (String pf : prioritySet) {
                    if (fCount >= SUMMARY_MAX_FIELDS) break;
                    if (fieldMap.containsKey(pf)) {
                        Schema.DescribeFieldResult fr = fieldMap.get(pf).getDescribe();
                        if (fr.isAccessible()) {
                            fieldNames.add(fr.getName());
                            fCount++;
                        }
                    }
                }

                // Then custom fields
                for (String fname : fieldMap.keySet()) {
                    if (fCount >= SUMMARY_MAX_FIELDS) break;
                    if (!fname.endsWith('__c')) continue;
                    Schema.DescribeFieldResult fr = fieldMap.get(fname).getDescribe();
                    if (fr.isAccessible() && !fieldNames.contains(fr.getName())) {
                        fieldNames.add(fr.getName());
                        fCount++;
                    }
                }

                // ── Collect parent relationships (lightweight — only from reference fields) ──
                List<String> parents = new List<String>();
                for (String fname : fieldMap.keySet()) {
                    Schema.DescribeFieldResult fr = fieldMap.get(fname).getDescribe();
                    if (fr.getType() == Schema.DisplayType.REFERENCE && fr.isAccessible()) {
                        String relName = fr.getRelationshipName();
                        List<Schema.SObjectType> refs = fr.getReferenceTo();
                        if (!refs.isEmpty() && String.isNotBlank(relName)) {
                            parents.add(refs[0].getDescribe().getName() + '(' + fr.getName() + ')');
                        }
                    }
                }

                // ── Collect child relationships (limited to avoid CPU) ──
                List<String> children = new List<String>();
                Integer childCount = 0;
                for (Schema.ChildRelationship cr : dr.getChildRelationships()) {
                    if (childCount >= SUMMARY_MAX_CHILDREN) break;
                    String relName = cr.getRelationshipName();
                    if (String.isBlank(relName)) continue;
                    String childName = cr.getChildSObject().getDescribe().getName();
                    if (childName.endsWith('__History') || childName.endsWith('__Tag') ||
                        childName.endsWith('__Share') || childName.endsWith('__Feed') ||
                        childName.endsWith('__ChangeEvent')) continue;
                    children.add(relName + '(' + childName + ')');
                    childCount++;
                }

                // ── Build the line ──
                String line = '- ' + dr.getLabel() + ' (' + objName + ')';
                if (dr.isCustom()) line += ' [custom]';
                line += ' | Fields: ' + String.join(fieldNames, ', ');
                if (!parents.isEmpty()) line += ' | Parents: ' + String.join(parents, ', ');
                if (!children.isEmpty()) line += ' | Children: ' + String.join(children, ', ');

                lines.add(line);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'SchemaService.getCompactSchemaSummary: Skipping ' + objKey + ' — ' + e.getMessage());
            }
        }

        lines.add('');
        lines.add('RELATIONSHIP NOTATION:');
        lines.add('- Parents: ParentObject(ForeignKeyField) — use dot notation: RelationshipName.FieldName');
        lines.add('- Children: RelationshipName(ChildObject) — use subquery: (SELECT Fields FROM RelationshipName)');

        return String.join(lines, '\n');
    }

    // ── Exception class ─────────────────────────────────────────────────────

    public class SchemaServiceException extends Exception {}
}
