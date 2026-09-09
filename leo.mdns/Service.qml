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

  property var pendingArp: ({})

  // ARP lookup is sequential because the ip neigh / ping pipeline uses one
  // pair of stateful Process objects; running them in parallel would let
  // one lookup's stdout arrive while another is still being configured.
  property var arpQueue: []

  PersistentProperties {
    id: persisted
    reloadableId: "leo-mdns"
    property var devices: ({})

    onDevicesChanged: service.saveSeenSoon()
  }

  // Alias so Panel.qml can read root.shell.serviceFor("leo.mdns").devices
  // without poking at PersistentProperties internals.
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
    service.hydrateSeen()
    service.startBrowsing()
  }

  function clearDevices() {
    persisted.devices = ({})
    service.flushSeenNow()
  }

  function hydrateSeen() {
    var raw = ""
    try {
      raw = Quickshell.readFile(seenPath) || ""
    } catch (e) {
      return
    }
    if (!raw) return
    try {
      var parsed = JSON.parse(raw)
      if (parsed && typeof parsed === "object") persisted.devices = parsed
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
    browseProc.command = ["avahi-browse", "-a", "-r", "-f", "-p"]
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
    service.recordSeen(rec.hostname, rec.address, rec.service)
  }

  function recordSeen(hostname, ip, serviceType) {
    var key = Mdns.deviceKey(hostname, ip)
    var now = Date.now()
    var existing = persisted.devices[key]
    var isNew = !existing
    if (existing && (now - existing.lastSeen) < service.minNotifyGapMs) {
      var copy = persisted.devices
      var updated = {}
      for (var k in copy) updated[k] = copy[k]
      var rec = updated[key]
      rec.lastSeen = now
      if (serviceType && rec.services.indexOf(serviceType) === -1) {
        rec.services = rec.services.concat([serviceType])
      }
      updated[key] = rec
      persisted.devices = updated
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
        services: serviceType ? [serviceType] : []
      }
    } else {
      var rec2 = updated[key]
      rec2.lastSeen = now
      if (serviceType && rec2.services.indexOf(serviceType) === -1) {
        rec2.services = rec2.services.concat([serviceType])
      }
      updated[key] = rec2
    }
    persisted.devices = updated

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
        // ping doesn't return parseable MAC info — re-query the neighbour
        // table to pick up whatever the echo populated.
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
        service.fireNotification(hostname, ip, mac)
      }
      service.pumpArpQueue()
    }
  }

  function fireNotification(hostname, ip, mac) {
    var key = Mdns.deviceKey(hostname, ip)
    var record = persisted.devices[key]
    var serviceType = (record && record.services && record.services.length > 0)
      ? record.services[0] : ""
    var displayName = (record && record.hostname) || Mdns.stripLocalSuffix(hostname) || ip
    var headline = "New device on the network: " + displayName
    var bodyLines = []
    bodyLines.push("IP: " + ip)
    if (mac) bodyLines.push("MAC: " + mac)
    if (serviceType) bodyLines.push("Service: " + serviceType)
    var body = bodyLines.join("\n")

    // -u low so the toast doesn't steal focus; -t 8000 = 8s on screen.
    // --app-name "leo.mdns" groups these in the notification history.
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
}