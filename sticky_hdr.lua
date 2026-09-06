-- sticky_hdr.lua -- keep a monitor in HDR for as long as an HDR window lives,
-- not just while it is fullscreen (Hyprland's render:cm_auto_hdr flaps on
-- alt-tab). A window whose process carries a marker env var, or whose class is
-- listed, switches the monitor to the `hdr` state until the last such window
-- is gone plus `cooldown` seconds. Each state can carry a monitor overlay and
-- compositor-wide hl.config values. Usage: see hypr/monitors.lua.
--
-- M.prewarm() enters HDR ahead of any window, for launchers that probe the
-- output's color state once at startup (gamescope). The hold lasts prewarm_sec
-- (default 10s): a qualifying window arriving inside it takes over normal
-- stickiness; otherwise the hold expires and the usual cooldown revert runs.
-- Each output's hold deadline is persisted to $XDG_RUNTIME_DIR so it survives
-- config reloads that recreate this Lua VM (Omarchy reloads on every save).
--
-- Hyprland 0.56 notes: monitor rules are whole-record replacements, so each
-- state's monitor overlay is merged over the full spec. Structured states use
-- { monitor = {...}, config = {...} }. Config is compositor-wide, so all
-- setup() calls must use matching config pairs; the module keeps HDR config active
-- until its last output finishes cooldown. SDR transitions queue the monitor
-- rule before restoring global config; Hyprland applies queued monitor rules
-- before cm_auto_hdr runs on the next render. window.close skips SIGKILL and
-- window.destroy has no address, so teardown recounts live windows; HL.Timer
-- has no cancel(), but set_enabled(false) calls a pending oneshot off --
-- callbacks still re-check a generation counter in case one was already in
-- flight; HL.Monitor exposes cm as the configured preset and vrr_active as a
-- live boolean, so neither the color state nor the configured VRR mode can be
-- read back, and the module keeps its own flag.
--
-- Tests (mock hl): tests/run.sh in the hypr-sticky-hdr repo.

local M = {}
M._instances = {}

local DEFAULTS = {
  sdr      = {
    monitor = { cm = "srgb" },
    config = { render = { cm_auto_hdr = 1 } },
  },
  hdr      = {
    monitor = { cm = "hdr" },
    config = { render = { cm_auto_hdr = 0 } },
  },
  env      = { "DXVK_HDR=1", "HYPR_STICKY_HDR=1" },
  classes  = { "gamescope" },
  cooldown_sec  = 2,
  prewarm_sec   = 10,
  reconcile_sec = 30, -- safety net for missed events; 0 disables
}

local global_configs = nil
local active_hdr_instances = 0
local applied_global_state = nil

local COALESCE_MS = 100 -- window events within this batch into one scan

local STATE_FILE_PREFIX = (os.getenv("XDG_RUNTIME_DIR") or "/tmp")
  .. "/hypr-sticky-hdr-prewarm"

local function state_file(output)
  local key = output == "" and "all" or output:gsub(".", function(c)
    return string.format("%02x", string.byte(c))
  end)
  return STATE_FILE_PREFIX .. "-" .. key
end

local function merged(base, over)
  local t = {}
  for k, v in pairs(base) do t[k] = v end
  for k, v in pairs(over or {}) do t[k] = v end
  return t
end

