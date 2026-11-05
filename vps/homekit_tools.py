"""HomeKit tools for a remote FastMCP server (for example one reachable from claude.ai).

Imported by that server's server.py, which calls register(mcp, audit).
Each tool forwards to the homekit-bridge MCP server on your Mac over Tailscale.
The bridge is your own signed Mac app (HomeKit Bridge), which holds HomeKit access and
listens only on the Mac's loopback (127.0.0.1:18767); `tailscale serve` exposes it to the
tailnet as port 8767, and the tailnet policy lets only tag:vps reach it.

Config, from the server's environment (e.g. /etc/code-mcp.env):
  HOMEKIT_MCP_URL         e.g. http://100.x.y.z:8767/mcp (the Mac's Tailscale address)
  HOMEKIT_MCP_TOKEN_FILE  file holding the bearer token (root-only, mode 600)

Every write is logged on the Mac (~/Library/Logs/homekit-bridge/actions.jsonl) and
here in the server's audit log (if register() was given one). Every write action accepts dry_run for a preview.
"""
import asyncio, functools, os
from pathlib import Path
from typing import Any, Literal

from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client
from mcp.types import ToolAnnotations

URL = os.environ.get("HOMEKIT_MCP_URL", "")
TOKEN_FILE = os.environ.get("HOMEKIT_MCP_TOKEN_FILE", "/etc/code-mcp/homekit.token")
TIMEOUT = 60

READ = ToolAnnotations(readOnlyHint=True, destructiveHint=False, idempotentHint=True, openWorldHint=False)
CONTROL = ToolAnnotations(readOnlyHint=False, destructiveHint=False, idempotentHint=True, openWorldHint=True)
EDIT = ToolAnnotations(readOnlyHint=False, destructiveHint=True, idempotentHint=False, openWorldHint=True)

_TOOLS = []


def _tool(annotations):
    def deco(fn):
        _TOOLS.append((fn, annotations))
        return fn
    return deco


class Unreachable(Exception):
    pass


def _token() -> str:
    try:
        token = Path(TOKEN_FILE).read_text().strip()
    except OSError as e:
        raise Unreachable(f"HomeKit token file unreadable: {type(e).__name__}")
    if not token:
        raise Unreachable("HomeKit token file is empty")
    return token


_lock = None
RETRY_DELAYS = (1, 2, 4)  # seconds; only for the Mac's 429 "busy" answers, which run nothing


def _is_busy(exc: BaseException) -> bool:
    stack = [exc]
    while stack:
        e = stack.pop()
        resp = getattr(e, "response", None)
        if getattr(resp, "status_code", None) == 429:
            return True
        stack.extend(getattr(e, "exceptions", ()) or ())
        for nxt in (e.__cause__, e.__context__):
            if nxt is not None and nxt is not e:
                stack.append(nxt)
    return False


async def _call_once(tool: str, clean: dict):
    async with streamablehttp_client(URL, headers={"Authorization": f"Bearer {_token()}"}, timeout=TIMEOUT) as (r, w, _):
        async with ClientSession(r, w) as session:
            await session.initialize()
            return await session.call_tool(tool, clean)


def _clean(args: dict) -> dict:
    out = {}
    for k, v in args.items():
        if v is None:
            continue
        if isinstance(v, list):
            v = [({kk: vv for kk, vv in i.items() if vv is not None} if isinstance(i, dict) else i) for i in v]
        elif isinstance(v, dict):
            v = {kk: vv for kk, vv in v.items() if vv is not None}
        out[k] = v
    return out


async def _call(tool: str, args: dict):
    global _lock
    if not URL.startswith("http://100.") and not URL.startswith("https://"):
        raise Unreachable("HOMEKIT_MCP_URL must be the Mac's Tailscale address")
    clean = _clean(args)
    if _lock is None:
        _lock = asyncio.Lock()
    async with _lock:
        for attempt, delay in enumerate((0,) + RETRY_DELAYS):
            if delay:
                await asyncio.sleep(delay)
            try:
                result = await _call_once(tool, clean)
                break
            except Unreachable:
                raise
            except Exception as e:
                if _is_busy(e) and attempt < len(RETRY_DELAYS):
                    continue
                if _is_busy(e):
                    raise Unreachable("Mac HomeKit bridge is busy; try again in a minute")
                raise Unreachable(f"Mac HomeKit bridge unreachable ({type(e).__name__}); is the Mac awake, on Tailscale, and HomeKit Bridge running?")
    if getattr(result, "isError", False):
        text = " ".join(getattr(c, "text", "") for c in result.content).strip()
        raise ValueError(text or "HomeKit call failed")
    return list(result.content)


