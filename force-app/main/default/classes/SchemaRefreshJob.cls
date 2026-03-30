/**
 * SchemaRefreshJob
 * ─────────────────────────────────────────────────────────────────────────────
 * Schedulable + callable job that pre-computes the org schema summary
 * and stores it in AI_Schema_Cache__c.
 *
 * This eliminates ALL CPU cost at query time — the orchestrator simply
 * reads the cached text via 1 SOQL query.
 *
 * Schedule daily:
 *   SchemaRefreshJob.schedule();
 *
 * Or run immediately:
 *   SchemaRefreshJob.refreshNow();
 *
 * The job also runs automatically on first request if no cache exists.
 * ─────────────────────────────────────────────────────────────────────────────
 */
public with sharing class SchemaRefreshJob implements Schedulable {

    private static final String CACHE_KEY = 'SCHEMA_SUMMARY';

    // ── Schedulable entry point ─────────────────────────────────────────────

    public void execute(SchedulableContext ctx) {
        refreshNow();
    }

    // ── Schedule the job (daily at 2 AM) ────────────────────────────────────

    public static void schedule() {
        // Remove existing job if any
        List<CronTrigger> existing = [
            SELECT Id FROM CronTrigger
            WHERE CronJobDetail.Name = 'AI Schema Refresh'
            LIMIT 1
        ];
        for (CronTrigger ct : existing) {
            System.abortJob(ct.Id);
        }

        // Schedule daily at 2:00 AM
        System.schedule('AI Schema Refresh', '0 0 2 * * ?', new SchemaRefreshJob());
    }

    // ── Refresh now (callable from anywhere) ────────────────────────────────

    public static void refreshNow() {
        String summary = SchemaService.getCompactSchemaSummary();

        // Count objects in summary (count lines starting with "- ")
        Integer objectCount = 0;
        for (String line : summary.split('\n')) {
            if (line.startsWith('- ')) objectCount++;
        }

        // Upsert the cache record
        List<AI_Schema_Cache__c> existing = [
            SELECT Id FROM AI_Schema_Cache__c
            WHERE Name = :CACHE_KEY
            LIMIT 1
        ];

        AI_Schema_Cache__c cache;
        if (!existing.isEmpty()) {
            cache = existing[0];
        } else {
            cache = new AI_Schema_Cache__c(Name = CACHE_KEY);
        }

        cache.Schema_Summary__c = summary;
        cache.Last_Refreshed__c = Datetime.now();
        cache.Object_Count__c   = objectCount;

        upsert cache;
    }

    // ── Read cached schema (called by orchestrator) ─────────────────────────

    /**
     * Returns the cached schema summary. If no cache exists, computes it
     * live WITHOUT DML (to avoid "uncommitted work" errors before callouts).
     * The cache will be populated on the next scheduled run or manual refresh.
     *
     * @return Pre-computed schema summary string
     */
    public static String getCachedSchema() {
        List<AI_Schema_Cache__c> cached = [
            SELECT Schema_Summary__c, Last_Refreshed__c
            FROM AI_Schema_Cache__c
            WHERE Name = :CACHE_KEY
            LIMIT 1
        ];

        if (!cached.isEmpty() && String.isNotBlank(cached[0].Schema_Summary__c)) {
            return cached[0].Schema_Summary__c;
        }

        // No cache exists — compute live (no DML to avoid callout conflict)
        // Cache will be populated by scheduled job or manual SchemaRefreshJob.refreshNow()
        return SchemaService.getCompactSchemaSummary();
    }
}
