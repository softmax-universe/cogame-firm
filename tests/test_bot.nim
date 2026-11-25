## The scripted baselines must play whole episodes without ever proposing an
## illegal move — they are both the no-credentials fallback (offline
## certification) and fieldable policies, so this is the completion path.
## Both are role-complete: a policy does not know which role the seed will
## deal it.

import std/[json, monotimes, os, strutils, times, unicode, unittest]
import firm/[llm, sim, prompts]

proc fixture(seed: int, shifts = 8, reports = true): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.shifts = shifts
  result.reports = reports
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("t" & $index)

proc apply(sim: var Sim, seat: int, decision: Decision) =
  ## The bot's move must be legal as-is: applyMemo / applyWork raise on
  ## anything else and would fail these tests.
  if sim.isManager(seat):
    check decision.payroll in 0 .. MaxPayrollPercent
    check decision.split.len == Machines
    var total = 0
    for share in decision.split:
      check share >= 0
      total += share
    check total == 100
    check decision.orders.len == Machines
    for line in decision.orders:
      check line == "A" or line == "B"
    check decision.say.runeLen <= MaxDirectiveLen
    sim.applyMemo(seat, decision.orders, decision.payroll, decision.split,
      decision.say, decision.notes, true)
  else:
    check decision.line == "A" or decision.line == "B"
    check decision.run in 0 .. ShiftHours
    check decision.maint in 0 .. ShiftHours
    check decision.run + decision.maint <= ShiftHours
    check decision.say.runeLen <= MaxReportLen
    sim.applyWork(seat, decision.line, decision.run, decision.maint,
      decision.say, decision.notes, true)
  check decision.notes.len == 0

proc playScripted(config: GameConfig,
    kinds: array[Seats, ScriptKind]): Sim =
  result = initSim(config)
  while not result.done:
    for seat in result.orderedSeats():
      result.apply(seat, scriptedAction(result, seat, kinds[seat]))

const
  AllSteady = [skSteady, skSteady, skSteady, skSteady, skSteady]
  AllTaskmaster = [skTaskmaster, skTaskmaster, skTaskmaster, skTaskmaster,
    skTaskmaster]
  Mixed = [skSteady, skTaskmaster, skSteady, skTaskmaster, skSteady]