# Row shapes shared by scenes and automations. Values are always strings.
SceneRow = dict[str, Any]   # {accessory, property, value, room?, service_name?, service_id?, service_index?}


# ---------- reading ----------
@_tool(READ)
async def homekit_status():
    """HomeKit Bridge health on the Mac: HomeKit permission, homes, accessory counts."""
    return await _call("homekit_status", {})


@_tool(READ)
async def homekit_device_map(home_id: str | None = None):
    """Whole home at a glance: zones, rooms, accessories, services, current state and which settings are writable. Start here before changing anything."""
    return await _call("homekit_device_map", locals())


@_tool(READ)
async def homekit_rooms(home_id: str | None = None):
    """List rooms and the accessories in each."""
    return await _call("homekit_rooms", locals())


@_tool(READ)
async def homekit_events(limit: int | None = None, since: str | None = None,
                         type: Literal["homes_updated", "reachability_change", "characteristic_change",
                                       "accessory_controlled", "scene_triggered"] | None = None):
    """Recent events the bridge has seen since it started. since is ISO 8601."""
    return await _call("homekit_events", locals())


# ---------- accessories: read and change settings ----------
@_tool(CONTROL)
async def homekit_accessories(action: Literal["list", "search", "get", "control"] = "list",
                              home_id: str | None = None, room: str | None = None,
                              accessory_id: str | None = None, query: str | None = None,
                              category: str | None = None, characteristic: str | None = None,
                              value: str | None = None, service_name: str | None = None,
                              service_id: str | None = None, service_index: int | None = None,
                              verify: bool | None = None, no_refresh: bool | None = None,
                              dry_run: bool | None = None):
    """Accessories. list (optionally by room), search (name/room/category/service type), get (every service and characteristic with type UUID, value, readable/writable, format, min/max/step, units, valid values; reads live values unless no_refresh), control (write one characteristic).
    control writes any characteristic HomeKit marks writable, which covers device settings as well as on/off: pass a friendly name (power, brightness, hue, saturation, color_temperature, target_temperature, target_heating_cooling, heating_threshold, cooling_threshold, lock_target_state, target_door_state, target_position, rotation_speed, swing_mode, active, target_humidity, volume, mute, lock_physical_controls, set_duration) or the type UUID from get. value is a string ("true", "40", "locked", "heat"). Writes are read back: verified=true when the device reports the new value; verified=false plus "reads" when it reports something else (the write was still sent, e.g. a light that is off or rounds values; verify=false skips the read-back). Some lights turn on when brightness is written. dry_run previews. Use service_name / service_id / service_index to pick one gang of a multi-gang device."""
    return await _call("homekit_accessories", locals())


# ---------- structure: names, rooms, zones, groups ----------
@_tool(EDIT)
async def homekit_manage(action: Literal["rename", "set_display_as", "remove_accessory", "assign_rooms",
                                         "create_room", "rename_room", "remove_room", "create_zone", "rename_zone",
                                         "remove_zone", "add_room_to_zone", "remove_room_from_zone",
                                         "list_groups", "create_group", "add_to_group", "remove_from_group",
                                         "rename_group", "delete_group"],
                         home_id: str | None = None, id: str | None = None, new_name: str | None = None,
                         display_as: Literal["light", "fan", "switch", "outlet", "default"] | None = None,
                         service_name: str | None = None, service_id: str | None = None,
                         service_index: int | None = None, name: str | None = None, group: str | None = None,
                         members: list[str] | None = None, room: str | None = None, zone: str | None = None,
                         assignments: list[dict[str, str]] | None = None, dry_run: bool | None = None):
    """Edit the home's structure. rename (accessory, or one service via a service UUID as id or service_* selectors), set_display_as (switch/outlet shown as light or fan), assign_rooms (move accessories: assignments=[{"uuid" or "accessory", "room"}], missing rooms are created), create_room / rename_room / remove_room, create_zone / rename_zone / remove_zone / add_room_to_zone / remove_room_from_zone, list_groups / create_group / add_to_group / remove_from_group / rename_group / delete_group, remove_accessory (unpairs it from HomeKit; hard to undo). Every action takes dry_run=true for a preview; use it before removals."""
    return await _call("homekit_manage", locals())


