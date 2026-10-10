import QtQuick
import Quickshell
import Quickshell.Io

import qs.Commons

import "MdnsLogic.js" as Mdns

Item {
  id: service

  property var shell: null

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: home + "/.local/state/omarchy/"
  readonly property string seenPath: stateDir + "mdns-devices.json"

  readonly property int reNotifyMs: 10 * 60 * 1000
  readonly property int minNotifyGapMs: 30 * 1000

  readonly property string probeIp: "1.1.1.1"
  readonly property int joinNotifyDelayMs: 3000
  readonly property int goneDebounceMs: 30000
  readonly property int reseedIntervalMs: 5 * 60 * 1000
  readonly property int arpRetryMs: 3000
  property string ownIface: ""
  property string ownIp: ""
  property string gatewayIp: ""
  // Set when we intentionally kill the monitor (iface change). The next
  // onExited fires with SIGTERM=15; we must not treat that as a crash.
  property bool _suppressMonitorExit: false
  property var pendingJoin: ({})
  property var pendingGone: ({})
  // IPs seen at startup. A `deleted` event for an IP not here is a transient
  // neighbour that vanished before we noticed — ignore.
  property var seededIps: ({})

  property var pendingArp: ({})

  // Sequential: the ip neigh / ping pipeline reuses a pair of stateful
  // Process objects whose stdout would collide if run in parallel.
  property var arpQueue: []

  PersistentProperties {
    id: persisted
    reloadableId: "leo-mdns"
    property var devices: ({})

    onDevicesChanged: service.saveSeenSoon()
  }

  readonly property alias devices: persisted.devices

  readonly property int deviceCount: {
    var n = 0
    for (var k in persisted.devices) n++
    return n
  }

  Timer {
    id: saveTimer
    interval: 2000
    repeat: false
    onTriggered: service.flushSeen()
  }

  Component.onCompleted: {
    service.startBrowsing()
  }

  // Quickshell.readFile() does not exist in this version — use FileView (async)
  // and gate ARP bootstrap on it so the snapshot doesn't clobber hydrated state.
  // watchChanges is off: this is our own private state file; every flushSeen()
  // would otherwise trigger a reload → re-save.
  FileView {
    id: seenFile
    path: service.seenPath
    watchChanges: false
    printErrors: false
    onLoaded: {
      service.hydrateSeen(text() || "")
      arpBootstrapDelay.start()
    }
    onLoadFailed: function(error) {
      console.warn("leo.mdns: hydrate load failed:", error, "path=", service.seenPath)
      arpBootstrapDelay.start()
    }
  }

  Timer {
    id: arpBootstrapDelay
    interval: 1500
    repeat: false
    onTriggered: service.startArpBootstrap()
  }

  function clearDevices() {
    persisted.devices = ({})
    service.flushSeenNow()
  }

  function hydrateSeen(raw) {
    if (!raw) return
    try {
      var parsed = JSON.parse(raw)
      if (!parsed || typeof parsed !== "object") return
      // Migrate legacy "hostname|ip" keys to single-IP identity.
      var migrated = {}
      var didMigrate = false
      for (var k in parsed) {
        var rec = parsed[k]
        if (!rec || typeof rec !== "object") continue
        var newKey = rec.ip || (k.indexOf("|") >= 0 ? k.substring(k.indexOf("|") + 1) : k)
        if (newKey !== k) didMigrate = true
        if (!("source" in rec)) rec.source = "mdns"
        if (!("goneAt" in rec)) rec.goneAt = 0
        // Drop legacy string-only services; the next mDNS hit will repopulate
        // them with `{type, port}` objects.
        if (rec.services) {
          for (var si = 0; si < rec.services.length; si++) {
            if (typeof rec.services[si] === "string") {
              rec.services = []
              break
            }
          }
        }
        if (migrated[newKey]) {
          // Two legacy entries collapsed onto the same IP — keep the fresher one.
          if ((rec.lastSeen || 0) > (migrated[newKey].lastSeen || 0)) {
            migrated[newKey] = rec
          }
        } else {
          migrated[newKey] = rec
        }
      }
      persisted.devices = migrated
      if (didMigrate) console.log("leo.mdns: migrated", "legacy hostname|ip keys to ip keys")
    } catch (e) {
      console.warn("leo.mdns: malformed", seenPath, e)
    }
  }

  function saveSeenSoon() {
    saveTimer.restart()
  }

  function flushSeenNow() {
    saveTimer.stop()
    service.flushSeen()
  }

  function flushSeen() {
    var payload = JSON.stringify(persisted.devices || {})
    var script =
      "import json, os, sys\n" +
      "p = " + JSON.stringify(seenPath) + "\n" +
      "os.makedirs(os.path.dirname(p), exist_ok=True)\n" +
      "tmp = p + '.tmp'\n" +
      "with open(tmp, 'w') as f: f.write(" + JSON.stringify(payload) + ")\n" +
      "os.replace(tmp, p)\n"
    Quickshell.execDetached(["python3", "-c", script])
  }

  function startBrowsing() {
    // `-k` disables avahi's service-type DB lookup so field 4 stays raw
    // (`_smb._tcp`) instead of being substituted with the human-readable name
    // ("Microsoft Windows Network"). Friendly display is done in JS.
    browseProc.command = ["avahi-browse", "-a", "-r", "-f", "-k", "-p"]
    browseProc.running = true
  }

  Process {
    id: browseProc

    stdout: SplitParser {
      onRead: function(line) {
        service.handleLine(String(line))
      }
    }
    stderr: StdioCollector {
      onStreamFinished: if (text.trim() !== "") {
        var t = text.trim()
        if (t.indexOf("Found user") !== 0 && t.indexOf("Successfully") !== 0) {
          console.warn("leo.mdns: avahi-browse stderr:", t)
        }
      }
    }

    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) {
        console.warn("leo.mdns: avahi-browse exited", exitCode, "— restarting in 3s")
        restartTimer.interval = 3000
        restartTimer.start()
      }
    }
  }

  Timer {
    id: restartTimer
    repeat: false
    onTriggered: service.startBrowsing()
  }

  function handleLine(line) {
    if (!line) return
    var rec = Mdns.parseLine(line)
    if (!rec) return
    if (!Mdns.isResolved(rec)) return
    if (Mdns.isLoopbackInterface(rec.iface)) return
    if (!Mdns.hasHostname(rec)) return
    if (!Mdns.isInterestingAddress(rec)) return
    service.recordSeen(rec.hostname, rec.address, rec.service, rec.port)
  }

  // Add or update a service on a device. Same-type re-announcements merge port
  // (avahi emits each service as a separate record, so port can land late).
  function addServiceTo(rec, serviceType, port) {
    if (!rec.services) rec.services = []
    for (var i = 0; i < rec.services.length; i++) {
      if (rec.services[i].type === serviceType) {
        if (port && !rec.services[i].port) rec.services[i].port = port
        return
      }
    }
    rec.services.push({type: serviceType, port: port || ""})
  }

  function recordSeen(hostname, ip, serviceType, port) {
    var key = Mdns.keyFromHostnameIp(hostname, ip)
    if (!key) return false
    var now = Date.now()
    var existing = persisted.devices[key]
    var isNew = !existing

    if (existing && (now - existing.lastSeen) < service.minNotifyGapMs) {
      var copy = persisted.devices
      var updated = {}
      for (var k in copy) updated[k] = copy[k]
      var rec = updated[key]
      rec.lastSeen = now
      rec.goneAt = 0
      if (serviceType) addServiceTo(rec, serviceType, port)
      if (rec.source === "arp") rec.source = "both"
      updated[key] = rec
      persisted.devices = updated

      if (service.pendingJoin[ip]) {
        service.fireJoinNotifyNow(key)
      }
      return false
    }

    var copy = persisted.devices
    var updated = {}
    for (var k2 in copy) updated[k2] = copy[k2]
    if (isNew) {
      updated[key] = {
        hostname: Mdns.stripLocalSuffix(hostname),
        ip: ip,
        mac: "",
        firstSeen: now,
        lastSeen: now,
        services: serviceType ? [{type: serviceType, port: port || ""}] : [],
        source: "mdns",
        goneAt: 0
      }
    } else {
      var rec2 = updated[key]
      rec2.hostname = Mdns.stripLocalSuffix(hostname) || rec2.hostname
      rec2.lastSeen = now
      rec2.goneAt = 0
      if (serviceType) addServiceTo(rec2, serviceType, port)
      if (rec2.source === "arp") rec2.source = "both"
      updated[key] = rec2
    }
    persisted.devices = updated

    if (service.pendingJoin[ip]) {
      service.fireJoinNotifyNow(key)
    }

    service.lookupMac(hostname, ip, key, isNew || (now - (existing ? existing.lastSeen : 0)) >= service.reNotifyMs)
    return true
  }

  function lookupMac(hostname, ip, dedupKey, shouldNotify) {
    if (service.pendingArp[ip]) return
    service.pendingArp[ip] = true
    service.arpQueue.push({
      hostname: hostname,
      ip: ip,
      key: dedupKey,
      shouldNotify: shouldNotify
    })
    service.pumpArpQueue()
  }

  function pumpArpQueue() {
    if (arpProc.running) return
    if (service.arpQueue.length === 0) return
    var item = service.arpQueue.shift()
    arpProc._pendingHostname = item.hostname
    arpProc._pendingIp = item.ip
    arpProc._pendingKey = item.key
    arpProc._pendingShouldNotify = item.shouldNotify
    arpProc._pendingStage = "neigh"
    arpProc._pendingMac = ""
    arpProc._pendingHops = 0
    arpProc.command = ["ip", "-4", "neigh", "show", item.ip]
    arpProc.running = true
  }

  Process {
    id: arpProc
    property string _pendingHostname: ""
    property string _pendingIp: ""
    property string _pendingKey: ""
    property bool _pendingShouldNotify: false
    property string _pendingStage: "neigh"
    property string _pendingMac: ""
    // Capped at 2: self-lookups (laptop's own IP) and a few corner cases
    // never produce an ARP entry no matter how often we ask.
    property int _pendingHops: 0
    readonly property int maxHops: 2

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: arpProc._pendingMac = Mdns.parseMacFromNeigh(text || "")
    }

    onExited: function(exitCode) {
      var hostname = arpProc._pendingHostname
      var ip = arpProc._pendingIp
      var key = arpProc._pendingKey
      var shouldNotify = arpProc._pendingShouldNotify
      var mac = arpProc._pendingMac
      var hops = arpProc._pendingHops

      if (arpProc._pendingStage === "neigh" && !mac && hops < arpProc.maxHops) {
        arpProc._pendingStage = "retry"
        arpProc._pendingMac = ""
        arpProc._pendingHops = hops + 1
        arpProc.command = ["ping", "-c", "1", "-W", "1", ip]
        arpProc.running = true
        return
      }
      if (arpProc._pendingStage === "retry") {
        // ping doesn't return parseable MAC info — re-query neigh to pick up what the echo populated.
        arpProc._pendingStage = "neigh"
        arpProc._pendingMac = ""
        arpProc._pendingHops = hops + 1
        arpProc.command = ["ip", "-4", "neigh", "show", ip]
        arpProc.running = true
        return
      }
      if (mac) {
        var copy = persisted.devices
        var updated = {}
        for (var k in copy) updated[k] = copy[k]
        if (updated[key]) updated[key].mac = mac
        persisted.devices = updated
      }
      delete service.pendingArp[ip]
      if (shouldNotify) {
        // Use the record we just wrote — mDNS may have enriched it while we queued.
        var rec = persisted.devices[key]
        if (rec) service.fireNotification(rec)
      }
      service.pumpArpQueue()
    }
  }

  // ----- ARP/neighbour watcher -------------------------------------------

  function startArpBootstrap() {
    ifaceProc.command = ["ip", "-4", "-j", "route", "get", service.probeIp]
    ifaceProc.running = true
  }

  Process {
    id: ifaceProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: service.parseRouteAndProceed(text || "")
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        console.warn("leo.mdns: ip route get failed", exitCode, "— retry in 3s")
        arpRetryTimer.interval = service.arpRetryMs
        arpRetryTimer.start()
      }
    }
  }

  function parseRouteAndProceed(text) {
    var r = Mdns.parseRouteOutput(text)
    if (!r.iface) {
      console.warn("leo.mdns: no iface from route — retry in 3s")
      arpRetryTimer.interval = service.arpRetryMs
      arpRetryTimer.start()
      return
    }
    var ifaceChanged = (r.iface !== service.ownIface)
    service.ownIface = r.iface
    service.ownIp = r.src
    service.gatewayIp = r.gw

    // ip monitor neigh on the same iface already sees joins/leaves via
    // netlink; only restart it if the iface changed (wifi ↔ ethernet) or
    // we're still in the initial bootstrap (ownIface empty).
    if (ifaceChanged || !arpMonitorProc.running) {
      service.seededIps = ({})
      if (arpMonitorProc.running) {
        // Suppress the SIGTERM=15 onExited that our own kill will produce.
        service._suppressMonitorExit = true
        arpMonitorProc.running = false
      }
      arpSnapProc.command = ["ip", "-4", "-j", "neigh", "show", "dev", service.ownIface]
      arpSnapProc.running = true
    }
  }

  Process {
    id: arpSnapProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: service.seedArpSnapshot(text || "")
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        console.warn("leo.mdns: ip neigh snapshot failed", exitCode)
      }
    }
  }

  function seedArpSnapshot(text) {
    var entries = Mdns.parseArpSnapshot(text)
    var seeded = {}
    for (var i = 0; i < entries.length; i++) {
      var e = entries[i]
      if (e.ip === service.ownIp || e.ip === service.gatewayIp) continue
      seeded[e.ip] = true
      // Silent: these devices were already on the network when we started.
      service.recordArpSeen(e.ip, e.mac, true)
    }
    service.seededIps = seeded
    arpMonitorProc.command = ["ip", "-4", "monitor", "neigh", "dev", service.ownIface]
    arpMonitorProc.running = true
    reseedTimer.start()
  }

  Process {
    id: arpMonitorProc
    stdout: SplitParser {
      onRead: function(line) { service.handleNeighEvent(String(line)) }
    }
    stderr: StdioCollector {
      onStreamFinished: if (text && text.trim() !== "") {
        console.warn("leo.mdns: ip monitor stderr:", text.trim())
      }
    }
    onExited: function(exitCode, exitStatus) {
      if (service._suppressMonitorExit) {
        service._suppressMonitorExit = false
        return
      }
      if (exitCode !== 0) {
        console.warn("leo.mdns: ip monitor exited", exitCode, "— restarting in 3s")
        arpRetryTimer.interval = service.arpRetryMs
        arpRetryTimer.start()
      }
    }
  }

  Timer {
    id: arpRetryTimer
    repeat: false
    onTriggered: service.startArpBootstrap()
  }

  Timer {
    id: reseedTimer
    interval: service.reseedIntervalMs
    repeat: true
    running: false
    onTriggered: service.reseedArpWatcher()
  }

  // Reseed is just a route re-probe. If the iface didn't change, the running
  // monitor keeps going — no SIGTERM, no false "exit 15" cascade.
  function reseedArpWatcher() {
    service.startArpBootstrap()
  }

  function handleNeighEvent(line) {
    if (!line) return
    if (!service.ownIface) return
    var ev = Mdns.parseNeighEvent(line)
    if (!ev) return
    if (ev.iface !== service.ownIface) return
    if (ev.ip === service.ownIp) return
    if (ev.ip === service.gatewayIp) return
    if (ev.kind === "join") {
      service.cancelGoneNotify(ev.ip)
      service.recordArpSeen(ev.ip, ev.mac, false)
    } else if (ev.kind === "gone") {
      // Only treat as leave if we ever knew this IP — otherwise it's a
      // transient probe that vanished before resolving.
      if (!service.seededIps[ev.ip] && !persisted.devices[ev.ip]) return
      service.recordGone(ev.ip)
    }
  }

  // silent=true suppresses the join notify (used for the startup snapshot).
  function recordArpSeen(ip, mac, silent) {
    if (!ip) return
    if (ip === service.ownIp || ip === service.gatewayIp) return
    var key = ip
    var existing = persisted.devices[key]
    var now = Date.now()
    // Snapshot BEFORE mutating — otherwise the debounce compares now-now.
    var prevLastSeen = existing ? (existing.lastSeen || 0) : 0
    var copy = persisted.devices
    var updated = {}
    for (var k in copy) updated[k] = copy[k]
    if (existing) {
      existing.goneAt = 0
      existing.lastSeen = now
      if (mac && !existing.mac) existing.mac = mac
      if (existing.source === "arp" && mac) existing.source = "arp"
      updated[key] = existing
    } else {
      updated[key] = {
        hostname: "",
        ip: ip,
        mac: mac || "",
        firstSeen: now,
        lastSeen: now,
        services: [],
        source: mac ? "arp" : "arp",
        goneAt: 0
      }
    }
    persisted.devices = updated

    if (silent) return
    if (existing && (now - prevLastSeen) < service.minNotifyGapMs) return
    service.scheduleJoinNotify(key)
  }

  function recordGone(ip) {
    if (!ip) return
    var key = ip
    var existing = persisted.devices[key]
    if (!existing) return
    if (existing.goneAt) return
    var now = Date.now()
    var copy = persisted.devices
    var updated = {}
    for (var k in copy) updated[k] = copy[k]
    if (updated[key]) {
      updated[key].goneAt = now
    }
    persisted.devices = updated
    scheduleGoneNotify(key)
  }

  function cancelGoneNotify(ip) {
    var t = service.pendingGone[ip]
    if (t) {
      t.stop()
      delete service.pendingGone[ip]
    }
    if (!persisted.devices[ip]) return
    if (!persisted.devices[ip].goneAt) return
    var copy = persisted.devices
    var updated = {}
    for (var k in copy) updated[k] = copy[k]
    if (updated[ip]) updated[ip].goneAt = 0
    persisted.devices = updated
  }

  // ----- Timer pools for deferred notifications --------------------------

  // Repeater refuses Timer as a delegate; pool is built via Instantiator.
  Instantiator {
    id: joinPool
    model: 8
    delegate: Timer {
      interval: service.joinNotifyDelayMs
      repeat: false
      property int slot: index
      property string key: ""
      onTriggered: service.onJoinTimerFire(slot)
    }
  }
  Instantiator {
    id: gonePool
    model: 8
    delegate: Timer {
      interval: service.goneDebounceMs
      repeat: false
      property int slot: index + 8
      property string key: ""
      onTriggered: service.onGoneTimerFire(slot)
    }
  }

  function findFreeJoinSlot() {
    for (var i = 0; i < joinPool.count; i++) {
      var t = joinPool.objectAt(i)
      if (t && !t.running) return i
    }
    return -1
  }

  function findFreeGoneSlot() {
    for (var i = 0; i < gonePool.count; i++) {
      var t = gonePool.objectAt(i)
      if (t && !t.running) return i + 8
    }
    return -1
  }

  function timerBySlot(slot) {
    if (slot < 8) return joinPool.objectAt(slot)
    return gonePool.objectAt(slot - 8)
  }

  function scheduleJoinNotify(key) {
    var ip = (persisted.devices[key] || {}).ip
    if (!ip) return
    if (service.pendingJoin[ip]) {
      service.pendingJoin[ip].restart()
      return
    }
    var slot = findFreeJoinSlot()
    if (slot < 0) {
      console.warn("leo.mdns: join timer pool exhausted")
      return
    }
    var t = joinPool.objectAt(slot)
    t.key = ip
    service.pendingJoin[ip] = t
    t.start()
  }

  function scheduleGoneNotify(key) {
    var ip = (persisted.devices[key] || {}).ip || key
    if (service.pendingGone[ip]) {
      service.pendingGone[ip].restart()
      return
    }
    var slot = findFreeGoneSlot()
    if (slot < 0) {
      console.warn("leo.mdns: gone timer pool exhausted")
      return
    }
    var t = timerBySlot(slot)
    t.key = ip
    service.pendingGone[ip] = t
    t.start()
  }

  function onJoinTimerFire(slot) {
    var t = joinPool.objectAt(slot)
    if (!t) return
    var ip = t.key
    t.key = ""
    var rec = persisted.devices[ip]
    if (rec) service.fireNotification(rec)
    delete service.pendingJoin[ip]
  }

  function onGoneTimerFire(slot) {
    var t = timerBySlot(slot)
    if (!t) return
    var ip = t.key
    t.key = ""
    var rec = persisted.devices[ip]
    if (rec) service.fireGoneNotification(rec)
    delete service.pendingGone[ip]
  }

  // Called when mDNS enriches a pending ARP join — short-circuit the 3s wait.
  function fireJoinNotifyNow(key) {
    var rec = persisted.devices[key]
    if (!rec) return
    var ip = rec.ip
    var t = service.pendingJoin[ip]
    if (t) {
      t.stop()
      t.key = ""
      delete service.pendingJoin[ip]
    }
    service.fireNotification(rec)
  }

  // ----- Notifications --------------------------------------------------

  function fireNotification(record) {
    if (!record) return
    var displayName = (record.hostname && Mdns.stripLocalSuffix(record.hostname))
      || record.ip
      || "(unknown)"
    var headline = "New device on the network: " + displayName
    var bodyLines = []
    bodyLines.push("IP: " + (record.ip || "—"))
    bodyLines.push("MAC: " + (record.mac || "(resolving)"))
    if (record.services && record.services.length > 0) {
      bodyLines.push("Service: " + Mdns.serviceDisplayLine(record.services[0]))
    }
    bodyLines.push("Source: " + (record.source || "mdns"))
    var body = bodyLines.join("\n")

    var args = [
      "omarchy-notification-send",
      "--app-name", "leo.mdns",
      "-u", "low",
      "-t", "8000",
      "-i", "network-wireless-symbolic",
      headline,
      body
    ]
    Quickshell.execDetached(args)
  }

  function fireGoneNotification(record) {
    if (!record) return
    var displayName = (record.hostname && Mdns.stripLocalSuffix(record.hostname))
      || record.ip
      || "(unknown)"
    var headline = "Device left the network: " + displayName
    var bodyLines = []
    bodyLines.push("IP: " + (record.ip || "—"))
    if (record.mac) bodyLines.push("MAC: " + record.mac)
    bodyLines.push("Source: " + (record.source || "mdns"))
    var body = bodyLines.join("\n")

    var args = [
      "omarchy-notification-send",
      "--app-name", "leo.mdns",
      "-u", "low",
      "-t", "6000",
      "-i", "network-wireless-offline-symbolic",
      headline,
      body
    ]
    Quickshell.execDetached(args)
  }
}
