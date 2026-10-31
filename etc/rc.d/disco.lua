-- Announce this computer at boot. Enable in /etc/rc.cfg, e.g.:
--   enabled = {"disco"}
--   disco = {name = "hub", services = {craftServer = 5990}}
function start()
    require("disco").start(args)
end

function stop()
    require("disco").stop()
end
