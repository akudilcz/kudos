#!/usr/bin/env python3
"""A stub OpenRouter chat-completions endpoint for testing the agent without a
real key or model. It replays a scripted sequence of assistant responses (tool
calls, then a final answer), advancing one step per POST. Two scripts exist:
SCRIPT (default) drives "sum the first 20 primes" (compile_app -> run_app);
IMPROVE_SCRIPT drives the self-improvement cycle (survey sources ->
compile_feature -> load_feature -> invoke_command). Tests select one by setting
Handler.script.

Usage: stub_openrouter.py [--port N]   (prints "PORT <n>" once listening)
"""

import argparse
import http.server
import json
import os
import threading

PRIMESUM_SOURCE = r'''const std = @import("std");
const abi = @import("abi.zig");
fn isPrime(n: u32) bool {
    if (n < 2) return false;
    var d: u32 = 2;
    while (d * d <= n) : (d += 1) if (n % d == 0) return false;
    return true;
}
pub fn main(api: *const abi.Api) i32 {
    var found: u32 = 0; var sum: u64 = 0; var n: u32 = 2;
    while (found < 20) : (n += 1) { if (isPrime(n)) { sum += n; found += 1; } }
    var line: [64]u8 = undefined;
    const out = std.fmt.bufPrint(&line, "sum of first 20 primes = {d}\n", .{sum}) catch return 3;
    api.print(api.ctx, out.ptr, out.len);
    return 0;
}
'''


# The agent requests a streamed completion (stream=true), so the endpoint answers
# in Server-Sent-Events: `data: <json>` lines, a finish_reason line, then [DONE] —
# the exact shape SseAccumulator (src/agent/openrouter.zig) folds back into one
# message. Tool arguments ride as a single delta fragment (index 0); the real
# service may split them across fragments, which the accumulator also handles.
def _sse(obj):
    return "data: " + json.dumps(obj) + "\n\n"


def tool_call_response(name, arguments):
    delta = {"choices": [{"delta": {"tool_calls": [
        {"index": 0, "id": "call_" + name, "type": "function",
         "function": {"name": name, "arguments": json.dumps(arguments)}}]}}]}
    finish = {"choices": [{"finish_reason": "tool_calls", "delta": {}}]}
    return _sse(delta) + _sse(finish) + "data: [DONE]\n\n"


def final_response(text):
    delta = {"choices": [{"delta": {"content": text}}]}
    finish = {"choices": [{"finish_reason": "stop", "delta": {}}]}
    return _sse(delta) + _sse(finish) + "data: [DONE]\n\n"


# The scripted conversation the stub plays back, in order.
SCRIPT = [
    tool_call_response("compile_app", {"name": "primesum", "source": PRIMESUM_SOURCE}),
    tool_call_response("run_app", {"name": "primesum"}),
    final_response("Done. I built primesum.kudos and ran it: the sum of the first 20 primes is 639."),
]

# The feature source is the committed sample — the canonical shape an
# agent-generated feature must follow (FeatureApi copied by value in register).
GREET_SOURCE = open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                 "samples", "greet_feature.zig")).read()

# The self-improvement cycle: survey what exists, write a feature, compile it,
# hot-load it, exercise it, report.
IMPROVE_SCRIPT = [
    tool_call_response("list_sources", {}),
    tool_call_response("compile_feature", {"name": "greet", "source": GREET_SOURCE}),
    tool_call_response("load_feature", {"name": "greet"}),
    tool_call_response("invoke_command", {"name": "greet", "args": "kudos"}),
    final_response("I extended kudos with a `greet` command; invoking it printed "
                   "a greeting from the hot-loaded feature."),
]


# The tool-surface cycle (AGT-006): write a file, read it back, report state.
FILE_SCRIPT = [
    tool_call_response("write_file", {"path": "/ramdisk/agent-note.txt",
                                      "content": "hello from the agent tool surface"}),
    tool_call_response("read_file", {"path": "/ramdisk/agent-note.txt"}),
    tool_call_response("system_state", {}),
    tool_call_response("open_app", {"name": "clock"}),
    final_response("I wrote /ramdisk/agent-note.txt, read it back, checked state, and opened the clock."),
]

# The directory half of the same surface: make a directory, write into it (and
# into one the write itself creates), list, then take it all back down again.
DIR_SCRIPT = [
    # An empty directory can be made and unmade...
    tool_call_response("make_dir", {"path": "scratch"}),
    tool_call_response("delete_dir", {"path": "scratch"}),
    # ...and a nested write makes the directories its path names.
    tool_call_response("write_file", {"path": "notes/deep/inner.txt", "content": "nested"}),
    tool_call_response("list_dir", {"path": "/ramdisk/notes"}),
    tool_call_response("delete_dir", {"path": "notes"}),
    tool_call_response("delete_file", {"path": "notes/deep/inner.txt"}),
    tool_call_response("list_dir", {"path": "/ramdisk"}),
    final_response("Made a directory, filled one by writing into it, and cleared both."),
]


class Handler(http.server.BaseHTTPRequestHandler):
    step = 0
    script = SCRIPT
    lock = threading.Lock()

    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        _ = self.rfile.read(n)
        with Handler.lock:
            i = min(Handler.step, len(Handler.script) - 1)
            Handler.step += 1
        body = Handler.script[i].encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=0)
    args = ap.parse_args()
    srv = http.server.HTTPServer(("127.0.0.1", args.port), Handler)
    print("PORT %d" % srv.server_address[1], flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
