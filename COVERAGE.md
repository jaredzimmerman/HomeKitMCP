# HomeKit coverage matrix (bridge v2)

Status key: **Y** done · **N** new in v2 · **UI** Apple only allows it through its own sheet, so the bridge opens that sheet on the Mac and a person finishes · **X** not possible with Apple's public API or your own signing.

## Public API (HomeKit.framework)

| Area | API | Tool / action | Status |
|---|---|---|---|
| Manager | homes, authorizationStatus | homekit_status, homekit_home info | Y |
| Manager | addHome / removeHome | homekit_home add_home / remove_home (confirm) | N |
| Manager | updatePrimaryHome (deprecated by Apple) | homekit_home set_primary | N, may be a no-op |
| Home | name / updateName | homekit_home rename_home | N |
| Home | homeHubState, supportsAddingNetworkRouter | homekit_home info | N (supports_network_router is null on Mac: unavailable in Mac Catalyst) |
| Home | currentUser, homeAccessControl(for:).isAdministrator | homekit_home info / users | N |
| Home | manageUsers (invite, remove, permissions) | homekit_home manage_users | N, UI |
| Home | other users list | none | X, only currentUser is public |
| Home | rooms, roomForEntireHome, add/remove/rename room | homekit_rooms, homekit_manage | Y |
| Home | zones, add/remove/rename, add/remove room | homekit_manage | Y |
| Home | serviceGroups, add/remove/rename, add/remove service | homekit_manage | Y |
| Home | assignAccessory(to: room) | homekit_manage assign_rooms | Y |
| Home | removeAccessory | homekit_manage remove_accessory | Y |
| Home | unblockAccessory | homekit_devices unblock | N |
| Home | HMAccessorySetupManager (add accessory, setup code URL) | homekit_home add_accessory | N, UI, needs macOS 27 |
| Home | HMAccessoryBrowser (unpaired accessories nearby) | homekit_home discover | X on Mac: unavailable in Mac Catalyst (returns an error) |
| Home | actionSets, add/remove/execute | homekit_scenes, homekit_scene_edit | Y |
| Home | builtinActionSet(ofType:) | homekit_scene_actions builtin | N |
| Home | triggers, add/remove | homekit_automations, homekit_triggers | Y / N |
| Home | servicesWithTypes | homekit_accessories search | Y |
| Home | delegate events (accessories added/removed, reachability, values) | homekit_events | Y |
| Accessory | name / updateName, room, category, reachable, bridged, blocked | homekit_accessories, homekit_manage, homekit_devices profiles | Y / N |
| Accessory | manufacturer, model, firmwareVersion | homekit_accessories get, homekit_devices profiles | Y |
| Accessory | uniqueIdentifiersForBridgedAccessories, matterNodeID, category type | homekit_devices profiles | N |
| Accessory | supportsIdentify / identify | homekit_devices identify | N |
| Accessory | profiles: HMNetworkConfigurationProfile (router protection) | homekit_devices profiles | N |
| Accessory | profiles: HMCameraProfile | homekit_cameras | N |
| Service | name / updateName, type, isPrimaryService, isUserInteractive | homekit_accessories get, homekit_manage rename | Y |
| Service | associatedServiceType / update (Display As) | homekit_manage set_display_as | Y |
| Service | linkedServices, matterEndpointID | homekit_devices linked_services | N (matter_endpoint needs macOS 15 / Mac Catalyst 18) |
| Characteristic | value, readValue | homekit_accessories get, homekit_devices read | Y / N |
| Characteristic | writeValue (any writable one, settings included) | homekit_accessories control, homekit_devices write_many | Y / N |
| Characteristic | metadata (format, min, max, step, units, valid values, manufacturer description) | homekit_accessories get, homekit_devices read | Y |
| Characteristic | properties (readable, writable, notifies, hidden) | homekit_accessories get | Y |
| Characteristic | enableNotification | homekit_devices notify | N |
| Scene | name / updateName, actions, actionSetType, lastExecutionDate | homekit_scenes, homekit_scene_edit | Y |
| Scene | addAction / removeAction (one at a time) | homekit_scene_actions add / remove | N |
| Action types | HMCharacteristicWriteAction (the only public action type) | everywhere | Y |
| Event trigger | several events, any one fires (multi-sensor) | homekit_triggers create_event events[] | N |
| Event trigger | HMCharacteristicEvent with a value | homekit_automations create, homekit_triggers | Y |
| Event trigger | HMCharacteristicEvent with no value (any change) | homekit_triggers any_change | N |
| Event trigger | HMCharacteristicThresholdRangeEvent (enters a range) | homekit_triggers min/max | N |
| Event trigger | programmable button press | homekit_automations, homekit_triggers button | Y |
| Event trigger | HMCalendarEvent, HMSignificantTimeEvent (+offset) | homekit_automations create_time, homekit_triggers time | Y |
| Event trigger | HMPresenceEvent (first, last, any; me or anyone) | homekit_automations create_presence, homekit_triggers presence | Y |
| Event trigger | HMLocationEvent (circular region, enter/exit) | homekit_triggers latitude/longitude | N |
| Event trigger | endEvents: HMDurationEvent and characteristic events | homekit_automations duration_seconds, homekit_triggers end_events | Y / N |
| Event trigger | recurrences (weekdays) | weekdays | Y |
| Event trigger | predicate: characteristic compare, presence, before/after time or sun | conditions, time_after/time_before | Y |
| Event trigger | predicate: OR, NOT, nested groups | homekit_triggers conditions any / all / not | N |
| Event trigger | executeOnce | homekit_triggers execute_once | N |
| Event trigger | triggerActivationState (e.g. no home hub) | homekit_triggers get | N |
| Event trigger | several scenes per automation, add/remove scene | homekit_triggers scene_ids, add_scenes, remove_scenes | N |
| Event trigger | updateEvents / updateEndEvents / updatePredicate / updateRecurrences | homekit_automations edit, homekit_triggers update | Y / N |
| Timer trigger | HMTimerTrigger with fire date and recurrence | homekit_triggers create_timer / update | N |
| Trigger | enable, rename, delete, lastFireDate | homekit_automations | Y |
| Camera | settings: night vision, rotation, mirroring, optical and digital zoom, tilt | homekit_cameras settings / set | N |
| Camera | speaker and microphone mute and volume | homekit_cameras settings / set | N |
| Camera | takeSnapshot, mostRecentSnapshot.captureDate | homekit_cameras snapshot | N |
| Camera | snapshot image | homekit_cameras snapshot image=true | N (tested: returns a real JPEG on macOS 27) |
| Camera | live stream | none | X, Apple only shows streams in HMCameraView on screen; nothing to send over MCP |

