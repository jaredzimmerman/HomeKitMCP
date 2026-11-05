import Foundation
import HomeKit

/// Friendly snake_case names for common characteristic and service types, and value parsing.
enum Names {
    static let characteristics: [String: String] = [
        HMCharacteristicTypePowerState: "power",
        HMCharacteristicTypeBrightness: "brightness",
        HMCharacteristicTypeHue: "hue",
        HMCharacteristicTypeSaturation: "saturation",
        HMCharacteristicTypeColorTemperature: "color_temperature",
        HMCharacteristicTypeCurrentTemperature: "current_temperature",
        HMCharacteristicTypeTargetTemperature: "target_temperature",
        HMCharacteristicTypeCurrentHeatingCooling: "current_heating_cooling",
        HMCharacteristicTypeTargetHeatingCooling: "target_heating_cooling",
        HMCharacteristicTypeTemperatureUnits: "temperature_units",
        HMCharacteristicTypeCoolingThreshold: "cooling_threshold",
        HMCharacteristicTypeHeatingThreshold: "heating_threshold",
        HMCharacteristicTypeCurrentRelativeHumidity: "current_humidity",
        HMCharacteristicTypeTargetRelativeHumidity: "target_humidity",
        HMCharacteristicTypeCurrentLockMechanismState: "lock_current_state",
        HMCharacteristicTypeTargetLockMechanismState: "lock_target_state",
        HMCharacteristicTypeCurrentDoorState: "current_door_state",
        HMCharacteristicTypeTargetDoorState: "target_door_state",
        HMCharacteristicTypeObstructionDetected: "obstruction_detected",
        HMCharacteristicTypeMotionDetected: "motion_detected",
        HMCharacteristicTypeContactState: "contact_state",
        HMCharacteristicTypeOccupancyDetected: "occupancy_detected",
        HMCharacteristicTypeCurrentLightLevel: "current_light_level",
        HMCharacteristicTypeBatteryLevel: "battery_level",
        HMCharacteristicTypeChargingState: "charging_state",
        HMCharacteristicTypeStatusLowBattery: "low_battery",
        HMCharacteristicTypeCurrentPosition: "current_position",
        HMCharacteristicTypeTargetPosition: "target_position",
        HMCharacteristicTypePositionState: "position_state",
        HMCharacteristicTypeHoldPosition: "hold_position",
        HMCharacteristicTypeName: "name",
        HMCharacteristicTypeIdentify: "identify",
        HMCharacteristicTypeOutletInUse: "outlet_in_use",
        HMCharacteristicTypeActive: "active",
        HMCharacteristicTypeCurrentFanState: "current_fan_state",
        HMCharacteristicTypeTargetFanState: "target_fan_state",
        HMCharacteristicTypeRotationDirection: "rotation_direction",
        HMCharacteristicTypeRotationSpeed: "rotation_speed",
        HMCharacteristicTypeSwingMode: "swing_mode",
        HMCharacteristicTypeLockPhysicalControls: "lock_physical_controls",
        HMCharacteristicTypeCurrentAirPurifierState: "air_purifier_state",
        HMCharacteristicTypeTargetAirPurifierState: "target_air_purifier_state",
        HMCharacteristicTypeAirQuality: "air_quality",
        HMCharacteristicTypeSmokeDetected: "smoke_detected",
        HMCharacteristicTypeCarbonMonoxideDetected: "carbon_monoxide_detected",
        HMCharacteristicTypeCarbonDioxideDetected: "carbon_dioxide_detected",
        HMCharacteristicTypeStatusActive: "status_active",
        HMCharacteristicTypeStatusFault: "status_fault",
        HMCharacteristicTypeStatusTampered: "status_tampered",
        HMCharacteristicTypeInputEvent: "input_event",
        HMCharacteristicTypeVolume: "volume",
        HMCharacteristicTypeMute: "mute",
        HMCharacteristicTypeInUse: "in_use",
        HMCharacteristicTypeIsConfigured: "is_configured",
        HMCharacteristicTypeValveType: "valve_type",
        HMCharacteristicTypeSetDuration: "set_duration",
        HMCharacteristicTypeRemainingDuration: "remaining_duration",
        "000000CB-0000-1000-8000-0026BB765291": "service_label_index",
        "00000020-0000-1000-8000-0026BB765291": "manufacturer",
        "00000021-0000-1000-8000-0026BB765291": "model",
        "00000030-0000-1000-8000-0026BB765291": "serial_number",
        "00000052-0000-1000-8000-0026BB765291": "firmware_version",
        "00000053-0000-1000-8000-0026BB765291": "hardware_version",
        "00000054-0000-1000-8000-0026BB765291": "software_version",
    ]

