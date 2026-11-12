#!/usr/bin/env python3
# KVM Console configuration helper.
#
# The Mac app sends this script to a PiKVM over the web terminal and runs it
# as root with one argument: the path of a JSON request. It prints exactly one
# result line, "PKC_JSON:" followed by a JSON object, and exits 0 unless it
# crashed. Everything else it prints is ignored by the app.
#
# Requests ({"op": ...}):
#   load       {"paths": ["otg/devices/audio/enabled", ...]}
#   validate   {"text": "..."}
#   merge      {"text": "...", "patch": {"a/b/c": value or null}}
#   save       {"text": "...", "restart": true}
#   backup     {"name": "20261111-043859.yaml"}            (read one backup)
#   restore    {"name": "20261111-043859.yaml", "restart": true}
#   service    {"unit": "kvmd-vnc", "enabled": true}
#   reboot     {}
#
# Only the Python standard library and the YAML modules that kvmd itself
# depends on (ruamel.yaml on current PiKVM OS, PyYAML on older ones) are used.

import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

OVERRIDE = "/etc/kvmd/override.yaml"
OVERRIDE_D = "/etc/kvmd/override.d"
BACKUPS = "/etc/kvmd/pikvm-console-backups"
KEEP_BACKUPS = 20

# Services the app may turn on or off.
TOGGLEABLE_UNITS = ["kvmd-vnc", "kvmd-ipmi"]

# Which service reads which top-level section of the config. kvmd itself is
# restarted for "kvmd" and for any section not listed here.
SECTION_UNITS = {
    "kvmd": ["kvmd"],
    "vnc": ["kvmd-vnc"],
    "ipmi": ["kvmd-ipmi"],
    "janus": ["kvmd-janus", "kvmd-janus-static"],
    "media": ["kvmd-media"],
    "pst": ["kvmd-pst"],
    "oled": ["kvmd-oled"],
    "localhid": ["kvmd-localhid"],
    "watchdog": ["kvmd-watchdog"],
    "nginx": ["kvmd-nginx"],
    "logging": ["kvmd"],
}
# Sections that only take effect after a reboot (the USB gadget is built at boot).
REBOOT_SECTIONS = {"otg", "otgnet"}

# Paths are overridable for tests.
OVERRIDE = os.environ.get("PKC_OVERRIDE", OVERRIDE)
OVERRIDE_D = os.environ.get("PKC_OVERRIDE_D", OVERRIDE_D)
BACKUPS = os.environ.get("PKC_BACKUPS", BACKUPS)
DRY_RUN = os.environ.get("PKC_DRY_RUN") == "1"  # tests: no rw/ro, systemctl or reboot


class Failure(Exception):
    def __init__(self, message, **extra):
        super().__init__(message)
        self.extra = extra


def emit(obj):
    sys.stdout.write("\nPKC_JSON:" + json.dumps(obj) + "\n")
    sys.stdout.flush()


def run(args, timeout=120):
    try:
        return subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              universal_newlines=True, timeout=timeout)
    except FileNotFoundError:
        return subprocess.CompletedProcess(args, 127, "", "%s: command not found" % args[0])
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(args, 124, "", "%s: timed out" % args[0])


def read_text(path):
    try:
        with open(path) as f:
            return f.read()
    except FileNotFoundError:
        return ""


# ===== YAML

def _ruamel():
    try:
        from ruamel.yaml import YAML  # noqa
        return YAML
    except ImportError:
        return None


def parse_plain(text):
    """Parses YAML into plain dicts, lists and scalars. Raises Failure."""
    try:
        YAML = _ruamel()
        if YAML is not None:
            y = YAML(typ="safe", pure=True)
            data = y.load(text)
        else:
            import yaml
            data = yaml.safe_load(text)
    except Exception as ex:
        raise Failure("The YAML is not valid: %s" % ex)
    if data is None:
        return {}
    if not isinstance(data, dict):
        raise Failure("The top level of the file must be a mapping (key: value).")
    return to_plain(data)


def to_plain(value):
    if isinstance(value, dict):
        return {str(k): to_plain(v) for (k, v) in value.items()}
    if isinstance(value, (list, tuple)):
        return [to_plain(v) for v in value]
    if isinstance(value, bool) or value is None:
        return value
    if isinstance(value, int):
        return int(value)
    if isinstance(value, float):
        return float(value)
    return str(value)


def split_path(path):
    parts = [p.strip() for p in path.split("/") if p.strip()]
    if not parts:
        raise Failure("Empty option path.")
    return parts