## Not reachable with the public API

- HomePod and Apple TV settings, Siri, intercom, announcements, media playback (no public classes on macOS).
- Home app favorites, "show in status", tile order, wallpapers.
- Camera recording modes (stream/record/off for home and away), activity zones, clip history.
- Accessory firmware updates and Thread network management.
- Adaptive Lighting on or off as a setting (its characteristics are written by the Home app's private controller).
- Shortcut-based automation steps and the hidden scenes that automations own: readable through private_homed_db, not writable (homed checks Apple's private entitlement).
- Full user list, guest access, Home Keys, access codes for locks.

## Private (undocumented) layer: separate `private_` tools

| Item | Source | Works with your own signing? | Tool | Risk |
|---|---|---|---|---|
| homed database read (~/Library/HomeKit/core.sqlite): Shortcut automation steps (WFWorkflowActions), hidden automation scenes, triggers, actions | homekit-extractor project (GitHub, tamengual) | Yes, read-only, after you grant HomeKit Bridge Full Disk Access | private_homed_db | Table names change between macOS versions; local copy can lag the hub |
| Reading private properties homed already sends to the app (applicationData, accessory settings tree, softwareUpdateController, residentDevices, mediaSystems, etc.) | Class-dumped HomeKit headers | Unverified; each property is tried and reports "unavailable" if missing or refused | private_probe read / describe | May break on any macOS update |
| Generic private selector call (respondsToSelector + exception-safe, confirm required) | Class-dumped headers | Most writes are refused by homed: "Missing entitlement for API" | private_probe call | Same |
| HMTrigger addActionSetWithCompletionHandler: (empty automation-owned scene) | HomeClaw docs/PRIVATE_API.md | Yes, but only creates an empty set | private_probe call | Low value |
| HMActionSet _addAction:completionHandler: (edit automation-owned scenes) | HomeClaw docs/PRIVATE_API.md | No: needs com.apple.homekit.private-spi-access, which Apple grants only to its own apps | private_probe call fails cleanly | none |
| HMActionSet _doAddAction:uuid: | HomeClaw docs/PRIVATE_API.md | Not used: changes memory only and is lost on restart | none | Silent data loss |

## Excluded: needs system protections off (not built)

- Giving HomeKit Bridge com.apple.homekit.private-spi-access (would allow editing automation-owned scenes, favorites, HomePod settings through homed). Only possible by re-signing with a private entitlement, which macOS refuses unless SIP and AMFI enforcement are turned off (boot-arg amfi_get_out_of_my_way=1 or similar). That lowers protection for the whole Mac.
- Injecting into the Home app or homed to borrow their entitlements. Needs SIP off and library validation off.
- Writing to the homed database directly. homed would overwrite or corrupt it, and it needs the same protections off to do safely.
