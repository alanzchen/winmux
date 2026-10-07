"use strict";

// Sends WinMux each Safari window's tabs (title, host, sound, pin and icon) whenever they change,
// and once a minute, so a WinMux that just started catches up. WinMux answers with the icons it
// doesn't have yet; only those are sent. Everything stays on this Mac, and Private Browsing
// windows are left out entirely. Each window's toolbar button is titled with the window's ids,
// so WinMux can tell which window is which (`WinMuxTabs.markerTitle`).
const nativeApplication = "com.zimengxiong.winmux";
const heartbeat = "winmux-heartbeat";
const iconPixels = 32;
const maximumIconBytes = 256 * 1024;
// WinMux keeps more icons than this, so every icon a tab reports fits there.
const cachedIcons = 256;
const iconsPerMessage = 32;
const pendingReports = 100;
const concurrentFetches = 3;
const failedAddressDelay = 10 * 60 * 1000;
const unavailableDelay = 60 * 1000;
// WinMux not answering is retried this soon, then twice as long each time, up to unavailableDelay:
// Safari reloads this page as WinMux starts, so its first report can come before WinMux listens.
const firstRetryDelay = 5 * 1000;

let sendTimer = null;
// WinMux asking, in its answer, for another report a moment later (`again`, in seconds).
let againTimer = null;
let retryDelay = firstRetryDelay;
let retryTimer = null;
let sending = false;
let sendAgain = false;
let forcedSend = false;
// The protocol version WinMux speaks, until it says it's older. Learned again whenever Safari
// reloads this page, so a WinMux updated meanwhile hears the current version.
let peerVersion = WinMuxTabs.protocolVersion;
// While WinMux isn't running, or has browser tabs off, only the heartbeat and the retries
// (`markUnavailable`) check in, and no icons are fetched.
let unavailableUntil = 0;
// What the last report WinMux took in full said (`WinMuxTabs.reportKey`). Only the heartbeat and
// WinMux asking send the same again.
let lastReport = null;
// A page lifetime is a new event stream, even when Safari retained its browsing session.
const pushEpoch = crypto.randomUUID();
let pushSequence = 0;
let pushEnabled = false;
let pushNeedsSnapshot = true;
const changedWindows = new Set();
const handledCommands = new Set();
const selecting = new Map();
let latestSelectionRequest = null;

function changedWindow(id) {
    if (Number.isInteger(id) && id >= 0) changedWindows.add(id);
    else pushNeedsSnapshot = true;
}

// The title each tab's toolbar button was given, so it's set only when it changes. Safari may drop
// it as the tab loads a page, so loading forgets it, and so does Safari unloading this page.
const stamped = new Map();
// Each tab's latest title operation: an older one's later steps don't overwrite a newer title.
const titleWrites = new Map();

// Safari unloads this page when idle, so what it needs again lives in session storage, which
// Safari keeps only in memory and clears when it quits: this browsing session's identifier, the
// icons it made, which tab shows which icon, and pages' icon reports that arrived while WinMux
// was away.
const sessionStorage = browser.storage.session;
const loaded = (async () => {
    const stored = await sessionStorage?.get(["session", "icons", "originIcons", "tabIcons", "pending", "unavailableUntil", "order"])
        .catch(() => ({})) ?? {};
    if (Number.isFinite(stored.unavailableUntil)) unavailableUntil = Math.max(unavailableUntil, stored.unavailableUntil);
    let session = stored.session;
    if (typeof session !== "string") {
        session = crypto.randomUUID();
        await sessionStorage?.set({ session }).catch(() => {});
        // Safari just started, or turned the extension on or updated it: open pages' icons
        // aren't known here, and their content scripts may be an earlier version's.
        injectIntoOpenTabs();
    }
    return {
        session,
        icons: stored.icons ?? {},
        originIcons: stored.originIcons ?? {},
        tabIcons: stored.tabIcons ?? {},
        pending: stored.pending ?? {},
        // Tab moves, attachments, openings and closings heard of this session.
        order: Number.isInteger(stored.order) ? stored.order : 0,
        addresses: new Map(),
        // The latest report from each tab's page; an icon finished for an older one is dropped.
        reports: new Map(),
        // Reports being made now, so a kept one isn't started twice.
        inFlight: new Set(),
    };
})();