def lookup(data, path):
    node = data
    for key in split_path(path):
        if not isinstance(node, dict) or key not in node:
            return (False, None)
        node = node[key]
    return (True, node)


def merge_text(text, patch):
    """Applies {path: value} to the YAML text; None deletes the key. Keeps
    comments and layout when ruamel.yaml is available."""
    YAML = _ruamel()
    if YAML is not None:
        from ruamel.yaml.comments import CommentedMap
        handler = YAML()
        handler.preserve_quotes = True
        handler.indent(mapping=4, sequence=4, offset=4)
        try:
            doc = handler.load(text)
        except Exception as ex:
            raise Failure("The YAML is not valid: %s" % ex)
        if doc is None:
            doc = CommentedMap()
            if text.strip():
                # A file of comments only: keep them as the document's header.
                doc.yaml_set_start_comment("\n".join(
                    _uncomment(line) for line in text.rstrip("\n").split("\n")
                ))
        elif not isinstance(doc, dict):
            raise Failure("The top level of the file must be a mapping (key: value).")
        new_map = CommentedMap
    else:
        doc = parse_plain(text)
        new_map = dict

    for (path, value) in patch.items():
        keys = split_path(path)
        if isinstance(value, float) and value.is_integer():
            value = int(value)  # JSON from the app may spell 80 as 80.0
        if value is None:
            _delete(doc, keys)
            continue
        node = doc
        for key in keys[:-1]:
            if not isinstance(node.get(key), dict):
                node[key] = new_map()
            node = node[key]
        node[keys[-1]] = value

    if YAML is not None:
        buf = io.StringIO()
        handler.dump(doc, buf)
        result = buf.getvalue()
        if not doc and result.rstrip().endswith("{}"):
            # Only comments are left; an empty file means the same to kvmd.
            result = result.rstrip()[:-2].rstrip("\n") + "\n"
            if not result.strip():
                result = ""
        return result
    import yaml
    if not doc:
        return ""
    return yaml.safe_dump(doc, default_flow_style=False, indent=4, sort_keys=False)


def _uncomment(line):
    # ruamel.yaml adds "# " back in front of each line of a start comment.
    if line.startswith("# "):
        return line[2:]
    if line.startswith("#"):
        return line[1:]
    return line


def _delete(node, keys):
    if not isinstance(node, dict) or keys[0] not in node:
        return
    if len(keys) == 1:
        del node[keys[0]]
        return
    _delete(node[keys[0]], keys[1:])
    if isinstance(node[keys[0]], dict) and not node[keys[0]]:
        del node[keys[0]]


def diff_paths(old, new, prefix=""):
    """Leaf paths whose value differs between two plain dicts."""
    paths = []
    for key in sorted(set(old) | set(new), key=str):
        path = prefix + str(key)
        (a, b) = (old.get(key, _MISSING), new.get(key, _MISSING))
        if isinstance(a, dict) or isinstance(b, dict):
            if (isinstance(a, dict) or a is _MISSING) and (isinstance(b, dict) or b is _MISSING):
                paths.extend(diff_paths(a if isinstance(a, dict) else {}, b if isinstance(b, dict) else {}, path + "/"))
            else:
                paths.append(path)
        elif a != b:
            paths.append(path)
    return paths


_MISSING = object()


# ===== kvmd

def validate(text):
    """Checks the text as kvmd would load it, with every other config file.
    Raises Failure with kvmd's message if kvmd would reject it."""
    parse_plain(text)
    (fd, path) = tempfile.mkstemp(prefix="pkc-candidate-", suffix=".yaml", dir="/tmp")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(text)
        result = run(["kvmd", "-m", "--override-config", path])
    finally:
        os.remove(path)
    if result.returncode != 0:
        message = (result.stderr.strip() or result.stdout.strip() or "kvmd exited with code %d" % result.returncode)
        message = message.replace(path, OVERRIDE)
        raise Failure("kvmd rejected this configuration.", details=message[-4000:])


def effective(paths):
    result = run(["kvmd", "-m"])
    if result.returncode != 0:
        return (None, (result.stderr.strip() or result.stdout.strip())[-2000:])
    try:
        config = parse_plain(result.stdout)
    except Failure as ex:
        return (None, str(ex))
    values = {}
    for path in paths:
        (found, value) = lookup(config, path)
        if found:
            values[path] = value
    return (values, None)


# ===== System

def root_is_read_only():
    options = None
    with open("/proc/mounts") as f:
        for line in f:
            fields = line.split()
            if len(fields) >= 4 and fields[1] == "/":
                options = fields[3].split(",")
    return options is not None and "ro" in options


