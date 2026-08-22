extends Node
## SidecarManager — spawns and supervises the backend (ported near-verbatim
## from infrastruct; ROADMAP P4). Processes launch through a shell wrapper
## (env vars + log redirect — OS.create_process has no env parameter); POSIX
## uses `exec` so the returned pid IS the backend. Health = GET /health every
## POLL_INTERVAL_S; a healthy sidecar that stops answering goes DOWN and is
## restarted with capped backoff. Nothing starts automatically — main.gd or
## a smoke calls configure() + start_all().
##
## Config: embedded default (game port 8030); orchestration/sidecars.json
## overrides when present; smokes call configure(port=8031).

signal state_changed(id: String, state: State)

enum State { STOPPED, STARTING, HEALTHY, DOWN, RESTARTING }

const POLL_INTERVAL_S := 2.0
const STARTING_DEADLINE_S := 90.0
const BACKOFF_STEPS_S: Array[float] = [2.0, 5.0, 10.0, 20.0]
const DEFAULT_ID := "transmission"
const GAME_PORT := 8030  # smokes: 8031; contract tests own 8032 — never 8000-8002/8010-8016/8020-8029

var repo_root := ""
var _sidecars := {}  # id -> {cfg, state, pid, http, in_flight, started_at, backoff_i, restart_at}
var _poll_timer: Timer


func _ready() -> void:
	repo_root = AppPaths.root()
	_poll_timer = Timer.new()
	_poll_timer.wait_time = POLL_INTERVAL_S
	_poll_timer.timeout.connect(_poll)
	add_child(_poll_timer)


## Configure the single transmission sidecar. Reads
## orchestration/sidecars.json when present, else the embedded default;
## `port` (when > 0) overrides either. The default MIRRORS the file (it had
## silently drifted — a checkout missing the file ran without AUTOSTART=
## false/LOG_LEVEL and behaved differently than dev for no visible reason).
func configure(port: int = 0) -> void:
	var cfg := {
		"id": DEFAULT_ID,
		"python": ".venv/bin/python",
		"module": "rttransportflow.main",
		"cwd": ".",
		"port": GAME_PORT,
		"env": {
			"RTTRANSPORTFLOW_EXTERNAL_CLOCK": "true",
			"RTTRANSPORTFLOW_HOST": "127.0.0.1",
			"RTTRANSPORTFLOW_SIMULATOR": "null",
			"RTTRANSPORTFLOW_AUTOSTART": "false",
			"RTTRANSPORTFLOW_LOG_LEVEL": "warning",
		},
	}
	var config_path := repo_root.path_join("orchestration/sidecars.json")
	if FileAccess.file_exists(config_path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(config_path))
		if parsed is Dictionary:
			for entry: Dictionary in (parsed as Dictionary).get("sidecars", []):
				if entry.get("id", "") == DEFAULT_ID:
					cfg.merge(entry, true)
	if port > 0:
		cfg["port"] = port
	# Two smoke runs on one machine otherwise fight over the same port, and
	# the loser silently ADOPTS the winner's already-healthy backend — its
	# verdict then describes someone else's grid. RTTF_PORT_OFFSET shifts the
	# whole spawn+talk path together (everything downstream reads port_of()),
	# so a parallel run is isolated rather than merely lucky.
	var offset := int(OS.get_environment("RTTF_PORT_OFFSET"))
	if offset != 0:
		cfg["port"] = int(cfg["port"]) + offset
	cfg["env"]["RTTRANSPORTFLOW_PORT"] = str(cfg["port"])

	var http := HTTPRequest.new()
	http.timeout = POLL_INTERVAL_S - 0.2
	add_child(http)
	_sidecars[DEFAULT_ID] = {
		"cfg": cfg, "state": State.STOPPED, "pid": -1, "http": http,
		"in_flight": false, "started_at": 0.0, "backoff_i": 0, "restart_at": 0.0,
	}


func ids() -> Array:
	return _sidecars.keys()


func state_of(id: String) -> State:
	return _sidecars[id]["state"] if _sidecars.has(id) else State.STOPPED


func port_of(id: String) -> int:
	return int(_sidecars[id]["cfg"]["port"])


func pid_of(id: String) -> int:
	return _sidecars[id]["pid"] if _sidecars.has(id) else -1


func all_healthy() -> bool:
	if _sidecars.is_empty():
		return false
	for id: String in _sidecars:
		if _sidecars[id]["state"] != State.HEALTHY:
			return false
	return true


func start_all() -> void:
	for id: String in _sidecars:
		_start(id)
	_poll_timer.start()


func stop_all() -> void:
	_poll_timer.stop()
	for id: String in _sidecars:
		_kill(id)
		_set_state(id, State.STOPPED)


func _start(id: String) -> void:
	var s: Dictionary = _sidecars[id]
	var cfg: Dictionary = s["cfg"]
	var log_dir := repo_root.path_join(".run")
	DirAccess.make_dir_recursive_absolute(log_dir)
	# port in the log name: parallel instances (live game + smoke run) must
	# never interleave in one file (family gotcha)
	var log_path := log_dir.path_join("sidecar_%s_%d.log" % [id, port_of(id)])
	var command := build_launch_command(OS.get_name(), repo_root, cfg, log_path)
	var args: Array = command["args"]
	var pid := OS.create_process(command["exe"], PackedStringArray(args))
	s["pid"] = pid
	s["started_at"] = Time.get_ticks_msec() / 1000.0
	_set_state(id, State.STARTING if pid > 0 else State.DOWN)