function isUnavailable() {
    return Date.now() < unavailableUntil;
}

/** Remembered across page unloads, so waking the page to load an icon doesn't ask WinMux again. */
function setUnavailableUntil(time) {
    unavailableUntil = time;
    sessionStorage?.set({ unavailableUntil: time }).catch(() => {});
}

/** WinMux didn't take a report: it's left alone for a while, and then asked again. */
function markUnavailable() {
    const delay = retryDelay;
    retryDelay = Math.min(unavailableDelay, retryDelay * 2);
    setUnavailableUntil(Date.now() + delay);
    retryIn(delay);
}

function retryIn(delay) {
    if (retryTimer === null) retryTimer = setTimeout(() => { retryTimer = null; scheduleSend(0, true); }, delay);
}

/** A forced send (the heartbeat, or WinMux asking) goes even while WinMux seemed away. */
function scheduleSend(delay = 250, force = false) {
    forcedSend ||= force;
    if (!force && isUnavailable()) return;
    if (sendTimer === null) sendTimer = setTimeout(send, delay);
}

function iconFor(data, tab) {
    const origin = WinMuxTabs.origin(tab.url ?? "");
    const shown = data.tabIcons[tab.id];
    const key = shown && shown.origin === origin ? shown.key : origin ? data.originIcons[origin]?.key : undefined;
    // Only icons still kept here: WinMux would ask for an evicted one that could never come.
    return key && data.icons[key] ? key : undefined;
}

/** Titles each normal window's active tab's toolbar button with the window's ids, once, or again
 * for every window when `all`: a button put back in the toolbar shows just the extension's name
 * until its tab's title changes, and nothing tells this page it came back. Safari ignores a title
 * the tab already has, so `all` resets each to the name first. */
function stampWindows(windows, session, all = false) {
    for (const window of Array.isArray(windows) ? windows : []) {
        if (window.incognito === true || (window.type !== undefined && window.type !== "normal")) continue;
        const tab = window.tabs?.find((tab) => tab.active === true);
        if (!Number.isInteger(tab?.id) || !Number.isInteger(window.id)) continue;
        const title = WinMuxTabs.markerTitle(session, window.id, tab.id);
        if (!all && stamped.get(tab.id) === title) continue;
        stamped.set(tab.id, title);
        setButtonTitle(tab.id, title, all);
    }
}

function setButtonTitle(tabId, title, reset) {
    const operation = (titleWrites.get(tabId) ?? 0) + 1;
    titleWrites.set(tabId, operation);
    const latest = () => titleWrites.get(tabId) === operation;
    const write = (value) => latest() ? Promise.resolve(browser.action?.setTitle({ tabId, title: value })) : Promise.resolve();
    try {
        (reset ? write(null).then(() => write(title)) : write(title)).catch(() => { if (latest()) stamped.delete(tabId); });
    } catch {
        stamped.delete(tabId);
    }
}

function save(data) {
    return sessionStorage?.set({ icons: data.icons, originIcons: data.originIcons, tabIcons: data.tabIcons, pending: data.pending })
        .catch(() => {});
}