class Writable:
    """Remounts the root filesystem read-write (PiKVM keeps it read-only)
    and puts it back the way it was."""

    def __enter__(self):
        self.was_ro = (not DRY_RUN) and root_is_read_only()
        if self.was_ro:
            r = run(["rw"])
            if r.returncode != 0:
                raise Failure("Couldn't make the filesystem writable (rw).", details=r.stderr.strip())
        return self

    def __exit__(self, *_):
        os.sync()
        if self.was_ro:
            run(["ro"])
        return False


def unit_state(unit):
    if DRY_RUN:
        return {"enabled": False, "active": False}
    enabled = run(["systemctl", "is-enabled", unit]).stdout.strip()
    active = run(["systemctl", "is-active", unit]).stdout.strip()
    return {"enabled": enabled == "enabled", "active": active == "active", "exists": enabled not in ("", "not-found")}


def list_backups():
    try:
        names = [n for n in os.listdir(BACKUPS) if n.endswith(".yaml") and not n.startswith(".")]
    except FileNotFoundError:
        return []
    names.sort(reverse=True)
    return [{"name": n, "size": os.path.getsize(os.path.join(BACKUPS, n))} for n in names]


def backup_path(name):
    name = os.path.basename(str(name))
    path = os.path.join(BACKUPS, name)
    if not name.endswith(".yaml") or not os.path.isfile(path):
        raise Failure("There is no backup named %s." % name)
    return path


