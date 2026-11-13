-- Pratirupa desktop tweaks for Omarchy's Hyprland.
--
-- Installed by pratirupa (module desktop-hyprland) and loaded by one
-- require("hypr.pratirupa") line at the end of ~/.config/hypr/hyprland.lua.
-- Re-running pratirupa replaces this file (the old copy is kept in
-- ~/.local/state/pratirupa/backup). Put your own changes in bindings.lua,
-- input.lua or looknfeel.lua instead.

local home = os.getenv("HOME")

local function exists(path)
  local f = io.open(path, "r")
  if f then f:close() return true end
  return false
end

local function have(cmd)
  return exists(home .. "/.local/bin/" .. cmd) or exists("/usr/bin/" .. cmd) or exists("/usr/local/bin/" .. cmd)
end

-- ---------------------------------------------------------------------------
-- Touchpad
-- ---------------------------------------------------------------------------

hl.config({
  input = {
    touchpad = {
      -- Content follows your fingers (macOS / Windows precision-touchpad feel).
      natural_scroll = true,
      -- Two-finger click = right click.
      clickfinger_behavior = true,
      -- Raise toward 1.0 if scrolling feels sluggish.
      scroll_factor = 0.4,
      -- Ignore the pad briefly after a keypress so palms don't move the cursor.
      disable_while_typing = true,
    },
  },
})

-- ---------------------------------------------------------------------------
-- Swipe gestures (Hyprland enables none by default)
-- ---------------------------------------------------------------------------

-- Three fingers left/right: move between workspaces, tracking 1:1.
hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })

-- Three fingers up: fullscreen the focused window (same as SUPER + F).
hl.gesture({ fingers = 3, direction = "up", action = "fullscreen", mode = "fullscreen" })

-- Three fingers down: close the focused window (same as SUPER + W).
hl.gesture({ fingers = 3, direction = "down", action = "close" })

-- Four fingers up: toggle Omarchy's scratchpad (same as SUPER + S).
hl.gesture({ fingers = 4, direction = "up", action = "special", workspace_name = "scratchpad" })

-- Four-finger pinch: Hyprland's screen magnifier. Two-finger pinch stays free
-- so browsers and other apps can zoom their own content.
hl.gesture({ fingers = 4, direction = "pinch", action = "cursor_zoom", zoom_level = 2 })

-- ---------------------------------------------------------------------------
-- Key bindings (each only when its program is installed)
-- ---------------------------------------------------------------------------

-- Always-listening voice control (Mantri): pause/resume listening.
if have("mantri-toggle") then
  o.bind("SUPER + CTRL + J", "Toggle Mantri voice control", "mantri-toggle")
end

-- Cast the screen to a network TV/display (Miracast or Chromecast).
if have("cast-screen") then
  o.bind("SUPER + ALT + SHIFT + C", "Cast screen", "cast-screen")
  o.window("org.gnome.NetworkDisplays", { float = true, center = true, size = { 520, 600 } })
end

-- Music: Paattu instead of Spotify.
if have("paattu") then
  hl.unbind("SUPER + SHIFT + M")
  o.bind("SUPER + SHIFT + M", "Music (Paattu)", "omarchy-shell paattu toggle")
end

-- Files: a revamped Nautilus build, when one is installed there.
local nautilus_revamp = home .. "/.local/lib/nautilus-revamp/nautilus-launcher"
if exists(nautilus_revamp) then
  hl.unbind("SUPER + SHIFT + F")
  o.bind("SUPER + SHIFT + F", "File manager", { launch = nautilus_revamp .. " --new-window" })
  hl.unbind("SUPER + ALT + SHIFT + F")
  o.bind("SUPER + ALT + SHIFT + F", "File manager (cwd)",
    "setsid " .. o.launch(nautilus_revamp .. ' --new-window "$(omarchy-cmd-terminal-cwd)"'))
end

-- Extra dictation keys (Alt + Space and Right Alt remain the defaults).
if o.dictation_installed and o.dictation_installed() then
  o.bind("SUPER + CTRL + X", "Toggle dictation", "omarchy-dictation toggle")
  o.bind_hold("F9", "Start dictation (push-to-talk)", "omarchy-dictation start",
    "Stop dictation (push-to-talk)", "omarchy-dictation stop")
end