async function send() {
    sendTimer = null;
    if (sending) {
        sendAgain = true;
        return;
    }
    sending = true;
    const force = forcedSend;
    forcedSend = false;
    try {
        const data = await loaded;
        // The pause may have been read from storage after this send was scheduled.
        if (!force && isUnavailable()) return;
        const wasUnavailable = unavailableUntil !== 0;
        // Noted before asking for the windows: their bounds describe some moment after this, and
        // their tab order is the one the order count names only if no move came in meanwhile.
        const measured = Date.now();
        const orderBefore = data.order;
        const full = !pushEnabled || pushNeedsSnapshot || force || changedWindows.size === 0;
        const dirty = [...changedWindows];
        changedWindows.clear();
        pushNeedsSnapshot = false;
        const windows = full ? await browser.windows.getAll({ populate: true })
            : (await Promise.all(dirty.map((id) => browser.windows.get(id, { populate: true }).catch(() => null)))).filter(Boolean);
        const order = data.order === orderBefore ? orderBefore : undefined;
        // A forced send (the heartbeat, at least once a minute) titles every window's button again.
        stampWindows(windows, data.session, force);
        const allSites = await browser.permissions.contains({ origins: ["*://*/*"] }).catch(() => false);
        const version = peerVersion;
        const message = WinMuxTabs.stateMessage({
            version, session: data.session, measured, order, time: Date.now(), allSites,
            windows: WinMuxTabs.stateWindows(windows, (tab) => iconFor(data, tab), version),
        });
        const removed = full ? [] : dirty.filter((id) => !message.windows.some((w) => w.id === id));
        // Older apps reject this type rather than interpreting a delta as a full report.
        if (!full) message.type = "events";
        const key = WinMuxTabs.reportKey(message) + JSON.stringify(removed);
        if (version >= 2) {
            message.push = { v: 1, browser: "safari", epoch: pushEpoch, seq: pushSequence + 1,
                kind: full ? "snapshot" : "delta", removed };
        }
        if (!force && key === lastReport) return;
        lastReport = null;
        if (message.push) pushSequence += 1;
        const reply = await browser.runtime.sendNativeMessage(nativeApplication, message);
        pushEnabled = reply?.events === 1;
        if (!full && !pushEnabled && reply?.reason === "invalid") {
            pushNeedsSnapshot = true;
            sendAgain = true;
            return;
        }
        if (reply?.snapshot === true) { pushNeedsSnapshot = true; sendAgain = true; return; }
        const spoken = WinMuxTabs.negotiatedVersion(reply, version);
        if (spoken !== version) {
            // An older WinMux: say it again in its version, without tab ids.
            pushEnabled = false;
            pushNeedsSnapshot = true;
            peerVersion = spoken;
            sendAgain = true;
            return;
        }
        if (reply?.ok !== true) {
            pushNeedsSnapshot = true;
            markUnavailable();
            return;
        }
        retryDelay = firstRetryDelay;
        if (wasUnavailable) setUnavailableUntil(0);
        // WinMux can't yet tell some of its windows apart, and a report a moment later may.
        const again = reply.again;
        if (Number.isInteger(again) && again >= 1 && again <= 60 && againTimer === null) {
            againTimer = setTimeout(() => { againTimer = null; scheduleSend(0, true); }, again * 1000);
        }
        const wanted = Array.isArray(reply.want) ? reply.want.filter((key) => typeof key === "string") : [];
        // Until WinMux has every icon it asked for, the same report may ask again.
        if (wanted.length === 0) lastReport = key;
        const icons = {};
        for (const key of wanted.slice(0, iconsPerMessage)) {
            const png = data.icons[key]?.png;
            if (png) icons[key] = png;
        }
        if (Object.keys(icons).length > 0) {
            await browser.runtime.sendNativeMessage(nativeApplication, {
                v: version, type: "icons", session: data.session, icons,
            });
        }
        // Ask again only after progress, so icons WinMux can't take or this page no longer has
        // never cause an endless exchange.
        if (wanted.length > iconsPerMessage && Object.keys(icons).length > 0) sendAgain = true;
        showPending(data);
    } catch {
        pushNeedsSnapshot = true;
        markUnavailable();
    } finally {
        sending = false;
        if (sendAgain) {
            sendAgain = false;
            scheduleSend();
        }
    }
}

let fetches = 0;
const waiting = [];

async function limited(work) {
    if (fetches >= concurrentFetches) await new Promise((resolve) => waiting.push(resolve));
    fetches += 1;
    try {
        return await work();
    } finally {
        fetches -= 1;
        waiting.shift()?.();
    }
}

async function bytesOf(response) {
    if (Number(response.headers.get("content-length") ?? 0) > maximumIconBytes) return null;
    const reader = response.body?.getReader();
    if (!reader) {
        const buffer = new Uint8Array(await response.arrayBuffer());
        return buffer.length <= maximumIconBytes ? buffer : null;
    }
    const chunks = [];
    let length = 0;
    for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        length += value.length;
        if (length > maximumIconBytes) {
            reader.cancel().catch(() => {});
            return null;
        }
        chunks.push(value);
    }
    const bytes = new Uint8Array(length);
    let offset = 0;
    for (const chunk of chunks) {
        bytes.set(chunk, offset);
        offset += chunk.length;
    }
    return bytes;
}

