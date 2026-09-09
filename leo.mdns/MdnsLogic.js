.pragma library

var RESOLVED_FLAG = "=";

// avahi emits C-style octal escapes (e.g. " " -> "\032") in -p output; we
// decode the obvious ones so a notification body says "AirPlay Remote Video"
// instead of "AirPlay\032Remote\032Video".
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

function stripLocalSuffix(hostname) {
    if (!hostname) return ""
    return hostname.replace(/\.local\.?$/i, "")
}

function deviceKey(hostname, ip) {
    return stripLocalSuffix(hostname) + "|" + ip
}

function parseMacFromNeigh(output) {
    if (!output) return ""
    var m = output.match(/lladdr\s+([0-9a-fA-F:]{17})/)
    return m ? m[1].toLowerCase() : ""
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        parseLine: parseLine,
        isResolved: isResolved,
        isLoopbackInterface: isLoopbackInterface,
        isInterestingAddress: isInterestingAddress,
        hasHostname: hasHostname,
        stripLocalSuffix: stripLocalSuffix,
        deviceKey: deviceKey,
        parseMacFromNeigh: parseMacFromNeigh
    };
}