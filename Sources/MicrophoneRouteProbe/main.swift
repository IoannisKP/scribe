import AudioCapture
@preconcurrency import AVFoundation
@preconcurrency import AudioToolbox
@preconcurrency import CoreAudio
import Darwin
import Foundation

// A standalone hardware diagnostic for the Bluetooth microphone capture bug.
//
// It reproduces the exact sequence MicrophoneCaptureService uses (resolve the
// default input device, bind the AUHAL, read the post-binding input format,
// install a tap with that format, start the engine) and then reports, on a
// timeline, what Core Audio actually does while an AirPods-style device
// switches into headset mode.
//
// Run it from Terminal so the microphone TCC prompt is attributable:
//
//     swift run MicrophoneRouteProbe
//     swift run MicrophoneRouteProbe --settle-ms 1500
//
// Options:
//     --settle-ms <n>   Wait n milliseconds after binding before reading the
//                       input format and installing the tap. Use this to test
//                       whether waiting for route stability fixes capture.
//     --watch-s <n>     Seconds to observe the first tap before rebuilding.

// MARK: - Argument parsing

let arguments = CommandLine.arguments

func integerOption(_ name: String, default defaultValue: Int) -> Int {
    guard
        let index = arguments.firstIndex(of: name),
        index + 1 < arguments.count,
        let value = Int(arguments[index + 1])
    else {
        return defaultValue
    }
    return value
}

let settleMilliseconds = integerOption("--settle-ms", default: 0)
let watchSeconds = integerOption("--watch-s", default: 20)

// MARK: - Timeline logging

let probeStart = Date()

final class Timeline: @unchecked Sendable {
    private let lock = NSLock()

    func log(_ message: String) {
        let elapsed = Date().timeIntervalSince(probeStart)
        lock.lock()
        print(String(format: "[%7.3fs] %@", elapsed, message))
        fflush(stdout)
        lock.unlock()
    }
}

let timeline = Timeline()

// MARK: - Tap accounting

final class TapCounters: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var callbackCount = 0
    private(set) var frameCount: Int64 = 0
    private(set) var zeroFrameCallbackCount = 0
    private(set) var nilChannelDataCallbackCount = 0
    private(set) var firstBufferDescription: String?
    private(set) var lastCallbackAt: Date?

    func record(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        callbackCount += 1
        lastCallbackAt = Date()
        if firstBufferDescription == nil {
            firstBufferDescription = describe(buffer.format)
                + ", frameLength \(buffer.frameLength)"
                + ", frameCapacity \(buffer.frameCapacity)"
        }
        if buffer.floatChannelData == nil {
            nilChannelDataCallbackCount += 1
        }
        if buffer.frameLength == 0 {
            zeroFrameCallbackCount += 1
        }
        frameCount += Int64(buffer.frameLength)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        callbackCount = 0
        frameCount = 0
        zeroFrameCallbackCount = 0
        nilChannelDataCallbackCount = 0
        firstBufferDescription = nil
        lastCallbackAt = nil
    }

    var summary: String {
        lock.lock()
        defer { lock.unlock() }
        return "callbacks \(callbackCount), frames \(frameCount)"
            + ", zero-frame \(zeroFrameCallbackCount)"
            + ", nil-channel \(nilChannelDataCallbackCount)"
    }
}

let counters = TapCounters()

// MARK: - Core Audio helpers

func describe(_ status: OSStatus) -> String {
    var bigEndian = UInt32(bitPattern: status).bigEndian
    let characters = withUnsafeBytes(of: &bigEndian) { bytes in
        bytes.map { byte -> Character in
            let printable = byte >= 32 && byte <= 126
            return printable ? Character(UnicodeScalar(byte)) : "?"
        }
    }
    let code = String(characters)
    return code.allSatisfy { $0 == "?" } ? "\(status)" : "'\(code)' (\(status))"
}

