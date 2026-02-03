local rsvp = require("rsvp")
vim.api.nvim_create_user_command("Rsvp", rsvp.rsvp, { desc = "RSVP", range = "%" })
vim.api.nvim_create_user_command("RsvpPlay", rsvp.play, { desc = "RSVP Play" })
vim.api.nvim_create_user_command("RsvpPause", rsvp.pause, { desc = "RSVP Pause" })
