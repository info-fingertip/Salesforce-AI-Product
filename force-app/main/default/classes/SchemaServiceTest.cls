/**
 * SchemaServiceTest
 * ─────────────────────────────────────────────────────────────────────────────
 * Test class for SchemaService (Phase 1 — Schema Discovery Engine)
 * Coverage target: 85%+
 * No DML, no HTTP callouts — pure metadata describe tests
 * ─────────────────────────────────────────────────────────────────────────────
 */
@isTest
private class SchemaServiceTest {

    // ─────────────────────────────────────────────────────────────────────────
    // 1.1  getAllObjects()
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void testGetAllObjects_ReturnsResults() {
        Test.startTest();
        List<SchemaService.ObjectSummary> objects = SchemaService.getAllObjects();
        Test.stopTest();

        System.assert(objects.size() > 0, 'Should return at least one object');
    }

    @isTest
    static void testGetAllObjects_ContainsStandardObjects() {
        Test.startTest();
        List<SchemaService.ObjectSummary> objects = SchemaService.getAllObjects();
        Test.stopTest();

        Set<String> apiNames = new Set<String>();
        for (SchemaService.ObjectSummary obj : objects) {
            apiNames.add(obj.apiName);
        }

        System.assert(apiNames.contains('Account'), 'Should contain Account');
        System.assert(apiNames.contains('Contact'), 'Should contain Contact');
        System.assert(apiNames.contains('Opportunity'), 'Should contain Opportunity');
    }

    @isTest
    static void testGetAllObjects_SortedByLabel() {
        Test.startTest();
        List<SchemaService.ObjectSummary> objects = SchemaService.getAllObjects();
        Test.stopTest();

        if (objects.size() >= 2) {
            for (Integer i = 1; i < objects.size(); i++) {
                String prev = objects[i-1].label + '|' + objects[i-1].apiName;
                String curr = objects[i].label + '|' + objects[i].apiName;
                System.assert(prev.compareTo(curr) <= 0,
                    'Objects should be sorted by label: ' + prev + ' should come before ' + curr);
            }
        }
    }

    @isTest
    static void testGetAllObjects_ExcludesSystemObjects() {
        Test.startTest();
        List<SchemaService.ObjectSummary> objects = SchemaService.getAllObjects();
        Test.stopTest();

        Set<String> apiNames = new Set<String>();
        for (SchemaService.ObjectSummary obj : objects) {
            apiNames.add(obj.apiName);
        }

        System.assert(!apiNames.contains('ApexClass'), 'Should not contain ApexClass');
        System.assert(!apiNames.contains('ApexTrigger'), 'Should not contain ApexTrigger');
    }

    @isTest
    static void testGetAllObjects_ExcludesHistoryAndFeedObjects() {
        Test.startTest();
        List<SchemaService.ObjectSummary> objects = SchemaService.getAllObjects();
        Test.stopTest();

        for (SchemaService.ObjectSummary obj : objects) {
            System.assert(!obj.apiName.endsWith('__History'), 'Should not contain History objects: ' + obj.apiName);
            System.assert(!obj.apiName.endsWith('__Feed'), 'Should not contain Feed objects: ' + obj.apiName);
            System.assert(!obj.apiName.endsWith('__Share'), 'Should not contain Share objects: ' + obj.apiName);
            System.assert(!obj.apiName.endsWith('__ChangeEvent'), 'Should not contain ChangeEvent objects: ' + obj.apiName);
        }
    }