func describe(_ format: AVAudioFormat) -> String {
    let common: String
    switch format.commonFormat {
    case .pcmFormatFloat32: common = "Float32"
    case .pcmFormatFloat64: common = "Float64"
    case .pcmFormatInt16: common = "Int16"
    case .pcmFormatInt32: common = "Int32"
    case .otherFormat: common = "other"
    @unknown default: common = "unknown"
    }
    let layout = format.isInterleaved ? "interleaved" : "noninterleaved"
    return String(
        format: "%.0f Hz, %u ch, %@, %@",
        format.sampleRate,
        format.channelCount,
        common,
        layout
    )
}

func describe(_ description: AudioStreamBasicDescription) -> String {
    String(
        format: "%.0f Hz, %u ch, %u bits, flags 0x%x",
        description.mSampleRate,
        description.mChannelsPerFrame,
        description.mBitsPerChannel,
        description.mFormatFlags
    )
}

func defaultInputDeviceID() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &size,
        &deviceID
    )
    guard status == noErr, deviceID != kAudioObjectUnknown else {
        return nil
    }
    return deviceID
}

func stringProperty(
    _ selector: AudioObjectPropertySelector,
    of deviceID: AudioObjectID
) -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var unmanaged: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(
        deviceID, &address, 0, nil, &size, &unmanaged
    )
    guard status == noErr, let unmanaged else {
        return "<unavailable>"
    }
    return unmanaged.takeRetainedValue() as String
}

func nominalSampleRate(of deviceID: AudioObjectID) -> Double? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var rate = Double(0)
    var size = UInt32(MemoryLayout<Double>.size)
    let status = AudioObjectGetPropertyData(
        deviceID, &address, 0, nil, &size, &rate
    )
    return status == noErr ? rate : nil
}

func availableSampleRates(of deviceID: AudioObjectID) -> [String] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32(0)
    guard
        AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
            == noErr,
        size > 0
    else {
        return []
    }
    let count = Int(size) / MemoryLayout<AudioValueRange>.size
    var ranges = [AudioValueRange](
        repeating: AudioValueRange(mMinimum: 0, mMaximum: 0),
        count: count
    )
    guard
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &ranges)
            == noErr
    else {
        return []
    }
    return ranges.map { range in
        range.mMinimum == range.mMaximum
            ? String(format: "%.0f", range.mMinimum)
            : String(format: "%.0f-%.0f", range.mMinimum, range.mMaximum)
    }
}

func inputChannelCount(of deviceID: AudioObjectID) -> Int {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32(0)
    guard
        AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
            == noErr,
        size > 0
    else {
        return 0
    }
    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size),
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { raw.deallocate() }
    guard
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw)
            == noErr
    else {
        return 0
    }
    let list = UnsafeMutableAudioBufferListPointer(
        raw.assumingMemoryBound(to: AudioBufferList.self)
    )
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func allDeviceIDs() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32(0)
    guard
        AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr
    else {
        return []
    }
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &ids
        ) == noErr
    else {
        return []
    }
    return ids
}

func audioUnitStreamFormat(
    _ audioUnit: AudioUnit,
    scope: AudioUnitScope,
    element: AudioUnitElement
) -> String {
    var description = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let status = AudioUnitGetProperty(
        audioUnit,
        kAudioUnitProperty_StreamFormat,
        scope,
        element,
        &description,
        &size
    )
    guard status == noErr else {
        return "<error \(describe(status))>"
    }
    return describe(description)
}

// MARK: - Device inventory

