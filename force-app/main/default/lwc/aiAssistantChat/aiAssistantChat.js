import { LightningElement, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import askAI from '@salesforce/apex/AIAssistantController.askAI';
import getAvailableObjects from '@salesforce/apex/AIAssistantController.getAvailableObjects';

const SUGGESTIONS = {
    Opportunity : ['List all open opportunities with stage and amount','What is the total pipeline value by stage?','Which deals close this month?','Top 5 deals by value'],
    Lead        : ['List all leads with name, company and status','Which leads have not been contacted?','Leads breakdown by source','Show lead conversion summary'],
    Account     : ['List all accounts with industry and annual revenue','Top accounts by annual revenue','Accounts breakdown by industry','Show all account details'],
    Case        : ['List all open cases with subject and priority','Cases by priority and status','Which cases have been open longest?','Case volume summary'],
    Contact     : ['List all contacts with email and phone','Contacts missing email or phone','Show contacts by account','Recently created contacts']
};
const DEFAULT_SUGGESTIONS = ['List all records with full details','Show me a breakdown by category','What are the key trends?','Give me a complete summary'];

export default class AiAssistantChat extends LightningElement {
    @track messages       = [];
    @track objectOptions  = [];
    @track selectedObject  = '';
    @track currentQuestion = '';
    @track filterClause    = '';
    @track isLoading       = false;
    msgCounter = 0;

    @wire(getAvailableObjects)
    wiredObjects({ error, data }) {
        if (data) {
            this.objectOptions = data.map(o => ({ label: o.label + ' (' + o.apiName + ')', value: o.apiName }));
        } else if (error) {
            this.showToast('Error', this.extractError(error), 'error');
        }
    }

    get isEmpty()         { return this.messages.length === 0 && !this.isLoading; }
    get isSendDisabled()  { return this.isLoading || !this.selectedObject || !this.currentQuestion.trim(); }
    get showSuggestions() { return !!this.selectedObject && this.messages.length === 0; }
    get suggestions()     { return SUGGESTIONS[this.selectedObject] || DEFAULT_SUGGESTIONS; }

    handleObjectChange(e)    { this.selectedObject   = e.detail.value; }
    handleFilterChange(e)    { this.filterClause     = e.target.value; }
    handleQuestionChange(e)  { this.currentQuestion  = e.target.value; }
    handleClear()            { this.messages = []; this.currentQuestion = ''; this.filterClause = ''; }
    handleSuggestionClick(e) { this.currentQuestion  = e.target.dataset.question; this.handleAsk(); }
    handleKeyDown(e)         { if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') { e.preventDefault(); if (!this.isSendDisabled) this.handleAsk(); } }

    async handleAsk() {
        const question = this.currentQuestion.trim();
        if (!question || !this.selectedObject || this.isLoading) return;
        this.pushUserMsg(question);
        this.currentQuestion = '';
        this.isLoading = true;
        this.scrollBottom();
        try {
            const result = await askAI({ objectApiName: this.selectedObject, userQuestion: question, filters: this.filterClause.trim() || null });
            if (result.isSuccess) { this.pushAIMsg(result); }
            else                  { this.pushErrorMsg(result.errorMessage || 'An error occurred.'); }
        } catch (err) {
            this.pushErrorMsg(this.extractError(err));
        } finally {
            this.isLoading = false;
            this.scrollBottom();
        }
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
        const raw        = result.answer || '';
        // remove the SHOW_CHART signal from displayed text
        const showChart  = raw.includes('SHOW_CHART');
        const cleanRaw   = raw.replace(/SHOW_CHART/g, '').trim();
        const blocks     = this.parseBlocks(cleanRaw);
        const chart      = showChart ? this.extractChart(blocks) : { bars: [], title: '' };

        this.messages = [...this.messages, {
            id          : ++this.msgCounter,
            isUser      : false,
            isError     : false,
            text        : cleanRaw,
            rawText     : cleanRaw,
            objectName  : result.objectName,
            recordCount : result.recordCount,
            timestamp   : this.now(),
            wrapperClass: 'msg-row msg-row_ai',
            blocks,
            chartBars   : chart.bars,
            chartTitle  : chart.title,
            hasChart    : showChart && chart.bars.length > 1
        }];
    }

    // ── Dynamic block parser — reads markdown line by line ──
    parseBlocks(raw) {
        const lines  = raw.split('\n');
        const blocks = [];
        let tableLines = [];
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
                blocks.push({ id: ++blockId, type: 'table', isTable:true, headers, rows });
            }
            tableLines = [];
        };

        for (let i = 0; i < lines.length; i++) {
            const line = lines[i];
            const t    = line.trim();

            // collect table lines
            if (t.startsWith('|')) { tableLines.push(t); continue; }

            // flush any pending table before processing next block
            if (tableLines.length) flushTable();

            if (!t) continue; // skip blanks

            // heading
            if (t.startsWith('### ')) { blocks.push({ id:++blockId, type:'h3',  isH3:true,      text: this.md(t.replace(/^###\s*/,'')) }); continue; }
            if (t.startsWith('## '))  { blocks.push({ id:++blockId, type:'h2',  isH2:true,      text: this.md(t.replace(/^##\s*/,''))  }); continue; }
            if (t.startsWith('# '))   { blocks.push({ id:++blockId, type:'h1',  isH1:true,      text: this.md(t.replace(/^#\s*/,''))   }); continue; }
            if (t.startsWith('> '))   { blocks.push({ id:++blockId, type:'quote', isQuote:true, text: this.md(t.replace(/^>\s*/,''))   }); continue; }
            if (/^[-*•]\s/.test(t))   { blocks.push({ id:++blockId, type:'bullet', isBullet:true, text: this.md(t.replace(/^[-*•]\s*/,'')) }); continue; }
            if (/^\d+\.\s/.test(t))   { blocks.push({ id:++blockId, type:'numbered', isNumbered:true, text: this.md(t.replace(/^\d+\.\s*/,'')), num: (blocks.filter(b=>b.type==='numbered').length+1) }); continue; }
            blocks.push({ id:++blockId, type:'para', isPara:true, text: this.md(t) });
        }
        if (tableLines.length) flushTable();
        return blocks;
    }

    // ── Strip markdown formatting to plain text, keep emojis ──
    md(text) {
        return (text || '')
            .replace(/\*\*\*(.+?)\*\*\*/g, '$1')   // bold+italic
            .replace(/\*\*(.+?)\*\*/g,   '$1')       // bold
            .replace(/\*(.+?)\*/g,         '$1')       // italic
            .replace(/__(.+?)__/g,           '$1')       // alt bold
            .replace(/_(.+?)_/g,             '$1')       // alt italic
            .replace(/`(.+?)`/g,             '$1')       // inline code
            .replace(/~~(.+?)~~/g,           '$1');      // strikethrough
    }

    // ── Extract chart from first table that has numeric data ──
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

    // ── Download response as .txt ──
    handleDownload(e) {
        const msgId = parseInt(e.currentTarget.dataset.msgid, 10);
        const msg   = this.messages.find(m => m.id === msgId);
        if (!msg) return;
        const blob = new Blob([msg.rawText], { type: 'text/plain' });
        const url  = URL.createObjectURL(blob);
        const a    = document.createElement('a');
        a.href     = url;
        a.download = (msg.objectName || 'AI') + '_response_' + this.now().replace(':','') + '.txt';
        a.click();
        URL.revokeObjectURL(url);
    }

    scrollBottom() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => { const w = this.template.querySelector('.chat-window'); if (w) w.scrollTop = w.scrollHeight; }, 120);
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