local function deep_equal(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do
    if not deep_equal(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

local function normalize_state(value, default)
  if value == nil then return default.monitor, default.config end
  assert(type(value) == "table", "sticky_hdr.setup: sdr/hdr must be tables")
  for key in pairs(value) do
    assert(key == "monitor" or key == "config",
      "sticky_hdr.setup: unknown state member '" .. tostring(key) .. "'")
  end
  assert(value.monitor ~= nil or value.config ~= nil,
    "sticky_hdr.setup: sdr/hdr must use monitor/config members")
  local monitor = value.monitor == nil and default.monitor or value.monitor
  local config = value.config == nil and default.config or value.config
  assert(type(monitor) == "table" and type(config) == "table",
    "sticky_hdr.setup: state monitor/config members must be tables")
  return monitor, config
end

local function to_set(list)
  local s = {}
  for _, v in ipairs(list or {}) do s[v] = true end
  return s
end

local function to_ms(v, name)
  local n = tonumber(v)
  assert(n and n >= 0 and n < math.huge,
    "sticky_hdr.setup: " .. name .. " must be a finite non-negative number")
  return math.floor(n * 1000)
end

-- The raw environ blob, or nil when it cannot be read. nil is a real
-- condition (another user namespace, a process mid-exec), distinct from "read
-- fine, no marker" -- callers must not cache it as a "no".
local function read_environ(pid)
  local f = io.open("/proc/" .. pid .. "/environ", "rb")
  if not f then return nil end
  local blob = f:read("a")
  f:close()
  return blob
end

-- Whole NUL-delimited environ entries; FOO=1 cannot match BARFOO=1.
local function environ_has_any(blob, entries)
  blob = "\0" .. blob .. "\0"
  for _, e in ipairs(entries) do
    if blob:find("\0" .. e .. "\0", 1, true) then return true end
  end
  return false
end

local function write_deadline(path, deadline)
  local f = io.open(path, "w")
  if f then
    f:write(tostring(deadline))
    f:close()
  end
end

local function write_hold_deadline(output, sec_from_now)
  write_deadline(state_file(output), os.time() + sec_from_now)
end

local function read_deadline(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local deadline = tonumber(f:read("a"))
  f:close()
  return deadline
end

local function remaining_hold_ms(deadline, cap_ms)
  if not deadline then return 0 end
  local remaining = (deadline - os.time()) * 1000
  if remaining <= 0 then return 0 end
  return math.min(math.floor(remaining), cap_ms)
end

local function persisted_hold(output, cap_ms)
  local deadline = read_deadline(state_file(output))
  return remaining_hold_ms(deadline, cap_ms)
end

--- Start managing one monitor. Returns a handle with .wants_hdr() (real
--- window demand, prewarm holds excluded), .in_hdr(), and .prewarm().
function M.setup(opts)
  assert(type(opts) == "table" and type(opts.monitor) == "table",
    "sticky_hdr.setup: opts.monitor (an hl.monitor spec) is required")

  local sdr_monitor, sdr_config = normalize_state(opts.sdr, DEFAULTS.sdr)
  local hdr_monitor, hdr_config = normalize_state(opts.hdr, DEFAULTS.hdr)
  local SDR     = merged(opts.monitor, sdr_monitor)
  local HDR     = merged(opts.monitor, hdr_monitor)
  local ENV     = opts.env or DEFAULTS.env
  local CLASSES = to_set(opts.classes or DEFAULTS.classes)
  local READ    = opts.environ_reader or read_environ
  local COOLDOWN_MS  = to_ms(opts.cooldown_sec or DEFAULTS.cooldown_sec, "cooldown_sec")
  local PREWARM_MS   = to_ms(opts.prewarm_sec or DEFAULTS.prewarm_sec, "prewarm_sec")
  local RECONCILE_MS = to_ms(opts.reconcile_sec or DEFAULTS.reconcile_sec, "reconcile_sec")

  -- Demand is scoped to this instance's output; "" manages every output, so
  -- it sees every window.
  local OUTPUT = opts.monitor.output or ""
  local FILTER = OUTPUT ~= "" and { monitor = OUTPUT } or nil
  local candidate_configs = { sdr = sdr_config, hdr = hdr_config }
  local first_setup = global_configs == nil
  if not first_setup then
    assert(deep_equal(global_configs.sdr, sdr_config)
        and deep_equal(global_configs.hdr, hdr_config),
      "sticky_hdr.setup: all instances must use matching sdr/hdr config tables")
  end
  local CONFIGS = global_configs or candidate_configs

  local env_wants     = {} -- pid -> bool, so /proc is read once per process
  local in_hdr        = false
  local last_want     = false
  local prewarm_gen   = 0 -- overlapping holds: only the newest timer may end one
  local cooldown_gen  = 0 -- ditto for cooldown reverts
  local cooldown_timer = nil
  local coalesce_timer = nil
  local prune_pending  = false
  local monitor_dirty  = false

  local function apply_global(state)
    if applied_global_state == state then return end
    hl.config(CONFIGS[state])
    applied_global_state = state
  end

  local function apply_monitor(spec)
    local ok, err = pcall(hl.monitor, spec)
    if not ok then
      monitor_dirty = true
      error(err, 0)
    end
    monitor_dirty = false
  end

  -- Monitor state is per instance; config state is shared by the module. The
  -- first HDR transition configures Hyprland before touching its monitor. The
  -- last SDR transition queues its monitor before restoring global config.
  local function transition(want_hdr, force_monitor)
    if want_hdr then
      if in_hdr then
        if force_monitor then apply_monitor(HDR) end
        return
      end

      local first = active_hdr_instances == 0
      if first then apply_global("hdr") end
      local ok, err = pcall(apply_monitor, HDR)
      if not ok then
        if first then
          local rollback_ok, rollback_err = pcall(apply_global, "sdr")
          if not rollback_ok then
            error(tostring(err) .. "; failed to restore SDR config: "
              .. tostring(rollback_err), 0)
          end
        end
        error(err, 0)
      end
      active_hdr_instances = active_hdr_instances + 1
      in_hdr = true
      return
    end

    if not in_hdr then
      if force_monitor then apply_monitor(SDR) end
      if active_hdr_instances == 0 then apply_global("sdr") end
      return
    end

    apply_monitor(SDR)
    active_hdr_instances = active_hdr_instances - 1
    in_hdr = false
    if active_hdr_instances == 0 then apply_global("sdr") end
  end

  local function window_wants_hdr(w)
    if CLASSES[w.class] then return true end
    local pid = w.pid
    if not pid or pid <= 0 then return false end
    local verdict = env_wants[pid]
    if verdict == nil then
      local blob = READ(pid)
      if blob == nil then return false end -- transient: retry next event
      verdict = environ_has_any(blob, ENV)
      env_wants[pid] = verdict
    end
    return verdict
  end

  local function window_demand()
    for _, w in ipairs(hl.get_windows(FILTER)) do
      if window_wants_hdr(w) then return true end
    end
    return false
  end

  local function demand()
    return prewarm_gen > 0 or window_demand()
  end

  -- Verdicts die with their windows, or PID reuse would serve a stale one.
  local function prune_cache()
    local live = {}
    for _, w in ipairs(hl.get_windows()) do
      if w.pid then live[w.pid] = true end
    end
    for pid in pairs(env_wants) do
      if not live[pid] then env_wants[pid] = nil end
    end
  end

  local function invalidate_cooldown()
    cooldown_gen = cooldown_gen + 1
    if cooldown_timer then
      cooldown_timer:set_enabled(false)
      cooldown_timer = nil
    end
  end

  -- Always a fresh full-length timer, so the cooldown runs from the LAST
  -- demand end -- a window opening and closing during a pending cooldown must
  -- not inherit the old, nearly expired deadline.
  local function arm_cooldown()
    invalidate_cooldown()
    local gen = cooldown_gen
    cooldown_timer = hl.timer(function()
      if gen ~= cooldown_gen then return end
      cooldown_timer = nil
      if in_hdr and not demand() then
        transition(false)
        last_want = false
      end
    end, { timeout = COOLDOWN_MS, type = "oneshot" })
  end

  -- Monitor flags follow hl.monitor; global state follows hl.config. A failed
  -- call therefore leaves the corresponding state ready for retry.
  local function sync()
    if prune_pending then
      prune_pending = false
      prune_cache()
    end
    local want = demand()
    if want then
      invalidate_cooldown()
      if not in_hdr or monitor_dirty then transition(true, monitor_dirty) end
    elseif in_hdr and (last_want or cooldown_timer == nil) then
      arm_cooldown()
    elseif monitor_dirty then
      transition(false, true)
    elseif active_hdr_instances == 0 and applied_global_state ~= "sdr" then
      apply_global("sdr")
    end
    last_want = want
  end

  -- One immediate sync per burst; the rest coalesce into a trailing re-check.
  local function schedule_sync()
    if coalesce_timer then return end
    sync()
    coalesce_timer = hl.timer(function()
      coalesce_timer = nil
      sync()
    end, { timeout = COALESCE_MS, type = "oneshot" })
  end

  local function schedule_hold(ms, gen)
    hl.timer(function()
      if gen ~= prewarm_gen then return end
      prewarm_gen = 0
      os.remove(state_file(OUTPUT)) -- a dead hold must not resurrect on reload
      sync()
    end, { timeout = ms, type = "oneshot" })
  end

  local function hold(ms)
    prewarm_gen = prewarm_gen + 1
    schedule_hold(ms, prewarm_gen)
  end

  local function prewarm()
    write_hold_deadline(OUTPUT, PREWARM_MS / 1000)
    hold(PREWARM_MS)
    sync()
  end

  -- Baseline. Adopts windows that already exist, and resumes a persisted
  -- prewarm hold, so a config reload mid-game or mid-launch does not flash
  -- SDR right as gamescope probes the output.
  local resume_ms = persisted_hold(OUTPUT, PREWARM_MS)
  if resume_ms > 0 then
    prewarm_gen = prewarm_gen + 1
  else
    os.remove(state_file(OUTPUT))
  end
  local want = demand()
  local baseline_ok, baseline_err = pcall(transition, want, true)
  if not baseline_ok then
    prewarm_gen = 0
    if first_setup then applied_global_state = nil end
    error(baseline_err, 0)
  end
  if first_setup then global_configs = candidate_configs end
  if resume_ms > 0 then schedule_hold(resume_ms, prewarm_gen) end
  last_want = want

  hl.on("window.open", schedule_sync)
  hl.on("window.close", function()
    prune_pending = true
    schedule_sync()
  end)
  hl.on("window.destroy", function()
    prune_pending = true
    schedule_sync()
  end)

  -- A monitor coming back re-applies Hyprland's own rules, wiping ours -- in
  -- BOTH directions: without re-asserting, an SDR desktop loses this spec's
  -- bitdepth/vrr and an HDR game drops to the default preset. Other outputs'
  -- hotplugs are none of this instance's business (a dock display appearing
  -- must not modeset the game monitor).
  hl.on("monitor.added", function(mon)
    if OUTPUT ~= "" and mon and mon.name and mon.name ~= OUTPUT then return end
    invalidate_cooldown()
    local current_want = demand()
    transition(current_want, true)
    last_want = current_want
  end)

  -- Missed or early events (see the 0.56 notes above) would otherwise pin a
  -- state forever; a periodic re-check is the backstop.
  if RECONCILE_MS > 0 then
    hl.timer(sync, { timeout = RECONCILE_MS, type = "repeat" })
  end

  local handle = {
    wants_hdr = window_demand,
    in_hdr    = function() return in_hdr end,
    prewarm   = prewarm,
  }
  table.insert(M._instances, handle)
  return handle
end

--- Enter HDR on every managed monitor before a launcher probes the output.
--- Called from outside the VM: hyprctl eval "require('hypr.sticky_hdr').prewarm()"
function M.prewarm()
  for _, h in ipairs(M._instances) do h.prewarm() end
end

return M