print("")
print("Scribe microphone route probe")
print("settle-ms \(settleMilliseconds), watch-s \(watchSeconds)")
print(String(repeating: "=", count: 78))
print("")
print("Input-capable devices:")
for deviceID in allDeviceIDs() {
    let channels = inputChannelCount(of: deviceID)
    guard channels > 0 else {
        continue
    }
    let name = stringProperty(kAudioObjectPropertyName, of: deviceID)
    let uid = stringProperty(kAudioDevicePropertyDeviceUID, of: deviceID)
    let rate = nominalSampleRate(of: deviceID).map {
        String(format: "%.0f Hz", $0)
    } ?? "<unavailable>"
    let rates = availableSampleRates(of: deviceID).joined(separator: ", ")
    print("  [\(deviceID)] \(name)")
    print("        uid       \(uid)")
    print("        channels  \(channels)")
    print("        nominal   \(rate)")
    print("        available \(rates.isEmpty ? "<unavailable>" : rates)")
}
print("")

guard let initialDeviceID = defaultInputDeviceID() else {
    print("No default input device. Connect a microphone and retry.")
    exit(1)
}

let initialName = stringProperty(kAudioObjectPropertyName, of: initialDeviceID)
let initialUID = stringProperty(
    kAudioDevicePropertyDeviceUID, of: initialDeviceID
)
timeline.log(
    "default input is [\(initialDeviceID)] \(initialName) (\(initialUID))"
)

// MARK: - Property listeners

var listenerAddresses: [(AudioObjectID, AudioObjectPropertyAddress)] = []

@MainActor
func watch(
    _ deviceID: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope,
    label: String,
    detail: @escaping @Sendable (AudioObjectID) -> String
) {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectAddPropertyListenerBlock(
        deviceID, &address, nil
    ) { @Sendable _, _ in
        timeline.log("PROPERTY \(label) -> \(detail(deviceID))")
    }
    if status == noErr {
        listenerAddresses.append((deviceID, address))
    } else {
        timeline.log("could not watch \(label): \(describe(status))")
    }
}

watch(
    initialDeviceID,
    kAudioDevicePropertyNominalSampleRate,
    kAudioObjectPropertyScopeGlobal,
    label: "device nominal sample rate"
) { deviceID in
    nominalSampleRate(of: deviceID).map { String(format: "%.0f Hz", $0) }
        ?? "<unavailable>"
}

watch(
    initialDeviceID,
    kAudioDevicePropertyStreamConfiguration,
    kAudioObjectPropertyScopeInput,
    label: "device input stream configuration"
) { deviceID in
    "\(inputChannelCount(of: deviceID)) ch"
}

watch(
    initialDeviceID,
    kAudioDevicePropertyDeviceIsAlive,
    kAudioObjectPropertyScopeGlobal,
    label: "device is-alive"
) { _ in "changed" }

watch(
    AudioObjectID(kAudioObjectSystemObject),
    kAudioHardwarePropertyDefaultInputDevice,
    kAudioObjectPropertyScopeGlobal,
    label: "system default input device"
) { _ in
    guard let deviceID = defaultInputDeviceID() else {
        return "<none>"
    }
    let name = stringProperty(kAudioObjectPropertyName, of: deviceID)
    return "[\(deviceID)] \(name)"
}

// MARK: - Engine

let engine = AVAudioEngine()

let configurationObserver = NotificationCenter.default.addObserver(
    forName: .AVAudioEngineConfigurationChange,
    object: engine,
    queue: nil
) { @Sendable _ in
    timeline.log("NOTIFICATION AVAudioEngineConfigurationChange")
}

@MainActor
func bindDefaultInput() -> AudioDeviceID? {
    guard let deviceID = defaultInputDeviceID() else {
        timeline.log("bind failed: no default input device")
        return nil
    }
    guard let audioUnit = engine.inputNode.audioUnit else {
        timeline.log("bind failed: input node has no audio unit")
        return nil
    }
    var requested = deviceID
    let setStatus = AudioUnitSetProperty(
        audioUnit,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &requested,
        UInt32(MemoryLayout<AudioDeviceID>.size)
    )
    guard setStatus == noErr else {
        timeline.log("bind failed: set CurrentDevice \(describe(setStatus))")
        return nil
    }
    var bound = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let getStatus = AudioUnitGetProperty(
        audioUnit,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &bound,
        &size
    )
    guard getStatus == noErr else {
        timeline.log("bind failed: get CurrentDevice \(describe(getStatus))")
        return nil
    }
    timeline.log("bound AUHAL CurrentDevice: requested \(deviceID), read back \(bound)")
    return bound == deviceID ? deviceID : nil
}