    static let services: [String: String] = [
        HMServiceTypeLightbulb: "light",
        HMServiceTypeSwitch: "switch",
        HMServiceTypeOutlet: "outlet",
        HMServiceTypeFan: "fan",
        HMServiceTypeThermostat: "thermostat",
        HMServiceTypeLockMechanism: "lock",
        HMServiceTypeGarageDoorOpener: "garage_door",
        HMServiceTypeWindowCovering: "window_covering",
        HMServiceTypeDoor: "door",
        HMServiceTypeWindow: "window",
        HMServiceTypeMotionSensor: "motion_sensor",
        HMServiceTypeContactSensor: "contact_sensor",
        HMServiceTypeOccupancySensor: "occupancy_sensor",
        HMServiceTypeTemperatureSensor: "temperature_sensor",
        HMServiceTypeHumiditySensor: "humidity_sensor",
        HMServiceTypeLightSensor: "light_sensor",
        HMServiceTypeAirQualitySensor: "air_quality_sensor",
        HMServiceTypeSmokeSensor: "smoke_sensor",
        HMServiceTypeCarbonMonoxideSensor: "carbon_monoxide_sensor",
        HMServiceTypeBattery: "battery",
        HMServiceTypeStatefulProgrammableSwitch: "stateful_button",
        HMServiceTypeStatelessProgrammableSwitch: "button",
        HMServiceTypeAccessoryInformation: "accessory_information",
        HMServiceTypeAirPurifier: "air_purifier",
        HMServiceTypeHeaterCooler: "heater_cooler",
        HMServiceTypeHumidifierDehumidifier: "humidifier_dehumidifier",
        HMServiceTypeValve: "valve",
        HMServiceTypeFaucet: "faucet",
        HMServiceTypeSecuritySystem: "security_system",
        HMServiceTypeDoorbell: "doorbell",
        HMServiceTypeSpeaker: "speaker",
        HMServiceTypeLabel: "label",
    ]

    static let serviceLabelIndexType = "000000CB-0000-1000-8000-0026BB765291"

    static func name(for type: String) -> String { characteristics[type] ?? type }
    static func serviceName(for type: String) -> String { services[type] ?? type }

    static func characteristicType(for key: String) -> String {
        let k = key.lowercased()
        if let hit = characteristics.first(where: { $0.value == k }) { return hit.key }
        return key.uppercased()
    }

    static func serviceType(for key: String) -> String? {
        let k = key.lowercased()
        if k == "default" { return nil }
        if let hit = services.first(where: { $0.value == k }) { return hit.key }
        return key.uppercased()
    }

    // Words accepted in place of numbers for common enumerations.
    private static let words: [String: [String: Int]] = [
        HMCharacteristicTypeTargetLockMechanismState: ["unlocked": 0, "unsecured": 0, "locked": 1, "secured": 1],
        HMCharacteristicTypeTargetDoorState: ["open": 0, "closed": 1],
        HMCharacteristicTypeTargetHeatingCooling: ["off": 0, "heat": 1, "cool": 2, "auto": 3],
        HMCharacteristicTypeActive: ["inactive": 0, "off": 0, "active": 1, "on": 1],
        HMCharacteristicTypeTargetFanState: ["manual": 0, "auto": 1],
        HMCharacteristicTypeTargetAirPurifierState: ["manual": 0, "auto": 1],
        HMCharacteristicTypeTemperatureUnits: ["celsius": 0, "c": 0, "fahrenheit": 1, "f": 1],
    ]

    /// Parse a string into the value type the characteristic's metadata asks for.
    static func parse(_ raw: String, for c: HMCharacteristic) throws -> Any {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let lower = s.lowercased()
        let format = c.metadata?.format ?? ""
        if let n = words[c.characteristicType]?[lower] { return NSNumber(value: n) }
        func bool() -> Bool? {
            switch lower {
            case "true", "on", "yes", "1": return true
            case "false", "off", "no", "0": return false
            default: return nil
            }
        }
        switch format {
        case HMCharacteristicMetadataFormatBool:
            guard let b = bool() else { throw BridgeError.message("Expected true/false, got \(raw)") }
            return NSNumber(value: b)
        case HMCharacteristicMetadataFormatString:
            return s
        case HMCharacteristicMetadataFormatData, HMCharacteristicMetadataFormatTLV8:
            guard let d = Data(base64Encoded: s) else { throw BridgeError.message("Expected base64 data") }
            return d
        case HMCharacteristicMetadataFormatFloat:
            guard let d = Double(s), d.isFinite else { throw BridgeError.message("Expected a number, got \(raw)") }
            try checkRange(d, c)
            return NSNumber(value: d)
        case HMCharacteristicMetadataFormatInt, HMCharacteristicMetadataFormatUInt8, HMCharacteristicMetadataFormatUInt16,
             HMCharacteristicMetadataFormatUInt32, HMCharacteristicMetadataFormatUInt64:
            if let b = bool(), Int(s) == nil { return NSNumber(value: b ? 1 : 0) }
            // isFinite + magnitude guard: Int64(d) below traps on inf/nan or values past Int64's range ("1e30").
            guard let d = Double(s), d.isFinite, d.rounded() == d, abs(d) < 9.2e18 else {
                throw BridgeError.message("Expected a whole number, got \(raw)")
            }
            try checkRange(d, c)
            if let valid = c.metadata?.validValues, !valid.isEmpty, !valid.contains(where: { $0.doubleValue == d }) {
                throw BridgeError.message("Allowed values: \(valid.map { $0.stringValue }.joined(separator: ", "))")
            }
            return NSNumber(value: Int64(d))
        default:
            if let b = bool() { return NSNumber(value: b) }
            if let d = Double(s) { return NSNumber(value: d) }
            return s
        }
    }

    private static func checkRange(_ d: Double, _ c: HMCharacteristic) throws {
        if let lo = c.metadata?.minimumValue?.doubleValue, d < lo { throw BridgeError.message("\(d) is below the minimum \(lo)") }
        if let hi = c.metadata?.maximumValue?.doubleValue, d > hi { throw BridgeError.message("\(d) is above the maximum \(hi)") }
    }

    static func same(_ a: Any?, _ b: Any) -> Bool {
        if let x = a as? NSNumber, let y = b as? NSNumber { return abs(x.doubleValue - y.doubleValue) < 0.51 }
        if let x = a as? String, let y = b as? String { return x == y }
        if let x = a as? Data, let y = b as? Data { return x == y }
        return false
    }
}
