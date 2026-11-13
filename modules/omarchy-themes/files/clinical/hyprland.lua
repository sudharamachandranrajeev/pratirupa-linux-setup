-- Clinical: teal→sky gradient on focus, quiet scrub-teal when idle,
-- with a faint monitor-glow shadow so the active window reads instantly.
local active_border_color = { colors = { "rgba(2dd4bfee)", "rgba(7dd3fcee)" }, angle = 45 }
local inactive_border_color = "rgba(1b3f4aaa)"
local active_shadow_color = "rgba(2dd4bf40)"
local inactive_shadow_color = "rgba(050e1266)"

hl.config({
  general = {
    col = {
      active_border = active_border_color,
      inactive_border = inactive_border_color,
    },
  },

  group = {
    col = {
      border_active = active_border_color,
      border_inactive = inactive_border_color,
    },
  },

  decoration = {
    shadow = {
      enabled = true,
      range = 10,
      render_power = 3,
      color = active_shadow_color,
      color_inactive = inactive_shadow_color,
    },
  },
})
