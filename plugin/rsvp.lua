local rsvp = require("rsvp")
local create_user_command = vim.api.nvim_create_user_command

create_user_command("Rsvp", rsvp.rsvp, { desc = "RSVP", range = "%" })
create_user_command("RsvpPlay", rsvp.play, { desc = "RSVP Play" })
create_user_command("RsvpPause", rsvp.pause, { desc = "RSVP Pause" })
create_user_command("RsvpRefresh", rsvp.refresh, { desc = "RSVP Refresh" })
create_user_command("RsvpDecreaseWpm", function()
  rsvp.adjust_wpm(-25)
end, { desc = "RSVP Increase WPM" })
create_user_command("RsvpIncreaseWpm", function()
  rsvp.adjust_wpm(25)
end, { desc = "RSVP Increase WPM" })
