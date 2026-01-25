local rsvp = require("rsvp")
vim.api.nvim_create_user_command("Rsvp", rsvp.rsvp, { desc = "RSVP", range = "%" })