@MainActor
func reportFormats(_ label: String) {
    let inputFormat = engine.inputNode.inputFormat(forBus: 0)
    let outputFormat = engine.inputNode.outputFormat(forBus: 0)
    timeline.log("\(label) inputNode.inputFormat  = \(describe(inputFormat))")
    timeline.log("\(label) inputNode.outputFormat = \(describe(outputFormat))")
    if let audioUnit = engine.inputNode.audioUnit {
        timeline.log(
            "\(label) AUHAL in-scope  el1 = "
                + audioUnitStreamFormat(
                    audioUnit, scope: kAudioUnitScope_Input, element: 1
                )
        )
        timeline.log(
            "\(label) AUHAL out-scope el1 = "
                + audioUnitStreamFormat(
                    audioUnit, scope: kAudioUnitScope_Output, element: 1
                )
        )
    }
    if let deviceID = defaultInputDeviceID() {
        let rate = nominalSampleRate(of: deviceID).map {
            String(format: "%.0f Hz", $0)
        } ?? "<unavailable>"
        let supported = availableSampleRates(of: deviceID).joined(
            separator: ", "
        )
        timeline.log(
            "\(label) device [\(deviceID)] nominal \(rate)"
                + ", \(inputChannelCount(of: deviceID)) ch"
                + ", supports [\(supported)]"
        )
    }
}

@discardableResult
@MainActor
func startCapture(label: String, settleMilliseconds: Int) -> Bool {
    timeline.log("--- \(label): resolving and binding input device")
    guard bindDefaultInput() != nil else {
        return false
    }

    if settleMilliseconds > 0 {
        timeline.log("--- \(label): waiting \(settleMilliseconds) ms for route settle")
        Thread.sleep(forTimeInterval: Double(settleMilliseconds) / 1_000)
    }

    reportFormats("\(label) pre-tap ")

    let tapFormat = engine.inputNode.inputFormat(forBus: 0)
    guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else {
        timeline.log("--- \(label): refusing to install tap on \(describe(tapFormat))")
        return false
    }

    timeline.log("--- \(label): installing tap with \(describe(tapFormat))")
    engine.inputNode.installTap(
        onBus: 0,
        bufferSize: 1_024,
        format: tapFormat
    ) { @Sendable buffer, _ in
        counters.record(buffer)
    }

    engine.prepare()
    do {
        try engine.start()
        timeline.log("--- \(label): engine.start() succeeded, isRunning \(engine.isRunning)")
    } catch {
        timeline.log("--- \(label): engine.start() FAILED \(error.localizedDescription)")
        return false
    }
    reportFormats("\(label) post-start ")
    return true
}

@MainActor
func stopCapture(label: String) {
    timeline.log("--- \(label): stopping engine and removing tap")
    engine.stop()
    engine.inputNode.removeTap(onBus: 0)
    engine.reset()
}

@MainActor
func observe(seconds: Int, label: String) {
    let deadline = Date().addingTimeInterval(Double(seconds))
    var lastSummary = ""
    var tick = 0
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        tick += 1
        let summary = counters.summary
        let changed = summary != lastSummary
        if changed || tick % 8 == 0 {
            let rate = defaultInputDeviceID()
                .flatMap { nominalSampleRate(of: $0) }
                .map { String(format: "%.0f Hz", $0) } ?? "?"
            timeline.log(
                "\(label) \(summary), engine.isRunning \(engine.isRunning)"
                    + ", device \(rate)"
                    + ", node in \(describe(engine.inputNode.inputFormat(forBus: 0)))"
            )
            lastSummary = summary
        }
    }
}

