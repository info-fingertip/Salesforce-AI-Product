/**
 * markdownParser.js
 * ─────────────────────────────────────────────────────────────────────────────
 * Phase 6 — Full Markdown-to-HTML converter
 *
 * Converts AI markdown responses to safe HTML. Supports:
 *   - Headings (h1-h6)
 *   - Bold, italic, bold+italic, strikethrough
 *   - Inline code and fenced code blocks with language hints
 *   - Blockquotes (single and multi-line)
 *   - Unordered lists (-, *, •) with nesting
 *   - Ordered lists (1. 2. 3.)
 *   - Tables with headers
 *   - Horizontal rules
 *   - Links and images
 *   - Line breaks
 *   - Emojis (passed through as-is)
 *
 * No external dependencies — pure ES module.
 * ─────────────────────────────────────────────────────────────────────────────
 */

// ── Inline formatting ───────────────────────────────────────────────────

function escapeHtml(text) {
    return text
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
}

function parseInline(text) {
    if (!text) return '';
    let s = escapeHtml(text);

    // Images: ![alt](url)
    s = s.replace(/!\[([^\]]*)\]\(([^)]+)\)/g, '<img src="$2" alt="$1" class="md-img"/>');
    // Links: [text](url)
    s = s.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" target="_blank" rel="noopener" class="md-link">$1</a>');
    // Bold+italic: ***text*** or ___text___
    s = s.replace(/\*\*\*(.+?)\*\*\*/g, '<strong><em>$1</em></strong>');
    s = s.replace(/___(.+?)___/g, '<strong><em>$1</em></strong>');
    // Bold: **text** or __text__
    s = s.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');
    s = s.replace(/__(.+?)__/g, '<strong>$1</strong>');
    // Italic: *text* or _text_ (but not inside words for _)
    s = s.replace(/\*(.+?)\*/g, '<em>$1</em>');
    s = s.replace(/(?<!\w)_(.+?)_(?!\w)/g, '<em>$1</em>');
    // Strikethrough: ~~text~~
    s = s.replace(/~~(.+?)~~/g, '<del>$1</del>');
    // Inline code: `text`
    s = s.replace(/`([^`]+)`/g, '<code class="md-inline-code">$1</code>');

    return s;
}

// ── Table parser ────────────────────────────────────────────────────────

function parseTable(lines) {
    if (lines.length < 2) return '';

    const splitRow = l => l.split('|').map(c => c.trim()).filter(c => c !== '');
    const isSep = l => /^[\|\-\:\s]+$/.test(l);

    const headers = splitRow(lines[0]);
    const dataRows = lines.slice(1).filter(l => !isSep(l));

    if (!headers.length || !dataRows.length) return '';

    let html = '<div class="md-tbl-wrap"><div class="md-tbl-scroll"><table class="md-tbl">';
    html += '<thead><tr>';
    for (const h of headers) {
        html += '<th>' + parseInline(h) + '</th>';
    }
    html += '</tr></thead><tbody>';
    for (const row of dataRows) {
        const cells = splitRow(row);
        if (cells.length === 0) continue;
        html += '<tr>';
        for (let i = 0; i < headers.length; i++) {
            html += '<td>' + parseInline(cells[i] || '') + '</td>';
        }
        html += '</tr>';
    }
    html += '</tbody></table></div></div>';
    return html;
}

// ── Main parser ─────────────────────────────────────────────────────────

export function markdownToHtml(raw) {
    if (!raw) return '';

    const lines = raw.split('\n');
    const parts = [];

    let tableLines = [];
    let codeLines = [];
    let inCode = false;
    let codeLang = '';
    let listItems = [];
    let listType = ''; // 'ul' or 'ol'

    const flushTable = () => {
        if (tableLines.length >= 2) {
            parts.push(parseTable(tableLines));
        }
        tableLines = [];
    };

    const flushCode = () => {
        if (codeLines.length > 0) {
            const langClass = codeLang ? ' data-lang="' + escapeHtml(codeLang) + '"' : '';
            const langLabel = codeLang
                ? '<span class="md-code-lang">' + escapeHtml(codeLang) + '</span>'
                : '';
            parts.push(
                '<div class="md-code-block"' + langClass + '>' +
                langLabel +
                '<pre><code>' + escapeHtml(codeLines.join('\n')) + '</code></pre></div>'
            );
        }
        codeLines = [];
        codeLang = '';
    };

    const flushList = () => {
        if (listItems.length === 0) return;
        const tag = listType === 'ol' ? 'ol' : 'ul';
        parts.push('<' + tag + ' class="md-list">' + listItems.join('') + '</' + tag + '>');
        listItems = [];
        listType = '';
    };

    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        const t = line.trim();

        // ── Code fence toggle ──
        if (t.startsWith('```')) {
            if (inCode) {
                flushCode();
                inCode = false;
            } else {
                if (tableLines.length) flushTable();
                if (listItems.length) flushList();
                inCode = true;
                codeLang = t.replace(/^```/, '').trim();
            }
            continue;
        }
        if (inCode) { codeLines.push(line); continue; }

        // ── Table lines ──
        if (t.startsWith('|')) {
            if (listItems.length) flushList();
            tableLines.push(t);
            continue;
        }
        if (tableLines.length) flushTable();

        // ── Blank line ──
        if (!t) {
            if (listItems.length) flushList();
            continue;
        }

        // ── Headings ──
        const headingMatch = t.match(/^(#{1,6})\s+(.+)$/);
        if (headingMatch) {
            if (listItems.length) flushList();
            const level = headingMatch[1].length;
            const tag = 'h' + level;
            parts.push('<' + tag + ' class="md-' + tag + '">' + parseInline(headingMatch[2]) + '</' + tag + '>');
            continue;
        }

        // ── Horizontal rule ──
        if (/^(---+|\*\*\*+|___+)$/.test(t)) {
            if (listItems.length) flushList();
            parts.push('<hr class="md-hr"/>');
            continue;
        }

        // ── Blockquote ──
        if (t.startsWith('> ')) {
            if (listItems.length) flushList();
            // Collect consecutive blockquote lines
            let quoteText = t.replace(/^>\s*/, '');
            while (i + 1 < lines.length && lines[i + 1].trim().startsWith('> ')) {
                i++;
                quoteText += '<br/>' + lines[i].trim().replace(/^>\s*/, '');
            }
            parts.push('<blockquote class="md-quote">' + parseInline(quoteText) + '</blockquote>');
            continue;
        }

        // ── Unordered list ──
        if (/^[-*•]\s/.test(t)) {
            if (listType === 'ol') flushList();
            listType = 'ul';
            listItems.push('<li>' + parseInline(t.replace(/^[-*•]\s*/, '')) + '</li>');
            continue;
        }

        // ── Ordered list ──
        if (/^\d+\.\s/.test(t)) {
            if (listType === 'ul') flushList();
            listType = 'ol';
            listItems.push('<li>' + parseInline(t.replace(/^\d+\.\s*/, '')) + '</li>');
            continue;
        }

        // ── Paragraph ──
        if (listItems.length) flushList();
        parts.push('<p class="md-para">' + parseInline(t) + '</p>');
    }

    // Flush any remaining
    if (inCode) flushCode();
    if (tableLines.length) flushTable();
    if (listItems.length) flushList();

    return parts.join('\n');
}

// ── Extract table data for chart generation ─────────────────────────────

export function extractChartData(raw) {
    if (!raw) return { bars: [], title: '' };

    const lines = raw.split('\n');
    let tableLines = [];
    let inCode = false;

    // Find first table
    for (const line of lines) {
        const t = line.trim();
        if (t.startsWith('```')) { inCode = !inCode; continue; }
        if (inCode) continue;
        if (t.startsWith('|')) { tableLines.push(t); continue; }
        if (tableLines.length >= 3) break; // found a complete table
        if (tableLines.length > 0 && !t.startsWith('|')) {
            if (tableLines.length >= 3) break;
            tableLines = []; // incomplete table, reset
        }
    }

    if (tableLines.length < 3) return { bars: [], title: '' };

    const splitRow = l => l.split('|').map(c => c.trim()).filter(c => c !== '');
    const isSep = l => /^[\|\-\:\s]+$/.test(l);

    const headers = splitRow(tableLines[0]);
    const dataRows = tableLines.slice(1).filter(l => !isSep(l)).map(l => splitRow(l));

    if (headers.length < 2 || dataRows.length < 2) return { bars: [], title: '' };

    // Find first numeric column
    let numCol = -1;
    for (let i = 1; i < headers.length; i++) {
        if (dataRows.some(r => r[i] && !isNaN(parseFloat((r[i] || '').replace(/[$,%\s,]/g, ''))))) {
            numCol = i;
            break;
        }
    }
    if (numCol === -1) return { bars: [], title: '' };

    const palette = ['#0070d2','#1589ee','#22bbd6','#f4a500','#3bba4c','#e8457a','#16325c','#9b59b6','#e67e22','#1abc9c'];
    const bars = dataRows.map(r => {
        const rawVal = r[numCol] || '0';
        const num = parseFloat(rawVal.replace(/[$,%\s,]/g, '')) || 0;
        const label = r[0] || '';
        return { label, num, displayValue: rawVal };
    }).filter(b => b.label && b.num > 0);

    if (bars.length < 2) return { bars: [], title: '' };

    const max = Math.max(...bars.map(b => b.num), 1);
    return {
        title: headers[0] + ' vs ' + headers[numCol],
        bars: bars.map((b, i) => ({
            label: b.label.length > 22 ? b.label.substring(0, 22) + '\u2026' : b.label,
            displayValue: b.displayValue,
            pct: Math.max(4, Math.round((b.num / max) * 100)),
            color: palette[i % palette.length],
            style: 'width:' + Math.max(4, Math.round((b.num / max) * 100)) + '%;background:' + palette[i % palette.length]
        }))
    };
}
