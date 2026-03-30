import { LightningElement } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import handleQuestion from '@salesforce/apex/AIAgentOrchestrator.handleQuestion';
import { markdownToHtml, extractChartData } from './markdownParser';
import { sanitizeHtml } from './htmlSanitizer';

const SUGGESTIONS = [
    'What does my pipeline look like this month?',
    'Show me top 10 accounts by annual revenue',
    'Any high-priority cases open right now?',
    'List leads that haven\'t been contacted yet',
    'Compare opportunity win rates by stage',
    'Show me contacts without email addresses'
];

export default class AiAssistantChat extends LightningElement {
    messages        = [];
    currentQuestion = '';
    isLoading       = false;
    statusText      = '';
    msgCounter      = 0;
    _pendingRender  = new Set(); // msg IDs needing HTML injection

    get isEmpty()         { return this.messages.length === 0 && !this.isLoading; }
    get isSendDisabled()  { return this.isLoading || !this.currentQuestion.trim(); }
    get showSuggestions() { return this.messages.length === 0 && !this.isLoading; }
    get suggestions()     { return SUGGESTIONS; }

    handleQuestionChange(e)  { this.currentQuestion = e.target.value; }
    handleClear()            { this.messages = []; this.currentQuestion = ''; this._pendingRender.clear(); }
    handleSuggestionClick(e) { this.currentQuestion = e.target.dataset.question; this.handleAsk(); }
    handleKeyDown(e)         { if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') { e.preventDefault(); if (!this.isSendDisabled) this.handleAsk(); } }

    // ── Main ask handler ────────────────────────────────────────────────

    async handleAsk() {
        const question = this.currentQuestion.trim();
        if (!question || this.isLoading) return;

        this.pushUserMsg(question);
        this.currentQuestion = '';
        this.isLoading = true;
        this.statusText = 'Analysing your question...';
        this.scrollBottom();

        try {
            const conversationJson = this.buildConversationJson();

            this.statusText = 'Querying your Salesforce data...';
            const result = await handleQuestion({
                userQuestion: question,
                conversationJson: conversationJson
            });

            if (result.isSuccess) {
                this.pushAIMsg(result);
            } else {
                this.pushErrorMsg(result.errorMessage || 'An error occurred.');
            }
        } catch (err) {
            this.pushErrorMsg(this.extractError(err));
        } finally {
            this.isLoading = false;
            this.statusText = '';
            this.scrollBottom();
        }
    }

    // ── Conversation context for follow-ups ─────────────────────────────

    buildConversationJson() {
        const history = [];
        for (const msg of this.messages) {
            if (msg.isUser) {
                history.push({ role: 'user', content: msg.text });
            } else if (!msg.isError) {
                const content = msg.rawText.length > 1500
                    ? msg.rawText.substring(0, 1500) + '...'
                    : msg.rawText;
                history.push({ role: 'assistant', content });
            }
        }
        return history.length > 0 ? JSON.stringify(history) : null;
    }

    // ── Message pushers ─────────────────────────────────────────────────

    pushUserMsg(text) {
        this.messages = [...this.messages, {
            id: ++this.msgCounter, isUser: true, isError: false, text,
            timestamp: this.now(), wrapperClass: 'msg-row msg-row_user',
            rawText: text
        }];
    }

    pushErrorMsg(text) {
        this.messages = [...this.messages, {
            id: ++this.msgCounter, isUser: false, isError: true, text,
            timestamp: this.now(), wrapperClass: 'msg-row msg-row_ai',
            rawText: text
        }];
    }

    pushAIMsg(result) {
        const raw = result.answer || '';

        // Parse chart data from raw markdown (before HTML conversion)
        const chart = extractChartData(raw);

        // Convert markdown → HTML → sanitize
        const htmlContent = sanitizeHtml(markdownToHtml(raw));

        const msgId = ++this.msgCounter;
        this._pendingRender.add(msgId);

        this.messages = [...this.messages, {
            id            : msgId,
            isUser        : false,
            isError       : false,
            text          : raw,
            rawText       : raw,
            htmlContent   : htmlContent,
            queriedObjects: result.queriedObjects,
            totalRecords  : result.totalRecords,
            modelUsed     : result.modelUsed,
            timestamp     : this.now(),
            wrapperClass  : 'msg-row msg-row_ai',
            chartBars     : chart.bars,
            chartTitle    : chart.title,
            hasChart      : chart.bars.length > 1
        }];
    }

    // ── Render HTML into lwc:dom="manual" containers ─────────────────────

    renderedCallback() {
        if (this._pendingRender.size === 0) return;

        for (const msgId of this._pendingRender) {
            const container = this.template.querySelector(`[data-content-id="${msgId}"]`);
            const msg = this.messages.find(m => m.id === msgId);

            if (container && msg && msg.htmlContent) {
                // eslint-disable-next-line @lwc/lwc/no-inner-html
                container.innerHTML = msg.htmlContent;
            }
        }
        this._pendingRender.clear();
        this.scrollBottom();
    }

    // ── Download response ───────────────────────────────────────────────

    handleDownload(e) {
        const msgId = parseInt(e.currentTarget.dataset.msgid, 10);
        const msg   = this.messages.find(m => m.id === msgId);
        if (!msg) return;
        const blob = new Blob([msg.rawText], { type: 'text/plain' });
        const url  = URL.createObjectURL(blob);
        const a    = document.createElement('a');
        a.href     = url;
        a.download = (msg.queriedObjects || 'AI') + '_response_' + this.now().replace(':', '') + '.txt';
        a.click();
        URL.revokeObjectURL(url);
    }

    // ── Utilities ───────────────────────────────────────────────────────

    scrollBottom() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            const w = this.template.querySelector('.chat-win');
            if (w) w.scrollTop = w.scrollHeight;
        }, 150);
    }

    now() {
        return new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    }

    extractError(e) {
        if (typeof e === 'string') return e;
        if (e && e.body && e.body.message) return e.body.message;
        if (e && e.message) return e.message;
        return 'An unexpected error occurred.';
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
