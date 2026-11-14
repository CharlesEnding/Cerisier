#!/usr/bin/env python3
"""Tool: machine_config. Args: {} (no parameters).
Reports the dev machine's configuration: OS/version, kernel, CPU, RAM, and
per-mount disk usage. Reads from the usual procfs/standard files rather than
shelling out, so it needs no run_command approval. Each section is wrapped
defensively so a missing file never breaks the whole report.
"""
import json
import os
import platform
import sys


def read_os_release():
    info = {"name": "", "version": "", "codename": ""}
    try:
        with open("/etc/os-release", "r") as f:
            for line in f:
                line = line.strip()
                if "=" not in line:
                    continue
                key, val = line.split("=", 1)
                val = val.strip('"')
                if key == "NAME":
                    info["name"] = val
                elif key == "VERSION_ID":
                    info["version"] = val
                elif key == "VERSION_CODENAME":
                    info["codename"] = val
    except OSError:
        pass
    return info


def read_memory():
    mem = {"total_mb": 0, "free_mb": 0, "available_mb": 0, "used_mb": 0}
    values = {}
    try:
        with open("/proc/meminfo", "r") as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 2:
                    values[parts[0].rstrip(":")] = int(parts[1])
        total = values.get("MemTotal", 0)
        free = values.get("MemFree", 0)
        avail = values.get("MemAvailable", free)
        mem["total_mb"] = total // 1024
        mem["free_mb"] = free // 1024
        mem["available_mb"] = avail // 1024
        mem["used_mb"] = max(0, (total - avail)) // 1024
    except (OSError, ValueError):
        pass
    return mem


def read_cpu():
    cpu = {"cores": 0, "model": ""}
    try:
        cpu["cores"] = os.cpu_count() or 0
    except Exception:
        pass
    try:
        with open("/proc/cpuinfo", "r") as f:
            for line in f:
                if line.startswith("model name"):
                    cpu["model"] = line.split(":", 1)[1].strip()
                    break
    except OSError:
        pass
    return cpu


def read_uptime():
    out = {"seconds": 0, "load_1m": 0.0, "load_5m": 0.0, "load_15m": 0.0}
    try:
        with open("/proc/uptime", "r") as f:
            out["seconds"] = int(float(f.read().split()[0]))
    except (OSError, ValueError):
        pass
    try:
        l1, l5, l15 = os.getloadavg()
        out["load_1m"] = round(l1, 2)
        out["load_5m"] = round(l5, 2)
        out["load_15m"] = round(l15, 2)
    except (OSError, AttributeError):
        pass
    return out


def read_disks():
    # Pseudo/virtual filesystems that don't represent real storage.
    pseudo = {
        "proc", "procfs", "sysfs", "devfs", "devtmpfs", "tmpfs", "cgroup",
        "cgroup2", "securityfs", "debugfs", "tracefs", "binfmt_misc",
        "nfsd", "configfs", "autofs", "fusectl", "mqueue", "pstore",
        "efivars", "resolvfs", "overlayfs", "squashfs", "efivarfs",
    }
    disks = []
    try:
        with open("/proc/mounts", "r") as f:
            lines = f.read().splitlines()
    except OSError:
        return disks

    seen = set()
    for line in lines:
        parts = line.split()
        if len(parts) < 3:
            continue
        device, mountpoint, fstype = parts[0], parts[1], parts[2]
        if fstype in pseudo:
            continue
        if mountpoint in seen:
            continue
        # Unescape octal sequences (e.g. \040 for space) in mountpoint.
        try:
            mountpoint = mountpoint.encode("utf-8").decode("unicode-escape")
        except Exception:
            pass
        try:
            st = os.statvfs(mountpoint)
            if st.f_blocks <= 0:
                continue
            if (st.f_blocks * st.f_bsize) < (1024 * 1024):
                continue
            total = st.f_blocks * st.f_bsize
            free = st.f_bfree * st.f_bsize
            used = total - free
            pct = int(round(100 * used / total)) if total > 0 else 0
            disks.append({
                "mountpoint": mountpoint,
                "device": device,
                "fstype": fstype,
                "total_mb": total // (1024 * 1024),
                "free_mb": free // (1024 * 1024),
                "used_mb": used // (1024 * 1024),
                "use_percent": pct,
            })
            seen.add(mountpoint)
        except OSError:
            continue
    return disks


def main():
    try:
        data = {
            "hostname": platform.node(),
            "os": read_os_release(),
            "kernel": platform.system() + " " + platform.release(),
            "arch": platform.machine(),
            "python_version": platform.python_version(),
            "cpu": read_cpu(),
            "memory": read_memory(),
            "disk": read_disks(),
            "uptime": read_uptime(),
        }
        print(json.dumps({"ok": True, "data": data}))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


if __name__ == "__main__":
    main()