def write_atomic(path, text):
    directory = os.path.dirname(path)
    try:
        st = os.stat(path)
        (mode, uid, gid) = (st.st_mode & 0o7777, st.st_uid, st.st_gid)
    except FileNotFoundError:
        (mode, uid, gid) = (0o644, 0, 0)
    (fd, tmp) = tempfile.mkstemp(prefix=".%s." % os.path.basename(path), dir=directory)
    try:
        with os.fdopen(fd, "w") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        if not DRY_RUN:
            os.chown(tmp, uid, gid)
        os.rename(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


def make_backup(current):
    os.makedirs(BACKUPS, mode=0o700, exist_ok=True)
    base = time.strftime("%Y%m%d-%H%M%S")
    name = base + ".yaml"
    n = 1
    while os.path.exists(os.path.join(BACKUPS, name)):
        n += 1
        name = "%s-%d.yaml" % (base, n)
    with open(os.path.join(BACKUPS, name), "w") as f:
        f.write(current)
    os.chmod(os.path.join(BACKUPS, name), 0o600)
    for old in list_backups()[KEEP_BACKUPS:]:
        os.remove(os.path.join(BACKUPS, old["name"]))
    return name


def units_for(sections):
    units = []
    for section in sections:
        if section in REBOOT_SECTIONS:
            continue
        for unit in SECTION_UNITS.get(section, ["kvmd"]):
            if unit not in units:
                units.append(unit)
    # nginx carries the app's own connection: restart it last, detached.
    if "kvmd-nginx" in units:
        units.remove("kvmd-nginx")
        units.append("kvmd-nginx")
    return units


def wait_healthy(unit, seconds=40):
    """True once the unit has stayed active for three checks in a row."""
    deadline = time.time() + seconds
    streak = 0
    while time.time() < deadline:
        time.sleep(2)
        state = run(["systemctl", "is-active", unit]).stdout.strip()
        if state == "active":
            streak += 1
            if streak >= 3:
                return True
        else:
            streak = 0
            if state == "failed":
                return False
    return False


def restart(units):
    """Restarts the units that are running. Returns (restarted, failed unit or None)."""
    restarted = []
    if DRY_RUN:
        return (units, None)
    for unit in units:
        if run(["systemctl", "is-active", unit]).stdout.strip() != "active":
            continue
        if unit == "kvmd-nginx":
            subprocess.Popen(["sh", "-c", "sleep 2; systemctl restart kvmd-nginx"],
                             start_new_session=True, stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            restarted.append(unit)
            continue
        run(["systemctl", "restart", unit], timeout=90)
        restarted.append(unit)
        if not wait_healthy(unit):
            return (restarted, unit)
    return (restarted, None)


def journal(unit):
    return run(["journalctl", "-u", unit, "-n", "40", "--no-pager", "-o", "short"]).stdout[-6000:]


def install(text, do_restart):
    """Validates, backs up, installs, and optionally restarts. Rolls back
    automatically if a restarted service doesn't come back."""
    validate(text)
    current = read_text(OVERRIDE)
    try:
        old = parse_plain(current)
    except Failure:
        old = {"kvmd": None}  # The current file is broken: treat everything as changed.
    changed = diff_paths(old, parse_plain(text))
    if current == text:
        return {"ok": True, "unchanged": True, "changed": [], "sections": [], "restarted": [], "rebootRequired": False}
    with Writable():
        name = make_backup(current)
        write_atomic(OVERRIDE, text)
    sections = sorted({p.split("/")[0] for p in changed})
    result = {
        "ok": True,
        "backup": name,
        "changed": changed[:200],
        "sections": sections,
        "rebootRequired": bool(REBOOT_SECTIONS & set(sections)),
        "restarted": [],
    }
    if do_restart:
        (restarted, failed) = restart(units_for(sections))
        result["restarted"] = restarted
        if failed is not None:
            log = journal(failed)
            with Writable():
                write_atomic(OVERRIDE, current)
            restart([failed])
            result.update({
                "ok": False,
                "rolledBack": True,
                "error": "%s didn't start with the new configuration, so the previous override.yaml was put back." % failed,
                "details": log,
            })
    return result


# ===== Operations

def op_load(req):
    (values, error) = effective(req.get("paths", []))
    try:
        dropins = sorted(n for n in os.listdir(OVERRIDE_D) if n.endswith(".yaml"))
    except FileNotFoundError:
        dropins = []
    text = read_text(OVERRIDE)
    try:
        current = parse_plain(text)
        overridden = [p for p in req.get("paths", []) if lookup(current, p)[0]]
    except Failure:
        overridden = []
    return {
        "ok": True,
        "text": text,
        "overridden": overridden,
        "overrideD": dropins,
        "effective": values,
        "effectiveError": error,
        "backups": list_backups(),
        "units": {u: unit_state(u) for u in TOGGLEABLE_UNITS},
        "rootReadOnly": (not DRY_RUN) and root_is_read_only(),
        "hasRuamel": _ruamel() is not None,
    }


def op_validate(req):
    validate(req["text"])
    try:
        old = parse_plain(read_text(OVERRIDE))
    except Failure:
        old = {}
    return {"ok": True, "changed": diff_paths(old, parse_plain(req["text"]))}


def op_merge(req):
    original = req.get("text", "")
    text = merge_text(original, req.get("patch", {}))
    # Without ruamel.yaml (old PiKVM OS) the file is rewritten without comments.
    lost = _ruamel() is None and any(line.lstrip().startswith("#") for line in original.splitlines())
    return {"ok": True, "text": text, "commentsLost": lost}


def op_save(req):
    return install(req["text"], bool(req.get("restart", True)))


def op_backup(req):
    return {"ok": True, "text": read_text(backup_path(req["name"]))}


def op_restore(req):
    result = install(read_text(backup_path(req["name"])), bool(req.get("restart", True)))
    result["restoredFrom"] = os.path.basename(req["name"])
    return result


def op_service(req):
    unit = req["unit"]
    if unit not in TOGGLEABLE_UNITS:
        raise Failure("%s can't be changed from the app." % unit)
    action = ["enable", "--now"] if req.get("enabled") else ["disable", "--now"]
    if not DRY_RUN:
        with Writable():
            r = run(["systemctl"] + action + [unit], timeout=90)
        if r.returncode != 0:
            raise Failure("systemctl %s %s failed." % (action[0], unit), details=r.stderr.strip())
    return {"ok": True, "units": {u: unit_state(u) for u in TOGGLEABLE_UNITS}}


def op_reboot(req):
    if not DRY_RUN:
        subprocess.Popen(["sh", "-c", "sleep 2; systemctl reboot"], start_new_session=True,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return {"ok": True}


OPS = {
    "load": op_load,
    "validate": op_validate,
    "merge": op_merge,
    "save": op_save,
    "backup": op_backup,
    "restore": op_restore,
    "service": op_service,
    "reboot": op_reboot,
}


def main():
    try:
        with open(sys.argv[1]) as f:
            req = json.load(f)
        op = OPS.get(req.get("op"))
        if op is None:
            raise Failure("Unknown operation %r." % req.get("op"))
        emit(op(req))
    except Failure as ex:
        out = {"ok": False, "error": str(ex)}
        out.update(ex.extra)
        emit(out)
    except Exception as ex:  # A bug here: report it rather than hang the app.
        emit({"ok": False, "error": "The configuration helper failed: %s: %s" % (type(ex).__name__, ex)})


if __name__ == "__main__":
    main()
