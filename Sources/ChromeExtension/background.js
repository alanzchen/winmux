"use strict";
importScripts("shared.js");

// Chrome owns this process/port. No daemon or high-frequency keepalive polling is installed.
const host = "com.zimengxiong.winmux.tabs";
let port = null;
let session = crypto.randomUUID();
let epoch = crypto.randomUUID();
let sequence = 0;
let order = 0;
let needsSnapshot = true;
let sending = false;
let timer = null;
let retry = 1000;
let reconnectAt = 0;
let reconnectTimer = null;
let againTimer = null;
const dirty = new Set();
const commands = new Set();
const selecting = new Map();
let latestSelectionRequest = null;
const waiting = new Map();

function schedule(id, full = false) {
    if (Number.isInteger(id) && id >= 0) dirty.add(id);
    needsSnapshot ||= full;
    if (timer === null) timer = setTimeout(() => { timer = null; publish(); }, 40);
}

function reconnectLater() {
    const delay = retry;
    retry = Math.min(60000, retry * 2);
    reconnectAt = Date.now() + delay;
    if (reconnectTimer !== null) clearTimeout(reconnectTimer);
    reconnectTimer = setTimeout(() => { reconnectTimer = null; schedule(undefined, true); }, delay);
}

function connect() {
    if (port || Date.now() < reconnectAt) return;
    try {
        const current = chrome.runtime.connectNative(host);
        port = current;
        epoch = crypto.randomUUID();
        sequence = 0;
        needsSnapshot = true;
        current.onMessage.addListener((message) => {
            if (port !== current) return;
            if (message.command) command(message.command);
            if (message.reply) {
                const resolve = waiting.get(message.seq);
                waiting.delete(message.seq);
                resolve?.(message.reply);
            }
        });
        current.onDisconnect.addListener(() => {
            void chrome.runtime.lastError;
            if (port !== current) return;
            port = null;
            for (const resolve of waiting.values()) resolve(null);
            waiting.clear();
            needsSnapshot = true;
            reconnectLater();
        });
    } catch {
        port = null;
        reconnectLater();
    }
}

function exchange(message) {
    const current = port;
    return new Promise((resolve) => {
        const deadline = setTimeout(() => {
            waiting.delete(message.push.seq);
            resolve(null);
            if (port === current) current?.disconnect();
        }, 4000);
        waiting.set(message.push.seq, (reply) => { clearTimeout(deadline); resolve(reply); });
        try { current.postMessage(message); }
        catch { clearTimeout(deadline); waiting.delete(message.push.seq); resolve(null); }
    });
}

async function publish() {
    if (sending) return;
    connect();
    if (!port) return;
    sending = true;
    const current = port;
    const full = needsSnapshot;
    const ids = [...dirty];
    dirty.clear();
    needsSnapshot = false;
    try {
        if (!full && ids.length === 0) return;
        const measured = Date.now();
        const before = order;
        const windows = full ? await chrome.windows.getAll({ populate: true })
            : (await Promise.all(ids.map((id) => chrome.windows.get(id, { populate: true }).catch(() => null)))).filter(Boolean);
        if (port !== current) { needsSnapshot = true; return; }
        // No paths or favicon URLs leave Chrome. Existing opt-in native origin icons remain intact.
        const described = WinMuxTabs.stateWindows(windows, () => undefined, 2);
        const message = { v: 2, type: full ? "state" : "events", session, time: Date.now(), measured,
            allSites: true, windows: described,
            push: { v: 1, browser: "chrome", epoch, seq: ++sequence, kind: full ? "snapshot" : "delta",
                removed: full ? [] : ids.filter((id) => !described.some((window) => window.id === id)) } };
        if (before === order) message.order = order;
        const reply = await exchange(message);
        if (!reply?.ok || reply.events !== 1) {
            needsSnapshot = true;
            // Only a sequence gap requests an immediate snapshot. Off/old/unreachable apps
            // disconnect and back off; they must not turn into a 40 ms full-report loop.
            if (!reply?.snapshot && port === current) current.disconnect();
            return;
        }
        retry = 1000;
        reconnectAt = 0;
        if (reconnectTimer !== null) { clearTimeout(reconnectTimer); reconnectTimer = null; }
        if (Number.isInteger(reply.again) && reply.again >= 1 && reply.again <= 60 && againTimer === null) {
            againTimer = setTimeout(() => { againTimer = null; schedule(undefined, true); }, reply.again * 1000);
        }
    } catch {
        needsSnapshot = true;
        if (port === current) current.disconnect();
    } finally {
        sending = false;
        if (port && (dirty.size || needsSnapshot)) schedule();
    }
}

