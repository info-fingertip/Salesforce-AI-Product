import { LightningElement } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import handleQuestion from '@salesforce/apex/AIAgentOrchestrator.handleQuestion';

const SUGGESTIONS = [
    'What does my pipeline look like this month?',
    'Show me top 10 accounts by annual revenue',
    'Any high-priority cases open right now?',
    'List leads that haven\'t been contacted yet',
    'Compare opportunity win rates by stage',
    'Show me contacts without email addresses'
];

export default class AiAssistantChat extends LightningElement {
    messages       = [];
    currentQuestion = '';
    isLoading       = false;
    statusText      = '';
    msgCounter      = 0;

    get isEmpty()         { return this.messages.length === 0 && !this.isLoading; }
    get isSendDisabled()  { return this.isLoading || !this.currentQuestion.trim(); }
    get showSuggestions() { return this.messages.length === 0 && !this.isLoading; }
    get suggestions()     { return SUGGESTIONS; }

    handleQuestionChange(e)  { this.currentQuestion = e.target.value; }
    handleClear()            { this.messages = []; this.currentQuestion = ''; }
    handleSuggestionClick(e) { this.currentQuestion = e.target.dataset.question; this.handleAsk(); }
    handleKeyDown(e)         { if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') { e.preventDefault(); if (!this.isSendDisabled) this.handleAsk(); } }

    async handleAsk() {
        const question = this.currentQuestion.trim();
        if (!question || this.isLoading) return;

        this.pushUserMsg(question);
        this.currentQuestion = '';
        this.isLoading = true;
        this.statusText = 'Analysing your question...';
        this.scrollBottom();

        try {
            // Build conversation history for follow-up context
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

    // ── Build conversation JSON for the orchestrator ──
    buildConversationJson() {
        const history = [];
        for (const msg of this.messages) {
            if (msg.isUser) {
                history.push({ role: 'user', content: msg.text });
            } else if (!msg.isError) {
                // Trim AI responses to keep context manageable
                const content = msg.rawText.length > 1500
                    ? msg.rawText.substring(0, 1500) + '...'
                    : msg.rawText;
                history.push({ role: 'assistant', content });
            }
        }
        return history.length > 0 ? JSON.stringify(history) : null;
    }

    pushUserMsg(text) {
        this.messages = [...this.messages, {
            id: ++this.msgCounter, isUser: true, isError: false, text,
            timestamp: this.now(), wrapperClass: 'msg-row msg-row_user',
            blocks: [], rawText: text
        }];
    }

    pushErrorMsg(text) {
        this.messages = [...this.messages, {
            id: ++this.msgCounter, isUser: false, isError: true, text,
            timestamp: this.now(), wrapperClass: 'msg-row msg-row_ai',
            blocks: [], rawText: text
        }];
    }

    pushAIMsg(result) {
        const raw = result.answer || '';
        const blocks = this.parseBlocks(raw);
        const chart = this.extractChart(blocks);

        this.messages = [...this.messages, {
            id          : ++this.msgCounter,
            isUser      : false,
            isError     : false,
            text        : raw,
            rawText     : raw,
            queriedObjects: result.queriedObjects,
            totalRecords  : result.totalRecords,
            modelUsed     : result.modelUsed,
            timestamp   : this.now(),
            wrapperClass: 'msg-row msg-row_ai',
            blocks,
            chartBars   : chart.bars,
            chartTitle  : chart.title,
            hasChart    : chart.bars.length > 1
        }];
    }

    // ── Markdown block parser ──
    parseBlocks(raw) {
        const lines  = raw.split('\n');
        const blocks = [];
        let tableLines = [];
        let codeLines = [];
        let inCode = false;
        let codeLang = '';
        let blockId = 0;

        const flushTable = () => {
            if (tableLines.length < 2) { tableLines = []; return; }
            const split  = l => l.split('|').map(c => c.trim()).filter(c => c !== '');
            const isSep  = l => /^[\|\-\:\s]+$/.test(l);
            const headers = split(tableLines[0]);
            const rows    = tableLines.slice(1)
                .filter(l => !isSep(l))
                .map((l, i) => ({ id: i, cells: split(l).map((v, j) => ({ key: i+'_'+j, value: v })) }))
                .filter(r => r.cells.length > 0);
            if (headers.length && rows.length) {
                blocks.push({ id: ++blockId, type: 'table', isTable: true, headers, rows });
            }
            tableLines = [];
        };

        const flushCode = () => {
            if (codeLines.length > 0) {
                blocks.push({ id: ++blockId, type: 'code', isCode: true, text: codeLines.join('\n'), language: codeLang });
            }
            codeLines = [];
            codeLang = '';
        };

        for (let i = 0; i < lines.length; i++) {
            const line = lines[i];
            const t    = line.trim();

            // Code fence toggle
            if (t.startsWith('```')) {
                if (inCode) {
                    flushCode();
                    inCode = false;
                } else {
                    if (tableLines.length) flushTable();
                    inCode = true;
                    codeLang = t.replace(/^```/, '').trim();
                }
                continue;
            }

            // Inside code block
            if (inCode) { codeLines.push(line); continue; }

            // Table lines
            if (t.startsWith('|')) { tableLines.push(t); continue; }
            if (tableLines.length) flushTable();

            if (!t) continue;

            // Headings
            if (t.startsWith('### ')) { blocks.push({ id:++blockId, type:'h3',  isH3:true,      text: this.md(t.replace(/^###\s*/,'')) }); continue; }
            if (t.startsWith('## '))  { blocks.push({ id:++blockId, type:'h2',  isH2:true,      text: this.md(t.replace(/^##\s*/,''))  }); continue; }
            if (t.startsWith('# '))   { blocks.push({ id:++blockId, type:'h1',  isH1:true,      text: this.md(t.replace(/^#\s*/,''))   }); continue; }
            if (t.startsWith('> '))   { blocks.push({ id:++blockId, type:'quote', isQuote:true, text: this.md(t.replace(/^>\s*/,''))   }); continue; }
            if (/^[-*•]\s/.test(t))   { blocks.push({ id:++blockId, type:'bullet', isBullet:true, text: this.md(t.replace(/^[-*•]\s*/,'')) }); continue; }
            if (/^\d+\.\s/.test(t))   { blocks.push({ id:++blockId, type:'numbered', isNumbered:true, text: this.md(t.replace(/^\d+\.\s*/,'')), num: (blocks.filter(b=>b.type==='numbered').length+1) }); continue; }
            if (t === '---' || t === '***') { blocks.push({ id:++blockId, type:'hr', isHr:true }); continue; }
            blocks.push({ id:++blockId, type:'para', isPara:true, text: this.md(t) });
        }
        if (inCode) flushCode();
        if (tableLines.length) flushTable();
        return blocks;
    }

    // ── Inline markdown formatting ──
    md(text) {
        return (text || '')
            .replace(/\*\*\*(.+?)\*\*\*/g, '$1')
            .replace(/\*\*(.+?)\*\*/g,   '$1')
            .replace(/\*(.+?)\*/g,         '$1')
            .replace(/__(.+?)__/g,           '$1')
            .replace(/_(.+?)_/g,             '$1')
            .replace(/`(.+?)`/g,             '$1')
            .replace(/~~(.+?)~~/g,           '$1');
    }

    // ── Extract chart from first table with numeric data ──
    extractChart(blocks) {
        const tableBlock = blocks.find(b => b.type === 'table');
        if (!tableBlock || tableBlock.rows.length < 2) return { bars: [], title: '' };

        const { headers, rows } = tableBlock;
        let numCol = -1;
        for (let i = 1; i < headers.length; i++) {
            if (rows.some(r => r.cells[i] && !isNaN(parseFloat((r.cells[i].value||'').replace(/[$,%\s,]/g,''))))) {
                numCol = i; break;
            }
        }
        if (numCol === -1) return { bars: [], title: '' };

        const palette = ['#0070d2','#1589ee','#22bbd6','#f4a500','#3bba4c','#e8457a','#16325c'];
        const bars = rows.map(r => {
            const rawVal = r.cells[numCol] ? r.cells[numCol].value : '0';
            const num    = parseFloat(rawVal.replace(/[$,%\s,]/g,'')) || 0;
            const label  = r.cells[0] ? r.cells[0].value : '';
            return { label, num, displayValue: rawVal };
        }).filter(b => b.label && b.num > 0);

        const max = Math.max(...bars.map(b => b.num), 1);
        return {
            title: headers[0] + ' vs ' + headers[numCol],
            bars : bars.map((b, i) => ({
                label       : b.label.length > 22 ? b.label.substring(0,22)+'…' : b.label,
                displayValue: b.displayValue,
                pct         : Math.max(4, Math.round((b.num/max)*100)),
                color       : palette[i % palette.length],
                style       : 'width:'+Math.max(4,Math.round((b.num/max)*100))+'%;background:'+palette[i%palette.length]
            }))
        };
    }

    // ── Download response ──
    handleDownload(e) {
        const msgId = parseInt(e.currentTarget.dataset.msgid, 10);
        const msg   = this.messages.find(m => m.id === msgId);
        if (!msg) return;
        const blob = new Blob([msg.rawText], { type: 'text/plain' });
        const url  = URL.createObjectURL(blob);
        const a    = document.createElement('a');
        a.href     = url;
        a.download = (msg.queriedObjects || 'AI') + '_response_' + this.now().replace(':','') + '.txt';
        a.click();
        URL.revokeObjectURL(url);
    }

    scrollBottom() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => { const w = this.template.querySelector('.chat-win'); if (w) w.scrollTop = w.scrollHeight; }, 120);
    }
    now() { return new Date().toLocaleTimeString([], { hour:'2-digit', minute:'2-digit' }); }
    extractError(e) {
        if (typeof e === 'string') return e;
        if (e && e.body && e.body.message) return e.body.message;
        if (e && e.message) return e.message;
        return 'An unexpected error occurred.';
    }
    showToast(title, message, variant) { this.dispatchEvent(new ShowToastEvent({ title, message, variant })); }
}
