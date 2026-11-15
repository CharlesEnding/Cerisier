#!/usr/bin/env python3
"""Tool: get_date_time. Args: {"format": "...", "timezone": "..."} for optional
format string and IANA timezone name. Returns the current date and time in
several useful representations. No arguments required — defaults to the system
timezone and ISO 8601 format.
"""
import json
import sys
from datetime import datetime, timezone, timedelta

try:
    from zoneinfo import ZoneInfo
    HAVE_ZONEINFO = True
except ImportError:
    HAVE_ZONEINFO = False


def main():
    try:
        args = json.loads(sys.argv[1])
    except (IndexError, json.JSONDecodeError):
        args = {}

    try:
        fmt = args.get("format", "%Y-%m-%dT%H:%M:%S")
        tz_name = args.get("timezone", None)

        # Resolve timezone
        tz = None
        if tz_name:
            if HAVE_ZONEINFO:
                try:
                    tz = ZoneInfo(tz_name)
                except (KeyError, ValueError):
                    # Try parsing as a UTC offset like "+05:00" or "-08:00"
                    try:
                        sign = 1 if tz_name[0] == "+" else -1
                        parts = tz_name.lstrip("+-").split(":")
                        hours = int(parts[0])
                        minutes = int(parts[1]) if len(parts) > 1 else 0
                        tz = timezone(timedelta(hours=sign * hours, minutes=sign * minutes))
                    except (ValueError, IndexError):
                        print(json.dumps({"ok": False, "error": f"invalid timezone: {tz_name}"}))
                        return
            else:
                # Fallback: try offset parsing only
                try:
                    sign = 1 if tz_name[0] == "+" else -1
                    parts = tz_name.lstrip("+-").split(":")
                    hours = int(parts[0])
                    minutes = int(parts[1]) if len(parts) > 1 else 0
                    tz = timezone(timedelta(hours=sign * hours, minutes=sign * minutes))
                except (ValueError, IndexError):
                    print(json.dumps({"ok": False, "error": f"invalid timezone: {tz_name} (zoneinfo not available)"}))
                    return
        else:
            tz = datetime.now().astimezone().tzinfo

        now = datetime.now(tz=tz)

        # Build timezone string for output
        if tz_name:
            tz_str = tz_name
        else:
            tz_str = str(tz) if tz else "local"

        print(json.dumps({
            "ok": True,
            "data": {
                "date": now.strftime("%Y-%m-%d"),
                "time": now.strftime("%H:%M:%S"),
                "datetime": now.strftime(fmt),
                "timestamp": now.timestamp(),
                "timezone": tz_str,
                "day_of_week": now.strftime("%A"),
            },
        }))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


if __name__ == "__main__":
    main()
