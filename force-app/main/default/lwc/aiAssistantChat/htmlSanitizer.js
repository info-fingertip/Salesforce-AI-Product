/**
 * htmlSanitizer.js
 * ─────────────────────────────────────────────────────────────────────────────
 * Phase 6 — Whitelist-based HTML sanitizer for XSS prevention
 *
 * Strips any tags, attributes, or protocols not in the whitelist.
 * Designed for use with lwc:dom="manual" innerHTML injection.
 *
 * Since we control the markdown→HTML conversion (markdownParser.js),
 * the risk is low, but this provides defense-in-depth against:
 *   - AI responses containing raw HTML
 *   - Injection via markdown edge cases
 *   - Unexpected content from external AI services
 * ─────────────────────────────────────────────────────────────────────────────
 */

const ALLOWED_TAGS = new Set([
    'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
    'p', 'br', 'hr',
    'strong', 'b', 'em', 'i', 'del', 's',
    'ul', 'ol', 'li',
    'blockquote',
    'pre', 'code',
    'table', 'thead', 'tbody', 'tr', 'th', 'td',
    'a', 'img',
    'span', 'div',
    'sup', 'sub'
]);

const ALLOWED_ATTRS = {
    'a':    new Set(['href', 'target', 'rel', 'class']),
    'img':  new Set(['src', 'alt', 'class', 'width', 'height']),
    'code': new Set(['class']),
    'pre':  new Set(['class']),
    'div':  new Set(['class', 'data-lang']),
    'span': new Set(['class']),
    'td':   new Set(['class', 'colspan', 'rowspan']),
    'th':   new Set(['class', 'colspan', 'rowspan']),
    'table': new Set(['class']),
    'thead': new Set(['class']),
    'tbody': new Set(['class']),
    'tr':   new Set(['class']),
    'ul':   new Set(['class']),
    'ol':   new Set(['class']),
    'li':   new Set(['class']),
    'blockquote': new Set(['class']),
    'h1':   new Set(['class']),
    'h2':   new Set(['class']),
    'h3':   new Set(['class']),
    'h4':   new Set(['class']),
    'h5':   new Set(['class']),
    'h6':   new Set(['class']),
    'p':    new Set(['class']),
    'hr':   new Set(['class']),
    'del':  new Set(['class'])
};

const SAFE_URL_PATTERN = /^(https?:\/\/|mailto:|#|\/)/i;

/**
 * Sanitizes HTML string by stripping disallowed tags and attributes.
 * Uses DOM parsing for reliable HTML handling.
 *
 * @param {string} html - Raw HTML string
 * @returns {string} Sanitized HTML safe for innerHTML injection
 */
export function sanitizeHtml(html) {
    if (!html) return '';

    // Use DOMParser for reliable parsing
    const parser = new DOMParser();
    const doc = parser.parseFromString('<div>' + html + '</div>', 'text/html');
    const container = doc.body.firstChild;

    sanitizeNode(container);

    return container.innerHTML;
}

function sanitizeNode(node) {
    const children = Array.from(node.childNodes);

    for (const child of children) {
        if (child.nodeType === Node.TEXT_NODE) {
            // Text nodes are safe
            continue;
        }

        if (child.nodeType === Node.ELEMENT_NODE) {
            const tagName = child.tagName.toLowerCase();

            if (!ALLOWED_TAGS.has(tagName)) {
                // Replace disallowed tag with its text content
                const text = document.createTextNode(child.textContent);
                node.replaceChild(text, child);
                continue;
            }

            // Strip disallowed attributes
            const allowedForTag = ALLOWED_ATTRS[tagName] || new Set();
            const attrs = Array.from(child.attributes);
            for (const attr of attrs) {
                if (!allowedForTag.has(attr.name)) {
                    child.removeAttribute(attr.name);
                    continue;
                }

                // Validate URLs
                if (attr.name === 'href' || attr.name === 'src') {
                    if (!SAFE_URL_PATTERN.test(attr.value)) {
                        child.removeAttribute(attr.name);
                    }
                }
            }

            // Force safe link behavior
            if (tagName === 'a') {
                child.setAttribute('target', '_blank');
                child.setAttribute('rel', 'noopener noreferrer');
            }

            // Recurse into children
            sanitizeNode(child);
        } else if (child.nodeType === Node.COMMENT_NODE) {
            // Remove HTML comments
            node.removeChild(child);
        }
    }
}
