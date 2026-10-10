.pragma library

var RESOLVED_FLAG = "=";

// avahi emits C-style octal escapes in -p output (" " -> "\032"); decode
// them so service names render as "AirPlay Remote Video" and not escapes.
function unescapeOctal(s) {
    if (!s) return s
    return s.replace(/\\([0-7]{1,3})/g, function(_, oct) {
        return String.fromCharCode(parseInt(oct, 8))
    })
}

function parseLine(line) {
    if (!line) return null
    var parts = line.split(";")
    if (parts.length < 8) return null
    return {
        flag: parts[0],
        iface: parts[1],
        family: parts[2],
        name: unescapeOctal(parts[3]),
        service: unescapeOctal(parts[4]),
        domain: unescapeOctal(parts[5] || ""),
        hostname: unescapeOctal(parts[6] || ""),
        address: unescapeOctal(parts[7] || ""),
        port: parts[8] || "",
        txt: unescapeOctal(parts[9] || "")
    }
}

function isResolved(rec) {
    return rec && rec.flag === RESOLVED_FLAG
}

function isLoopbackInterface(iface) {
    return iface === "lo"
}

function isInterestingAddress(rec) {
    if (!rec) return false
    if (rec.family !== "IPv4") return false
    if (!rec.address) return false
    if (rec.address === "127.0.0.1") return false
    return true
}

function hasHostname(rec) {
    return rec && !!rec.hostname
}

// `_airplay._tcp` → `airplay`. Used by the popup to render a friendly label.
function friendlyServiceName(type) {
    if (!type) return ""
    return type.replace(/^_/, "").replace(/\._(tcp|udp)$/, "")
}

// Render one service as `[port] name` (or just `name` if no port).
function serviceDisplayLine(svc) {
    var name = friendlyServiceName(svc && svc.type)
    if (svc && svc.port && Number(svc.port) > 0) {
        return "[" + svc.port + "] " + name
    }
    return name
}

function stripLocalSuffix(hostname) {
    if (!hostname) return ""
    return hostname.replace(/\.local\.?$/i, "")
}

function deviceKey(hostname, ip) {
    return stripLocalSuffix(hostname) + "|" + ip
}

function keyFromIp(ip) {
    return ip || ""
}

function keyFromHostnameIp(hostname, ip) {
    if (ip) return ip
    return stripLocalSuffix(hostname) || ""
}

function parseMacFromNeigh(output) {
    if (!output) return ""
    var m = output.match(/lladdr\s+([0-9a-fA-F:]{17})/)
    return m ? m[1].toLowerCase() : ""
}

function isValidMac(mac) {
    return /^[0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5}$/.test(mac)
}

// `ip -4 -j route get 1.1.1.1` — single-element array; surface src/gw/iface.
function parseRouteOutput(jsonText) {
    var empty = { src: "", gw: "", iface: "" }
    if (!jsonText) return empty
    try {
        var arr = JSON.parse(jsonText)
        if (!Array.isArray(arr) || arr.length === 0) return empty
        var r = arr[0] || {}
        return {
            src: r.prefsrc || "",
            gw: r.gateway || "",
            iface: r.dev || ""
        }
    } catch (e) {
        return empty
    }
}

// `ip -4 -j neigh show dev <iface>` — flat array of {ip, mac, state}.
// Entries without a usable lladdr (probes, FAILED) are dropped.
function parseArpSnapshot(jsonText) {
    if (!jsonText) return []
    try {
        var arr = JSON.parse(jsonText)
        if (!Array.isArray(arr)) return []
        var out = []
        for (var i = 0; i < arr.length; i++) {
            var e = arr[i]
            if (!e || !e.dst || !e.lladdr) continue
            if (!isValidMac(e.lladdr)) continue
            out.push({
                ip: e.dst,
                mac: e.lladdr.toLowerCase(),
                state: e.state || ""
            })
        }
        return out
    } catch (e) {
        return []
    }
}

// One line of `ip -4 monitor neigh`. Returns a {join} or {gone} record,
// or null for FAILED/PROBE/incomplete. Caller filters by seededIps.
function parseNeighEvent(line) {
    if (!line) return null
    var trimmed = line.trim()
    if (!trimmed) return null

    var tokens = trimmed.split(/\s+/)
    if (tokens.length < 3) return null

    var ip = tokens[0]
    if (tokens[1] !== "dev") return null
    var idx = 2

    var iface = tokens[idx]
    idx++

    if (tokens[idx] === "router") idx++

    if (tokens[idx] === "deleted") {
        return { ip: ip, iface: iface, mac: null, kind: "gone" }
    }

    if (tokens[idx] === "lladdr" && idx + 2 < tokens.length) {
        var mac = tokens[idx + 1]
        if (!isValidMac(mac)) return null
        return {
            ip: ip,
            iface: iface,
            mac: mac.toLowerCase(),
            kind: "join",
            state: tokens[idx + 2] || ""
        }
    }

    // FAILED, INCOMPLETE, or other state-only lines without lladdr.
    return null
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        parseLine: parseLine,
        isResolved: isResolved,
        isLoopbackInterface: isLoopbackInterface,
        isInterestingAddress: isInterestingAddress,
        hasHostname: hasHostname,
        friendlyServiceName: friendlyServiceName,
        serviceDisplayLine: serviceDisplayLine,
        stripLocalSuffix: stripLocalSuffix,
        deviceKey: deviceKey,
        keyFromIp: keyFromIp,
        keyFromHostnameIp: keyFromHostnameIp,
        parseMacFromNeigh: parseMacFromNeigh,
        isValidMac: isValidMac,
        parseRouteOutput: parseRouteOutput,
        parseArpSnapshot: parseArpSnapshot,
        parseNeighEvent: parseNeighEvent
    };
}
