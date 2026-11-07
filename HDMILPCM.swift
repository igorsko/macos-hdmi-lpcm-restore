import Foundation
import CoreAudio
import AudioToolbox

struct Failure: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }
func check(_ s: OSStatus, _ what: String) throws { if s != noErr { throw Failure("\(what): OSStatus \(s)") } }
func addr(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector:s, mScope:scope, mElement:kAudioObjectPropertyElementMain)
}
func raw(_ id: AudioObjectID, _ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> Data {
    var a = addr(s, scope); var n: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(id, &a, 0, nil, &n), "size")
    if n == 0 { return Data() }
    var d = Data(count:Int(n))
    try d.withUnsafeMutableBytes { p in try check(AudioObjectGetPropertyData(id, &a, 0, nil, &n, p.baseAddress!), "read") }
    return d.prefix(Int(n))
}
func value<T: BitwiseCopyable>(_ id: AudioObjectID, _ s: AudioObjectPropertySelector, _ initial: T, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
    var v = initial; var n = UInt32(MemoryLayout<T>.size); var a = addr(s, scope)
    try check(AudioObjectGetPropertyData(id, &a, 0, nil, &n, &v), "read scalar")
    return v
}
func ids(_ id: AudioObjectID, _ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
    let d = try raw(id,s,scope)
    return d.withUnsafeBytes { Array($0.bindMemory(to:AudioObjectID.self)) }
}
func string(_ id: AudioObjectID, _ s: AudioObjectPropertySelector) throws -> String {
    var a = addr(s); var v: Unmanaged<CFString>?; var n = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try check(AudioObjectGetPropertyData(id, &a, 0, nil, &n, &v), "read string")
    guard let v else { throw Failure("Missing string") }; return v.takeRetainedValue() as String
}
func format(_ id: AudioObjectID, _ s: AudioObjectPropertySelector) throws -> AudioStreamBasicDescription {
    try value(id,s,AudioStreamBasicDescription())
}
func setFormat(_ id: AudioObjectID, _ s: AudioObjectPropertySelector, _ f: AudioStreamBasicDescription) throws {
    // This is deliberately the ONLY property write in the program.
    guard s == kAudioStreamPropertyPhysicalFormat || s == kAudioStreamPropertyVirtualFormat else { throw Failure("Forbidden property write") }
    var a = addr(s); var writable: DarwinBoolean = false
    try check(AudioObjectIsPropertySettable(id,&a,&writable),"settable")
    guard writable.boolValue else { throw Failure("Format is read-only") }
    var f = f
    try check(AudioObjectSetPropertyData(id,&a,0,nil,UInt32(MemoryLayout.size(ofValue:f)),&f),"set format")
}
func describe(_ f: AudioStreamBasicDescription) -> String { "\(f.mChannelsPerFrame)ch / \(Int(f.mSampleRate))Hz / \(f.mBitsPerChannel)bit / format \(f.mFormatID)" }
func target(_ f: AudioStreamBasicDescription, _ rate: Double) -> Bool { f.mFormatID == kAudioFormatLinearPCM && f.mChannelsPerFrame == 8 && f.mSampleRate == rate }
func same(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
    a.mSampleRate == b.mSampleRate && a.mFormatID == b.mFormatID && a.mFormatFlags == b.mFormatFlags && a.mBytesPerPacket == b.mBytesPerPacket && a.mFramesPerPacket == b.mFramesPerPacket && a.mBytesPerFrame == b.mBytesPerFrame && a.mChannelsPerFrame == b.mChannelsPerFrame && a.mBitsPerChannel == b.mBitsPerChannel
}
func candidate(_ stream: AudioObjectID, _ selector: AudioObjectPropertySelector, _ current: AudioStreamBasicDescription, _ rate: Double) throws -> AudioStreamBasicDescription {
    let data = try raw(stream,selector)
    let ranges = data.withUnsafeBytes { Array($0.bindMemory(to:AudioStreamRangedDescription.self)) }
    return try choose(ranges,current,rate)
}
func choose(_ ranges: [AudioStreamRangedDescription], _ current: AudioStreamBasicDescription, _ rate: Double) throws -> AudioStreamBasicDescription {
    let choices = ranges.filter { $0.mFormat.mFormatID == kAudioFormatLinearPCM && $0.mFormat.mChannelsPerFrame == 8 && $0.mSampleRateRange.mMinimum <= rate && $0.mSampleRateRange.mMaximum >= rate }
    let ranked = choices.sorted {
        func score(_ x: AudioStreamRangedDescription) -> Int { (x.mFormat.mBitsPerChannel == current.mBitsPerChannel ? 4 : 0) + (x.mFormat.mFormatFlags == current.mFormatFlags ? 2 : 0) }
        return score($0) > score($1)
    }
    guard var f = ranked.first?.mFormat else { throw Failure("8-channel LPCM at requested rate not advertised; no change") }
    f.mSampleRate = rate; return f
}
struct Config: Codable {
    let uid: String; let rate: Double
    var layout: Data; var stereo: Data
    let originalPhysical: Data; let originalVirtual: Data
    var persistedMapping: Data
    var busyPolicy: String? = nil // Missing in older configurations: preserve idle-only behavior.
}
enum BusyPolicy: String { case idle, reconnect }
func policy(_ c: Config) throws -> BusyPolicy {
    guard let p = BusyPolicy(rawValue:c.busyPolicy ?? "idle") else { throw Failure("Invalid busy policy") }; return p
}
// Monotonic time, independent of wall-clock corrections. State persists across event bursts.
struct RecoveryGate {
    var signature: Data?
    var stableSince: Double = 0
    var lastAttempt: Double?
    mutating func observe(_ next: Data, now: Double) {
        if signature != next { signature = next; stableSince = now }
    }
    mutating func invalidate() { signature = nil }
    func canAttempt(now: Double) -> Bool { lastAttempt.map { now - $0 >= 60 } ?? true }
    func allowBusy(_ mode: BusyPolicy, stereo: Bool, now: Double) -> Bool {
        mode == .reconnect && stereo && signature != nil && now - stableSince >= 8 && canAttempt(now:now)
    }
}
func saveConfig(_ c: Config, to path: String) throws {
    _ = try policy(c)
    let url = URL(fileURLWithPath:path)
    let old = try Data(contentsOf:url)
    let folder = url.deletingLastPathComponent().appendingPathComponent("config-backups",isDirectory:true)
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    let backup = folder.appendingPathComponent(UUID().uuidString + ".json")
    try old.write(to:backup,options:.withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:backup.path)
    try JSONEncoder().encode(c).write(to:url,options:.atomic)
    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path)
    print("Configuration saved; previous configuration retained in config-backups. No audio properties written.")
}
func audioClients(_ d: AudioObjectID) -> [String] {
    if #available(macOS 14.2, *) {
        guard let processes = try? ids(AudioObjectID(kAudioObjectSystemObject),kAudioHardwarePropertyProcessObjectList) else { return ["unavailable"] }
        return processes.compactMap { p in
            guard let used = try? ids(p,kAudioProcessPropertyDevices,kAudioObjectPropertyScopeOutput), used.contains(d),
                  (try? value(p,kAudioProcessPropertyIsRunningOutput,UInt32(0))) == 1 else { return nil }
            return (try? string(p,kAudioProcessPropertyBundleID)) ?? "unidentified audio client"
        }
    }
    return ["unavailable on this macOS version"]
}
func bytes(_ f: AudioStreamBasicDescription) -> Data { var f = f; return withUnsafeBytes(of:&f) { Data($0) } }
func decode(_ d: Data) throws -> AudioStreamBasicDescription {
    guard d.count == MemoryLayout<AudioStreamBasicDescription>.size else { throw Failure("Invalid saved format") }
    return d.withUnsafeBytes { $0.loadUnaligned(as:AudioStreamBasicDescription.self) }
}
func devices() throws -> [AudioObjectID] { try ids(AudioObjectID(kAudioObjectSystemObject),kAudioHardwarePropertyDevices) }
func device(_ c: Config) throws -> AudioObjectID {
    let found = try devices().filter { try string($0,kAudioDevicePropertyDeviceUID) == c.uid }
    guard found.count == 1, let d = found.first else { throw Failure("Configured HDMI device absent or ambiguous") }
    guard try value(d,kAudioDevicePropertyTransportType,UInt32(0)) == kAudioDeviceTransportTypeHDMI else { throw Failure("Target is not HDMI") }
    return d
}
func stream(_ d: AudioObjectID) throws -> AudioObjectID {
    let s = try ids(d,kAudioDevicePropertyStreams,kAudioObjectPropertyScopeOutput)
    guard s.count == 1 else { throw Failure("Expected exactly one output stream") }; return s[0]
}
func mappings(_ d: AudioObjectID) throws -> (Data,Data) {
    (try raw(d,kAudioDevicePropertyPreferredChannelLayout,kAudioObjectPropertyScopeOutput), try raw(d,kAudioDevicePropertyPreferredChannelsForStereo,kAudioObjectPropertyScopeOutput))
}
// Read-only safeguard for the saved surround mapping. This plist is not a public API;
// missing or changed schema fails closed rather than guessing a replacement mapping.
func savedMapping(_ uid: String) throws -> Data {
    let data = try Data(contentsOf:URL(fileURLWithPath:"/Library/Preferences/Audio/com.apple.audio.SystemSettings.plist"))
    guard let root = try PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any],
          let dev = root["device." + uid] as? [String:Any],
          let surround = dev["output.surround"], let left = dev["output.stereo.left"], let right = dev["output.stereo.right"] else { throw Failure("Saved mapping unavailable; no changes") }
    return try PropertyListSerialization.data(fromPropertyList:["surround":surround,"left":left,"right":right],format:.binary,options:0)
}
func savedEqual(_ a: Data, _ b: Data) throws -> Bool {
    guard let aa = try PropertyListSerialization.propertyList(from:a,format:nil) as? NSDictionary,
          let bb = try PropertyListSerialization.propertyList(from:b,format:nil) as? NSDictionary else { return false }
    return aa.isEqual(bb)
}
func stereoProjection(_ baseline: Data) -> Data? {
    guard baseline.count == 12 + 8 * 20 else { return nil }
    let header = baseline.withUnsafeBytes { ($0.loadUnaligned(as:UInt32.self), $0.loadUnaligned(fromByteOffset:8,as:UInt32.self)) }
    guard header.0 == 0 && header.1 == 8 else { return nil }
    var projected = baseline.prefix(12 + 2 * 20)
    var count: UInt32 = 2
    withUnsafeBytes(of:&count) { projected.replaceSubrange(8..<12,with:$0) }
    return Data(projected)
}
func guardMapping(_ d: AudioObjectID, _ c: Config, allowStereo: Bool = false) throws {
    let (l,s) = try mappings(d)
    guard try savedEqual(savedMapping(c.uid),c.persistedMapping), s == c.stereo else { throw Failure("Saved mapping or stereo assignment differs; refusing format write") }
    if l == c.layout { return }
    if allowStereo, stereoProjection(c.layout) == l {
        let streamID = try stream(d)
        let p = try format(streamID,kAudioStreamPropertyPhysicalFormat), v = try format(streamID,kAudioStreamPropertyVirtualFormat)
        if p.mFormatID == kAudioFormatLinearPCM && v.mFormatID == kAudioFormatLinearPCM &&
           [UInt32(2),UInt32(8)].contains(p.mChannelsPerFrame) && [UInt32(2),UInt32(8)].contains(v.mChannelsPerFrame) &&
           (p.mChannelsPerFrame == 2 || v.mChannelsPerFrame == 2) { return }
    }
    throw Failure("Mapping differs from saved baseline; refusing format write")
}
func log(_ s: String) { print("\(ISO8601DateFormatter().string(from:Date())) \(s)"); fflush(stdout) }
// Called on a serial non-realtime queue. No playback, default-output, volume or layout writes.
@discardableResult
func apply(_ c: Config, restore: Bool = false, allowBusy: Bool = false) throws -> Bool {
    let d = try device(c); let s = try stream(d)
    try guardMapping(d,c,allowStereo:true)
    let p = try format(s,kAudioStreamPropertyPhysicalFormat), v = try format(s,kAudioStreamPropertyVirtualFormat)
    if !restore && target(p,c.rate) && target(v,c.rate) { log("Already correct; no writes"); return false }
    let running = try value(d,kAudioDevicePropertyDeviceIsRunningSomewhere,UInt32(0))
    guard running == 0 || allowBusy else { throw Failure("Audio device busy; clients: " + audioClients(d).joined(separator:", ")) }
    if let hog = try? value(d,kAudioDevicePropertyHogMode,Int32(-1)), hog != -1 { throw Failure("Device exclusively owned by another process; no changes") }
    if running != 0 { log("Recovering stable stereo fallback while audio is active; a brief interruption is possible") }
    let pp = try restore ? decode(c.originalPhysical) : candidate(s,kAudioStreamPropertyAvailablePhysicalFormats,p,c.rate)
    let vv = try restore ? decode(c.originalVirtual) : candidate(s,kAudioStreamPropertyAvailableVirtualFormats,v,c.rate)
    do {
        if !same(p,pp) { try setFormat(s,kAudioStreamPropertyPhysicalFormat,pp); Thread.sleep(forTimeInterval:0.25) }
        try guardMapping(d,c,allowStereo:true)
        if !same(try format(s,kAudioStreamPropertyVirtualFormat),vv) { try setFormat(s,kAudioStreamPropertyVirtualFormat,vv) }
        Thread.sleep(forTimeInterval:0.4)
        try guardMapping(d,c)
        let actualP = try format(s,kAudioStreamPropertyPhysicalFormat), actualV = try format(s,kAudioStreamPropertyVirtualFormat)
        guard restore ? (same(actualP,pp) && same(actualV,vv)) : (target(actualP,c.rate) && target(actualV,c.rate)) else { throw Failure("Readback mismatch") }
        log("Verified physical + virtual: \(describe(actualP)); mapping unchanged")
        return true
    } catch {
        // Best effort format rollback only. Never rewrite speaker mapping, even on failure.
        do { try setFormat(s,kAudioStreamPropertyPhysicalFormat,p); try setFormat(s,kAudioStreamPropertyVirtualFormat,v); log("Previous formats restored after failure") }
        catch { log("Format rollback failed: \(error)") }
        throw error
    }
}
final class Watcher {
    let c: Config
    let q = DispatchQueue(label:"native.hdmi.lpcm")
    var listeners: [(AudioObjectID,AudioObjectPropertyAddress,AudioObjectPropertyListenerBlock)] = []
    var windowActive = false
    var gate = RecoveryGate()
    init(_ c: Config) { self.c = c }
    func add(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) {
        var a = addr(sel,scope)
        guard AudioObjectHasProperty(id,&a) else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _,_ in self?.event(invalidate:sel != kAudioDevicePropertyDeviceIsRunningSomewhere) }
        let status = AudioObjectAddPropertyListenerBlock(id,&a,q,block)
        if status == 0 { listeners.append((id,a,block)) } else { log("Listener registration failed: \(status)") }
    }
    func rebind() {
        for (id,var a,b) in listeners { AudioObjectRemovePropertyListenerBlock(id,&a,q,b) }
        listeners.removeAll()
        add(AudioObjectID(kAudioObjectSystemObject),kAudioHardwarePropertyDevices)
        add(AudioObjectID(kAudioObjectSystemObject),kAudioHardwarePropertyServiceRestarted)
        if let d = try? device(c) {
            add(d,kAudioDevicePropertyStreams,kAudioObjectPropertyScopeOutput)
            add(d,kAudioDevicePropertyDeviceIsAlive)
            add(d,kAudioDevicePropertyDeviceIsRunningSomewhere)
            add(d,kAudioDevicePropertyNominalSampleRate)
            add(d,kAudioDevicePropertyPreferredChannelLayout,kAudioObjectPropertyScopeOutput)
            add(d,kAudioDevicePropertyPreferredChannelsForStereo,kAudioObjectPropertyScopeOutput)
            if let s = try? stream(d) {
                for sel in [kAudioStreamPropertyPhysicalFormat,kAudioStreamPropertyVirtualFormat,kAudioStreamPropertyAvailablePhysicalFormats,kAudioStreamPropertyAvailableVirtualFormats] { add(s,sel) }
            }
        }
    }
    func attempt() {
        rebind()
        let now = ProcessInfo.processInfo.systemUptime
        do {
            let d = try device(c), s = try stream(d)
            try guardMapping(d,c,allowStereo:true)
            let p = try format(s,kAudioStreamPropertyPhysicalFormat), v = try format(s,kAudioStreamPropertyVirtualFormat)
            if target(p,c.rate) && target(v,c.rate) { gate.invalidate(); return }
            // Both advertised targets must be stable, together with the current device, stream and formats.
            let pp = try candidate(s,kAudioStreamPropertyAvailablePhysicalFormats,p,c.rate)
            let vv = try candidate(s,kAudioStreamPropertyAvailableVirtualFormats,v,c.rate)
            var signature = Data("\(d):\(s):".utf8)
            for f in [p,v,pp,vv] { signature.append(bytes(f)) }
            gate.observe(signature,now:now)
            let stereo = p.mFormatID == kAudioFormatLinearPCM && v.mFormatID == kAudioFormatLinearPCM &&
                         (p.mChannelsPerFrame == 2 || v.mChannelsPerFrame == 2)
            let busy = try value(d,kAudioDevicePropertyDeviceIsRunningSomewhere,UInt32(0)) != 0
            let allow = gate.allowBusy(try policy(c),stereo:stereo,now:now)
            if busy && !allow {
                log("Waiting for idle or stable stereo recovery; clients: " + audioClients(d).joined(separator:", "))
                return
            }
            guard gate.canAttempt(now:now) else { log("Recovery cooldown; no writes"); return }
            // Count failed writes too: an application or driver must not provoke a format fight.
            gate.lastAttempt = now
            try apply(c,allowBusy:allow)
            gate.invalidate()
        } catch { gate.invalidate(); log("Deferred (will recheck on HDMI/mapping events): \(error)") }
    }
    func event(invalidate: Bool = true) {
        if invalidate { gate.invalidate() }
        // Events join the active window instead of postponing recovery indefinitely.
        guard !windowActive else { return }
        windowActive = true
        for delay in [1.0,3.0,7.0,12.0,20.0,35.0,60.0,75.0] {
            q.asyncAfter(deadline:.now()+delay) { [self] in
                attempt()
                if delay == 75 { windowActive = false }
            }
        }
    }
    func start() { q.async { self.rebind(); self.event(); log("CoreAudio listener active") } }
}
let args = CommandLine.arguments
func usage() -> Never { fputs("Usage: hdmi-lpcm list | capture UID RATE CONFIG | check CONFIG | once CONFIG | watch CONFIG | restore CONFIG | status CONFIG | policy CONFIG idle|reconnect | accept-mapping CONFIG\n",stderr); exit(2) }
do {
    guard args.count > 1 else { usage() }
    switch args[1] {
    case "self-test":
        func expect(_ condition: Bool, _ message: String) throws { if !condition { throw Failure("Test failed: " + message) } }
        func ranged(_ channels: UInt32, _ rate: Double, _ bits: UInt32, _ id: UInt32 = kAudioFormatLinearPCM) -> AudioStreamRangedDescription {
            var f = AudioStreamBasicDescription(); f.mChannelsPerFrame = channels; f.mSampleRate = rate; f.mFormatID = id; f.mBitsPerChannel = bits
            return AudioStreamRangedDescription(mFormat:f,mSampleRateRange:AudioValueRange(mMinimum:rate,mMaximum:rate))
        }
        let current = ranged(2,48000,24).mFormat
        let desired = try choose([ranged(2,192000,24),ranged(8,48000,24),ranged(8,192000,16),ranged(8,192000,24),ranged(8,192000,24,123)],current,192000)
        try expect(target(desired,192000) && desired.mBitsPerChannel == 24,"advertised LPCM, channel count, exact rate, bit depth")
        do { _ = try choose([ranged(2,192000,24),ranged(8,48000,24),ranged(8,192000,24,123)],current,192000); throw Failure("Unsupported format accepted") }
        catch let e as Failure { if e.description == "Unsupported format accepted" { throw e } }
        var broad = ranged(8,48000,24); broad.mSampleRateRange.mMaximum = 192000
        let expanded = try choose([broad],current,192000); try expect(expanded.mSampleRate == 192000,"rate ranges")
        let decoded = try decode(bytes(desired)); try expect(same(decoded,desired),"format snapshot roundtrip")
        do { _ = try decode(Data([0])); throw Failure("Bad snapshot accepted") }
        catch let e as Failure { if e.description == "Bad snapshot accepted" { throw e } }
        var layout = Data(count:12 + 8 * 20)
        var eight: UInt32 = 8
        withUnsafeBytes(of:&eight) { layout.replaceSubrange(8..<12,with:$0) }
        guard let projection = stereoProjection(layout) else { throw Failure("Stereo projection missing") }
        try expect(projection.count == 52 && stereoProjection(projection) == nil,"only explicit eight-channel baseline projects")
        let savedA = try PropertyListSerialization.data(fromPropertyList:["a":1,"b":[2,3]],format:.binary,options:0)
        let savedB = try PropertyListSerialization.data(fromPropertyList:["b":[2,3],"a":1],format:.xml,options:0)
        let savedC = try PropertyListSerialization.data(fromPropertyList:["b":[2,4],"a":1],format:.binary,options:0)
        let equal = try savedEqual(savedA,savedB), unequal = try savedEqual(savedA,savedC)
        try expect(equal && !unequal,"saved mapping semantic equality and changed channel rejection")
        var gate = RecoveryGate()
        gate.observe(Data([1]),now:100)
        try expect(!gate.allowBusy(.idle,stereo:true,now:120),"idle policy never interrupts")
        try expect(!gate.allowBusy(.reconnect,stereo:true,now:107),"no busy write before stability interval")
        try expect(gate.allowBusy(.reconnect,stereo:true,now:108),"stable stereo fallback can recover")
        try expect(!gate.allowBusy(.reconnect,stereo:false,now:120),"busy multichannel rate changes stay deferred")
        gate.observe(Data([2]),now:109)
        try expect(!gate.allowBusy(.reconnect,stereo:true,now:110),"format changes reset stability")
        gate.lastAttempt = 110
        try expect(!gate.allowBusy(.reconnect,stereo:true,now:169),"cooldown blocks repeated writes")
        try expect(gate.allowBusy(.reconnect,stereo:true,now:170),"cooldown expires")
        gate.invalidate()
        try expect(!gate.allowBusy(.reconnect,stereo:true,now:200),"absent or invalid mapping clears stability")
        print("PASS: format selection, snapshots, mapping guards, reconnect stability and write cooldown")
    case "list":
        for d in try devices() {
            print("name=\(try string(d,kAudioObjectPropertyName)) uid=\(try string(d,kAudioDevicePropertyDeviceUID)) transport=\(try value(d,kAudioDevicePropertyTransportType,UInt32(0)))")
            if let s = try? stream(d) { print("  physical \(describe(try format(s,kAudioStreamPropertyPhysicalFormat)))\n  virtual  \(describe(try format(s,kAudioStreamPropertyVirtualFormat)))") }
        }
    case "capture":
        guard args.count == 5, let rate = Double(args[3]), [48000.0,96000.0,192000.0].contains(rate) else { usage() }
        guard !FileManager.default.fileExists(atPath:args[4]) else { throw Failure("Refusing to overwrite baseline") }
        let ds = try devices().filter { try string($0,kAudioDevicePropertyDeviceUID) == args[2] }
        guard ds.count == 1 else { throw Failure("UID absent or ambiguous") }; let d = ds[0]; let s = try stream(d); let (l,st) = try mappings(d)
        let c = Config(uid:args[2],rate:rate,layout:l,stereo:st,originalPhysical:bytes(try format(s,kAudioStreamPropertyPhysicalFormat)),originalVirtual:bytes(try format(s,kAudioStreamPropertyVirtualFormat)),persistedMapping:try savedMapping(args[2]))
        _ = try device(c)
        guard stereoProjection(l) != nil else { throw Failure("Capture requires an existing explicit 8-channel speaker mapping") }
        _ = try candidate(s,kAudioStreamPropertyAvailablePhysicalFormats,try format(s,kAudioStreamPropertyPhysicalFormat),rate)
        _ = try candidate(s,kAudioStreamPropertyAvailableVirtualFormats,try format(s,kAudioStreamPropertyVirtualFormat),rate)
        try JSONEncoder().encode(c).write(to:URL(fileURLWithPath:args[4]),options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:args[4]); print("Baseline saved; no audio writes")
    case "check", "once", "watch", "restore", "status", "policy", "accept-mapping":
        guard args.count == (args[1] == "policy" ? 4 : 3) else { usage() }
        var c = try JSONDecoder().decode(Config.self,from:Data(contentsOf:URL(fileURLWithPath:args[2])))
        guard [48000.0,96000.0,192000.0].contains(c.rate) else { throw Failure("Invalid configured rate") }
        _ = try policy(c)
        if args[1] == "policy" {
            guard let p = BusyPolicy(rawValue:args[3]) else { throw Failure("Policy must be idle or reconnect") }
            c.busyPolicy = p.rawValue; try saveConfig(c,to:args[2])
        } else if args[1] == "accept-mapping" {
            let d = try device(c), s = try stream(d)
            let (l,st) = try mappings(d)
            guard stereoProjection(l) != nil,
                  target(try format(s,kAudioStreamPropertyPhysicalFormat),c.rate),
                  target(try format(s,kAudioStreamPropertyVirtualFormat),c.rate) else { throw Failure("Set the correct eight-channel format and mapping in Audio MIDI Setup first") }
            let saved = try savedMapping(c.uid)
            Thread.sleep(forTimeInterval:0.5)
            let (nextL,nextSt) = try mappings(d)
            let savedUnchanged = try savedEqual(saved,savedMapping(c.uid))
            guard nextL == l && nextSt == st && savedUnchanged else { throw Failure("Mapping still changing; try again after HDMI settles") }
            c.layout = l; c.stereo = st; c.persistedMapping = saved
            // Keep original stream formats for rollback. Only explicit mapping acceptance changes the baseline.
            try saveConfig(c,to:args[2])
        } else if args[1] == "status" {
            let d = try device(c), s = try stream(d)
            print("Busy policy: \(try policy(c).rawValue)")
            print("Physical: \(describe(try format(s,kAudioStreamPropertyPhysicalFormat))); virtual: \(describe(try format(s,kAudioStreamPropertyVirtualFormat)))")
            print("Active audio clients: " + audioClients(d).joined(separator:", "))
            do { try guardMapping(d,c,allowStereo:true); print("Mapping guard: verified (temporary stereo fallback allowed)") }
            catch { print("Mapping guard: BLOCKED: \(error)"); exit(1) }
        } else if args[1] == "check" {
            let d = try device(c); let s = try stream(d); try guardMapping(d,c)
            print("Mapping matches baseline. Physical: \(describe(try format(s,kAudioStreamPropertyPhysicalFormat))); virtual: \(describe(try format(s,kAudioStreamPropertyVirtualFormat)))")
        } else if args[1] == "watch" { let w = Watcher(c); w.start(); withExtendedLifetime(w) { dispatchMain() } }
        else { try apply(c,restore:args[1] == "restore") }
    default: usage()
    }
} catch { fputs("\(error)\n",stderr); exit(1) }
