#!/usr/bin/env python3
"""Agentmail CLI — wrapper for the Agentmail API.

Reads credentials from .env in the brain root directory. The agent calls this
script instead of using curl directly, keeping API keys out of tool output.

Usage:
    python3 scripts/agentmail.py list-unread
    python3 scripts/agentmail.py get-message <message_id>
    python3 scripts/agentmail.py mark-read <message_id>
    python3 scripts/agentmail.py send --to addr@example.com --subject "Hi" --text "Body"
    python3 scripts/agentmail.py reply <message_id> --text "Reply body"
    python3 scripts/agentmail.py forward <message_id> --to addr@example.com
    python3 scripts/agentmail.py create-draft --to addr@example.com --subject "Hi" --text "Body"
    python3 scripts/agentmail.py send-draft <draft_id>
    python3 scripts/agentmail.py list-drafts
    python3 scripts/agentmail.py list-threads
    python3 scripts/agentmail.py get-thread <thread_id>
    python3 scripts/agentmail.py get-attachment <message_id> <attachment_id>
    python3 scripts/agentmail.py list-inboxes

Environment (read from .env):
    AGENTMAIL_API_KEY   — API key from console.agentmail.to
    AGENTMAIL_INBOX_ID  — inbox email/ID
"""

import argparse
import json
import os
import sys
import urllib.request
import urllib.error
import urllib.parse

API_BASE = "https://api.agentmail.to/v0"


def load_env(env_path):
    """Load key=value pairs from a .env file into a dict."""
    env = {}
    if not os.path.exists(env_path):
        return env
    with open(env_path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                key, value = line.split("=", 1)
                env[key.strip()] = value.strip().strip('"').strip("'")
    return env


def get_credentials():
    """Get API key and inbox ID from environment or .env file."""
    api_key = os.environ.get("AGENTMAIL_API_KEY", "")
    inbox_id = os.environ.get("AGENTMAIL_INBOX_ID", "")

    if not api_key or not inbox_id:
        # Walk up from script location to find .env
        script_dir = os.path.dirname(os.path.abspath(__file__))
        for search_dir in [
            os.path.join(script_dir, ".."),  # brain root (scripts/../)
            os.path.expanduser("~/brain"),
            os.path.expanduser("~/Dropbox/brain"),
        ]:
            env_path = os.path.join(search_dir, ".env")
            if os.path.exists(env_path):
                env = load_env(env_path)
                api_key = api_key or env.get("AGENTMAIL_API_KEY", "")
                inbox_id = inbox_id or env.get("AGENTMAIL_INBOX_ID", "")
                break

    if not api_key:
        print("Error: AGENTMAIL_API_KEY not found", file=sys.stderr)
        sys.exit(1)
    if not inbox_id:
        print("Error: AGENTMAIL_INBOX_ID not found", file=sys.stderr)
        sys.exit(1)

    return api_key, inbox_id


def api_request(method, path, api_key, data=None):
    """Make an API request and return parsed JSON."""
    url = f"{API_BASE}{path}"
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }

    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(url, data=body, headers=headers, method=method)

    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read().decode()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        error_body = e.read().decode() if e.fp else ""
        print(f"API error {e.code}: {error_body}", file=sys.stderr)
        sys.exit(1)


def encode_id(value):
    """URL-encode a path segment.

    Agentmail message IDs are RFC 5322 Message-IDs like
    ``<abc=@example.com>`` and contain ``<``, ``>``, ``@``, ``=`` — all
    unsafe in a URL path. If the caller supplied the ID without the angle
    brackets, add them back (the API stores IDs with brackets).
    """
    if not value:
        return value
    # Re-add angle brackets if stripped (e.g. by shell or by hand-copying)
    if "@" in value and not value.startswith("<"):
        value = f"<{value}>"
    return urllib.parse.quote(value, safe="")


def cmd_list_unread(args):
    api_key, inbox_id = get_credentials()
    result = api_request("GET", f"/inboxes/{inbox_id}/messages?labels=unread", api_key)
    messages = result.get("messages", [])
    if not messages:
        print("No unread messages.")
        return
    print(f"{len(messages)} unread message(s):\n")
    for msg in messages:
        sender = msg.get("from", "unknown")
        sender_str = sender.get("email", sender) if isinstance(sender, dict) else str(sender)
        print(f"  ID: {msg.get('message_id', msg.get('id', 'unknown'))}")
        print(f"  From: {sender_str}")
        print(f"  Subject: {msg.get('subject', '(no subject)')}")
        print(f"  Date: {msg.get('created_at', 'unknown')}")
        print()


def cmd_get_message(args):
    api_key, inbox_id = get_credentials()
    mid = encode_id(args.message_id)
    result = api_request("GET", f"/inboxes/{inbox_id}/messages/{mid}", api_key)
    print(json.dumps(result, indent=2))