async function decoded(bytes, type) {
    const vector = type.includes("svg");
    const blob = new Blob([bytes], vector ? { type: "image/svg+xml" } : {});
    if (!vector && typeof createImageBitmap === "function") {
        try { return await createImageBitmap(blob); } catch {}
    }
    if (typeof Image !== "function") return null;
    const address = URL.createObjectURL(blob);
    try {
        const image = new Image();
        image.src = address;
        await image.decode();
        return image;
    } catch {
        return null;
    } finally {
        URL.revokeObjectURL(address);
    }
}

/** A 32-pixel PNG of the icon at `address`, fetched without cookies, or null. */
async function rasterized(address) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 5000);
    try {
        // A redirect could lead anywhere, and its request would already be sent before the
        // extension saw where, so an icon that redirects isn't used.
        const response = await fetch(address, {
            credentials: "omit", cache: "force-cache", redirect: "error", referrerPolicy: "no-referrer", signal: controller.signal,
        });
        if (!response.ok) return null;
        const type = (response.headers.get("content-type") ?? "").toLowerCase();
        if (type.startsWith("text/") || type.includes("html")) return null;
        const bytes = await bytesOf(response);
        if (!bytes || !WinMuxTabs.iconBytesAllowed(bytes, type)) return null;
        const image = await decoded(bytes, type);
        if (!image) return null;
        const width = image.naturalWidth || image.width || iconPixels;
        const height = image.naturalHeight || image.height || iconPixels;
        const canvas = typeof OffscreenCanvas === "function" ? new OffscreenCanvas(iconPixels, iconPixels)
            : Object.assign(document.createElement("canvas"), { width: iconPixels, height: iconPixels });
        const context = canvas.getContext("2d");
        const scale = Math.min(iconPixels / width, iconPixels / height);
        const drawnWidth = Math.max(1, Math.round(width * scale));
        const drawnHeight = Math.max(1, Math.round(height * scale));
        context.imageSmoothingQuality = "high";
        context.drawImage(image, (iconPixels - drawnWidth) / 2, (iconPixels - drawnHeight) / 2, drawnWidth, drawnHeight);
        image.close?.();
        const pixels = context.getImageData(0, 0, iconPixels, iconPixels).data;
        if (!pixels.some((value, index) => index % 4 === 3 && value > 0)) return null;
        const png = canvas.convertToBlob ? await canvas.convertToBlob({ type: "image/png" })
            : await new Promise((resolve) => canvas.toBlob(resolve, "image/png"));
        return png ? new Uint8Array(await png.arrayBuffer()) : null;
    } catch {
        return null;
    } finally {
        clearTimeout(timer);
    }
}

async function iconMade(address) {
    const png = await limited(() => rasterized(address));
    if (!png) return null;
    const key = WinMuxTabs.hex(new Uint8Array(await crypto.subtle.digest("SHA-256", png)));
    return { key, png: WinMuxTabs.base64(png) };
}

/** Makes each icon address's icon once; many tabs of one site share it. A failed address waits ten minutes. */
function iconAt(data, address) {
    const known = data.addresses.get(address);
    if (known && (known.failedAt === undefined || Date.now() - known.failedAt < failedAddressDelay)) return known.icon;
    if (data.addresses.size >= 500) data.addresses.clear();
    const entry = { icon: iconMade(address) };
    data.addresses.set(address, entry);
    entry.icon.then((value) => { if (!value) entry.failedAt = Date.now(); });
    return entry.icon;
}

function isSameReport(left, right) {
    return left && right && left.page === right.page && left.report === right.report;
}

function flightKey(tabId, report) {
    return `${tabId}:${report.page}:${report.report}`;
}

/** Makes the icon a tab's page reported, unless the page has moved on by the time it's ready. */
async function showIcon(tabId, report) {
    const data = await loaded;
    const key = flightKey(tabId, report);
    if (data.inFlight.has(key)) return;
    data.inFlight.add(key);
    try {
        await makeIcon(data, tabId, report);
    } finally {
        data.inFlight.delete(key);
        // A kept report is done once this, its current job, has made it or found it overtaken;
        // until then it survives the page unloading.
        const current = data.reports.get(tabId) === report || !isSameReport(data.reports.get(tabId), report);
        if (current && isSameReport(data.pending[tabId], report) && !isUnavailable()) {
            delete data.pending[tabId];
            await save(data);
        }
    }
}