async function command(value) {
    if (value?.protocol !== 1 || value.browser !== "chrome" || value.session !== session || value.epoch !== epoch
        || typeof value.request !== "string") return;
    const current = port;
    const reply = (kind) => {
        if (port === current) current?.postMessage({ v: 2, type: "push-control", protocol: 1, browser: "chrome",
            session, epoch, request: value.request, kind, window: value.window, tab: value.tab });
    };
    if (value.kind === "probe") { reply("ready"); return; }
    if (value.kind === "snapshot") { schedule(undefined, true); return; }
    if (value.kind === "cancel") {
        commands.add(value.request);
        if (commands.size > 256) commands.delete(commands.values().next().value);
        if (latestSelectionRequest === value.request) latestSelectionRequest = null;
        selecting.delete(value.request);
        return;
    }
    if (value.kind !== "select" || commands.has(value.request)) return;
    latestSelectionRequest = value.request;
    commands.add(value.request);
    if (commands.size > 256) commands.delete(commands.values().next().value);
    const before = order;
    let dispatched = false;
    try {
        const tab = await chrome.tabs.get(value.tab);
        const window = await chrome.windows.get(value.window);
        if (latestSelectionRequest !== value.request || port !== current || value.seq !== sequence || sending || needsSnapshot || dirty.size || before !== order
            || !Number.isFinite(value.expires) || Date.now() > value.expires || tab.windowId !== value.window || tab.incognito || window.incognito
            || window.type !== "normal") { reply("refused"); return; }
        selecting.set(value.request, { window: value.window, tab: value.tab, reply });
        setTimeout(() => selecting.delete(value.request), 2000);
        dispatched = true;
        await chrome.tabs.update(value.tab, { active: true });
        reply("result");
        const selected = await chrome.tabs.get(value.tab);
        if (tab.active && selected.windowId === value.window && selected.active && !selected.incognito) reply("activated");
        schedule(value.window);
    } catch { if (!dispatched) reply("refused"); }
}

chrome.tabs.onUpdated.addListener((id, change, tab) => {
    if (["title", "url", "favIconUrl", "audible", "mutedInfo", "status", "pinned"].some((key) => key in change)) {
        schedule(tab.windowId);
    }
});
chrome.tabs.onActivated.addListener((info) => {
    for (const entry of selecting.values()) {
        if (entry.window === info.windowId && entry.tab === info.tabId) entry.reply("activated");
    }
    schedule(info.windowId);
});
chrome.tabs.onCreated.addListener((tab) => { order++; schedule(tab.windowId); });
chrome.tabs.onRemoved.addListener((id, info) => { order++; schedule(info.windowId); });
chrome.tabs.onMoved.addListener((id, info) => { order++; schedule(info.windowId); });
chrome.tabs.onAttached.addListener((id, info) => { order++; schedule(info.newWindowId); });
chrome.tabs.onDetached.addListener((id, info) => { order++; schedule(info.oldWindowId); });
chrome.tabs.onReplaced.addListener(() => { order++; schedule(undefined, true); });
chrome.windows.onCreated.addListener((window) => schedule(window.id));
chrome.windows.onRemoved.addListener((id) => schedule(id));
chrome.windows.onFocusChanged.addListener((id) => { if (id >= 0) schedule(id); });
chrome.alarms.onAlarm.addListener((alarm) => { if (alarm.name === "winmux-reconcile") schedule(undefined, true); });
chrome.runtime.onInstalled.addListener(() => schedule(undefined, true));
chrome.runtime.onStartup.addListener(() => schedule(undefined, true));
chrome.alarms.create("winmux-reconcile", { periodInMinutes: 1 });
schedule(undefined, true);