def cmd_mark_read(args):
    api_key, inbox_id = get_credentials()
    mid = encode_id(args.message_id)
    api_request(
        "PATCH",
        f"/inboxes/{inbox_id}/messages/{mid}",
        api_key,
        {"remove_labels": ["unread"]},
    )
    print(f"Marked {args.message_id} as read.")


def cmd_send(args):
    api_key, inbox_id = get_credentials()
    data = {
        "to": args.to,
        "subject": args.subject,
        "text": args.text,
    }
    if args.html:
        data["html"] = args.html
    if args.cc:
        data["cc"] = args.cc
    if args.bcc:
        data["bcc"] = args.bcc

    result = api_request("POST", f"/inboxes/{inbox_id}/messages/send", api_key, data)
    msg_id = result.get("message_id", result.get("id", "unknown"))
    thread_id = result.get("thread_id", "")
    print(f"Sent. Message ID: {msg_id}")
    if thread_id:
        print(f"Thread ID: {thread_id}")


def _extract_email(from_field):
    """Extract email address from a 'from' field (string or dict)."""
    if isinstance(from_field, dict):
        return from_field.get("email", str(from_field))
    s = str(from_field)
    # Handle "Display Name <email@example.com>" format
    if "<" in s and ">" in s:
        return s[s.index("<") + 1:s.index(">")]
    return s


def cmd_reply(args):
    api_key, inbox_id = get_credentials()
    # Get original message to find thread
    mid = encode_id(args.message_id)
    original = api_request("GET", f"/inboxes/{inbox_id}/messages/{mid}", api_key)
    reply_addr = _extract_email(original.get("from", ""))
    subject = original.get("subject", "")
    if not subject.lower().startswith("re:"):
        subject = f"Re: {subject}"

    data = {
        "to": [reply_addr],
        "subject": subject,
        "text": args.text,
        "in_reply_to": args.message_id,
    }
    if original.get("thread_id"):
        data["thread_id"] = original["thread_id"]

    result = api_request("POST", f"/inboxes/{inbox_id}/messages/send", api_key, data)
    msg_id = result.get("message_id", result.get("id", "unknown"))
    print(f"Reply sent to {reply_addr}. Message ID: {msg_id}")


def cmd_forward(args):
    api_key, inbox_id = get_credentials()
    mid = encode_id(args.message_id)
    original = api_request("GET", f"/inboxes/{inbox_id}/messages/{mid}", api_key)
    subject = original.get("subject", "")
    if not subject.lower().startswith("fwd:"):
        subject = f"Fwd: {subject}"

    # Build forwarded body
    sender_str = str(original.get("from", "unknown"))
    orig_date = original.get("created_at", "unknown")
    orig_text = original.get("text", original.get("body", ""))

    fwd_body = args.text + "\n\n" if args.text else ""
    fwd_body += "---------- Forwarded message ----------\n"
    fwd_body += f"From: {sender_str}\n"
    fwd_body += f"Date: {orig_date}\n"
    fwd_body += f"Subject: {original.get('subject', '')}\n\n"
    fwd_body += orig_text

    data = {
        "to": args.to,
        "subject": subject,
        "text": fwd_body,
    }

    result = api_request("POST", f"/inboxes/{inbox_id}/messages/send", api_key, data)
    msg_id = result.get("message_id", result.get("id", "unknown"))
    print(f"Forwarded to {', '.join(args.to)}. Message ID: {msg_id}")


def cmd_create_draft(args):
    api_key, inbox_id = get_credentials()
    data = {
        "to": args.to,
        "subject": args.subject,
        "text": args.text,
    }
    if args.html:
        data["html"] = args.html

    result = api_request("POST", f"/inboxes/{inbox_id}/drafts", api_key, data)
    draft_id = result.get("draft_id", result.get("id", "unknown"))
    print(f"Draft created. Draft ID: {draft_id}")


def cmd_send_draft(args):
    api_key, inbox_id = get_credentials()
    result = api_request("POST", f"/inboxes/{inbox_id}/drafts/{args.draft_id}/send", api_key)
    msg_id = result.get("message_id", result.get("id", "unknown"))
    print(f"Draft sent. Message ID: {msg_id}")


def cmd_list_drafts(args):
    api_key, inbox_id = get_credentials()
    result = api_request("GET", f"/inboxes/{inbox_id}/drafts", api_key)
    drafts = result.get("drafts", [])
    if not drafts:
        print("No drafts.")
        return
    print(f"{len(drafts)} draft(s):\n")
    for d in drafts:
        to_list = d.get("to", [])
        to_str = ", ".join(to_list) if isinstance(to_list, list) else str(to_list)
        print(f"  ID: {d.get('draft_id', d.get('id', 'unknown'))}")
        print(f"  To: {to_str}")
        print(f"  Subject: {d.get('subject', '(no subject)')}")
        print()


