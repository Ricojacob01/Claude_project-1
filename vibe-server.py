#!/usr/bin/env python3
"""
Vibe Office Server - Local agent launcher for Claude Code
Run: python vibe-server.py
Then open: http://localhost:5555
"""

import json
import os
import shutil
import subprocess
import sys
import threading
import time
import queue
from http.server import HTTPServer, SimpleHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

PORT = int(os.environ.get("VIBE_PORT", 5555))

# Find claude CLI
CLAUDE_BIN = None
for candidate in [
    os.path.expanduser("~/.local/bin/claude"),
    shutil.which("claude") or "",
    shutil.which("claude-code") or "",
    "/usr/local/bin/claude",
    "/opt/homebrew/bin/claude",
]:
    if candidate and os.path.isfile(candidate):
        CLAUDE_BIN = candidate
        break

if not CLAUDE_BIN:
    print("ERROR: Could not find 'claude' CLI. Install it first.")
    print("Try: npm install -g @anthropic-ai/claude-code")
    sys.exit(1)

print(f"Using Claude CLI: {CLAUDE_BIN}")

# Active agent processes
active_agents = {}  # id -> {"process", "output_queue", "status", "prompt"}
agent_counter = 0
agent_lock = threading.Lock()


def run_agent(agent_id, prompt):
    """Run claude CLI in a subprocess and capture output."""
    agent = active_agents[agent_id]
    q = agent["output_queue"]

    try:
        agent["status"] = "running"
        q.put({"type": "status", "status": "running"})

        proc = subprocess.Popen(
            [CLAUDE_BIN, "-p", prompt, "--no-input"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            env={k: v for k, v in os.environ.items() if k != "CLAUDECODE"} | {"NO_COLOR": "1"},
        )
        agent["process"] = proc

        for line in proc.stdout:
            q.put({"type": "output", "data": line})

        proc.wait()
        exit_code = proc.returncode
        agent["status"] = "done" if exit_code == 0 else "error"
        q.put({"type": "status", "status": agent["status"], "exit_code": exit_code})

    except Exception as e:
        agent["status"] = "error"
        q.put({"type": "error", "data": str(e)})

    q.put({"type": "done"})


class VibeHandler(SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        # Quiet logging
        pass

    def do_GET(self):
        parsed = urlparse(self.path)

        if parsed.path == "/" or parsed.path == "/index.html":
            self.serve_html()

        elif parsed.path == "/api/status":
            self.send_json({"status": "ok", "claude_bin": CLAUDE_BIN, "active_agents": len(active_agents)})

        elif parsed.path == "/api/agents":
            agents_summary = {}
            with agent_lock:
                for aid, a in active_agents.items():
                    agents_summary[aid] = {
                        "status": a["status"],
                        "prompt": a["prompt"][:100],
                    }
            self.send_json(agents_summary)

        elif parsed.path.startswith("/api/stream/"):
            agent_id = parsed.path.split("/")[-1]
            self.stream_agent(agent_id)

        else:
            super().do_GET()

    def do_POST(self):
        parsed = urlparse(self.path)

        if parsed.path == "/api/launch":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length)
            data = json.loads(body)

            prompt = data.get("prompt", "")
            agent_type = data.get("agent_type", "general-purpose")
            skills = data.get("skills", [])

            if not prompt:
                self.send_json({"error": "No prompt provided"}, 400)
                return

            # Build full prompt with skill context
            full_prompt = prompt
            if skills:
                skill_list = "\n".join(f"- /{s['name']} ({s['type']}): {s.get('desc', '')}" for s in skills)
                full_prompt += f"\n\nYou have access to these skills — use them as needed:\n{skill_list}"

            global agent_counter
            with agent_lock:
                agent_counter += 1
                agent_id = f"agent-{agent_counter}"
                active_agents[agent_id] = {
                    "process": None,
                    "output_queue": queue.Queue(),
                    "status": "starting",
                    "prompt": full_prompt,
                }

            thread = threading.Thread(target=run_agent, args=(agent_id, full_prompt), daemon=True)
            thread.start()

            self.send_json({"agent_id": agent_id, "status": "starting"})

        elif parsed.path == "/api/stop":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length)
            data = json.loads(body)
            agent_id = data.get("agent_id", "")

            with agent_lock:
                agent = active_agents.get(agent_id)
                if agent and agent["process"]:
                    agent["process"].terminate()
                    agent["status"] = "stopped"
                    self.send_json({"status": "stopped"})
                else:
                    self.send_json({"error": "Agent not found"}, 404)

        else:
            self.send_json({"error": "Not found"}, 404)

    def stream_agent(self, agent_id):
        """Server-Sent Events stream for agent output."""
        with agent_lock:
            agent = active_agents.get(agent_id)

        if not agent:
            self.send_json({"error": "Agent not found"}, 404)
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()

        q = agent["output_queue"]
        while True:
            try:
                msg = q.get(timeout=30)
                event_data = json.dumps(msg)
                self.wfile.write(f"data: {event_data}\n\n".encode())
                self.wfile.flush()
                if msg.get("type") == "done":
                    break
            except queue.Empty:
                # Send keepalive
                self.wfile.write(b": keepalive\n\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                break

    def send_json(self, data, code=200):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def serve_html(self):
        """Serve the vibe-office.html if it exists, otherwise a message."""
        html_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vibe-office.html")
        if os.path.exists(html_path):
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            with open(html_path, "rb") as f:
                self.wfile.write(f.read())
        else:
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(b"""
            <html><body style="background:#0f0e17;color:#e2e8f0;font-family:monospace;padding:40px;text-align:center">
            <h1>Vibe Office</h1>
            <p>Run <code>./vibe-office.sh</code> first to generate the HTML, then refresh this page.</p>
            </body></html>
            """)


class ThreadedHTTPServer(HTTPServer):
    """Handle requests in separate threads."""
    def process_request(self, request, client_address):
        thread = threading.Thread(target=self._handle, args=(request, client_address), daemon=True)
        thread.start()

    def _handle(self, request, client_address):
        try:
            self.finish_request(request, client_address)
        except Exception:
            self.handle_error(request, client_address)
        finally:
            self.shutdown_request(request)


if __name__ == "__main__":
    # Auto-generate HTML if not present
    html_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vibe-office.html")
    script_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vibe-office.sh")
    if not os.path.exists(html_path) and os.path.exists(script_path):
        print("Generating vibe-office.html...")
        subprocess.run(["bash", script_path, html_path], check=True)

    server = ThreadedHTTPServer(("127.0.0.1", PORT), VibeHandler)
    print(f"\n  VIBE OFFICE SERVER")
    print(f"  Local:   http://localhost:{PORT}")
    print(f"  Claude:  {CLAUDE_BIN}")
    print(f"\n  Press Ctrl+C to stop\n")

    try:
        import webbrowser
        webbrowser.open(f"http://localhost:{PORT}")
    except Exception:
        pass

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.shutdown()
