"use strict";

// Pure helpers shared by the content and background scripts. They take plain values, never
// browser objects, so WinMux's tests run them in JavaScriptCore.
var WinMuxTabs = (() => {
    // Version 2 names each tab by Safari's id. An older WinMux understands only version 1.
    const protocolVersion = 2;
    const maximumWindows = 64;
    const maximumTabs = 500;
    const maximumTitleLength = 512;
    const maximumCandidates = 4;
    const maximumDataAddressLength = 350 * 1024;
    const maximumIconPixels = 1024;

    /** A web address's scheme, origin and host name, or null when it isn't on the web. */
    function webAddress(address) {
        const match = /^(https?):\/\/([^/?#\\]*)/i.exec(typeof address === "string" ? address : "");
        if (!match) return null;
        const authority = match[2].slice(match[2].lastIndexOf("@") + 1).toLowerCase();
        const name = authority.startsWith("[") ? authority.slice(0, authority.indexOf("]") + 1) : authority.replace(/:\d*$/, "");
        if (!name || name.length > 253 || /[\s<>]/.test(name)) return null;
        const scheme = match[1].toLowerCase();
        return { scheme, origin: `${scheme}://${authority.replace(scheme === "https" ? /:443$/ : /:80$/, "")}`, host: name };
    }

    /** The page's host name, or null for pages that aren't on the web. Paths, queries and credentials never leave the extension. */
    function host(address) {
        return webAddress(address)?.host ?? null;
    }

    /** The page's origin, which keys the icon cache: sites on one host can use different ports. */
    function origin(address) {
        return webAddress(address)?.origin ?? null;
    }

    function isLocal(name) {
        return !name.includes(".") || name.startsWith("[") || /^[\d.]+$/.test(name) || name.endsWith(".")
            || ["localhost", ".localhost", ".local", ".internal", ".lan", ".home.arpa"].some((suffix) => name === suffix || name.endsWith(suffix));
    }

    /**
     * Whether the extension may fetch an icon a page declares: an image inside the page itself, the
     * page's own origin, or a public HTTPS address. Pages can't point it at a local network device.
     */
    function iconAddressAllowed(address, pageAddress) {
        if (typeof address !== "string") return false;
        if (address.startsWith("data:")) return address.startsWith("data:image/") && address.length <= maximumDataAddressLength;
        const icon = webAddress(address);
        const page = webAddress(pageAddress);
        if (!icon || !page) return false;
        if (icon.origin === page.origin) return true;
        return icon.scheme === "https" && !isLocal(icon.host);
    }

    function iconSize(sizes) {
        if (typeof sizes !== "string") return null;
        let best = null;
        for (const token of sizes.toLowerCase().split(/\s+/)) {
            if (token === "any") return Infinity;
            const match = /^(\d+)x(\d+)$/.exec(token);
            if (match) best = Math.max(best ?? 0, Number(match[1]), Number(match[2]));
        }
        return best;
    }

    /**
     * The icons a page declares, best first, then its origin's /favicon.ico. Each link is
     * `{rel, href, sizes, type}` with an absolute href. Icons near 32 pixels win, and any favicon
     * beats a touch icon made for home screens; mask icons, single-color silhouettes, are skipped.
     */
    function iconCandidates(links, pageAddress) {
        const page = webAddress(pageAddress);
        if (!page) return [];
        const ranked = [];
        (Array.isArray(links) ? links : []).forEach((link, order) => {
            const rel = String(link?.rel ?? "").toLowerCase().split(/\s+/);
            const touch = rel.includes("apple-touch-icon") || rel.includes("apple-touch-icon-precomposed");
            if (!touch && !rel.includes("icon")) return;
            const href = String(link?.href ?? "");
            if (!iconAddressAllowed(href, pageAddress)) return;
            const vector = String(link?.type ?? "").toLowerCase() === "image/svg+xml" || /\.svg(?:[?#]|$)/i.test(href)
                || href.startsWith("data:image/svg+xml");
            const size = vector ? Infinity : iconSize(link?.sizes);
            const fit = size === Infinity ? 0 : size === null ? 0.05 : size >= 32 ? (size - 32) / 1000 : (32 - size) / 32;
            ranked.push({ href, score: (touch ? 1 : 0) + fit, order });
        });
        ranked.sort((left, right) => left.score - right.score || left.order - right.order);
        const result = [];
        for (const { href } of ranked) {
            if (!result.includes(href)) result.push(href);
            if (result.length === maximumCandidates) break;
        }
        const fallback = `${page.origin}/favicon.ico`;
        if (!result.includes(fallback)) result.push(fallback);
        return result;
    }

    function uint16(bytes, offset, little) {
        return little ? bytes[offset] | bytes[offset + 1] << 8 : bytes[offset] << 8 | bytes[offset + 1];
    }

    function uint32(bytes, offset) {
        return (bytes[offset] << 24 >>> 0) + (bytes[offset + 1] << 16) + (bytes[offset + 2] << 8) + bytes[offset + 3];
    }

    /**
     * An image's pixel size from its header, before anything decodes it, or null for a format the
     * extension doesn't accept. SVG is drawn straight at icon size, so it has no pixel size.
     */
    function imageDimensions(bytes) {
        const ascii = (offset, text) => [...text].every((character, index) => bytes[offset + index] === character.charCodeAt(0));
        if (bytes.length >= 24 && bytes[0] === 0x89 && ascii(1, "PNG")) {
            return { width: uint32(bytes, 16), height: uint32(bytes, 20) };
        }
        if (bytes.length >= 10 && ascii(0, "GIF8")) {
            return { width: uint16(bytes, 6, true), height: uint16(bytes, 8, true) };
        }
        if (bytes.length >= 6 && bytes[0] === 0 && bytes[1] === 0 && bytes[2] === 1 && bytes[3] === 0) {
            // An ICO's entries each say 1 to 256 pixels (0 means 256).
            const count = uint16(bytes, 4, true);
            if (count === 0 || bytes.length < 6 + count * 16) return null;
            let width = 0;
            let height = 0;
            for (let index = 0; index < count; index++) {
                width = Math.max(width, bytes[6 + index * 16] || 256);
                height = Math.max(height, bytes[7 + index * 16] || 256);
            }
            return { width, height };
        }
        if (bytes.length >= 30 && ascii(0, "RIFF") && ascii(8, "WEBP")) {
            if (ascii(12, "VP8X")) {
                return { width: 1 + (bytes[24] | bytes[25] << 8 | bytes[26] << 16), height: 1 + (bytes[27] | bytes[28] << 8 | bytes[29] << 16) };
            }
            if (ascii(12, "VP8L") && bytes[20] === 0x2f) {
                const bits = bytes[21] | bytes[22] << 8 | bytes[23] << 16 | bytes[24] << 24;
                return { width: 1 + (bits & 0x3fff), height: 1 + (bits >>> 14 & 0x3fff) };
            }
            if (ascii(12, "VP8 ")) {
                return { width: uint16(bytes, 26, true) & 0x3fff, height: uint16(bytes, 28, true) & 0x3fff };
            }
            return null;
        }
        if (bytes.length >= 4 && bytes[0] === 0xff && bytes[1] === 0xd8) {
            let offset = 2;
            while (offset + 9 < bytes.length) {
                if (bytes[offset] !== 0xff) return null;
                const marker = bytes[offset + 1];
                if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
                    offset += 2;
                    continue;
                }
                if (marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker)) {
                    return { width: uint16(bytes, offset + 7), height: uint16(bytes, offset + 5) };
                }
                offset += 2 + uint16(bytes, offset + 2);
            }
        }
        return null;
    }

    /** Whether the extension should decode these bytes into an icon. */
    function iconBytesAllowed(bytes, type) {
        if (bytes.length === 0) return false;
        if (typeof type === "string" && type.includes("svg")) return true;
        const size = imageDimensions(bytes);
        return size !== null && size.width > 0 && size.height > 0 && size.width <= maximumIconPixels && size.height <= maximumIconPixels;
    }

    function title(value) {
        const text = typeof value === "string" ? value.replace(/\s+/g, " ").trim() : "";
        return text.length > maximumTitleLength ? text.slice(0, maximumTitleLength) : text;
    }

    function bounds(window) {
        const values = [window.left, window.top, window.width, window.height];
        return values.every((value) => Number.isFinite(value)) ? values : undefined;
    }

    /**
     * What WinMux receives for each normal window: its place on screen and its tabs in tab-bar
     * order, each with only its id (from version 2), title, host, sound and pin state, and icon
     * key. Private Browsing windows are left out. `iconFor(tab)` returns the key of that tab's
     * icon, if any.
     */
    function stateWindows(windows, iconFor, version = protocolVersion) {
        return (Array.isArray(windows) ? windows : [])
            .filter((window) => window && (window.type === undefined || window.type === "normal")
                && window.incognito !== true && Array.isArray(window.tabs))
            .slice(0, maximumWindows)
            .map((window) => ({
                id: window.id,
                bounds: bounds(window),
                // Version 2 needs every tab's id; a tab without one (none should be) is left out.
                tabs: window.tabs.filter((tab) => version < 2 || Number.isInteger(tab?.id))
                    .sort((left, right) => left.index - right.index).slice(0, maximumTabs).map((tab) => {
                    const entry = {
                        title: title(tab.title),
                        active: tab.active === true,
                        audible: tab.audible === true,
                        muted: tab.mutedInfo?.muted === true,
                        pinned: tab.pinned === true,
                    };
                    if (version >= 2) entry.id = tab.id;
                    const name = host(tab.url ?? "");
                    if (name) entry.host = name;
                    const icon = iconFor(tab);
                    if (typeof icon === "string") entry.icon = icon;
                    return entry;
                }),
            }));
    }

    /**
     * A report of `windows` for WinMux, in `version`. From version 2 it also says when the
     * extension began measuring windows, `measured`, before it asked Safari for them: WinMux
     * trusts their bounds only against where it saw windows from just before then. And `order`
     * counts the tab moves, attachments, openings and closings the extension has heard of this
     * session, when that count didn't change while it asked: two reports with the same count saw
     * no reordering in between.
     */
    function stateMessage({ version = protocolVersion, session, measured, order, time, allSites, windows }) {
        const message = { v: version, type: "state", session, time, allSites, windows };
        if (version >= 2) {
            message.measured = measured;
            if (Number.isInteger(order) && order >= 0) message.order = order;
        }
        return message;
    }

    /**
     * The version to speak to WinMux after its `reply` to a message in `version`: an older WinMux
     * refuses a newer message as invalid and names the version it speaks.
     */
    function negotiatedVersion(reply, version) {
        const spoken = reply?.v;
        return reply?.ok !== true && reply?.reason === "invalid" && Number.isInteger(spoken) && spoken >= 1 && spoken < version
            ? spoken : version;
    }

    /** Keeps the `limit` most recently used entries of a `{key: {used, ...}}` map. */
    function trimmed(entries, limit) {
        const keys = Object.keys(entries);
        if (keys.length <= limit) return entries;
        keys.sort((left, right) => (entries[right].used ?? 0) - (entries[left].used ?? 0));
        const result = {};
        for (const key of keys.slice(0, limit)) result[key] = entries[key];
        return result;
    }

    function hex(bytes) {
        return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
    }

    function base64(bytes) {
        let text = "";
        for (let index = 0; index < bytes.length; index += 0x8000) {
            text += String.fromCharCode.apply(null, bytes.subarray(index, index + 0x8000));
        }
        return btoa(text);
    }

    return {
        protocolVersion, host, origin, iconAddressAllowed, iconCandidates, imageDimensions, iconBytesAllowed,
        stateWindows, stateMessage, negotiatedVersion, trimmed, hex, base64,
    };
})();
