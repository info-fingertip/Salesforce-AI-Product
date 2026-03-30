/**
 * ConversationMemory
 * ─────────────────────────────────────────────────────────────────────────────
 * Phase 5 — Multi-turn conversation context management
 *
 * Manages conversation history for the AI Agent so users can ask
 * follow-up questions naturally:
 *   - "Now filter that by Closed Won"
 *   - "Show me just the top 5"
 *   - "What about leads instead?"
 *
 * History is maintained client-side (in the LWC) and passed to the
 * orchestrator as JSON. This class provides server-side utilities for
 * formatting, trimming, and token-budgeting the conversation context.
 * ─────────────────────────────────────────────────────────────────────────────
 */
public with sharing class ConversationMemory {

    private static final Integer MAX_MESSAGES     = 10;  // 5 turns (user + ai)
    private static final Integer MAX_MSG_CHARS    = 2000; // per message
    private static final Integer MAX_TOTAL_CHARS  = 8000; // entire context

    // ── Message wrapper ─────────────────────────────────────────────────────

    public class ConversationMessage {
        @AuraEnabled public String role    { get; set; } // 'user' or 'assistant'
        @AuraEnabled public String content { get; set; }
    }

    // ── Build conversation context for AI prompts ───────────────────────────

    /**
     * Takes raw conversation JSON from the LWC, trims it for token budget,
     * and returns a list of messages ready for AI prompt injection.
     *
     * @param conversationJson JSON array: [{"role":"user","content":"..."},{"role":"assistant","content":"..."}]
     * @return List of trimmed ConversationMessages
     */
    public static List<ConversationMessage> buildContext(String conversationJson) {
        List<ConversationMessage> result = new List<ConversationMessage>();
        if (String.isBlank(conversationJson)) return result;

        try {
            List<Object> raw = (List<Object>) JSON.deserializeUntyped(conversationJson);
            Integer totalChars = 0;

            // Take from the end (most recent messages are most relevant)
            Integer startIdx = Math.max(0, raw.size() - MAX_MESSAGES);

            for (Integer i = startIdx; i < raw.size(); i++) {
                Map<String, Object> msg = (Map<String, Object>) raw[i];
                String role = String.valueOf(msg.get('role'));
                String content = String.valueOf(msg.get('content'));

                // Validate role
                if (role != 'user' && role != 'assistant') continue;

                // Trim individual message
                if (content.length() > MAX_MSG_CHARS) {
                    content = content.substring(0, MAX_MSG_CHARS) + '... (trimmed)';
                }

                // Check total budget
                if (totalChars + content.length() > MAX_TOTAL_CHARS) {
                    // Truncate this message to fit
                    Integer remaining = MAX_TOTAL_CHARS - totalChars;
                    if (remaining > 200) {
                        content = content.substring(0, remaining) + '... (trimmed)';
                    } else {
                        break; // No room left
                    }
                }

                ConversationMessage cm = new ConversationMessage();
                cm.role = role;
                cm.content = content;
                result.add(cm);
                totalChars += content.length();
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'ConversationMemory.buildContext failed: ' + e.getMessage());
        }

        return result;
    }

    // ── Format for AI messages array ────────────────────────────────────────

    /**
     * Converts conversation messages into the format needed for AI API calls.
     *
     * @param messages List of ConversationMessage
     * @return List of Maps with 'role' and 'content' keys
     */
    public static List<Map<String, String>> toAIMessages(List<ConversationMessage> messages) {
        List<Map<String, String>> result = new List<Map<String, String>>();
        for (ConversationMessage cm : messages) {
            result.add(new Map<String, String>{
                'role' => cm.role,
                'content' => cm.content
            });
        }
        return result;
    }

    // ── Summarize conversation for context ──────────────────────────────────

    /**
     * Creates a brief summary of the conversation for injection into prompts
     * where the full history is too expensive.
     *
     * @param conversationJson JSON array of messages
     * @return A compact string summary
     */
    public static String summarize(String conversationJson) {
        List<ConversationMessage> messages = buildContext(conversationJson);
        if (messages.isEmpty()) return '';

        List<String> parts = new List<String>();
        parts.add('CONVERSATION CONTEXT (previous ' + messages.size() + ' messages):');

        for (ConversationMessage cm : messages) {
            String prefix = cm.role == 'user' ? 'User' : 'AI';
            String snippet = cm.content;
            if (snippet.length() > 150) snippet = snippet.substring(0, 150) + '...';
            parts.add(prefix + ': ' + snippet);
        }

        return String.join(parts, '\n');
    }
}
