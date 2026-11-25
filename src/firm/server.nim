## Firm game server: implements the Coworld game contract.
##
## Endpoints:
##   GET /healthz                    - liveness
##   GET /client/global              - spectator page
##   GET /client/player              - player page (view-only; policies are prompts)
##   GET /client/replay              - replay page (replay mode)
##   GET /client/renderer.js         - shared stage renderer
##   GET /client/chrome.css          - shared broadcast chrome
##   GET /client/assets/<name>       - sprites and fonts
##   WS  /player?slot=N&token=T      - player protocol (prompt delivery)
##   WS  /global                     - spectator snapshots
##   WS  /replay                     - replay payload (replay mode)
##
## Player protocol (firm.player.v2), all JSON text frames:
##   game -> player: {"type":"welcome","slot":N,"name":...,"role":...,
##                    "machine":N,"shifts":N}
##                   {"type":"state",...} after every event, REDACTED to the
##                   seat's own view: the manager sees the order board and no
##                   machine's condition, a worker sees its machine and no
##                   part of the board
##                   {"type":"final","scores":[...],"pay":[...],...}
##   player -> game: {"type":"prompt","prompt":"...","scripted":"steady"}
##                   (max 4000 chars; scripted plays a built-in baseline for
##                   that seat: "steady" or "taskmaster")
##   player -> game: {"type":"register","control":"external"}
##   game -> external player: {"type":"observation","id":N,
##                   "observation":<seat-private state>}
##   external player -> game: {"type":"action","id":N,"action":{...}}

import
  std/[json, locks, os, sets, strutils, tables, times, unicode],
  bitworld/runtime,
  curly,
  mummy,
  mummy/routers,
  llm,
  sim, prompts, native_capture

const
  MaxPromptLen = 4000
  ReplayVersion = 1

type
  GameState = object
    selection: PromptSelection
    config: GameConfig
    sim: Sim
    capture: RuntimeCapture
    prompts: seq[string]
    scripted: seq[ScriptKind]
    external: seq[bool]
    policyReady: seq[bool]
    decisionId: int
    pendingActions: seq[JsonNode]
    pendingErrors: seq[string]
    failureSlot: int
    failureReason: string
    failureShift: int
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    started: bool
    finished: bool

var
  stateLock: Lock
  state: GameState
  gameServer: Server
  runtimeConfigGlobal: RuntimeConfig
  replayPayloadGlobal: string

initLock(stateLock)

proc clientDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "client", appDir / ".." / "client", "client"]:
    if dirExists(candidate):
      return candidate
  "client"

proc dataDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "data", appDir / ".." / "data", "data"]:
    if dirExists(candidate):
      return candidate
  "data"

proc policyNamesJson(gs: GameState): JsonNode =
  ## Seats play under anonymous cog aliases; the policy names ride alongside
  ## for the SPECTATOR views only, which render them in place of the aliases.
  result = newJArray()
  for player in gs.config.players:
    result.add(%player.name)

proc snapshotJson(gs: GameState): JsonNode =
  var events = newJArray()
  for event in gs.sim.events:
    events.add(event.eventToJson())
  var connected = newJArray()
  for slot in 0 ..< gs.config.tokens.len:
    connected.add(%gs.playerSockets.hasKey(slot))
  result = gs.sim.tableStateJson()
  result["type"] = %"state"
  result["game"] = %"firm"
  result["policyNames"] = gs.policyNamesJson()
  result["events"] = events
  result["started"] = %gs.started
  result["done"] = %gs.sim.done
  result["connected"] = connected

proc playerFrameJson(gs: GameState, slot: int): JsonNode =
  ## The seat's own redacted view. Decisions are server-side, so redaction
  ## loses nothing.
  result = gs.sim.playerStateJson(slot)
  result["type"] = %"state"
  result["slot"] = %slot
  result["started"] = %gs.started

