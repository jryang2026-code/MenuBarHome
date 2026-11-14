import Foundation

/// Identifies a single controllable field on a `SmartDevice` card so optimistic writes and stale
/// snapshot protection stay scoped to the edited property rather than freezing unrelated state.
public enum OptimisticField: String, Hashable, Sendable {
    case power
    case brightness
    case colorTemperature
    case effect
    case targetTemperature
    case hvacMode
    case fanLevel
    case presetMode
    case swingMode
    case coverPosition
    case volume
    case muted
    case mediaState
    case screenOff
    case inputSource
    case sleepMode
    case childLock
    case nightShot
    case motionDetection
    case targetHumidity
    case fridgeTargetTemperature
    case freezerTargetTemperature
    case applianceLight
    case vacuumStatus
}

/// Identifies either a card-level `OptimisticField` or a drawer `FacetControl` lock on a device.
public struct OptimisticLockKey: Hashable, Sendable {
    public enum Target: Hashable, Sendable {
        case field(OptimisticField)
        case facet(String)
    }

    public let deviceId: String
    public let target: Target

    public init(deviceId: String, target: Target) {
        self.deviceId = deviceId
        self.target = target
    }

    public static func field(_ deviceId: String, _ field: OptimisticField) -> OptimisticLockKey {
        OptimisticLockKey(deviceId: deviceId, target: .field(field))
    }

    public static func facet(_ deviceId: String, _ controlId: String) -> OptimisticLockKey {
        OptimisticLockKey(deviceId: deviceId, target: .facet(controlId))
    }

    public var field: OptimisticField? {
        guard case .field(let field) = target else { return nil }
        return field
    }
}

/// Per-field or per-facet optimistic lock lease with independent expiration and write revision.
public struct OptimisticLockEntry: Equatable, Sendable {
    public var until: Date
    public var untilInstant: ContinuousClock.Instant?
    public var revision: UInt64

    public init(until: Date, untilInstant: ContinuousClock.Instant? = nil, revision: UInt64) {
        self.until = until
        self.untilInstant = untilInstant
        self.revision = revision
    }

    public func isActive(at now: Date) -> Bool {
        now < until
    }
}

extension Duration {
    var optimisticTimeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

public extension OptimisticField {
    /// Fields representing a device kind's primary power / active-state toggle.
    static func primaryPowerFields(for kind: DeviceKind) -> Set<OptimisticField> {
        switch kind {
        case .cover:
            return [.coverPosition]
        case .climate:
            return [.power, .hvacMode]
        case .tv:
            return [.power, .mediaState, .screenOff]
        case .speaker:
            return [.mediaState]
        case .vacuum:
            return [.vacuumStatus]
        case .fridge, .sensor:
            return []
        default:
            return [.power]
        }
    }