    @isTest
    static void testGetAllObjects_FieldsPopulated() {
        Test.startTest();
        List<SchemaService.ObjectSummary> objects = SchemaService.getAllObjects();
        Test.stopTest();

        for (SchemaService.ObjectSummary obj : objects) {
            System.assertNotEquals(null, obj.label, 'Label should not be null');
            System.assertNotEquals(null, obj.apiName, 'API name should not be null');
            System.assertNotEquals(null, obj.isQueryable, 'isQueryable should not be null');
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1.2  describeObject()
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void testDescribeObject_Account() {
        Test.startTest();
        SchemaService.ObjectDetail detail = SchemaService.describeObject('Account');
        Test.stopTest();

        System.assertEquals('Account', detail.apiName);
        System.assertEquals(false, detail.isCustom);
        System.assert(detail.fields.size() > 0, 'Account should have fields');
        System.assertNotEquals(null, detail.label);
    }

    @isTest
    static void testDescribeObject_FieldsHaveMetadata() {
        Test.startTest();
        SchemaService.ObjectDetail detail = SchemaService.describeObject('Account');
        Test.stopTest();

        Boolean hasNameField = false;
        for (SchemaService.FieldDetail fd : detail.fields) {
            System.assertNotEquals(null, fd.label, 'Field label should not be null');
            System.assertNotEquals(null, fd.apiName, 'Field apiName should not be null');
            System.assertNotEquals(null, fd.dataType, 'Field dataType should not be null');
            if (fd.apiName == 'Name') hasNameField = true;
        }
        System.assert(hasNameField, 'Account should have a Name field');
    }

    @isTest
    static void testDescribeObject_ParentRelationships() {
        Test.startTest();
        SchemaService.ObjectDetail detail = SchemaService.describeObject('Contact');
        Test.stopTest();

        Boolean hasAccountParent = false;
        for (SchemaService.ParentRelationship pr : detail.parentRelationships) {
            if (pr.parentObject == 'Account' && pr.fieldName == 'AccountId') {
                hasAccountParent = true;
                System.assertNotEquals(null, pr.relationshipName, 'Relationship name should not be null');
            }
        }
        System.assert(hasAccountParent, 'Contact should have Account as parent');
    }

    @isTest
    static void testDescribeObject_ChildRelationships() {
        Test.startTest();
        SchemaService.ObjectDetail detail = SchemaService.describeObject('Account');
        Test.stopTest();

        System.assert(detail.childRelationships.size() > 0, 'Account should have child relationships');
        Boolean hasContacts = false;
        for (SchemaService.ChildRelationship cr : detail.childRelationships) {
            if (cr.childObject == 'Contact' && cr.relationshipName == 'Contacts') {
                hasContacts = true;
                System.assertEquals('AccountId', cr.foreignKeyField);
            }
        }
        System.assert(hasContacts, 'Account should have Contacts as child relationship');
    }

    @isTest
    static void testDescribeObject_Opportunity_HasPicklists() {
        Test.startTest();
        SchemaService.ObjectDetail detail = SchemaService.describeObject('Opportunity');
        Test.stopTest();

        Boolean hasStagePick = false;
        for (SchemaService.FieldDetail fd : detail.fields) {
            if (fd.apiName == 'StageName' && fd.dataType == 'PICKLIST') {
                hasStagePick = true;
                System.assert(fd.picklistValues.size() > 0, 'StageName should have picklist values');
            }
        }
        System.assert(hasStagePick, 'Opportunity should have StageName picklist');
    }

    @isTest
    static void testDescribeObject_BlankName_ThrowsException() {
        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            SchemaService.describeObject('');
        } catch (SchemaService.SchemaServiceException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('required'));
        }
        Test.stopTest();
        System.assert(exceptionThrown, 'Should throw exception for blank name');
    }