proc broadcastLocked(gs: GameState) =
  ## Callers hold stateLock. Spectators get the whole floor; players get the
  ## redacted per-seat state.
  let payload = $gs.snapshotJson()
  for socket in gs.globalSockets:
    socket.send(payload)
  for slot, socket in gs.playerSockets:
    socket.send($gs.playerFrameJson(slot))

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  ## Writes a Coworld artifact, honoring the platform's PUT/POST method hint.
  if uri.len == 0:
    return
  let httpMethod = getEnv(methodEnv, "PUT").toUpperAscii()
  if uri.isHttpCogameUri() and httpMethod == "POST":
    let curl = newCurly()
    var headers: HttpHeaders
    headers["content-type"] = contentType
    let response = curl.post(uri, headers, data, 60)
    if response.code < 200 or response.code >= 300:
      raise newException(IOError, "artifact POST failed: " & $response.code)
  else:
    writeCogameUri(uri, data, contentType, methodEnv)

proc replayPayload(gs: GameState, results: JsonNode): string =
  var names = newJArray()
  for name in gs.sim.names:
    names.add(%name)
  var events = newJArray()
  for event in gs.sim.events:
    events.add(event.eventToJson())
  $ %*{
    "protocol": "firm.replay.v" & $ReplayVersion,
    "names": names,
    "policyNames": gs.policyNamesJson(),
    "config": {
      "shifts": gs.config.shifts,
      "seed": gs.config.seed,
      "reports": gs.config.reports,
      "sampled": true
    },
    "events": events,
    "results": results
  }

proc statesFromEvents(config: GameConfig, events: seq[GameEvent]): JsonNode =
  ## One table-state object per event prefix, for scrubbing replays.
  result = newJArray()
  for frame in replayMatch(config, events):
    result.add(frame.tableStateJson())