async function makeIcon(data, tabId, report) {
    const origin = WinMuxTabs.origin(report.pageAddress);
    if (!origin) return;
    const isCurrent = () => data.reports.get(tabId) === report;
    for (const address of report.candidates) {
        if (!isCurrent()) return;
        // WinMux is away: the report stays kept for when it answers again.
        if (isUnavailable()) return;
        if (!WinMuxTabs.iconAddressAllowed(address, report.pageAddress)) continue;
        const icon = await iconAt(data, address);
        if (!icon) continue;
        // The tab may have gone to another page, or into a private window, while its icon loaded.
        const tab = await browser.tabs.get(tabId).catch(() => null);
        if (!isCurrent() || !tab || tab.incognito || WinMuxTabs.origin(tab.url ?? "") !== origin) return;
        const now = Date.now();
        data.icons = WinMuxTabs.trimmed({ ...data.icons, [icon.key]: { png: icon.png, used: now } }, cachedIcons);
        data.originIcons = WinMuxTabs.trimmed({ ...data.originIcons, [origin]: { key: icon.key, used: now } }, cachedIcons);
        data.tabIcons[tabId] = { key: icon.key, origin };
        await save(data);
        // Origin fallback can affect other windows too. Preserve that existing icon behavior,
        // even when an unrelated tab event has already queued a partial report.
        pushNeedsSnapshot = true;
        scheduleSend();
        return;
    }
}

/** Keeps each report until its icon is made, so Safari unloading this page meanwhile loses nothing. */
async function receiveReport(data, tabId, report) {
    data.reports.set(tabId, report);
    if (!isSameReport(data.pending[tabId], report)) {
        data.pending = WinMuxTabs.trimmed({ ...data.pending, [tabId]: { ...report, used: Date.now() } }, pendingReports);
        await save(data);
    }
    showIcon(tabId, report);
}

/** Once WinMux answers again, makes the icons of reports still kept: those that arrived while it
 * was away, or whose work Safari cut short by unloading this page. */
async function showPending(data) {
    for (const [tabId, kept] of Object.entries(data.pending)) {
        const id = Number(tabId);
        if (data.inFlight.has(flightKey(id, kept))) continue;
        const latest = data.reports.get(id);
        if (latest && latest.page === kept.page && latest.report > kept.report) continue;
        // Only while the tab still shows the very page that reported.
        const tab = await browser.tabs.get(id).catch(() => null);
        if (!isSameReport(data.pending[tabId], kept) || data.inFlight.has(flightKey(id, kept))) continue;
        if (!tab || tab.incognito || tab.url !== kept.pageAddress) {
            delete data.pending[tabId];
            save(data);
            continue;
        }
        const current = data.reports.get(id);
        const report = isSameReport(current, kept) ? current
            : { page: kept.page, report: kept.report, pageAddress: kept.pageAddress, candidates: kept.candidates };
        data.reports.set(id, report);
        showIcon(id, report);
    }
}

async function injectIntoOpenTabs() {
    // Pages open before the extension was turned on don't have its content script yet, and one
    // left from before an update can't reach this page. Each reports its icons again.
    const tabs = await browser.tabs.query({}).catch(() => []);
    for (const tab of tabs) {
        if (tab.incognito || !WinMuxTabs.host(tab.url ?? "")) continue;
        const target = { tabId: tab.id };
        browser.scripting.executeScript({ target, func: () => { delete globalThis.winMuxTabsContentLoaded; } })
            .then(() => browser.scripting.executeScript({ target, files: ["shared.js", "content.js"] }))
            .catch(() => {});
    }
}

async function ensureHeartbeat() {
    if (!(await browser.alarms.get(heartbeat).catch(() => null))) browser.alarms.create(heartbeat, { periodInMinutes: 1 });
}

