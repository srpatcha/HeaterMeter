module("luci.controller.linkmeter.admin", package.seeall)

function index()
  entry({"admin", "lm"}, alias("admin", "lm", "conf"), "LinkMeter", 50).index = true
  entry({"admin", "lm", "home"}, alias("lm", "login"), "Home", 10)
  entry({"admin", "lm", "conf"}, template("linkmeter/conf"), "Configuration", 20)
  entry({"admin", "lm", "archive"}, template("linkmeter/archive"), "Archive", 30)
  entry({"admin", "lm", "fw"}, call("action_fw"), "AVR Firmware", 40)

  entry({"admin", "lm", "stashdb"}, call("action_stashdb"))
end

function action_fw()
  local hex = "/tmp/hm.hex"
  
  local file
  luci.http.setfilehandler(
    function(meta, chunk, eof)
      if not nixio.fs.access(hex) and not file and chunk and #chunk > 0 then
        file = io.open(hex, "w")
      end
      if file and chunk then
        file:write(chunk)
      end
      if file and eof then
        file:close()
      end
    end
  )
  local step = tonumber(luci.http.formvalue("step") or 1)
  local has_upload = luci.http.formvalue("hexfile")
  if step == 1 then
    if has_upload and nixio.fs.access(hex) then
      step = 2
    else
      nixio.fs.unlink(hex)
    end
    return luci.template.render("linkmeter/fw", { step=step })
  end
  if step == 3 then
    luci.http.prepare_content("text/plain")
    local pipe = require "luci.controller.admin.system".ltn12_popen(
      "/usr/sbin/avrupdate %q" % hex)
    return luci.ltn12.pump.all(pipe, luci.http.write)
  end 
end

function action_stashdb()
  local http = require "luci.http"
  local uci = luci.model.uci.cursor()

  local RRD_FILE = uci:get("linkmeter", "daemon", "rrd_file")
  local STASH_PATH = uci:get("linkmeter", "daemon", "stashpath") or "/root"
  local restoring = http.formvalue("restore")
  local resetting = http.formvalue("reset")
  local stashfile = http.formvalue("rrd") or "hm.rrd"

  -- directory traversal
  if stashfile:find("[/\\]+") then
    http.status(400, "Bad Request")
    http.prepare_content("text/plain")
    return http.write("Invalid stashfile spefified: "..stashfile)
  end

  -- the stashfile should start with a slash
  if stashfile:sub(1,1) ~= "/" then stashfile = "/"..stashfile end
  -- and end with .rrd
  if stashfile:sub(-4) ~= ".rrd" then stashfile = stashfile..".rrd" end

  stashfile = STASH_PATH..stashfile

  local result
  http.prepare_content("text/plain")
  if restoring == "1" or resetting == "1" then
    luci.sys.call("/etc/init.d/linkmeterd stop")
    if resetting == "1" then
      result = nixio.fs.unlink(RRD_FILE)
      http.write("Resetting "..RRD_FILE)
    else
      result = nixio.fs.copy(stashfile, RRD_FILE)
      http.write("Restoring "..stashfile.." to "..RRD_FILE)
    end
    luci.sys.call("/etc/init.d/linkmeterd start")
  else
    result = nixio.fs.copy(RRD_FILE, stashfile)
    http.write("Stashing "..RRD_FILE.." to "..stashfile)
  end

  if result then
    http.write("\nOK")
  else
    http.write("\nERR")
  end
end