proc finishEpisode(runtimeConfig: RuntimeConfig) =
  var results: JsonNode
  var replayData: string
  var failurePayload = ""
  withLock stateLock:
    if state.finished:
      return
    state.finished = true
    results = state.sim.resultsJson()
    if state.failureSlot >= 0:
      failurePayload = $ %*{
        "slot": state.failureSlot,
        "player": state.config.players[state.failureSlot].name,
        "reason": state.failureReason,
        "shift": state.failureShift
      }
    replayData = state.replayPayload(results)

    ## Send final frames to players BEFORE writing artifacts: the hosted
    ## worker tears player pods down as soon as results.json exists, and
    ## writing first would race player log collection.
    ## Results carry POLICY names for the platform, but the final frame goes
    ## to the player sockets — hand them the table aliases instead.
    var aliasNames = newJArray()
    for name in state.sim.names:
      aliasNames.add(%name)
    var final = %*{
      "type": "final",
      "done": true,
      "scores": results["scores"],
      "roles": results["roles"],
      "names": aliasNames,
      "pay": results["pay"],
      "profit": results["profit"],
      "shifts": results["shifts"],
      "reason": results["reason"]
    }
    for slot, socket in state.playerSockets:
      final["slot"] = %slot
      socket.send($final)
    state.broadcastLocked()

  state.capture.finishCapture(results)
  sleep(500)
  echo "firm: writing results and replay"
  if failurePayload.len > 0:
    writeArtifact(
      getEnv("COGAME_PLAYER_FAILURE_URI"), failurePayload, "application/json",
      "COGAME_PLAYER_FAILURE_METHOD"
    )
  writeArtifact(
    runtimeConfig.resultsUri, $results, "application/json",
    "COGAME_RESULTS_METHOD"
  )
  writeArtifact(
    runtimeConfig.replayUri, replayData, "application/octet-stream",
    "COGAME_SAVE_REPLAY_METHOD"
  )
  sleep(500)
  echo "firm: episode complete, shutting down"
  quit(0)

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let config = state.config
    let gameStart = epochTime()
    let deadline = gameStart + config.playerConnectTimeoutSeconds

    while epochTime() < deadline:
      var allReady = true
      withLock stateLock:
        for ready in state.policyReady:
          if not ready: allReady = false
      if allReady:
        break
      sleep(200)

    withLock stateLock:
      state.started = true
      echo "firm: starting with ", state.playerSockets.len, "/",
        config.tokens.len, " players connected"
      state.broadcastLocked()

    let client = newLlmClient(config)

    ## The platform kills the episode at its timeout and keeps nothing. Play
    ## inside a fraction of it so results and the replay are written with
    ## room to spare. The hosted dispatcher hands the timeout only to its own
    ## worker sidecar, NOT to the game container, so when the env is silent
    ## assume the configured platform default rather than playing open-ended.
    let hostedTimeout = getEnv("COWORLD_TIMEOUT_SECONDS", "").strip()
    var timeoutSeconds =
      if hostedTimeout.len > 0:
        try: parseFloat(hostedTimeout) except ValueError: 0.0
      else: 0.0
    if timeoutSeconds <= 0.0:
      timeoutSeconds = config.episodeTimeoutSeconds.float
    let playDeadline =
      if timeoutSeconds > 0.0: gameStart + timeoutSeconds * PlayBudgetFraction
      else: 0.0
    if playDeadline > 0.0:
      echo "firm: episode timeout ", timeoutSeconds.int, "s (",
        (if hostedTimeout.len > 0: "from env" else: "assumed"),
        "); playing until ", (timeoutSeconds * PlayBudgetFraction).int, "s"

    while true:
      var simCopy: Sim
      var seats: seq[int]
      var prompts: seq[string]
      var scripted: seq[ScriptKind]
      var external: seq[bool]
      var policyReady: seq[bool]
      var decisionId: int
      withLock stateLock:
        if state.sim.done:
          break
        if playDeadline > 0.0 and epochTime() > playDeadline:
          ## Checked BEFORE the batch, never mid-shift: give up shifts
          ## rather than the whole result.
          echo "firm: episode deadline reached after ",
            state.sim.shiftsPlayed, "/", config.shifts,
            " shifts; ending early"
          state.sim.endEarly()
          state.broadcastLocked()
          break
        ## The manager first, then workers 0..3 — the machine ordering in
        ## the record depends on the seeded role draw, not on slot numbers.
        seats = state.sim.orderedSeats()
        simCopy = state.sim
        prompts = state.prompts
        scripted = state.scripted
        external = state.external
        policyReady = state.policyReady
        inc state.decisionId
        decisionId = state.decisionId
        state.pendingActions = newSeq[JsonNode](config.players.len)
        state.pendingErrors = newSeq[string](config.players.len)
        for seat in seats:
          if external[seat] and state.playerSockets.hasKey(seat):
            state.playerSockets[seat].send($ %*{
              "type": "observation", "id": decisionId,
              "observation": state.playerFrameJson(seat)})
        echo "firm: shift ", state.sim.shift, " of ", config.shifts,
          " at ", (epochTime() - gameStart).int, "s"

      ## The slow part (Claude, ONE parallel batch for all model seats) runs
      ## outside the lock on a snapshot; only this thread mutates the sim, so
      ## the snapshot cannot go stale — and every seat decides from the same
      ## pre-shift picture, which is what makes the shift simultaneous.
      var captures: seq[CapturedDecision]
      var batchSeats: seq[int]
      var batchIndices: seq[int]
      var batchCaptures: seq[CapturedDecision]
      for index, seat in seats:
        var observation = simCopy.playerStateJson(seat)
        observation["policy_registered"] = %policyReady[seat]
        if not policyReady[seat]:
          observation["failure_reason"] = %"unregistered_policy"
        let cap = state.capture.beginDecision("shift-" & $simCopy.shift & "-seat-" & $seat,
          config.players[seat].name, observation,
          state.selection.selectionMetadata(), simCopy.nativeStateHash())
        captures.add(cap)
        if policyReady[seat] and not external[seat]:
          batchSeats.add(seat)
          batchIndices.add(index)
          batchCaptures.add(cap)
      var decisions = newSeq[Decision](seats.len)
      if batchSeats.len > 0:
        let batchDecisions = client.decideAll(
          simCopy, batchSeats, prompts, scripted, state.selection, batchCaptures)
        for pos, index in batchIndices:
          decisions[index] = batchDecisions[pos]
      for index, seat in seats:
        if not policyReady[seat]:
          decisions[index] = Decision(
            failed: true,
            error: "unregistered policy"
          )
      let deadline = epochTime() + config.llmTimeoutSeconds.float
      while epochTime() < deadline:
        var ready = true
        withLock stateLock:
          for seat in seats:
            if external[seat] and state.playerSockets.hasKey(seat) and
                state.pendingActions[seat].isNil and
                state.pendingErrors[seat].len == 0:
              ready = false
        if ready:
          break
        sleep(20)
      for index, seat in seats:
        if external[seat]:
          var action: JsonNode
          var errMsg: string
          var connected: bool
          withLock stateLock:
            action = state.pendingActions[seat]
            errMsg = state.pendingErrors[seat]
            connected = state.playerSockets.hasKey(seat)
          if errMsg.len > 0:
            decisions[index] = Decision(failed: true, error: errMsg)
          elif not action.isNil:
            try:
              decisions[index] = simCopy.parseReply(seat, action)
            except CatchableError as error:
              decisions[index] = Decision(failed: true, error: error.msg)
          else:
            let detail =
              if not connected: "external player disconnected before acting"
              else: "external player timed out waiting for action"
            decisions[index] = Decision(failed: true, error: detail)

      var forfeited = false
      withLock stateLock:
        for index, seat in seats:
          if decisions[index].failed:
            let origin =
              if not policyReady[seat]: "unregistered"
              elif external[seat]: "external"
              else: "model"
            echo "firm: shift ", state.sim.shift, " seat ", seat, " (", origin,
              ") forfeited: ", decisions[index].error
            if state.failureSlot < 0:
              state.failureSlot = seat
              state.failureReason = decisions[index].error
              state.failureShift = state.sim.shift
            state.capture.rejected(captures[index], seat, state.sim, origin,
              decisions[index].error)
            forfeited = true
        if forfeited:
          state.sim.forfeit()
          state.broadcastLocked()
        else:
          for index, seat in seats:
            let decision = decisions[index]
            let startEvent = state.sim.events.len
            let origin =
              if external[seat]: "external"
              elif scripted[seat] != skNone: "scripted"
              elif decision.scripted: "fallback"
              else: "model"
            let wasScripted = decision.scripted or scripted[seat] != skNone
            let isManager = state.sim.isManager(seat)
            if isManager:
              echo "firm: shift ", state.sim.shift, " ", state.sim.names[seat],
                " (Manager) orders ", decision.orders, " payroll ",
                decision.payroll, " split ", decision.split,
                " at ", (epochTime() - gameStart).int, "s"
            else:
              echo "firm: shift ", state.sim.shift, " ", state.sim.names[seat],
                " (", machineLabel(state.sim.workerIndex[seat]), ") runs line ",
                decision.line, " ", decision.run, "h, maintains ",
                decision.maint, "h at ", (epochTime() - gameStart).int, "s"
            try:
              if isManager:
                state.sim.applyMemo(seat, decision.orders, decision.payroll,
                  decision.split, decision.say, decision.notes, wasScripted)
              else:
                state.sim.applyWork(seat, decision.line, decision.run,
                  decision.maint, decision.say, decision.notes, wasScripted)
            except FirmError as error:
              echo "firm: reply rejected at apply (", error.msg, "); forfeiting"
              state.failureSlot = seat
              state.failureReason = error.msg
              state.failureShift = state.sim.shift
              state.capture.rejected(captures[index], seat, state.sim, origin,
                error.msg)
              state.sim.forfeit()
              forfeited = true
              break
            state.capture.applied(captures[index], seat,
              simCopy.decisionJson(seat, decision), state.sim, startEvent, origin)
          state.broadcastLocked()
      if forfeited:
        break

      ## Pace between shifts so spectators can read the floor.
      if config.turnDelayMs > 0:
        sleep(config.turnDelayMs)

    ## Let the last settlement land before the final frame.
    if config.turnDelayMs > 0:
      sleep(config.turnDelayMs)
    finishEpisode(runtimeConfig)