def cmd_list_threads(args):
    api_key, inbox_id = get_credentials()
    result = api_request("GET", f"/inboxes/{inbox_id}/threads", api_key)
    threads = result.get("threads", [])
    if not threads:
        print("No threads.")
        return
    print(f"{len(threads)} thread(s):\n")
    for t in threads:
        print(f"  ID: {t.get('thread_id', t.get('id', 'unknown'))}")
        print(f"  Subject: {t.get('subject', '(no subject)')}")
        print(f"  Messages: {t.get('message_count', '?')}")
        print()


def cmd_get_thread(args):
    api_key, inbox_id = get_credentials()
    result = api_request("GET", f"/inboxes/{inbox_id}/threads/{args.thread_id}", api_key)
    print(json.dumps(result, indent=2))


def cmd_get_attachment(args):
    api_key, inbox_id = get_credentials()
    mid = encode_id(args.message_id)
    aid = urllib.parse.quote(args.attachment_id, safe="")
    result = api_request(
        "GET",
        f"/inboxes/{inbox_id}/messages/{mid}/attachments/{aid}",
        api_key,
    )
    # If the result has content (base64), decode and save to file
    content = result.get("content", "")
    filename = result.get("filename", args.attachment_id)
    if content and args.output:
        import base64
        with open(args.output, "wb") as f:
            f.write(base64.b64decode(content))
        print(f"Saved: {args.output} ({filename})")
    elif content:
        print(f"Attachment: {filename}")
        print(f"Content-Type: {result.get('content_type', 'unknown')}")
        print(f"Size: {len(content)} bytes (base64)")
        print("Use --output <path> to save to file")
    else:
        print(json.dumps(result, indent=2))


def cmd_list_inboxes(args):
    api_key, _ = get_credentials()
    result = api_request("GET", "/inboxes", api_key)
    inboxes = result.get("inboxes", [])
    if not inboxes:
        print("No inboxes.")
        return
    for inbox in inboxes:
        print(f"  ID: {inbox.get('inbox_id', 'unknown')}")
        print(f"  Email: {inbox.get('email', 'unknown')}")
        print(f"  Display name: {inbox.get('display_name', '')}")
        print()


def main():
    parser = argparse.ArgumentParser(description="Agentmail CLI")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("list-unread", help="List unread messages")

    p_get = sub.add_parser("get-message", help="Get a specific message")
    p_get.add_argument("message_id")

    p_read = sub.add_parser("mark-read", help="Mark a message as read")
    p_read.add_argument("message_id")

    p_send = sub.add_parser("send", help="Send an email")
    p_send.add_argument("--to", required=True, nargs="+", help="Recipient(s)")
    p_send.add_argument("--subject", required=True)
    p_send.add_argument("--text", required=True)
    p_send.add_argument("--html", default=None)
    p_send.add_argument("--cc", nargs="+", default=None)
    p_send.add_argument("--bcc", nargs="+", default=None)

    p_reply = sub.add_parser("reply", help="Reply to a message")
    p_reply.add_argument("message_id")
    p_reply.add_argument("--text", required=True)

    p_fwd = sub.add_parser("forward", help="Forward a message")
    p_fwd.add_argument("message_id")
    p_fwd.add_argument("--to", required=True, nargs="+", help="Forward recipient(s)")
    p_fwd.add_argument("--text", default=None, help="Optional note to prepend")

    p_draft = sub.add_parser("create-draft", help="Create a draft email")
    p_draft.add_argument("--to", required=True, nargs="+", help="Recipient(s)")
    p_draft.add_argument("--subject", required=True)
    p_draft.add_argument("--text", required=True)
    p_draft.add_argument("--html", default=None)

    p_send_draft = sub.add_parser("send-draft", help="Send an existing draft")
    p_send_draft.add_argument("draft_id")

    sub.add_parser("list-drafts", help="List draft emails")

    sub.add_parser("list-threads", help="List email threads")

    p_get_thread = sub.add_parser("get-thread", help="Get a specific thread")
    p_get_thread.add_argument("thread_id")

    p_attach = sub.add_parser("get-attachment", help="Download a message attachment")
    p_attach.add_argument("message_id")
    p_attach.add_argument("attachment_id")
    p_attach.add_argument("--output", default=None, help="Save to file path")

    sub.add_parser("list-inboxes", help="List all inboxes")

    args = parser.parse_args()
    commands = {
        "list-unread": cmd_list_unread,
        "get-message": cmd_get_message,
        "mark-read": cmd_mark_read,
        "send": cmd_send,
        "reply": cmd_reply,
        "forward": cmd_forward,
        "create-draft": cmd_create_draft,
        "send-draft": cmd_send_draft,
        "list-drafts": cmd_list_drafts,
        "list-threads": cmd_list_threads,
        "get-thread": cmd_get_thread,
        "get-attachment": cmd_get_attachment,
        "list-inboxes": cmd_list_inboxes,
    }
    commands[args.command](args)


if __name__ == "__main__":
    main()