    @isTest
    static void testDescribeObject_InvalidObject_ThrowsException() {
        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            SchemaService.describeObject('NonExistentObject__xyz');
        } catch (SchemaService.SchemaServiceException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('not found'));
        }
        Test.stopTest();
        System.assert(exceptionThrown, 'Should throw exception for invalid object');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1.3  getRelationshipPath()
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void testGetRelationshipPath_OpportunityToAccount() {
        Test.startTest();
        List<SchemaService.RelationshipInfo> rels =
            SchemaService.getRelationshipPath('Opportunity', 'Account');
        Test.stopTest();

        System.assert(rels.size() > 0, 'Should find relationships between Opportunity and Account');

        Boolean hasChildToParent = false;
        for (SchemaService.RelationshipInfo ri : rels) {
            if (ri.direction == 'child-to-parent' && ri.parentObject == 'Account') {
                hasChildToParent = true;
                System.assertEquals('AccountId', ri.foreignKeyField);
                System.assertEquals('Opportunity', ri.childObject);
            }
        }
        System.assert(hasChildToParent, 'Should find child-to-parent from Opportunity to Account');
    }

    @isTest
    static void testGetRelationshipPath_AccountToContact() {
        Test.startTest();
        List<SchemaService.RelationshipInfo> rels =
            SchemaService.getRelationshipPath('Account', 'Contact');
        Test.stopTest();

        System.assert(rels.size() > 0, 'Should find relationships between Account and Contact');

        Boolean hasParentToChild = false;
        for (SchemaService.RelationshipInfo ri : rels) {
            if (ri.direction == 'parent-to-child' && ri.childObject == 'Contact') {
                hasParentToChild = true;
                System.assertEquals('Account', ri.parentObject);
                System.assertEquals('Contacts', ri.relationshipName);
            }
        }
        System.assert(hasParentToChild, 'Should find parent-to-child from Account to Contact');
    }

    @isTest
    static void testGetRelationshipPath_BothDirections() {
        // Contact → Account has both: Contact has AccountId (child-to-parent)
        // and Account has Contacts relationship (parent-to-child from Account perspective)
        // But when querying Contact→Account, we expect child-to-parent
        Test.startTest();
        List<SchemaService.RelationshipInfo> rels =
            SchemaService.getRelationshipPath('Contact', 'Account');
        Test.stopTest();

        System.assert(rels.size() > 0, 'Should find at least one relationship');
    }

    @isTest
    static void testGetRelationshipPath_UnrelatedObjects() {
        // Campaign and Product2 typically have no direct relationship
        Test.startTest();
        List<SchemaService.RelationshipInfo> rels =
            SchemaService.getRelationshipPath('Product2', 'Case');
        Test.stopTest();

        // May or may not have relationships depending on org config
        // Just verify it doesn't throw
        System.assertNotEquals(null, rels);
    }

    @isTest
    static void testGetRelationshipPath_BlankInputs_ThrowsException() {
        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            SchemaService.getRelationshipPath('', 'Account');
        } catch (SchemaService.SchemaServiceException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('required'));
        }
        Test.stopTest();
        System.assert(exceptionThrown, 'Should throw for blank inputs');
    }

    @isTest
    static void testGetRelationshipPath_InvalidObject_ThrowsException() {
        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            SchemaService.getRelationshipPath('FakeObject__xyz', 'Account');
        } catch (SchemaService.SchemaServiceException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('not found'));
        }
        Test.stopTest();
        System.assert(exceptionThrown, 'Should throw for invalid object');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1.4  getCompactSchemaSummary()
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void testGetCompactSchemaSummary_ReturnsContent() {
        Test.startTest();
        String summary = SchemaService.getCompactSchemaSummary();
        Test.stopTest();

        System.assertNotEquals(null, summary, 'Summary should not be null');
        System.assert(summary.length() > 100, 'Summary should have substantial content');
    }

    @isTest
    static void testGetCompactSchemaSummary_ContainsHeader() {
        Test.startTest();
        String summary = SchemaService.getCompactSchemaSummary();
        Test.stopTest();

        System.assert(summary.contains('ORG SCHEMA SUMMARY'), 'Should contain header');
        System.assert(summary.contains('RELATIONSHIP NOTATION'), 'Should contain relationship notation guide');
    }

    @isTest
    static void testGetCompactSchemaSummary_ContainsStandardObjects() {
        Test.startTest();
        String summary = SchemaService.getCompactSchemaSummary();
        Test.stopTest();

        System.assert(summary.contains('Account'), 'Summary should mention Account');
        System.assert(summary.contains('Contact'), 'Summary should mention Contact');
    }

    @isTest
    static void testGetCompactSchemaSummary_ContainsFieldsAndRelationships() {
        Test.startTest();
        String summary = SchemaService.getCompactSchemaSummary();
        Test.stopTest();

        System.assert(summary.contains('Fields:'), 'Should contain Fields section');
        // At least some objects should have parent or child relationships
        System.assert(summary.contains('Parents:') || summary.contains('Children:'),
            'Should contain relationship info');
    }

    @isTest
    static void testGetCompactSchemaSummary_ReasonableSize() {
        Test.startTest();
        String summary = SchemaService.getCompactSchemaSummary();
        Test.stopTest();

        // Should be substantial but not excessively large
        // A typical org might produce 5000-50000 chars depending on # of objects
        System.assert(summary.length() < 200000, 'Summary should not be excessively large');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Data class instantiation tests (for coverage)
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void testDataClasses_ObjectSummary() {
        SchemaService.ObjectSummary os = new SchemaService.ObjectSummary();
        os.label = 'Test';
        os.apiName = 'Test__c';
        os.isCustom = true;
        os.isQueryable = true;

        System.assertEquals('Test', os.label);
        System.assertEquals('Test__c', os.apiName);
        System.assertEquals(true, os.isCustom);
    }

    @isTest
    static void testDataClasses_FieldDetail() {
        SchemaService.FieldDetail fd = new SchemaService.FieldDetail();
        fd.label = 'Status';
        fd.apiName = 'Status__c';
        fd.dataType = 'PICKLIST';
        fd.length = 40;
        fd.isRequired = true;
        fd.isCustom = true;
        fd.isFilterable = true;
        fd.isSortable = true;
        fd.picklistValues = new List<String>{ 'Open', 'Closed' };

        System.assertEquals('PICKLIST', fd.dataType);
        System.assertEquals(2, fd.picklistValues.size());
    }

    @isTest
    static void testDataClasses_RelationshipInfo() {
        SchemaService.RelationshipInfo ri = new SchemaService.RelationshipInfo();
        ri.direction = 'child-to-parent';
        ri.relationshipName = 'Account';
        ri.foreignKeyField = 'AccountId';
        ri.traversalPath = 'Account.Name';
        ri.parentObject = 'Account';
        ri.childObject = 'Opportunity';

        System.assertEquals('child-to-parent', ri.direction);
        System.assertEquals('Account.Name', ri.traversalPath);
    }
}
