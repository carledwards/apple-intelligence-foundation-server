#!/usr/bin/env python3
"""
Upload files to the Apple Intelligence Foundation Server and see what the model does.

Supports: .txt, .md, .json, .csv, .pdf, .docx, and other plain text files.

Usage:
    python upload.py <file>                        # analyze a file
    python upload.py <file> -p "summarize this"    # with a custom instruction
    python upload.py -t "some text"                # send raw text directly
    python upload.py <file> --server http://host:port  # custom server URL
    python upload.py --chat                        # interactive chat mode
    python upload.py <file> --chat                 # upload file then chat about it
"""

import argparse
import json
import mimetypes
import os
import sys

import requests


def extract_text_from_pdf(path):
    from PyPDF2 import PdfReader

    reader = PdfReader(path)
    pages = []
    for i, page in enumerate(reader.pages, 1):
        text = page.extract_text()
        if text:
            pages.append(f"--- Page {i} ---\n{text}")
    if not pages:
        raise ValueError("Could not extract any text from the PDF.")
    return "\n\n".join(pages)


def extract_text_from_docx(path):
    import docx

    doc = docx.Document(path)
    paragraphs = [p.text for p in doc.paragraphs if p.text.strip()]
    if not paragraphs:
        raise ValueError("Could not extract any text from the DOCX.")
    return "\n\n".join(paragraphs)


def extract_text_from_file(path):
    ext = os.path.splitext(path)[1].lower()

    if ext == ".pdf":
        return extract_text_from_pdf(path)
    elif ext == ".docx":
        return extract_text_from_docx(path)
    else:
        # Try reading as plain text (covers .txt, .md, .json, .csv, .html, .xml, etc.)
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()


def create_session(server_url):
    url = f"{server_url.rstrip('/')}/sessions"
    resp = requests.post(url, timeout=30)
    resp.raise_for_status()
    return resp.json()["session_id"]


def delete_session(server_url, session_id):
    url = f"{server_url.rstrip('/')}/sessions/{session_id}"
    resp = requests.delete(url, timeout=30)
    resp.raise_for_status()


def send_to_server(server_url, prompt, session_id=None):
    url = f"{server_url.rstrip('/')}/inference"
    payload = {"prompt": prompt}
    if session_id:
        payload["session_id"] = session_id
    resp = requests.post(url, json=payload, timeout=120)
    resp.raise_for_status()
    return resp.json()


def interactive_mode(server_url, initial_content=None):
    session_id = create_session(server_url)
    print(f"Session started: {session_id[:8]}...")
    print("Type 'quit' or 'exit' to end, 'new' for a fresh session.\n")

    try:
        # Send initial content if provided (e.g. from a file upload)
        if initial_content:
            print("Sending file content...")
            print("-" * 60)
            result = send_to_server(server_url, initial_content, session_id)
            print(result.get("response", json.dumps(result, indent=2)))
            print("-" * 60)
            print()

        while True:
            try:
                user_input = input("You: ").strip()
            except EOFError:
                break

            if not user_input:
                continue

            if user_input.lower() in ("quit", "exit"):
                break

            if user_input.lower() == "new":
                delete_session(server_url, session_id)
                session_id = create_session(server_url)
                print(f"New session: {session_id[:8]}...")
                continue

            try:
                result = send_to_server(server_url, user_input, session_id)
                print(f"\nAssistant: {result.get('response', json.dumps(result, indent=2))}\n")
            except requests.exceptions.ConnectionError:
                print("Error: Lost connection to server.", file=sys.stderr)
                break
            except requests.exceptions.HTTPError as e:
                try:
                    body = e.response.json()
                    print(f"Error ({e.response.status_code}): {body.get('error', body)}", file=sys.stderr)
                except Exception:
                    print(f"Error: {e}", file=sys.stderr)
    finally:
        try:
            delete_session(server_url, session_id)
        except Exception:
            pass
        print("Session ended.")


def main():
    parser = argparse.ArgumentParser(
        description="Upload files to the Apple Intelligence Foundation Server"
    )
    parser.add_argument("file", nargs="?", help="Path to a file to upload")
    parser.add_argument("-t", "--text", help="Send raw text instead of a file")
    parser.add_argument(
        "-p",
        "--prompt",
        default="Please analyze the following content and provide a summary:",
        help="Instruction to prepend to the content (default: summarize)",
    )
    parser.add_argument(
        "--server",
        default="http://localhost:8080",
        help="Server URL (default: http://localhost:8080)",
    )
    parser.add_argument(
        "--raw",
        action="store_true",
        help="Send the content as-is without prepending the prompt instruction",
    )
    parser.add_argument(
        "--chat",
        action="store_true",
        help="Start interactive chat mode (optionally after uploading a file)",
    )
    parser.add_argument(
        "--session",
        help="Use an existing session ID for a one-shot request",
    )
    args = parser.parse_args()

    # Interactive chat mode
    if args.chat:
        initial_content = None
        if args.file:
            if not os.path.isfile(args.file):
                print(f"Error: File not found: {args.file}", file=sys.stderr)
                sys.exit(1)
            print(f"Reading: {args.file}")
            content = extract_text_from_file(args.file)
            print(f"Extracted {len(content):,} characters from {args.file}")
            if args.raw:
                initial_content = content
            else:
                initial_content = f"{args.prompt}\n\n{content}"
        try:
            interactive_mode(args.server, initial_content)
        except requests.exceptions.ConnectionError:
            print(
                f"Error: Could not connect to {args.server}. Is the server running?",
                file=sys.stderr,
            )
            sys.exit(1)
        return

    if not args.file and not args.text:
        parser.print_help()
        sys.exit(1)

    # Extract content
    if args.text:
        content = args.text
        source = "direct text"
    else:
        if not os.path.isfile(args.file):
            print(f"Error: File not found: {args.file}", file=sys.stderr)
            sys.exit(1)
        print(f"Reading: {args.file}")
        content = extract_text_from_file(args.file)
        source = args.file

    char_count = len(content)
    print(f"Extracted {char_count:,} characters from {source}")

    # Warn if content is very large (context window is ~4096 tokens ≈ 12-16k chars)
    if char_count > 14000:
        print(
            f"Warning: Content is {char_count:,} chars, which may exceed the model's "
            f"~4096 token context window. Consider sending a shorter excerpt.",
            file=sys.stderr,
        )

    # Build the prompt
    if args.raw:
        prompt = content
    else:
        prompt = f"{args.prompt}\n\n{content}"

    print(f"\nSending to {args.server} ...")
    print("-" * 60)

    try:
        result = send_to_server(args.server, prompt, args.session)
        print(result.get("response", json.dumps(result, indent=2)))
    except requests.exceptions.ConnectionError:
        print(
            f"Error: Could not connect to {args.server}. Is the server running?",
            file=sys.stderr,
        )
        sys.exit(1)
    except requests.exceptions.HTTPError as e:
        try:
            body = e.response.json()
            print(f"Error ({e.response.status_code}): {body.get('error', body)}", file=sys.stderr)
        except Exception:
            print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