var gameThread: Thread[RuntimeConfig]

proc serveFile(request: Request, path, contentType: string) =
  if fileExists(path):
    var headers: HttpHeaders
    headers["Content-Type"] = contentType
    request.respond(200, headers, readFile(path))
  else:
    request.respond(404)

proc htmlHandler(name: string): RequestHandler =
  proc handler(request: Request) {.gcsafe.} =
    {.gcsafe.}:
      serveFile(request, clientDir() / name, "text/html; charset=utf-8")
  handler

proc assetHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    if "/" in name or "\\" in name or name.startsWith("."):
      request.respond(404)
      return
    let contentType =
      if name.endsWith(".png"): "image/png"
      elif name.endsWith(".ttf"): "font/ttf"
      else: "application/octet-stream"
    serveFile(request, dataDir() / name, contentType)

proc rendererHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(
      request, clientDir() / "renderer.js",
      "application/javascript; charset=utf-8"
    )

proc chromeCssHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(request, clientDir() / "chrome.css", "text/css; charset=utf-8")

proc healthzHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"ok": true}""")

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let slotText = request.queryParams["slot"]
    let token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    var authorized = false
    withLock stateLock:
      authorized = slot >= 0 and slot < state.config.tokens.len and
        state.config.tokens[slot] == token
    if not authorized:
      request.respond(401)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.playerSockets[slot] = websocket
      state.socketSlots[websocket] = slot
      echo "firm: player slot ", slot, " connected (",
        state.playerSockets.len, "/", state.config.tokens.len, ")"
      websocket.send($ %*{
        "type": "welcome",
        "protocol": "firm.player.v2",
        "slot": slot,
        "name": state.sim.names[slot],
        "role": state.sim.roleName(slot),
        "machine": (if state.sim.isManager(slot): 0
                    else: state.sim.workerIndex[slot] + 1),
        "shifts": state.config.shifts
      })

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.globalSockets.incl(websocket)
      websocket.send($state.snapshotJson())

proc replayUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    if replayPayloadGlobal.len > 0:
      websocket.send(replayPayloadGlobal)

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application instead of answering
      ## them itself; the platform's certifier pings /global to check the
      ## game is alive, so an unanswered ping fails certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind != TextMessage:
        return
      var slot = -1
      withLock stateLock:
        slot = state.socketSlots.getOrDefault(websocket, -1)
        if slot >= 0 and state.playerSockets.getOrDefault(slot) != websocket:
          slot = -1
      if slot < 0:
        return
      try:
        let payload = parseJson(message.data)
        if payload{"type"}.getStr() == "register":
          if payload["control"].getStr() != "external":
            raise newException(FirmError, "unknown player control")
          withLock stateLock:
            if state.playerSockets.getOrDefault(slot) != websocket:
              return
            state.external[slot] = true
            state.policyReady[slot] = true
          return
        if payload{"type"}.getStr() == "action":
          withLock stateLock:
            if state.playerSockets.getOrDefault(slot) != websocket:
              return
            if state.external[slot] and payload.hasKey("id") and
                payload["id"].kind == JInt and
                payload["id"].getInt() == state.decisionId and
                state.pendingActions[slot].isNil and
                state.pendingErrors[slot].len == 0:
              try:
                if not payload.hasKey("action"):
                  raise newException(FirmError, "action frame missing action field")
                let action = payload["action"]
                let decision = state.sim.parseReply(slot, action)
                var probe = state.sim
                if state.sim.isManager(slot):
                  probe.applyMemo(slot, decision.orders, decision.payroll,
                    decision.split, decision.say, decision.notes, false)
                else:
                  probe.applyWork(slot, decision.line, decision.run,
                    decision.maint, decision.say, decision.notes, false)
                state.pendingActions[slot] = action
              except CatchableError as error:
                echo "firm: external slot ", slot, " action rejected: ", error.msg
                state.pendingErrors[slot] = error.msg
          return
        if payload{"type"}.getStr() == "prompt":
          if not payload.hasKey("prompt") or payload["prompt"].kind != JString:
            raise newException(FirmError, "prompt must be a string")
          var prompt = payload["prompt"].getStr()
          if prompt.runeLen > MaxPromptLen:
            prompt = prompt.runeSubStr(0, MaxPromptLen)
          let node = payload{"scripted"}
          var scripted = skNone
          if not node.isNil:
            if node.kind != JString:
              raise newException(FirmError, "scripted must be a string")
            let rawScripted = node.getStr().strip()
            scripted = parseScriptKind(rawScripted)
            if scripted == skNone and rawScripted notin ["", "none"]:
              raise newException(FirmError, "unknown scripted policy")
          withLock stateLock:
            if state.playerSockets.getOrDefault(slot) != websocket:
              return
            state.prompts[slot] = prompt
            state.scripted[slot] = scripted
            state.external[slot] = false
            state.policyReady[slot] = true
          echo "firm: slot ", slot, " delivered a prompt (", prompt.len,
            " chars",
            (if scripted != skNone: ", scripted " & $scripted else: ""), ")"
      except CatchableError as error:
        echo "firm: ignoring bad player frame: ", error.msg
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in state.socketSlots:
          let slot = state.socketSlots[websocket]
          state.socketSlots.del(websocket)
          if state.playerSockets.getOrDefault(slot) == websocket:
            state.playerSockets.del(slot)
        state.globalSockets.excl(websocket)

proc buildRouter(replayMode: bool): Router =
  result.get("/healthz", healthzHandler)
  result.get("/client/global", htmlHandler("global.html"))
  result.get("/client/player", htmlHandler("player.html"))
  result.get("/client/replay", htmlHandler("replay.html"))
  result.get("/client/renderer.js", rendererHandler)
  result.get("/client/chrome.css", chromeCssHandler)
  result.get("/client/assets/@name", assetHandler)
  result.get("/global", globalUpgradeHandler)
  result.get("/replay", replayUpgradeHandler)
  if not replayMode:
    result.get("/player", playerUpgradeHandler)

proc configFromReplay*(payload: JsonNode): GameConfig =
  result = defaultGameConfig()
  result.shifts = payload["config"]{"shifts"}.getInt(8)
  result.seed = payload["config"]{"seed"}.getInt(0)
  result.reports = payload["config"]{"reports"}.getBool(true)
  ## The replay carries the episode's fitted cap; never re-fit it. Roles,
  ## the demand levels and the switch shift are re-derived from the seed.
  result.sampled = true
  for name in payload["names"]:
    result.players.add(PlayerConfig(name: name.getStr()))

proc runReplayServer*(runtimeConfig: RuntimeConfig) =
  ## Replay mode: parse the recorded replay, precompute the scrub states,
  ## and serve the viewer until the platform tears the container down.
  let payload = parseJson(runtimeConfig.replay)
  let config = configFromReplay(payload)
  var events: seq[GameEvent]
  for node in payload["events"]:
    events.add(eventFromJson(node))
  var enriched = %*{
    "type": "replay",
    "protocol": payload{"protocol"}.getStr("firm.replay.v1"),
    "names": payload["names"],
    "policyNames": payload{"policyNames"},
    "config": payload["config"],
    "events": payload["events"],
    "results": payload{"results"},
    "states": statesFromEvents(config, events)
  }
  replayPayloadGlobal = $enriched

  let router = buildRouter(replayMode = true)
  gameServer = newServer(router, websocketHandler)
  echo "firm: replay mode on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  if config.tokens.len != config.players.len:
    raise newException(FirmError, "tokens and players must align")
  state.selection = promptSelection(parseJson(runtimeConfig.config))
  state.config = config
  state.sim = initSim(config)
  state.capture = newRuntimeCapture(state.sim, runtimeConfig.resultsUri, runtimeConfig.replayUri)
  state.prompts = newSeq[string](config.players.len)
  state.scripted = newSeq[ScriptKind](config.players.len)
  state.external = newSeq[bool](config.players.len)
  state.policyReady = newSeq[bool](config.players.len)
  state.pendingActions = newSeq[JsonNode](config.players.len)
  state.pendingErrors = newSeq[string](config.players.len)
  state.failureSlot = -1
  state.failureReason = ""
  state.failureShift = -1
  runtimeConfigGlobal = runtimeConfig

  let router = buildRouter(replayMode = false)
  gameServer = newServer(router, websocketHandler)
  createThread(gameThread, runGame, runtimeConfig)
  echo "firm: serving on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
