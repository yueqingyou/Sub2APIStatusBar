import Foundation

public enum CodexHookSenderScript {
    public static let executableName = "sub2api-statusbar-hook-sender"

    public static var payload: Data {
        Data(source.utf8)
    }

    public static let source = """
#!/usr/bin/env python3
import argparse
import datetime
import hashlib
import hmac
import json
import sys
import urllib.request
import uuid

EVENTS = {
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "PermissionRequest",
    "Stop",
    "PreCompact",
    "PostCompact",
    "SubagentStart",
    "SubagentStop",
}


def field(payload, key):
    return payload.get(key)


def normalized_text(value):
    if value is None:
        return None
    if isinstance(value, str):
        text = value.strip()
        return text or None
    if isinstance(value, (dict, list)):
        return json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    text = str(value).strip()
    return text or None


def first_text(payload, keys):
    for key in keys:
        text = normalized_text(field(payload, key))
        if text is not None:
            return text
    return None


def tool_name_from_payload(payload):
    direct = first_text(payload, ["tool_name"])
    if direct is not None:
        return direct
    tool = field(payload, "tool")
    if isinstance(tool, dict):
        return first_text(tool, ["name"])
    return normalized_text(tool)


def required_text(value, code):
    if value is None:
        raise ValueError(code)
    text = str(value).strip()
    if not text:
        raise ValueError(code)
    return text


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--managed-by", required=True)
    parser.add_argument("--event", required=True)
    parser.add_argument("--config", required=True)
    args = parser.parse_args()

    if args.managed_by != "Sub2APIStatusBar":
        raise ValueError("invalid managed-by")
    if args.event not in EVENTS:
        raise ValueError("invalid event")

    raw_input = sys.stdin.buffer.read()
    payload = json.loads(raw_input.decode("utf-8"))
    with open(args.config, "r", encoding="utf-8") as handle:
        node_config = json.load(handle)

    session_id = required_text(field(payload, "session_id"), "missing session_id")
    turn_id = required_text(field(payload, "turn_id"), "missing turn_id")
    observed_at = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    event = {
        "schema_version": 1,
        "event_id": str(uuid.uuid4()),
        "node_id": required_text(node_config.get("nodeId"), "missing node id"),
        "observed_at": observed_at,
        "hook_event": args.event,
        "session_id": session_id,
        "turn_id": turn_id,
    }
    cwd = normalized_text(field(payload, "cwd"))
    model = normalized_text(field(payload, "model"))
    tool_name = tool_name_from_payload(payload)
    tool_use_id = first_text(payload, ["tool_use_id"])
    transcript_path = first_text(payload, ["transcript_path"])
    user_agent = first_text(payload, [
        "user_agent",
        "userAgent",
        "user-agent",
        "request_user_agent",
        "requestUserAgent",
        "header_user_agent",
        "headerUserAgent",
    ])
    raw_payload_hash = hashlib.sha256(raw_input).hexdigest()
    status_hint = first_text(payload, [
        "status_hint",
        "status",
        "outcome",
        "result",
    ])
    error_message = first_text(payload, [
        "error_message",
        "failure_reason",
    ])
    if error_message is None:
        error_message = normalized_text(field(payload, "error"))
    if field(payload, "success") is False or field(payload, "failed") is True:
        status_hint = status_hint or "failed"
    if cwd is not None:
        event["cwd"] = cwd
    if model is not None:
        event["model"] = model
    if tool_name is not None:
        event["tool_name"] = tool_name
    if tool_use_id is not None:
        event["tool_use_id"] = tool_use_id
    if transcript_path is not None:
        event["transcript_path"] = transcript_path
    if user_agent is not None:
        event["user_agent"] = user_agent
    event["raw_payload_hash"] = "sha256:" + raw_payload_hash
    if status_hint is not None:
        event["status_hint"] = status_hint
    if error_message is not None:
        event["error_message"] = error_message

    body = json.dumps(event, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    secret = required_text(node_config.get("secret"), "missing secret")
    signature = hmac.new(secret.encode("utf-8"), body, hashlib.sha256).hexdigest()
    request = urllib.request.Request(
        required_text(node_config.get("receiverUrl"), "missing receiver url"),
        data=body,
        headers={
            "Content-Type": "application/json",
            "X-S2SB-Node-ID": event["node_id"],
            "X-S2SB-Timestamp": observed_at,
            "X-S2SB-Signature": "hmac-sha256=" + signature,
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=5) as response:
        status = response.getcode()
    if status < 200 or status >= 300:
        raise RuntimeError("receiver rejected hook event")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception:
        raise SystemExit(0)
"""
}