browser.runtime.onMessage.addListener((message, sender) => {
    const tab = sender.tab;
    if (message?.type !== "winmux-icon-candidates" || !tab || tab.incognito || (sender.frameId ?? 0) !== 0) return;
    // Only the tab's own page names its icons.
    const pageAddress = sender.url ?? tab.url ?? "";
    if (!Array.isArray(message.candidates) || WinMuxTabs.origin(pageAddress) !== WinMuxTabs.origin(tab.url ?? "")) return;
    const report = { page: String(message.page ?? ""), report: Number(message.report) || 0, pageAddress,
        candidates: message.candidates.filter((address) => typeof address === "string").slice(0, 5) };
    loaded.then((data) => {
        const latest = data.reports.get(tab.id);
        // A page's reports can arrive out of order; only its newest counts.
        if (latest && latest.page === report.page && latest.report > report.report) return;
        receiveReport(data, tab.id, report);
    });
});

// Capture exact affected windows; lifecycle changes invalidate both sides of an attachment.
browser.tabs.onUpdated.addListener((id, changes, tab) => changedWindow(tab?.windowId));
browser.tabs.onActivated.addListener((info) => {
    for (const entry of selecting.values()) {
        if (entry.window === info?.windowId && entry.tab === info?.tabId) entry.reply("activated");
    }
    changedWindow(info?.windowId);
});
browser.tabs.onCreated.addListener((tab) => changedWindow(tab?.windowId));
browser.tabs.onRemoved.addListener((id, info) => changedWindow(info?.windowId));
browser.tabs.onMoved.addListener((id, info) => changedWindow(info?.windowId));
browser.tabs.onAttached.addListener((id, info) => changedWindow(info?.newWindowId));
browser.tabs.onDetached.addListener((id, info) => changedWindow(info?.oldWindowId));
browser.windows.onCreated.addListener((window) => changedWindow(window?.id));
browser.windows.onRemoved.addListener(changedWindow);

browser.tabs.onUpdated.addListener((tabId, changes) => {
    // A tab that goes to another address drops its page's unfinished icon, and a report it kept.
    // Safari also reports the address when it hasn't changed, as a page finishes loading.
    if ("url" in changes) {
        loaded.then((data) => {
            if (data.reports.get(tabId)?.pageAddress !== changes.url) data.reports.delete(tabId);
            if (data.pending[tabId] && data.pending[tabId].pageAddress !== changes.url) {
                delete data.pending[tabId];
                save(data);
            }
        });
    }
    // A page loading may reset the tab's toolbar title.
    if ("url" in changes || "status" in changes) stamped.delete(tabId);
    if (["title", "url", "favIconUrl", "status", "audible", "mutedInfo", "pinned"].some((key) => key in changes)) scheduleSend();
});
/** Counts a change that may reorder tabs, remembered across page unloads. */
function countOrderChange(data) {
    data.order += 1;
    sessionStorage?.set({ order: data.order }).catch(() => {});
}

for (const event of [browser.tabs.onCreated, browser.tabs.onMoved, browser.tabs.onAttached, browser.tabs.onDetached,
                     browser.windows.onCreated, browser.windows.onRemoved]) {
    event?.addListener(() => loaded.then(countOrderChange));
}
browser.tabs.onRemoved.addListener(async (tabId) => {
    stamped.delete(tabId);
    titleWrites.delete(tabId);
    const data = await loaded;
    countOrderChange(data);
    data.reports.delete(tabId);
    if (data.tabIcons[tabId] || data.pending[tabId]) {
        delete data.tabIcons[tabId];
        delete data.pending[tabId];
        await save(data);
    }
    scheduleSend();
});
browser.tabs.onReplaced?.addListener(async (added, removed) => {
    pushNeedsSnapshot = true;
    stamped.delete(removed);
    titleWrites.delete(removed);
    const data = await loaded;
    countOrderChange(data);
    if (data.tabIcons[removed]) {
        data.tabIcons[added] = data.tabIcons[removed];
        delete data.tabIcons[removed];
        await save(data);
    }
    scheduleSend();
});
for (const event of [browser.tabs.onCreated, browser.tabs.onActivated, browser.tabs.onMoved, browser.tabs.onAttached,
                     browser.tabs.onDetached, browser.windows.onCreated, browser.windows.onRemoved]) {
    event?.addListener(() => scheduleSend());
}
// WinMux switching windows in its sidebar moves them, and Safari says nothing of where windows
// are but this: a report a second later, once they've settled, says where they are now. One that
// moved none says nothing new, and isn't sent.
browser.windows.onFocusChanged?.addListener((windowId) => {
    if (windowId !== browser.windows.WINDOW_ID_NONE) scheduleSend(1000);
});
browser.alarms.onAlarm.addListener((alarm) => { if (alarm.name === heartbeat) scheduleSend(0, true); });
browser.runtime.onInstalled.addListener(() => { injectIntoOpenTabs(); scheduleSend(0, true); });
browser.runtime.onStartup.addListener(() => scheduleSend(0, true));

