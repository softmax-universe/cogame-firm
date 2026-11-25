"""System proof: unregistered seats cannot authorize game-side inference.

Run with an already compiled Firm binary and an owned output directory. All HTTP
responses are synthetic loopback fixtures; this never invokes a provider.
"""

import argparse
import base64
import hashlib
import http.server
import json
import re
import socket
import subprocess
import threading
import time
import uuid
from pathlib import Path

from websockets.exceptions import ConnectionClosed
from websockets.sync.client import connect


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def run_case(binary, root, case):
    output = root / case
    output.mkdir()
    calls = []
    clients = []
    external_errors = []
    first_request = threading.Event()
    started = time.monotonic()

    class Fixture(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            raw = self.rfile.read(int(self.headers["Content-Length"]))
            assert len(raw) < 65536
            request = json.loads(raw)
            assert request["model"] == "anthropic/claude-haiku-4.5"
            seat = int(self.headers["X-Coworld-Player-Slot"])
            assert seat == 0 and len(calls) < 8
            action = {"line": "A", "run": 6, "maint": 3, "notes": "fixture"}
            call_id = str(uuid.uuid4())
            if case == "native-provider-error":
                response = json.dumps(
                    {"error": {"type": "server_error", "message": "synthetic 500"}}
                ).encode()
                calls.append(
                    {
                        "slot": seat,
                        "request_b64": base64.b64encode(raw).decode(),
                        "response_b64": base64.b64encode(response).decode(),
                        "fixture_call_id": call_id,
                        "elapsed": time.monotonic() - started,
                    }
                )
                first_request.set()
                self.send_response(500)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(response)))
                self.send_header("X-Softmax-Llm-Call-Id", call_id)
                self.send_header("request-id", call_id)
                self.end_headers()
                self.wfile.write(response)
                return
            if case == "native-fenced":
                if len(calls) % 2 == 0:
                    text = f"```json\n{json.dumps(action)}\n```"
                else:
                    text = f"```\n{json.dumps(action)}\n```"
            elif case == "native-rejected-prose":
                text = f"Here is my move: {json.dumps(action)}"
            elif case == "native-ambiguous-multi-object":
                text = f"{json.dumps(action)} {json.dumps(action)}"
            else:
                text = json.dumps(action)
            response = json.dumps(
                {
                    "content": [{"type": "text", "text": text}],
                    "stop_reason": "end_turn",
                }
            ).encode()
            calls.append(
                {
                    "slot": seat,
                    "request_b64": base64.b64encode(raw).decode(),
                    "response_b64": base64.b64encode(response).decode(),
                    "fixture_call_id": call_id,
                    "elapsed": time.monotonic() - started,
                }
            )
            first_request.set()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(response)))
            self.send_header("X-Softmax-Llm-Call-Id", call_id)
            self.send_header("request-id", call_id)
            self.end_headers()
            self.wfile.write(response)

        def log_message(self, format, *_args):
            pass

    fixture = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    threading.Thread(target=fixture.serve_forever, daemon=True).start()
    port = free_port()
    config = {
        "players": [{"name": f"fixture{i}"} for i in range(5)],
        "tokens": [f"token{i}" for i in range(5)],
        "num_agents": 5,
        "seed": 7,
        "shifts": 4,
        "reports": True,
        "turnDelayMs": 400,
        "player_connect_timeout_seconds": 1.0,
        "maxOutputTokens": 800,
        "llmTimeoutSeconds": 5,
        "episodeTimeoutSeconds": 60,
    }
    (output / "config.json").write_text(json.dumps(config))
    env = {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": str(Path.home()),
        "COGAME_SAVE_TRAJECTORY_URI": (output / "trajectory.jsonl").as_uri(),
        "COGAME_PLAYER_FAILURE_URI": (output / "player_failure.json").as_uri(),
        "COWORLD_SOURCE_REVISION": "local-registration-lock-fix",
        "COWORLD_GAME_VERSION": "fixture-only",
        "COWORLD_EPISODE_ID": f"fixture-{case}",
    }
    if case != "native-missing-credentials":
        env["COWORLD_LLM_ENDPOINT"] = f"http://127.0.0.1:{fixture.server_port}"
        env["COWORLD_LLM_MODEL"] = "anthropic/claude-haiku-4.5"
    command = [
        str(binary),
        "--host:127.0.0.1",
        f"--port:{port}",
        "--config-path:" + str(output / "config.json"),
        "--results-uri:" + (output / "results.json").as_uri(),
        "--save-replay-uri:" + (output / "replay.json").as_uri(),
    ]
    (output / "command.json").write_text(
        json.dumps(
            {
                "argv": command,
                "environment_keys": sorted(env),
                "provider_credentials_forwarded": False,
            }
        )
    )

    def player(slot):
        deadline = time.monotonic() + 5
        while True:
            try:
                ws = connect(
                    f"ws://127.0.0.1:{port}/player?slot={slot}&token=token{slot}",
                    open_timeout=0.5,
                    max_size=2**20,
                    proxy=None,
                )
                break
            except OSError:
                assert time.monotonic() < deadline
                time.sleep(0.05)
        clients.append(ws)
        assert json.loads(ws.recv(timeout=2))["type"] == "welcome"
        return ws

    def external(ws):
        try:
            while True:
                frame = json.loads(ws.recv(timeout=10))
                if frame["type"] == "observation":
                    if case == "external-disconnected":
                        ws.close()
                        return
                    payload = (
                        {"line": "line a", "run": 6, "maint": 3}
                        if case == "external-rejected"
                        else {"line": "A", "run": 6, "maint": 3}
                    )
                    ws.send(
                        json.dumps(
                            {
                                "type": "action",
                                "id": frame["id"],
                                "action": payload,
                            }
                        )
                    )
                if frame["type"] in {"final", "error"}:
                    return
        except ConnectionClosed:
            pass
        except (OSError, ValueError, KeyError, TimeoutError) as error:
            external_errors.append(str(error))

    with (output / "game.log").open("w") as log:
        game = subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            for slot in [1, 2, 3, 4]:
                peer = player(slot)
                if case == "stale-replaced" and slot == 4:
                    held = peer
                    continue
                peer.send(
                    json.dumps(
                        {
                            "type": "prompt",
                            "prompt": "original steady registration",
                            "scripted": "steady",
                        }
                    )
                )
            if case != "missing":
                ws = player(0)
                if case in {
                    "native",
                    "native-disconnected",
                    "native-fenced",
                    "native-rejected-prose",
                    "native-ambiguous-multi-object",
                    "native-provider-error",
                    "native-missing-credentials",
                }:
                    source = Path("src/firm_player.nim").read_text()
                    operator_match = re.search(
                        r'const DefaultPrompt = """\n(.*?)"""', source, re.DOTALL
                    )
                    assert operator_match is not None
                    operator = operator_match[1]
                    ws.send(
                        json.dumps(
                            {"type": "prompt", "prompt": operator, "scripted": ""}
                        )
                    )
                    if case == "native-disconnected":
                        assert first_request.wait(3), (
                            "registered native control never started"
                        )
                        ws.close()
                elif case == "taskmaster":
                    ws.send(
                        json.dumps(
                            {
                                "type": "prompt",
                                "prompt": "original taskmaster registration",
                                "scripted": "taskmaster",
                            }
                        )
                    )
                elif case in {"external", "external-rejected", "external-disconnected"}:
                    ws.send(json.dumps({"type": "register", "control": "external"}))
                    threading.Thread(target=external, args=(ws,), daemon=True).start()
                elif case == "malformed":
                    ws.send(
                        json.dumps(
                            {"type": "prompt", "prompt": 13, "scripted": "steady"}
                        )
                    )
                    ws.send(
                        json.dumps(
                            {
                                "type": "prompt",
                                "prompt": "invalid",
                                "scripted": "unknown-policy",
                            }
                        )
                    )
                elif case == "unregistered-disconnected":
                    ws.close()
                elif case == "stale-replaced":
                    replacement = player(0)
                    replacement.send(
                        json.dumps(
                            {
                                "type": "prompt",
                                "prompt": "current steady owner",
                                "scripted": "steady",
                            }
                        )
                    )
                    # Exercise real authenticated replacement, then stale frames
                    # for all three mutating message kinds before play starts.
                    ws.send(
                        json.dumps(
                            {
                                "type": "prompt",
                                "prompt": "stale native owner",
                                "scripted": "",
                            }
                        )
                    )
                    ws.send(json.dumps({"type": "register", "control": "external"}))
                    ws.send(
                        json.dumps(
                            {
                                "type": "action",
                                "id": 1,
                                "action": {"line": "B", "run": 0, "maint": 0},
                            }
                        )
                    )
                    time.sleep(0.05)
                    held.send(
                        json.dumps(
                            {
                                "type": "prompt",
                                "prompt": "original steady registration",
                                "scripted": "steady",
                            }
                        )
                    )
            game.wait(timeout=15)
        finally:
            if game.poll() is None:
                game.terminate()
                game.wait(timeout=2)
            for ws in clients:
                ws.close()
            fixture.shutdown()
    (output / "http.json").write_text(json.dumps(calls, indent=2))
    assert not external_errors, external_errors
    rows = [
        json.loads(line)
        for line in (output / "trajectory.jsonl").read_text().splitlines()
    ]
    target = [row for row in rows if row.get("seat") == "0"]
    episode_row = [row for row in rows if row.get("event_type") == "episode"]
    assert len(episode_row) == 1, episode_row
    episode_row = episode_row[0]
    origins = [row["observation"]["native_execution"]["origin"] for row in target]
    failed_cases = {
        "missing",
        "malformed",
        "unregistered-disconnected",
        "native-rejected-prose",
        "native-ambiguous-multi-object",
        "native-provider-error",
        "native-missing-credentials",
        "external-rejected",
        "external-disconnected",
    }
    results = None
    if case in failed_cases:
        assert game.returncode != 0, (case, game.returncode)
        assert not (output / "results.json").exists(), (
            f"{case} must not write authoritative numeric results.json"
        )
        assert not (output / "replay.json").exists(), (
            f"{case} must not write scored replay.json"
        )
        failure = json.loads((output / "player_failure.json").read_text())
        assert failure["status"] == "failed", failure
        assert failure["slot"] == 0 and failure["shift"] == 0 and failure["reason"], failure
        for forbidden in ("scores", "pay", "profit", "revenue", "wages", "units"):
            assert forbidden not in failure, (case, forbidden, failure)
        assert episode_row["status"] == "failed", episode_row
        assert episode_row["participant_outcomes"] is None, episode_row
        for forbidden in ("scores", "pay", "profit", "revenue", "wages", "units"):
            assert forbidden not in episode_row["outcome"], (case, forbidden, episode_row)
        assert len(target) == 1
        assert target[0]["observation"]["native_execution"]["native_applied"] is False
        assert target[0]["executed_action"] is None
        if case in {"native-rejected-prose", "native-ambiguous-multi-object"}:
            assert len(calls) == 2, (case, len(calls))
            assert origins == ["model"]
            assert failure["failure_kind"] == "invalid_action", failure
            assert failure["infrastructure_failure"] is False, failure
            assert target[0]["action_status"] == "rejected"
            assert len(target[0]["attempts"]) == 2
        elif case == "native-provider-error":
            assert len(calls) == 1, (case, len(calls))
            assert origins == ["provider"]
            assert failure["failure_kind"] == "provider_error", failure
            assert failure["infrastructure_failure"] is True, failure
            assert target[0]["action_status"] == "missing"
            assert len(target[0]["attempts"]) == 1
        elif case == "native-missing-credentials":
            assert len(calls) == 0, (case, len(calls))
            assert origins == ["provider"]
            assert failure["failure_kind"] == "provider_error", failure
            assert failure["infrastructure_failure"] is True, failure
            assert target[0]["action_status"] == "missing"
            assert not target[0]["attempts"]
        elif case == "external-rejected":
            assert len(calls) == 0, (case, len(calls))
            assert origins == ["external"]
            assert failure["failure_kind"] == "invalid_action", failure
            assert failure["infrastructure_failure"] is False, failure
            assert target[0]["action_status"] == "rejected"
        elif case == "external-disconnected":
            assert len(calls) == 0, (case, len(calls))
            assert origins == ["external"]
            assert failure["failure_kind"] == "missing_action", failure
            assert failure["infrastructure_failure"] is False, failure
            assert target[0]["action_status"] == "missing"
        else:
            assert len(calls) == 0, (case, len(calls))
            assert origins == ["unregistered"]
            assert failure["failure_kind"] == "missing_action", failure
            assert failure["infrastructure_failure"] is False, failure
            assert target[0]["observation"]["policy_registered"] is False
            assert target[0]["action_status"] == "missing"
            assert not target[0]["attempts"]
    else:
        assert game.returncode == 0, (case, game.returncode)
        assert not (output / "player_failure.json").exists()
        results = json.loads((output / "results.json").read_text())
        assert (
            results["reason"] == "complete"
            and results["shifts"] == results["maxShifts"] == 4
        )
        assert len(rows) == 21
        assert len(target) == 4
        expected_http = 4 if case in {"native", "native-disconnected", "native-fenced"} else 0
        assert len(calls) == expected_http, (case, len(calls), origins)
        if case in {"native", "native-disconnected", "native-fenced"}:
            assert origins == ["model"] * 4
            assert all(row["observation"]["policy_registered"] is True for row in target)
            assert all(len(row["attempts"]) == 1 for row in target)
            assert all(row["action_status"] == "accepted" for row in target)
        elif case == "external":
            assert origins == ["external"] * 4
        else:
            assert origins == ["scripted"] * 4
    summary = {
        "case": case,
        "HTTP": len(calls),
        "slot0_origins": origins,
        "rows": len(rows),
        "elapsed_seconds": time.monotonic() - started,
        "provider_calls": 0,
        "teacher_admission": 0,
        "results": results,
    }
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    binary = args.game.resolve()
    operator_match = re.search(
        r'const DefaultPrompt = """\n(.*?)"""',
        Path("src/firm_player.nim").read_text(),
        re.DOTALL,
    )
    assert operator_match is not None
    (root / "operator-prompt.txt").write_text(operator_match[1])
    summaries = [
        run_case(binary, root, case)
        for case in [
            "missing",
            "native",
            "native-fenced",
            "native-rejected-prose",
            "native-ambiguous-multi-object",
            "native-provider-error",
            "native-missing-credentials",
            "taskmaster",
            "external",
            "external-rejected",
            "external-disconnected",
            "native-disconnected",
            "malformed",
            "unregistered-disconnected",
            "stale-replaced",
        ]
    ]
    (root / "summary.json").write_text(
        json.dumps(
            {
                "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
                "cases": summaries,
            },
            indent=2,
        )
        + "\n"
    )
    print(
        json.dumps(
            [
                {
                    key: case[key]
                    for key in ["case", "HTTP", "slot0_origins", "elapsed_seconds"]
                }
                for case in summaries
            ],
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