# ---------- scenes ----------
@_tool(CONTROL)
async def homekit_scenes(action: Literal["list", "get", "trigger"] = "list", home_id: str | None = None,
                         scene_id: str | None = None):
    """Scenes: list, get (every action in the scene), trigger (run it now)."""
    return await _call("homekit_scenes", locals())


@_tool(EDIT)
async def homekit_scene_edit(action: Literal["create", "update", "rename", "delete"], scene: str,
                             actions: list[SceneRow] | None = None, new_name: str | None = None,
                             home_id: str | None = None, dry_run: bool | None = None):
    """Create, replace, rename or delete a scene. actions rows: {"accessory": UUID or name, "property": characteristic name or type UUID, "value": string, optional "room", "service_name", "service_id", "service_index"}. update replaces the whole action list but keeps the scene's UUID, so automations that run it keep working. dry_run=true previews."""
    return await _call("homekit_scene_edit", locals())


# ---------- automations ----------
@_tool(EDIT)
async def homekit_automations(action: Literal["list", "get", "create", "create_time", "create_presence", "edit",
                                              "enable", "disable", "rename", "delete"] = "list",
                              home_id: str | None = None, id: str | None = None, name: str | None = None,
                              new_name: str | None = None, accessory_id: str | None = None,
                              characteristic: str | None = None, trigger_value: str | None = None,
                              press_type: Literal[0, 1, 2] | None = None, service_name: str | None = None,
                              service_id: str | None = None, service_index: int | None = None,
                              time: str | None = None,
                              presence: Literal["first_arrives", "last_leaves", "any_arrives", "any_leaves"] | None = None,
                              presence_who: Literal["anyone", "me"] | None = None,
                              scene_id: str | None = None, actions: list[SceneRow] | None = None,
                              conditions: list[dict[str, Any]] | None = None,
                              time_after: str | None = None, time_before: str | None = None,
                              duration_seconds: int | None = None, clear_duration: bool | None = None,
                              weekdays: list[int] | None = None, dry_run: bool | None = None):
    """Automations. list / get. Triggers: create (button: accessory_id + press_type 0 single, 1 double, 2 long, service_index picks the button; or state change: accessory_id + characteristic + trigger_value), create_time (time "HH:MM", "sunrise", "sunset", "sunset-30", "sunrise+15"), create_presence (presence first_arrives / last_leaves / any_arrives / any_leaves, presence_who anyone or me). Each runs scene_id or makes a scene from actions rows {"accessory","property","value"}.
    Gates, all ANDed: weekdays (1=Sun..7=Sat); conditions rows {"accessory","property","value","op"("==" default, "!=", ">", ">=", "<", "<=")} or {"presence": "anyone_home" | "nobody_home" | "me_home" | "me_away"}; time_after / time_before (HH:MM or sunrise/sunset with offset; a window crossing midnight like sunset to sunrise works). duration_seconds turns the actions back after that long.
    edit changes in place and keeps the UUID: pass only what changes (a new time, presence or accessory trigger; conditions and time window, rebuilt together from what you pass; weekdays, [] for every day; duration_seconds or clear_duration; new_name). enable / disable / rename / delete. dry_run=true previews."""
    return await _call("homekit_automations", locals())


def _audited(fn, audit):
    @functools.wraps(fn)
    async def wrapper(*args, **kwargs):
        safe = {k: v for k, v in kwargs.items() if v is not None and k not in ("actions", "conditions", "assignments", "members")}
        for k in ("actions", "conditions", "assignments", "members"):
            if kwargs.get(k) is not None:
                safe[k] = len(kwargs[k])
        audit(fn.__name__, **safe)
        return await fn(*args, **kwargs)
    return wrapper


def register(mcp, audit=None):
    """Add every HomeKit tool to the given FastMCP server."""
    for fn, ann in _TOOLS:
        if audit:
            fn = _audited(fn, audit)
        mcp.tool(annotations=ann)(fn)
    return [f.__name__ for f, _ in _TOOLS]