// MARK: - System tap rate observation

func defaultOutputDeviceID() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
    )
    guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
    return deviceID
}

func processTapFormat(_ tapID: AudioObjectID) -> AudioStreamBasicDescription? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var format = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let status = AudioObjectGetPropertyData(
        tapID, &address, 0, nil, &size, &format
    )
    return status == noErr ? format : nil
}

/// Answers whether the system tap's format, which the production resampler is
/// configured from, tracks a Bluetooth output device switching into headset
/// mode. If it does not change, no tap-format listener can fire and a rate
/// captured at prewarm stays stale for the whole session.
@MainActor
func runSystemTapMode() async {
    let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
    description.isPrivate = true
    description.muteBehavior = .unmuted
    var tapID = AudioObjectID(kAudioObjectUnknown)
    let status = AudioHardwareCreateProcessTap(description, &tapID)
    guard status == noErr, tapID != kAudioObjectUnknown else {
        timeline.log("TAP creation failed \(describe(status))")
        return
    }
    defer { AudioHardwareDestroyProcessTap(tapID) }
    timeline.log("TAP created, id \(tapID)")

    var sawTapFormatChange = false
    var tapAddress = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    _ = AudioObjectAddPropertyListenerBlock(tapID, &tapAddress, nil) { @Sendable _, _ in
        timeline.log("LISTENER kAudioTapPropertyFormat fired")
    }

    func snapshot(_ label: String) {
        var parts: [String] = []
        if let format = processTapFormat(tapID) {
            parts.append("tap \(describe(format))")
        } else {
            parts.append("tap <unreadable>")
        }
        if let outputID = defaultOutputDeviceID() {
            let rate = nominalSampleRate(of: outputID)
                .map { String(format: "%.0f Hz", $0) } ?? "?"
            parts.append("output [\(outputID)] \(stringProperty(kAudioObjectPropertyName, of: outputID)) \(rate)")
        }
        if let inputID = defaultInputDeviceID() {
            let rate = nominalSampleRate(of: inputID)
                .map { String(format: "%.0f Hz", $0) } ?? "?"
            parts.append("input \(rate)")
        }
        timeline.log("\(label) \(parts.joined(separator: " | "))")
    }

    snapshot("BEFORE ")

    // Force the headset-mode switch through the production service, which is
    // what reliably drives AirPods into headset mode.
    timeline.log("starting MicrophoneCaptureService to force headset mode")
    let micURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("systemtap-mic-\(UUID().uuidString).wav")
    let service = MicrophoneCaptureService()
    do {
        try await service.startRecording(to: micURL)
        timeline.log("microphone service started")
    } catch {
        timeline.log("microphone service FAILED \(error.localizedDescription)")
        return
    }

    var lastLine = ""
    for _ in 0..<(watchSeconds * 4) {
        try? await Task.sleep(for: .milliseconds(250))
        var line = ""
        if let format = processTapFormat(tapID) {
            line = String(format: "%.0f", format.mSampleRate)
        }
        if let outputID = defaultOutputDeviceID() {
            line += "/" + (nominalSampleRate(of: outputID).map { String(format: "%.0f", $0) } ?? "?")
        }
        if line != lastLine {
            snapshot("CHANGE ")
            if !lastLine.isEmpty { sawTapFormatChange = true }
            lastLine = line
        }
    }

    if let result = try? await service.stopCapture() {
        timeline.log("microphone captured \(result.capturedSampleCount) frames")
    }
    for route in await service.microphoneInputRouteChanges() {
        timeline.log(
            "mic route \(route.reason.rawValue)"
                + String(format: " @ %.0f Hz", route.inputSampleRate)
        )
    }
    try? FileManager.default.removeItem(at: micURL)
    snapshot("AFTER  ")
    timeline.log(
        sawTapFormatChange
            ? "RESULT tap/output rate DID change during the session"
            : "RESULT tap/output rate never changed during the session"
    )
}

