import Foundation
import WebKit

// MODULE: AgentPage
// PURPOSE: Convert a tab's live DOM into a bounded snapshot and validate its element references.
// CORE DATA STRUCTURES: Snapshot holds at most 100 visible elements; refs live in the page until the next observation.
// TO MODIFY BEHAVIOR: Edit the extractor script or action script below, then run the local fixture flow.
// DO NOT: Execute agent-supplied JavaScript or persist password values.
// EXTENSION POINT: Add a validated action verb to `act`, with a matching postcondition in AgentRuntime.

@MainActor
enum AgentPage {
    static func evaluate(_ tab: Tab, _ script: String) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            tab.web.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value ?? NSNull()) }
            }
        }
    }

    static func json(_ tab: Tab, _ script: String) async throws -> [String: Any] {
        guard let text = try await evaluate(tab, script) as? String,
              let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw AgentError("PAGE_SCRIPT_FAILED", "Page did not return a JSON object") }
        return object
    }

    private static func literal(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])) ?? Data("null".utf8)
        return String(data: data, encoding: .utf8) ?? "null"
    }

    static func observe(_ tab: Tab) async throws -> [String: Any] {
        let snapshotID = UUID().uuidString.lowercased()
        let script = """
        (function() {
          const id = \(literal(snapshotID));
          const selectors = 'a[href],button,input,textarea,select,[role],[contenteditable="true"],h1,h2,h3,[aria-live]';
          const nodes = Array.from(document.querySelectorAll(selectors));
          const refs = {};
          const elements = [];
          const clean = (s, limit=240) => String(s || '').replace(/\\s+/g, ' ').trim().slice(0, limit);
          for (const el of nodes) {
            if (elements.length >= 100) break;
            const style = getComputedStyle(el);
            const rect = el.getBoundingClientRect();
            if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity) < 0.02 || rect.width < 1 || rect.height < 1) continue;
            const tag = el.tagName.toLowerCase();
            const inputRole = tag === 'input' ? ({checkbox:'checkbox',radio:'radio',submit:'button',button:'button'}[el.type] || 'textbox') : null;
            const role = el.getAttribute('role') || inputRole || ({a:'link',button:'button',textarea:'textbox',select:'combobox'}[tag] || (tag[0] === 'h' ? 'heading' : tag));
            const name = clean(el.getAttribute('aria-label') || el.labels?.[0]?.innerText || el.getAttribute('alt') || el.getAttribute('placeholder') || el.innerText || el.textContent);
            const ref = 'e' + (elements.length + 1);
            refs[ref] = el;
            const editable = (tag === 'input' && !/^(checkbox|radio|submit|button|reset|file|hidden)$/i.test(el.type)) || tag === 'textarea' || el.isContentEditable;
            const secret = tag === 'input' && /^(password|hidden)$/i.test(el.type);
            elements.push({ref, role, name, text: clean(el.innerText), placeholder: clean(el.getAttribute('placeholder')),
              value: editable && !secret ? clean(el.value || el.innerText) : null,
              href: tag === 'a' ? el.href : null,
              disabled: !!el.disabled || el.getAttribute('aria-disabled') === 'true',
              readonly: !!el.readOnly, checked: !!el.checked, selected: !!el.selected,
              editable, secret, visible: true});
          }
          window.__searchAgentSnapshot = {id, url: location.href, refs};
          return JSON.stringify({snapshot_id:id, url:location.href, title:document.title,
            elements, text:clean(document.body && document.body.innerText || '',6000),
            timestamp:new Date().toISOString()});
        })()
        """
        return try await json(tab, script)
    }

    static func act(_ tab: Tab, verb: String, snapshotID: String, ref: String, text: String = "", expected: [String: Any] = [:]) async throws -> [String: Any] {
        let arguments: [String: Any] = ["verb": verb, "snapshot": snapshotID, "ref": ref, "text": text, "expected": expected]
        let script = """
        (function() {
          const p = \(literal(arguments));
          const snap = window.__searchAgentSnapshot;
          if (!snap || snap.id !== p.snapshot || snap.url !== location.href) return JSON.stringify({error:'ELEMENT_STALE'});
          const el = snap.refs[p.ref];
          if (!el || !el.isConnected) return JSON.stringify({error:'ELEMENT_STALE'});
          const style = getComputedStyle(el), rect = el.getBoundingClientRect();
          if (style.display === 'none' || style.visibility === 'hidden' || rect.width < 1 || rect.height < 1) return JSON.stringify({error:'ELEMENT_NOT_VISIBLE'});
          if (el.disabled || el.getAttribute('aria-disabled') === 'true') return JSON.stringify({error:'ELEMENT_DISABLED'});
          const tag = el.tagName.toLowerCase();
          const inputRole = tag === 'input' ? ({checkbox:'checkbox',radio:'radio',submit:'button',button:'button'}[el.type] || 'textbox') : null;
          const role = el.getAttribute('role') || inputRole || ({a:'link',button:'button',textarea:'textbox',select:'combobox'}[tag] || tag);
          const clean = s => String(s || '').replace(/\\s+/g, ' ').trim().slice(0,240);
          const name = clean(el.getAttribute('aria-label') || el.labels?.[0]?.innerText || el.getAttribute('alt') || el.getAttribute('placeholder') || el.innerText || el.textContent);
          if (p.expected.role && p.expected.role !== role || p.expected.name && p.expected.name !== name) return JSON.stringify({error:'ELEMENT_STALE'});
          if (p.verb === 'click') { el.scrollIntoView({block:'center'}); el.focus?.(); el.click(); return JSON.stringify({ok:true}); }
          if (p.verb === 'fill' || p.verb === 'type') {
            if (!((tag === 'input' && !/^(checkbox|radio|submit|button|reset|file|hidden)$/i.test(el.type)) || tag === 'textarea' || el.isContentEditable)) return JSON.stringify({error:'INVALID_ACTION'});
            if (tag === 'input' && /^(password|hidden)$/i.test(el.type)) return JSON.stringify({error:'INVALID_ACTION'});
            el.focus?.();
            const previous = el.isContentEditable ? el.textContent : el.value;
            const next = p.verb === 'type' ? previous + p.text : p.text;
            if (el.isContentEditable) el.textContent = next;
            else { const proto = tag === 'textarea' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
              const setter = Object.getOwnPropertyDescriptor(proto,'value')?.set;
              if (setter) setter.call(el,next); else el.value = next; }
            el.dispatchEvent(new Event('input',{bubbles:true}));
            el.dispatchEvent(new Event('change',{bubbles:true}));
            return JSON.stringify({ok:true, previous, value:el.isContentEditable ? el.textContent : el.value});
          }
          if (p.verb === 'keypress') {
            el.focus?.();
            const before = document.activeElement === el;
            const event = new KeyboardEvent('keydown', {key:p.text,bubbles:true,cancelable:true});
            el.dispatchEvent(event);
            el.dispatchEvent(new KeyboardEvent('keyup', {key:p.text,bubbles:true,cancelable:true}));
            return JSON.stringify({ok:true, focused:before, handled:event.defaultPrevented});
          }
          return JSON.stringify({error:'INVALID_ACTION'});
        })()
        """
        return try await json(tab, script)
    }

    static func scroll(_ tab: Tab, y: Double) async throws -> [String: Any] {
        try await json(tab, "(function(){const before=window.scrollY;window.scrollBy(0,\(y));return JSON.stringify({before,after:window.scrollY});})()")
    }
}
