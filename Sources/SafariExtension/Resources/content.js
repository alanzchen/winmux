"use strict";

// Tells the background script which icons this page declares, when it loads and when the page
// changes them (sites such as mail or chat update their icon with an unread count). It reads
// only the page's icon links; the page's text and data are never read.
(() => {
    if (window.top !== window || globalThis.winMuxTabsContentLoaded) return;
    globalThis.winMuxTabsContentLoaded = true;
    // Tells this page's reports apart from an earlier page's in the same tab, so a slow icon
    // for the page before never replaces this one's.
    const page = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
    let reports = 0;
    let last = null;
    let timer = null;

    function report() {
        timer = null;
        const address = location.href;
        const links = Array.from(document.querySelectorAll("link[rel][href]"), (link) => ({
            rel: link.rel, href: link.href, sizes: link.getAttribute("sizes"), type: link.type,
        }));
        const candidates = WinMuxTabs.iconCandidates(links, location.href);
        const key = JSON.stringify(candidates);
        if (candidates.length === 0 || key === last) return;
        last = key;
        reports += 1;
        browser.runtime.sendMessage({ type: "winmux-icon-candidates", page, report: reports, address, candidates })
            .catch(() => { last = null; });
    }

    function schedule() {
        if (timer === null) timer = setTimeout(report, 1000);
    }

    report();
    const head = document.head ?? document.documentElement;
    if (head) {
        new MutationObserver((records) => {
            if (records.some((record) => [...record.addedNodes, ...record.removedNodes].some((node) => node.nodeName === "LINK")
                || (record.type === "attributes" && record.target.nodeName === "LINK"))) schedule();
        }).observe(head, { childList: true, subtree: true, attributes: true, attributeFilter: ["href", "rel", "sizes", "type"] });
    }
    // A page restored from the back-forward cache is a different page without a new load.
    window.addEventListener("pageshow", (event) => { if (event.persisted) { last = null; report(); } });
    // The tab went to another address: its icon is the new page's only once this page names it
    // again, as a page that changes its address by script stays. The extension asks; this page
    // also does it by itself a moment after its own address changes, once Safari knows it.
    browser.runtime.onMessage.addListener((message) => {
        if (message?.type === "winmux-icon-request") { last = null; report(); }
    });
    const again = () => { last = null; schedule(); };
    window.addEventListener("hashchange", again);
    window.addEventListener("popstate", again);
    window.navigation?.addEventListener?.("navigatesuccess", again);
})();