## Pure launch-command builder: {exe, args} for OS.create_process. POSIX
## runs through `exec` so the spawned pid IS the backend; Windows kills the
## tree. (Ported from infrastruct, incl. the Windows env branch.)
static func build_launch_command(os_name: String, root: String,
		cfg: Dictionary, log_path: String) -> Dictionary:
	var run := '"%s"' % root.path_join(cfg["exe"]) if cfg.has("exe") \
		else '"%s" -m %s' % [
			translate_python_path(os_name, root, cfg["python"]), cfg["module"]]
	if os_name == "Windows":
		var win_parts: Array[String] = ['cd /d "%s"' % root.path_join(cfg["cwd"])]
		for key: String in cfg.get("env", {}):
			win_parts.append('set "%s=%s"' % [key, cfg["env"][key]])
		win_parts.append('%s >> "%s" 2>&1' % [run, log_path])
		return {"exe": "cmd.exe", "args": ["/c", " && ".join(win_parts)]}
	var parts: Array[String] = ['cd "%s"' % root.path_join(cfg["cwd"])]
	for key: String in cfg.get("env", {}):
		parts.append('export %s="%s"' % [key, cfg["env"][key]])
	# exec: the shell is replaced by the backend, so pid == backend pid
	parts.append('exec %s >> "%s" 2>&1' % [run, log_path])
	return {"exe": "sh", "args": ["-c", " && ".join(parts)]}


## NEVER resolve()/follow the interpreter symlink: uv-venv pythons link to
## the base interpreter and following them escapes the venv (family gotcha).
static func translate_python_path(os_name: String, root: String,
		rel: String) -> String:
	if os_name != "Windows" and rel.contains("/Scripts/"):
		rel = rel.replace("/Scripts/", "/bin/").trim_suffix(".exe")
	return root.path_join(rel)


func kill_for_test(id: String) -> void:
	_kill(id)


func _kill(id: String) -> void:
	var pid: int = _sidecars[id]["pid"]
	if pid > 0:
		if OS.get_name() == "Windows":
			OS.execute("taskkill", ["/PID", str(pid), "/T", "/F"])
		else:
			OS.execute("kill", ["-9", str(pid)])
	_sidecars[id]["pid"] = -1


func _set_state(id: String, state: State) -> void:
	if _sidecars[id]["state"] == state:
		return
	# low-volume, permanent: the 2026-08-22 boot wedge had ZERO log
	# evidence precisely because state transitions were silent
	print("SIDECAR %s: %s -> %s" % [id, State.keys()[_sidecars[id]["state"]],
		State.keys()[state]])
	_sidecars[id]["state"] = state
	state_changed.emit(id, state)


func _poll() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	for id: String in _sidecars:
		var s: Dictionary = _sidecars[id]
		match s["state"]:
			State.STOPPED:
				continue
			State.RESTARTING:
				if now >= s["restart_at"]:
					_start(id)
				continue
			State.STARTING:
				if now - s["started_at"] > STARTING_DEADLINE_S:
					_schedule_restart(id, now)
					continue
			State.DOWN:
				_schedule_restart(id, now)
				continue
		if s["in_flight"]:
			# belt over the 4 s probe timeout: a probe whose completion
			# signal was lost (backend killed mid-probe) must never gag
			# the poller forever — a stuck in_flight silently wedged a
			# whole boot in the health wait (2026-08-22)
			if now - float(s.get("in_flight_since", now)) > 10.0:
				s["in_flight"] = false
			continue
		_check_health(id)


func _schedule_restart(id: String, now: float) -> void:
	var s: Dictionary = _sidecars[id]
	_kill(id)
	var backoff: float = BACKOFF_STEPS_S[mini(s["backoff_i"], BACKOFF_STEPS_S.size() - 1)]
	s["backoff_i"] += 1
	s["restart_at"] = now + backoff
	_set_state(id, State.RESTARTING)


func _check_health(id: String) -> void:
	var s: Dictionary = _sidecars[id]
	var http: HTTPRequest = s["http"]
	# 8 s, not 4: HTTPRequest pumps in _process, so a probe needs FRAMES,
	# not just wall time — a present-blocked (occluded) or hitching loop
	# timed out EVERY probe against a 5 ms /health and the manager killed
	# healthy backends at the STARTING deadline forever (2026-08-22).
	# vsync_mode=0 + max_fps removed the present-block; this is the belt.
	http.timeout = 8.0
	var url := "http://127.0.0.1:%d/health" % port_of(id)
	var err := http.request(url)
	if err != OK:
		print("SIDECAR %s: health request refused (err %d)" % [id, err])
		http.cancel_request()  # unstick a node wedged in a lost request
		return
	s["in_flight"] = true
	s["in_flight_since"] = Time.get_ticks_msec() / 1000.0
	var result: Array = await http.request_completed
	s["in_flight"] = false
	var ok: bool = result[0] == HTTPRequest.RESULT_SUCCESS and result[1] == 200
	if not ok:
		s["probe_fails"] = int(s.get("probe_fails", 0)) + 1
		if int(s["probe_fails"]) % 10 == 1:
			print("SIDECAR %s: probe failed (result %d, http %d, fail #%d)"
				% [id, result[0], result[1], s["probe_fails"]])
	if ok:
		s["backoff_i"] = 0
		s["health_misses"] = 0
		_set_state(id, State.HEALTHY)
	elif s["state"] == State.HEALTHY:
		# TOLERANCE, not a hair trigger: a hard power-flow retry ladder can
		# stall the backend's event loop for a few seconds, and one missed
		# probe used to declare it DOWN — the restart then bind-failed
		# against the still-alive process in a loop while the in-flight
		# step reply was lost (the live-game freeze, 2026-08-21)
		s["health_misses"] = int(s.get("health_misses", 0)) + 1
		if int(s["health_misses"]) >= 3:
			s["health_misses"] = 0
			_set_state(id, State.DOWN)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_EXIT_TREE:
		stop_all()
