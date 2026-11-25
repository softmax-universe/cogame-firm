"""Complete published firms through numeric and full role-specific text actions."""

import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = Path(sys.argv[1]).resolve()
WORDINGS = (
    "canonical",
    "plain",
    "numbered",
    "questions",
    "reordered",
    "heldout-briefing",
    "heldout-reference",
)


def play(variant, seed, wording="canonical", prompt_seed=0, private=False):
    command = [
        str(BRIDGE),
        str(ROOT / "coworld_manifest_template.json"),
        variant,
    ]
    command.append("text")
    with subprocess.Popen(
        command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True
    ) as process:
        assert process.stdin is not None and process.stdout is not None

        def request(value):
            process.stdin.write(json.dumps(value) + "\n")
            process.stdin.flush()
            return json.loads(process.stdout.readline())

        observation = request(
            {
                "kind": "reset",
                "players": 5,
                "seed": str(seed),
                "promptVariant": wording,
                "promptSeed": prompt_seed,
                "split": "test",
            }
        )
        trace, systems, roles = [], {}, {}
        frozen = None
        while observation["kind"] == "decision":
            index, seat = observation["decision_id"], observation["seat"]
            assert index == len(trace)
            messages = observation["messages"]
            assert ("disabled in this variant" in messages[0]["content"]) == (
                variant == "silent-floor"
            )
            systems.setdefault(seat, messages[0]["content"])
            assert systems[seat] == messages[0]["content"]
            view = observation["semantic_view"]
            roles[seat] = view["role"]
            metadata = view["prompt_template"]
            assert metadata["bank"] == "firm-rules-v2"
            assert metadata["variant"] == (
                WORDINGS[prompt_seed] if wording == "mixed" else wording
            )
            for message in messages:
                assert (
                    metadata[message["role"] + "_sha256"].lower()
                    == hashlib.sha256(message["content"].encode()).hexdigest()
                )
            public = (
                view["directive"],
                view["payroll"],
                view["split"],
                [(m["setup"], m["order"], m["units"]) for m in view["floor"]],
            )
            if index % 5 == 0:
                frozen = public
                assert view["role"] == "Manager"
            assert frozen == public
            assert all(
                "condition" not in machine and "notes" not in machine
                for machine in view["floor"]
            )
            if view["role"] == "Manager":
                assert "board" in view and "own" not in view
            else:
                assert "board" not in view and "ledger" not in view and "own" in view
            if private:
                for other in range(5):
                    if other != seat:
                        assert (
                            f"PRIVATE-{other}-"
                            not in json.dumps(view) + messages[1]["content"]
                        )
                if index >= 5:
                    assert view["notes"].startswith(f"PRIVATE-{seat}-")
            teacher = json.loads(request({"kind": "teacher"})["response"])
            if private:
                teacher["notes"] = f"PRIVATE-{seat}-" + "λ" * 900
                if view["role"] == "Manager":
                    teacher["payroll"] = 40
                    teacher["orders"] = ["A", "B", "A", "B"]
                    teacher["split"] = [1, 1, 1, 1]
                    teacher["directive"] = "PUBLIC\n" + "δ" * 300
                else:
                    teacher["run"] = 6
                    teacher["maint"] = 3
                    teacher["line"] = "B"
                    teacher["report"] = "REPORT\n" + "δ" * 180
                # Verify legacy shims and surrounding prose are rejected without advancing state.
                bad_payloads = [
                    "Here is my move: " + json.dumps(teacher),
                    json.dumps(teacher) + " " + json.dumps(teacher),
                    json.dumps({**teacher, "payroll": "40.0"} if view["role"] == "Manager" else {**teacher, "line": " b "}),
                ]
                for bad in bad_payloads:
                    rejected = request({"kind": "step", "decision_id": index, "response": bad})
                    assert rejected["kind"] == "rejected", rejected
                response_text = (
                    f"```json\n{json.dumps(teacher)}\n```"
                    if index % 2 == 0
                    else f"```\n{json.dumps(teacher)}\n```"
                )
            else:
                response_text = json.dumps(teacher)
            result = request(
                {"kind": "step", "decision_id": index, "response": response_text}
            )
            assert result["kind"] == "accepted"
            if private:
                action = result["action"]
                assert action["notes"].startswith(f"PRIVATE-{seat}-")
                if view["role"] == "Manager":
                    assert action["payroll"] == 40 and action["split"] == [25] * 4
                    assert action["orders"] == ["A", "B", "A", "B"]
                    assert (
                        len(action["directive"]) == 240
                        and "\n" not in action["directive"]
                    )
                else:
                    assert (action["line"], action["run"], action["maint"]) == (
                        "B",
                        6,
                        3,
                    )
                    assert len(action["report"]) == (
                        120 if variant == "standard" else 0
                    )
            else:
                expected = dict(teacher)
                if variant == "silent-floor" and view["role"] == "Worker":
                    expected["report"] = ""
                assert result["action"] == expected
            trace.append(messages[1]["content"])
            observation = result["observation"]
        assert len(trace) == 40 and set(observation["scores"]) == {
            str(s) for s in range(5)
        }
        process.stdin.close()
        assert process.wait(timeout=5) == 0
        return trace, observation, systems, roles


for variant in ("standard", "silent-floor"):
    for seed in (17,):
        baseline = play(variant, seed)
        distinct = []
        for wording, prompt_seed in [(name, 0) for name in WORDINGS] + [("mixed", 4)]:
            trace, outcome, systems, roles = play(variant, seed, wording, prompt_seed)
            assert (trace, outcome) == baseline[:2]
            assert sorted(roles.values()) == ["Manager"] + ["Worker"] * 4
            if wording == "canonical":
                assert systems == baseline[2]
            if wording == "mixed":
                assert systems == distinct[prompt_seed]
            else:
                distinct.append(systems)
        assert all(len({entry[seat] for entry in distinct}) == 7 for seat in range(5))
    play(variant, 17, private=True)
    print(
        variant,
        "10 complete matched/private-role games PASS",
        flush=True,
    )
for wording in WORDINGS[-2:]:
    rejected = subprocess.run(
        [str(BRIDGE), str(ROOT / "coworld_manifest_template.json"), "standard", "text"],
        input=json.dumps(
            {
                "kind": "reset",
                "players": 5,
                "seed": "17",
                "promptVariant": wording,
                "split": "train",
            }
        )
        + "\n",
        text=True,
        capture_output=True,
        timeout=10,
    )
    assert (
        rejected.returncode != 0
        and "held-out wording cannot be used for training" in rejected.stderr
    )
print(
    "20 complete text games and held-out training gate PASS",
    flush=True,
)