if arguments.contains("--system-tap") {
    await runSystemTapMode()
    print("")
    print("Probe complete.")
    print("")
    exit(0)
}

// MARK: - Service mode

/// Drives the real MicrophoneCaptureService end to end, so the shipped code
/// path is what gets verified rather than a reimplementation of it.
@MainActor
func runServiceMode() async {
    let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "microphone-route-probe-\(UUID().uuidString).wav",
            isDirectory: false
        )
    timeline.log("SERVICE recording to \(outputURL.lastPathComponent)")

    let service = MicrophoneCaptureService()
    do {
        try await service.startRecording(to: outputURL)
    } catch {
        timeline.log("SERVICE startRecording FAILED \(error.localizedDescription)")
        return
    }
    timeline.log("SERVICE startRecording returned")

    let deadline = Date().addingTimeInterval(Double(watchSeconds))
    var lastDescription = ""
    while Date() < deadline {
        try? await Task.sleep(for: .milliseconds(250))
        let state = await service.state
        let description = "\(state)"
        if description != lastDescription {
            timeline.log("SERVICE state \(description)")
            lastDescription = description
        }
    }

    do {
        let result = try await service.stopCapture()
        timeline.log(
            "SERVICE stopped: captured \(result.capturedSampleCount) frames"
                + ", dropped \(result.droppedSampleCount)"
        )
    } catch {
        timeline.log("SERVICE stopCapture FAILED \(error.localizedDescription)")
    }

    let routes = await service.microphoneInputRouteChanges()
    for route in routes {
        timeline.log(
            "SERVICE route \(route.reason.rawValue): \(route.device.name)"
                + String(format: " @ %.0f Hz", route.inputSampleRate)
                + ", \(route.inputChannelCount) ch"
        )
    }

    let size = (
        try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size]
    ) as? Int ?? -1
    timeline.log("SERVICE microphone.wav is \(size) bytes")
    try? FileManager.default.removeItem(at: outputURL)
}

if arguments.contains("--service") {
    await runServiceMode()
    print("")
    print(String(repeating: "=", count: 78))
    print("Probe complete.")
    print("")
    exit(0)
}

// MARK: - Run

print("")
print("Speak continuously for the whole run so silence is never the reason.")
print(String(repeating: "-", count: 78))

let firstStarted = startCapture(label: "PASS 1", settleMilliseconds: settleMilliseconds)
if firstStarted {
    if let description = counters.firstBufferDescription {
        timeline.log("PASS 1 first buffer: \(description)")
    }
    observe(seconds: watchSeconds, label: "PASS 1")
    timeline.log("PASS 1 RESULT: \(counters.summary)")
    if let description = counters.firstBufferDescription {
        timeline.log("PASS 1 first buffer: \(description)")
    } else {
        timeline.log("PASS 1 first buffer: NONE — the tap never fired")
    }
}

stopCapture(label: "PASS 1")

timeline.log("")
timeline.log("Rebuilding after the route has had time to settle.")
counters.reset()

let secondStarted = startCapture(label: "PASS 2", settleMilliseconds: 0)
if secondStarted {
    observe(seconds: 10, label: "PASS 2")
    timeline.log("PASS 2 RESULT: \(counters.summary)")
    if let description = counters.firstBufferDescription {
        timeline.log("PASS 2 first buffer: \(description)")
    } else {
        timeline.log("PASS 2 first buffer: NONE — the tap never fired")
    }
}

stopCapture(label: "PASS 2")

for (deviceID, address) in listenerAddresses {
    var mutableAddress = address
    AudioObjectRemovePropertyListenerBlock(
        deviceID, &mutableAddress, nil
    ) { _, _ in }
}
NotificationCenter.default.removeObserver(configurationObserver)

print("")
print(String(repeating: "=", count: 78))
print("Probe complete.")
print("")