suite "scripted baselines":
  test "every baseline in every role plays a legal, bounded, fast episode":
    for seed in [1, 7, 42, 1234]:
      for kinds in [AllSteady, AllTaskmaster, Mixed]:
        let started = getMonoTime()
        let sim = playScripted(fixture(seed), kinds)
        let elapsed = (getMonoTime() - started).inMilliseconds
        check sim.done
        check sim.reason == "complete"
        check sim.shiftsPlayed == sim.config.shifts
        var memos = 0
        var works = 0
        for event in sim.events:
          case event.kind
          of evMemo:
            inc memos
            check event.payroll in 0 .. MaxPayrollPercent
            check event.say.runeLen <= MaxDirectiveLen
          of evWork:
            inc works
            check event.run in 0 .. ShiftHours
            check event.maint in 0 .. ShiftHours
            check event.run + event.maint <= ShiftHours
            check event.say.runeLen <= MaxReportLen
          else: discard
        check memos == sim.config.shifts
        check works == sim.config.shifts * Machines
        check elapsed < 2000

  test "steady holds the machines; taskmaster destroys them":
    for seed in [1, 7, 42, 1234]:
      let steady = playScripted(fixture(seed), AllSteady)
      for worker in 0 ..< Machines:
        check abs(steady.machines[worker].condition - MaxCondition) <= 3
      ## The competent baseline always runs the line it was ordered on.
      var disobeyed = 0
      for record in steady.history:
        for worker in 0 ..< Machines:
          if not record.obeyed[worker]:
            inc disobeyed
      check disobeyed == 0

      var wrecked = false
      let taskmaster = playScripted(fixture(seed, shifts = 4), AllTaskmaster)
      for worker in 0 ..< Machines:
        if taskmaster.machines[worker].condition < 25:
          wrecked = true
      check wrecked

  test "the competent baseline is the one a prompt has to beat":
    ## NOTE (deviation from the design note, reported in phase 20): the note
    ## asserted the all-steady MANAGER outscores the all-taskmaster manager.
    ## It does not, and cannot: taskmaster's workers obey at run 10 whatever
    ## they are paid, so its 20% pay rule simply keeps more revenue than
    ## steady's 40%. The true statement — and the one that carries the same
    ## meaning — is that steady's floor is worth strictly more in total, and
    ## its workers are worth vastly more to themselves. Both managers' scores
    ## are echoed so tuning drift stays visible.
    for seed in [1, 7, 42, 1234]:
      let steady = playScripted(fixture(seed), AllSteady)
      let taskmaster = playScripted(fixture(seed), AllTaskmaster)
      var steadySurplus = steady.firmProfit
      var taskSurplus = taskmaster.firmProfit
      for worker in 0 ..< Machines:
        steadySurplus += steady.workerNet[worker]
        taskSurplus += taskmaster.workerNet[worker]
        check steady.score(steady.workerSeat[worker]) >
          taskmaster.score(taskmaster.workerSeat[worker])
      echo "seed ", seed,
        ": steady manager ", steady.score(steady.managerSeat).formatFloat(
          ffDecimal, 3),
        " workers ", steady.score(steady.workerSeat[0]).formatFloat(
          ffDecimal, 3),
        " surplus ", steadySurplus.formatFloat(ffDecimal, 1),
        " | taskmaster manager ", taskmaster.score(
          taskmaster.managerSeat).formatFloat(ffDecimal, 3),
        " workers ", taskmaster.score(taskmaster.workerSeat[0]).formatFloat(
          ffDecimal, 3),
        " surplus ", taskSurplus.formatFloat(ffDecimal, 1)
      check steadySurplus > taskSurplus

  test "the steady baseline never lies in its reports":
    var sim = initSim(fixture(5, shifts = 6))
    while not sim.done:
      for seat in sim.orderedSeats():
        let decision = scriptedAction(sim, seat, skSteady)
        if not sim.isManager(seat):
          let worker = sim.workerIndex[seat]
          let machine = sim.machines[worker]
          check decision.say == machineLabel(worker) & ": condition " &
            $machine.condition & ", ran " & $machine.run & ", maintained " &
            $machine.maint & ", " & $machine.units & " units."
        sim.apply(seat, decision)

  test "a scripted move carries its own provenance; a parsed reply does not":
    ## The seat's static registration cannot tell you that an LLM seat fell
    ## back mid-episode, and phase 60 counts fallbacks from the replay — so
    ## the flag rides on the decision.
    let sim = initSim(fixture(9))
    check scriptedAction(sim, sim.managerSeat, skSteady).scripted
    check scriptedAction(sim, sim.workerSeat[0], skTaskmaster).scripted
    check not parseManagerReply(sim, parseJson(
      """{"orders": ["A", "A", "A", "B"], "payroll": 30, "split": [25, 25, 25, 25]}""")).scripted
    check not parseWorkerReply(sim, sim.workerSeat[0], parseJson(
      """{"line": "A", "run": 5, "maint": 0}""")).scripted

  test "with no credentials every seat plays scripted, with no network call":
    let saved = [
      ("COWORLD_LLM_ENDPOINT", getEnv("COWORLD_LLM_ENDPOINT")),
      ("AWS_ENDPOINT_URL_BEDROCK_RUNTIME", getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME")),
      ("AWS_BEARER_TOKEN_BEDROCK", getEnv("AWS_BEARER_TOKEN_BEDROCK")),
      ("ANTHROPIC_API_KEY", getEnv("ANTHROPIC_API_KEY")),
      ("ANTHROPIC_API_KEY_URI", getEnv("ANTHROPIC_API_KEY_URI")),
    ]
    for (k, _) in saved:
      delEnv(k)
    defer:
      for (k, v) in saved:
        if v.len > 0: putEnv(k, v)
        else: delEnv(k)
    let config = fixture(3, shifts = 6)
    let client = newLlmClient(config)
    check client.disabled
    var sim = initSim(config)
    let seats = sim.orderedSeats()
    check seats.len == Seats
    var prompts = newSeq[string](Seats)
    prompts[seats[0]] = "be bold"
    var scripted = newSeq[ScriptKind](Seats)
    scripted[sim.workerSeat[1]] = skTaskmaster
    let started = getMonoTime()
    let decisions = client.decideAll(sim, seats, prompts, scripted, PromptSelection())
    check (getMonoTime() - started).inMilliseconds < 500
    check decisions.len == Seats
    for index, seat in seats:
      let kind = if seat == sim.workerSeat[1]: skTaskmaster else: skSteady
      let expected = scriptedAction(sim, seat, kind)
      check not decisions[index].failed
      check decisions[index].line == expected.line
      check decisions[index].run == expected.run
      check decisions[index].payroll == expected.payroll
      check decisions[index].scripted
      sim.apply(seat, decisions[index])
    check sim.shift == 1

suite "reply parsing":
  test "the manager's reply requires canonical fields and rejects legacy shims":
    let sim = initSim(fixture(11))
    let full = parseManagerReply(sim, parseJson("""
      {"orders": ["B", "A", "A", "B"], "payroll": 45,
       "split": [30, 30, 20, 20], "directive": "switch 1 to B",
       "notes": "watching machine 4"}"""))
    check full.orders == @["B", "A", "A", "B"]
    check full.payroll == 45
    check full.split == @[30, 30, 20, 20]
    check full.say == "switch 1 to B"
    check full.notes == "watching machine 4"
    ## Optional directive and notes default to "".
    let minimal = parseManagerReply(sim, parseJson(
      """{"orders": ["A", "A", "A", "B"], "payroll": 30, "split": [2, 2, 2, 2]}"""))
    check minimal.orders == @["A", "A", "A", "B"]
    check minimal.payroll == 30
    check minimal.split == @[25, 25, 25, 25]
    check minimal.say == ""
    check minimal.notes == ""
    ## All-zero split is normalized to equal shares per game rules.
    check parseManagerReply(sim, parseJson(
      """{"orders": ["A", "A", "A", "B"], "payroll": 30, "split": [0, 0, 0, 0]}""")).split ==
      @[25, 25, 25, 25]
    ## Reject float/string numbers, legacy line aliases, missing required fields, and unknown keys.
    for bad in [
      """{"orders": ["b", "A", "A", "B"], "payroll": 45, "split": [25,25,25,25]}""",
      """{"orders": ["Line A", "A", "A", "B"], "payroll": 45, "split": [25,25,25,25]}""",
      """{"orders": ["Z", "A", "A", "B"], "payroll": 30, "split": [25,25,25,25]}""",
      """{"orders": ["B"], "payroll": 30, "split": [25,25,25,25]}""",
      """{"payroll": 30, "split": [25,25,25,25]}""",
      """{"orders": ["A", "A", "A", "B"], "payroll": 39.6, "split": [25,25,25,25]}""",
      """{"orders": ["A", "A", "A", "B"], "payroll": "20", "split": [25,25,25,25]}""",
      """{"orders": ["A", "A", "A", "B"], "payroll": 30}""",
      """{"orders": ["A", "A", "A", "B"], "split": [25,25,25,25]}""",
      """{"orders": ["A", "A", "A", "B"], "payroll": "lots", "split": [25,25,25,25]}""",
      """{"orders": ["A", "A", "A", "B"], "payroll": -1, "split": [25,25,25,25]}""",
      """{"orders": ["A", "A", "A", "B"], "payroll": 61, "split": [25,25,25,25]}""",
      """{"orders": ["A", "A", "A", "B"], "payroll": 30, "split": [50, 50]}""",
      """{"orders": ["A", "A", "A", "B"], "payroll": 30, "split": [-1, 40, 30, 31]}""",
      """{"orders": ["A", "A", "A", "B"], "payroll": 30, "split": [25.0, 25, 25, 25]}""",
      """{"orders": ["A", "A", "A", "B"], "payroll": 30, "split": [25,25,25,25], "directive": 123}""",
      """{"orders": ["A", "A", "A", "B"], "payroll": 30, "split": [25,25,25,25], "memo": "alias"}""",
    ]:
      expect FirmError:
        discard parseManagerReply(sim, parseJson(bad))

  test "a worker's reply requires canonical fields and rejects legacy shims":
    let sim = initSim(fixture(11))
    let seat = sim.workerSeat[0]
    let full = parseWorkerReply(sim, seat, parseJson("""
      {"line": "B", "run": 7, "maint": 3, "report": "needs a bearing",
       "notes": "condition 84"}"""))
    check full.line == "B"
    check full.run == 7
    check full.maint == 3
    check full.say == "needs a bearing"
    check full.notes == "condition 84"
    ## Optional report and notes default to "".
    let minimal = parseWorkerReply(sim, seat, parseJson(
      """{"line": "A", "run": 5, "maint": 0}"""))
    check minimal.line == "A"
    check minimal.run == 5
    check minimal.maint == 0
    check minimal.say == ""
    check minimal.notes == ""
    for bad in [
      """{"line": "line b", "run": 7, "maint": 3}""",
      """{"line": "a", "run": 7, "maint": 3}""",
      """{"line": "C", "run": 5, "maint": 0}""",
      """{"run": 5, "maint": 0}""",
      """{"line": "A", "run": 5}""",
      """{"line": "A", "run": 6.4, "maint": 3}""",
      """{"line": "A", "run": "8", "maint": 2}""",
      """{"line": "A", "run": 6, "maint": 3.0}""",
      """{"line": "A", "maint": 3}""",
      """{"line": "A", "run": -1, "maint": 0}""",
      """{"line": "A", "run": 11, "maint": 0}""",
      """{"line": "A", "run": 3, "maint": 11}""",
      """{"line": "A", "run": 6, "maint": 5}""",
      """{"line": "A", "run": 6, "maint": 3, "notes": 42}""",
      """{"line": "A", "run": 6, "maint": 3, "extra": 1}""",
    ]:
      expect FirmError:
        discard parseWorkerReply(sim, seat, parseJson(bad))

  test "extractJsonObject accepts one bare or single-fenced object and rejects ambiguity":
    check extractJsonObject("""{"line": "A", "run": 6, "maint": 3}""")["line"].getStr() == "A"
    check extractJsonObject("```json\n{\"line\": \"A\", \"run\": 6, \"maint\": 3}\n```")["run"].getInt() == 6
    check extractJsonObject("```\n{\"line\": \"B\", \"run\": 4, \"maint\": 2}\n```")["line"].getStr() == "B"
    check extractJsonObject("  ```JSON\n{\"line\": \"A\", \"run\": 6, \"maint\": 3}\n```  ")["maint"].getInt() == 3
    for bad in [
      """Here is my move: {"line": "A", "run": 6, "maint": 3}""",
      """{"line": "A", "run": 6, "maint": 3} thanks!""",
      "Here:\n```json\n{\"line\": \"A\", \"run\": 6, \"maint\": 3}\n```",
      "```json\n{\"line\": \"A\", \"run\": 6, \"maint\": 3}\n```\nDone.",
      """{"line": "A", "run": 6, "maint": 3} {"line": "B", "run": 0, "maint": 0}""",
      "```json\n{\"line\": \"A\", \"run\": 6, \"maint\": 3}\n```\n```json\n{\"line\": \"B\", \"run\": 0, \"maint\": 0}\n```",
      "```python\n{\"line\": \"A\", \"run\": 6, \"maint\": 3}\n```",
      """[1, 2, 3]""",
    ]:
      expect FirmError:
        discard extractJsonObject(bad)

  test "free text is capped on rune boundaries":
    let sim = initSim(fixture(11))
    let seat = sim.workerSeat[0]
    var long = ""
    for index in 0 ..< 700:
      long.add("é")
    check cleanText(long, MaxNotesLen).runeLen == MaxNotesLen
    check cleanText(long, MaxDirectiveLen).runeLen == MaxDirectiveLen
    check cleanText(long, MaxReportLen).runeLen == MaxReportLen
    check cleanText(long, MaxNotesLen).validateUtf8() == -1
    let manager = parseManagerReply(sim, %*{
      "orders": ["A", "A", "A", "B"], "payroll": 40, "split": [25, 25, 25, 25],
      "directive": long, "notes": long})
    check manager.say.runeLen == MaxDirectiveLen
    check manager.notes.runeLen == MaxNotesLen
    let worker = parseWorkerReply(sim, seat, %*{
      "line": "A", "run": 6, "maint": 3, "report": long, "notes": long})
    check worker.say.runeLen == MaxReportLen
    check worker.notes.runeLen == MaxNotesLen
    check parseScriptKind("steady") == skSteady
    check parseScriptKind("taskmaster") == skTaskmaster
    check parseScriptKind("") == skNone
    check parseScriptKind("1") == skNone
    check parseScriptKind("true") == skNone
    check parseScriptKind("task-master") == skNone

  test "a reply with no JSON is quoted back on rune boundaries":
    ## The quoted head goes to the container log, which phase 60 reads; a
    ## byte slice through a multi-byte character makes it unreadable.
    var long = ""
    for index in 0 ..< 400:
      long.add("é")
    expect FirmError:
      discard extractJsonObject(long)
    try:
      discard extractJsonObject(long)
    except FirmError as error:
      check error.msg.validateUtf8() == -1
      check error.msg.runeLen < long.runeLen

  test "prompts carry the seat's own view and nothing hidden":
    var sim = initSim(fixture(7, shifts = 8, reports = false))
    for seat in sim.orderedSeats():
      sim.apply(seat, scriptedAction(sim, seat, skSteady))
    let manager = sim.userPrompt(sim.managerSeat, "operator says hi")
    check "THE BOARD" in manager
    check "THE FLOOR" in manager
    check "operator says hi" in manager
    ## With the report channel closed the manager's own view carries no
    ## machine internals at all: no condition, no hours, no effort.
    check "condition" notin manager.toLowerAscii()
    check "maintain" notin manager.toLowerAscii()
    check "effort" notin manager.toLowerAscii()

    let worker = sim.userPrompt(sim.workerSeat[1], "run it hot")
    check "YOUR MACHINE" in worker
    check "MACHINE 2" in worker
    check "run it hot" in worker
    ## The order board is the manager's alone: no demand numbers, no prices,
    ## no firm ledger. ("revenue" appears only as the word in the pay rule —
    ## the percentage is public, the amount is not.)
    for word in ["THE BOARD", "wants", "scrap", "salvage", "$10", "HISTORY:\nshift | A wanted"]:
      check word notin worker
    check "THE FLOOR:" notin worker