    /// Computes which `OptimisticField`s differ between two versions of the same device.
    /// Falls back to primary power fields if two distinct writes happen to produce identical values.
    static func changedFields(from previous: SmartDevice, to updated: SmartDevice) -> Set<OptimisticField> {
        var changed: Set<OptimisticField> = []
        switch (previous.kind, updated.kind) {
        case (.light(let prev), .light(let next)):
            if prev.isOn != next.isOn { changed.insert(.power) }
            if prev.brightnessPercent != next.brightnessPercent { changed.insert(.brightness) }
            if prev.colorTempKelvin != next.colorTempKelvin { changed.insert(.colorTemperature) }
            if prev.currentEffect != next.currentEffect { changed.insert(.effect) }
        case (.climate(let prev), .climate(let next)):
            if prev.isOn != next.isOn { changed.insert(.power) }
            if prev.hvacMode != next.hvacMode { changed.insert(.hvacMode) }
            if prev.targetTemperature != next.targetTemperature { changed.insert(.targetTemperature) }
            if prev.fanMode != next.fanMode { changed.insert(.fanLevel) }
            if prev.swingMode != next.swingMode { changed.insert(.swingMode) }
        case (.fan(let prev), .fan(let next)):
            if prev.isOn != next.isOn { changed.insert(.power) }
            if prev.percentage != next.percentage { changed.insert(.fanLevel) }
            if prev.presetMode != next.presetMode { changed.insert(.presetMode) }
            if prev.isOscillating != next.isOscillating { changed.insert(.swingMode) }
        case (.plug(let prev), .plug(let next)):
            if prev.isOn != next.isOn { changed.insert(.power) }
            if prev.isChildLocked != next.isChildLocked { changed.insert(.childLock) }
        case (.fridge(let prev), .fridge(let next)):
            if prev.currentMode != next.currentMode { changed.insert(.presetMode) }
            if prev.fridgeTargetTemp != next.fridgeTargetTemp { changed.insert(.fridgeTargetTemperature) }
            if prev.freezerTargetTemp != next.freezerTargetTemp { changed.insert(.freezerTargetTemperature) }
        case (.vacuum(let prev), .vacuum(let next)):
            if prev.status != next.status { changed.insert(.vacuumStatus) }
            if prev.currentMode != next.currentMode { changed.insert(.presetMode) }
        case (.speaker(let prev), .speaker(let next)):
            if prev.state != next.state { changed.insert(.mediaState) }
            if prev.volumePercent != next.volumePercent { changed.insert(.volume) }
            if prev.isMuted != next.isMuted { changed.insert(.muted) }
            if prev.isSleepMode != next.isSleepMode { changed.insert(.sleepMode) }
        case (.tv(let prev), .tv(let next)):
            if prev.state != next.state {
                changed.insert(.mediaState)
                changed.insert(.power)
            }
            if prev.volumePercent != next.volumePercent { changed.insert(.volume) }
            if prev.isMuted != next.isMuted { changed.insert(.muted) }
            if prev.isScreenOff != next.isScreenOff { changed.insert(.screenOff) }
            if prev.currentSource != next.currentSource { changed.insert(.inputSource) }
        case (.camera(let prev), .camera(let next)):
            if prev.isOn != next.isOn { changed.insert(.power) }
            if prev.nightShot != next.nightShot { changed.insert(.nightShot) }
            if prev.isMotionDetectionOn != next.isMotionDetectionOn { changed.insert(.motionDetection) }
        case (.cover(let prev), .cover(let next)):
            if prev.positionPercent != next.positionPercent
                || prev.reportedPositionPercent != next.reportedPositionPercent
                || prev.motion != next.motion
                || prev.motionIsInferred != next.motionIsInferred {
                changed.insert(.coverPosition)
            }
        case (.appliance(let prev), .appliance(let next)):
            if prev.isOn != next.isOn { changed.insert(.power) }
            if prev.currentMode != next.currentMode { changed.insert(.presetMode) }
            if prev.targetTemperature != next.targetTemperature { changed.insert(.targetTemperature) }
            if prev.light?.isOn != next.light?.isOn { changed.insert(.applianceLight) }
            if prev.fanLevel?.current != next.fanLevel?.current { changed.insert(.fanLevel) }
        case (.generic(let prev), .generic(let next)):
            if prev.isOn != next.isOn { changed.insert(.power) }
        case (.humidifier(let prev), .humidifier(let next)):
            if prev.isOn != next.isOn { changed.insert(.power) }
            if prev.currentMode != next.currentMode { changed.insert(.presetMode) }
            if prev.targetHumidity != next.targetHumidity { changed.insert(.targetHumidity) }
        case (.valve(let prev), .valve(let next)):
            if prev.isOpen != next.isOpen || prev.motion != next.motion {
                changed.insert(.power)
            }
        case (.sensor, .sensor):
            break
        default:
            return primaryPowerFields(for: updated.kind)
        }
        return changed
    }
}

public extension SmartDevice {
    /// Applies `lockedFields` from `local` onto `self` (the incoming snapshot), allowing all
    /// unlocked control fields, sensor readouts, and `isOnline` to update smoothly.
    func mergingOptimisticFields(from local: SmartDevice, lockedFields: Set<OptimisticField>) -> SmartDevice {
        guard !lockedFields.isEmpty else { return self }
        var merged = self
        switch (self.kind, local.kind) {
        case (.light(var spec), .light(let localSpec)):
            if lockedFields.contains(.power) { spec.isOn = localSpec.isOn }
            if lockedFields.contains(.brightness) { spec.brightnessPercent = localSpec.brightnessPercent }
            if lockedFields.contains(.colorTemperature) { spec.colorTempKelvin = localSpec.colorTempKelvin }
            if lockedFields.contains(.effect) { spec.currentEffect = localSpec.currentEffect }
            merged.kind = .light(spec)
        case (.climate(var spec), .climate(let localSpec)):
            if lockedFields.contains(.power) { spec.isOn = localSpec.isOn }
            if lockedFields.contains(.hvacMode) { spec.hvacMode = localSpec.hvacMode }
            if lockedFields.contains(.targetTemperature) { spec.targetTemperature = localSpec.targetTemperature }
            if lockedFields.contains(.fanLevel) { spec.fanMode = localSpec.fanMode }
            if lockedFields.contains(.swingMode) { spec.swingMode = localSpec.swingMode }
            merged.kind = .climate(spec)
        case (.fan(var spec), .fan(let localSpec)):
            if lockedFields.contains(.power) { spec.isOn = localSpec.isOn }
            if lockedFields.contains(.fanLevel) { spec.percentage = localSpec.percentage }
            if lockedFields.contains(.presetMode) { spec.presetMode = localSpec.presetMode }
            if lockedFields.contains(.swingMode) { spec.isOscillating = localSpec.isOscillating }
            merged.kind = .fan(spec)
        case (.plug(var spec), .plug(let localSpec)):
            if lockedFields.contains(.power) { spec.isOn = localSpec.isOn }
            if lockedFields.contains(.childLock) { spec.isChildLocked = localSpec.isChildLocked }
            merged.kind = .plug(spec)
        case (.fridge(var spec), .fridge(let localSpec)):
            if lockedFields.contains(.presetMode) { spec.currentMode = localSpec.currentMode }
            if lockedFields.contains(.fridgeTargetTemperature) {
                spec.fridgeTargetTemp = localSpec.fridgeTargetTemp
            }
            if lockedFields.contains(.freezerTargetTemperature) {
                spec.freezerTargetTemp = localSpec.freezerTargetTemp
            }
            merged.kind = .fridge(spec)
        case (.vacuum(var spec), .vacuum(let localSpec)):
            if lockedFields.contains(.vacuumStatus) { spec.status = localSpec.status }
            if lockedFields.contains(.presetMode) { spec.currentMode = localSpec.currentMode }
            merged.kind = .vacuum(spec)
        case (.speaker(var spec), .speaker(let localSpec)):
            if lockedFields.contains(.mediaState) { spec.state = localSpec.state }
            if lockedFields.contains(.volume) { spec.volumePercent = localSpec.volumePercent }
            if lockedFields.contains(.muted) { spec.isMuted = localSpec.isMuted }
            if lockedFields.contains(.sleepMode) { spec.isSleepMode = localSpec.isSleepMode }
            merged.kind = .speaker(spec)
        case (.tv(var spec), .tv(let localSpec)):
            if lockedFields.contains(.mediaState) || lockedFields.contains(.power) {
                spec.state = localSpec.state
            }
            if lockedFields.contains(.volume) { spec.volumePercent = localSpec.volumePercent }
            if lockedFields.contains(.muted) { spec.isMuted = localSpec.isMuted }
            if lockedFields.contains(.screenOff) { spec.isScreenOff = localSpec.isScreenOff }
            if lockedFields.contains(.inputSource) { spec.currentSource = localSpec.currentSource }
            merged.kind = .tv(spec)
        case (.camera(var spec), .camera(let localSpec)):
            if lockedFields.contains(.power) { spec.isOn = localSpec.isOn }
            if lockedFields.contains(.nightShot) { spec.nightShot = localSpec.nightShot }
            if lockedFields.contains(.motionDetection) {
                spec.isMotionDetectionOn = localSpec.isMotionDetectionOn
            }
            merged.kind = .camera(spec)
        case (.cover(var spec), .cover(let localSpec)):
            if lockedFields.contains(.coverPosition) {
                spec.positionPercent = localSpec.positionPercent
                spec.reportedPositionPercent = localSpec.reportedPositionPercent
                spec.motion = localSpec.motion
                spec.motionIsInferred = localSpec.motionIsInferred
            }
            merged.kind = .cover(spec)
        case (.appliance(var spec), .appliance(let localSpec)):
            if lockedFields.contains(.power) { spec.isOn = localSpec.isOn }
            if lockedFields.contains(.presetMode) { spec.currentMode = localSpec.currentMode }
            if lockedFields.contains(.targetTemperature) { spec.targetTemperature = localSpec.targetTemperature }
            if lockedFields.contains(.applianceLight), let localLight = localSpec.light {
                if spec.light != nil {
                    spec.light?.isOn = localLight.isOn
                } else {
                    spec.light = localLight
                }
            }
            if lockedFields.contains(.fanLevel), let localFan = localSpec.fanLevel {
                if spec.fanLevel != nil {
                    spec.fanLevel?.current = localFan.current
                } else {
                    spec.fanLevel = localFan
                }
            }
            merged.kind = .appliance(spec)
        case (.generic(var spec), .generic(let localSpec)):
            if lockedFields.contains(.power) {
                spec.isOn = localSpec.isOn
                if spec.powerControl != nil {
                    spec.powerControl?.value = .bool(localSpec.isOn)
                }
            }
            merged.kind = .generic(spec)
        case (.humidifier(var spec), .humidifier(let localSpec)):
            if lockedFields.contains(.power) { spec.isOn = localSpec.isOn }
            if lockedFields.contains(.presetMode) { spec.currentMode = localSpec.currentMode }
            if lockedFields.contains(.targetHumidity) { spec.targetHumidity = localSpec.targetHumidity }
            merged.kind = .humidifier(spec)
        case (.valve(var spec), .valve(let localSpec)):
            if lockedFields.contains(.power) {
                spec.isOpen = localSpec.isOpen
                spec.motion = localSpec.motion
            }
            merged.kind = .valve(spec)
        case (.sensor, .sensor):
            break
        default:
            break
        }
        return merged
    }
}