// WinMux asks for everything again when it starts, or when it sees a Safari window it can't
// match. Best effort: Safari may have unloaded this page, and then the heartbeat catches up, or
// WinMux's answer to the next report asks again (`again` above).
try {
    browser.runtime.connectNative(nativeApplication).onMessage.addListener((message) => {
        if ((message?.name ?? message?.type) === "resync") scheduleSend(0, true);
        if (message?.name === "winmux-push" || message?.protocol === 1) handlePushCommand(message.userInfo ?? message);
    });
} catch {}

ensureHeartbeat();
// Safari can unload and reload this page while WinMux is away: the retry it was waiting for
// comes when that pause ends.
loaded.then(() => isUnavailable() ? retryIn(unavailableUntil - Date.now()) : scheduleSend());

// A dispatch acknowledgement proves delivery only for this page lifetime, never that Safari
// can wake a suspended page. Missing result/postcondition is unknown, never retried by WinMux.
async function handlePushCommand(command) {
    const data = await loaded;
    if (command?.protocol !== 1 || command.browser !== "safari" || command.session !== data.session
        || command.epoch !== pushEpoch || typeof command.request !== "string") return;
    const reply = (kind) => browser.runtime.sendNativeMessage(nativeApplication, {
        v: 2, type: "push-control", protocol: 1, browser: "safari", session: data.session, epoch: pushEpoch,
        request: command.request, kind, window: command.window, tab: command.tab,
    }).catch(() => {});
    if (command.kind === "probe") { await reply("ready"); return; }
    if (command.kind === "snapshot") { scheduleSend(0, true); return; }
    if (command.kind === "cancel") {
        handledCommands.add(command.request);
        if (handledCommands.size > 256) handledCommands.delete(handledCommands.values().next().value);
        if (latestSelectionRequest === command.request) latestSelectionRequest = null;
        selecting.delete(command.request);
        return;
    }
    if (command.kind !== "select" || handledCommands.has(command.request)) return;
    latestSelectionRequest = command.request;
    handledCommands.add(command.request);
    // A bounded page-local replay guard; expired requests remain ineligible after eviction.
    if (handledCommands.size > 256) handledCommands.delete(handledCommands.values().next().value);
    const order = data.order;
    const current = () => latestSelectionRequest === command.request && command.seq === pushSequence && !sending && sendTimer === null
        && changedWindows.size === 0 && data.order === order && Number.isFinite(command.expires) && Date.now() <= command.expires;
    let dispatched = false;
    try {
        const tab = await browser.tabs.get(command.tab);
        const window = await browser.windows.get(command.window);
        if (!current() || tab.windowId !== command.window || tab.incognito || window.incognito
            || window.type !== "normal") { await reply("refused"); return; }
        selecting.set(command.request, { window: command.window, tab: command.tab, reply });
        setTimeout(() => selecting.delete(command.request), 2000);
        dispatched = true;
        await browser.tabs.update(command.tab, { active: true });
        await reply("result");
        const selected = await browser.tabs.get(command.tab);
        if (tab.active && selected.windowId === command.window && selected.active && !selected.incognito) await reply("activated");
        changedWindow(command.window);
        scheduleSend(0);
    } catch {
        // Once tabs.update was invoked, even rejection may follow a side effect. Silence is an
        // unknown outcome at the native deadline; only a failure before invocation is refused.
        if (!dispatched) await reply("refused");
    }
}
