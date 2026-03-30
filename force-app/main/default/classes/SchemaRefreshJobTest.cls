/**
 * SchemaRefreshJobTest
 * ─────────────────────────────────────────────────────────────────────────────
 * Test class for SchemaRefreshJob
 * ─────────────────────────────────────────────────────────────────────────────
 */
@isTest
private class SchemaRefreshJobTest {

    @isTest
    static void testRefreshNow_CreatesCache() {
        // Ensure no cache exists
        List<AI_Schema_Cache__c> before = [SELECT Id FROM AI_Schema_Cache__c WHERE Name = 'SCHEMA_SUMMARY'];
        System.assertEquals(0, before.size(), 'Should start with no cache');

        Test.startTest();
        SchemaRefreshJob.refreshNow();
        Test.stopTest();

        List<AI_Schema_Cache__c> after = [
            SELECT Schema_Summary__c, Last_Refreshed__c, Object_Count__c
            FROM AI_Schema_Cache__c
            WHERE Name = 'SCHEMA_SUMMARY'
        ];
        System.assertEquals(1, after.size(), 'Should create one cache record');
        System.assertNotEquals(null, after[0].Schema_Summary__c, 'Schema should not be null');
        System.assert(after[0].Schema_Summary__c.length() > 100, 'Schema should have content');
        System.assertNotEquals(null, after[0].Last_Refreshed__c, 'Timestamp should be set');
        System.assert(after[0].Object_Count__c > 0, 'Object count should be > 0');
    }

    @isTest
    static void testRefreshNow_UpdatesExisting() {
        // Create initial cache
        AI_Schema_Cache__c initial = new AI_Schema_Cache__c(
            Name = 'SCHEMA_SUMMARY',
            Schema_Summary__c = 'old schema',
            Last_Refreshed__c = Datetime.now().addDays(-7),
            Object_Count__c = 1
        );
        insert initial;

        Test.startTest();
        SchemaRefreshJob.refreshNow();
        Test.stopTest();

        List<AI_Schema_Cache__c> after = [
            SELECT Schema_Summary__c, Last_Refreshed__c, Object_Count__c
            FROM AI_Schema_Cache__c
            WHERE Name = 'SCHEMA_SUMMARY'
        ];
        System.assertEquals(1, after.size(), 'Should still be one record');
        System.assertNotEquals('old schema', after[0].Schema_Summary__c, 'Schema should be updated');
        System.assert(after[0].Object_Count__c > 1, 'Should have more than 1 object');
    }

    @isTest
    static void testGetCachedSchema_ReturnsExisting() {
        // Pre-populate cache
        AI_Schema_Cache__c cache = new AI_Schema_Cache__c(
            Name = 'SCHEMA_SUMMARY',
            Schema_Summary__c = 'cached schema content here',
            Last_Refreshed__c = Datetime.now(),
            Object_Count__c = 5
        );
        insert cache;

        Test.startTest();
        String result = SchemaRefreshJob.getCachedSchema();
        Test.stopTest();

        System.assertEquals('cached schema content here', result, 'Should return cached content');
    }

    @isTest
    static void testGetCachedSchema_ComputesLiveWhenNoCache() {
        // No cache exists — should compute live without DML
        Test.startTest();
        String result = SchemaRefreshJob.getCachedSchema();
        Test.stopTest();

        System.assertNotEquals(null, result, 'Should return schema');
        System.assert(result.length() > 100, 'Should have substantial content');

        // Should NOT have created a cache record (no DML to avoid callout conflict)
        List<AI_Schema_Cache__c> stored = [
            SELECT Id FROM AI_Schema_Cache__c
            WHERE Name = 'SCHEMA_SUMMARY'
        ];
        System.assertEquals(0, stored.size(), 'Should not create cache during live compute');
    }

    @isTest
    static void testSchedulableExecution() {
        Test.startTest();
        SchemaRefreshJob job = new SchemaRefreshJob();
        job.execute(null);
        Test.stopTest();

        List<AI_Schema_Cache__c> cached = [
            SELECT Schema_Summary__c
            FROM AI_Schema_Cache__c
            WHERE Name = 'SCHEMA_SUMMARY'
        ];
        System.assertEquals(1, cached.size());
        System.assert(cached[0].Schema_Summary__c.length() > 50);
    }

    @isTest
    static void testScheduleMethod() {
        Test.startTest();
        SchemaRefreshJob.schedule();
        Test.stopTest();

        List<CronTrigger> jobs = [
            SELECT Id FROM CronTrigger
            WHERE CronJobDetail.Name = 'AI Schema Refresh'
        ];
        System.assertEquals(1, jobs.size(), 'Should have scheduled job');
    }

    @isTest
    static void testScheduleMethod_ReplacesExisting() {
        // Schedule twice — should not create duplicates
        Test.startTest();
        SchemaRefreshJob.schedule();
        SchemaRefreshJob.schedule();
        Test.stopTest();

        List<CronTrigger> jobs = [
            SELECT Id FROM CronTrigger
            WHERE CronJobDetail.Name = 'AI Schema Refresh'
        ];
        System.assertEquals(1, jobs.size(), 'Should have exactly one scheduled job');
    }
}
