import strict

var web_kit = module('web_kit')

# Web rendering helpers. The whole web UI is hand-built HTML emitted via
# tasmota.web_send_decimal(); these two cover the two <tr> templates used
# everywhere (sub-row and group header) so a label/style change lives in one
# place instead of ~30 inline <tr> literals. Output is byte-identical to the
# inline markup they replace.
def wrow(label, value)
    return "<tr class='sub'><th>" .. label .. "</th><td>" .. value .. "</td></tr>"
end

def wgrp(label)
    return "<tr class='grp'><td colspan='2'>" .. label .. "</td></tr>"
end

# onclick attribute with a single quote rule: HTML attr value in single quotes,
# JS inside may use double quotes freely (no Berry-level escape audit per site).
def wonclick(js)
    return "onclick='" .. js .. "'"
end

# Section-toggle onclick (header + chevron share the same _secToggle call).
def wtoggle(sec)
    return wonclick('_secToggle("' .. sec .. '");return false;')
end

# Header badge (raw/сухо/влажно pill in the section header row).
def wpill(label, value)
    return "<span class='pill'><b>" .. label .. "</b> " .. value .. "</span>"
end

# Berry's module() does not auto-collect file-level names (gotcha #13), so the
# five helpers are published explicitly.
web_kit.wrow = wrow
web_kit.wgrp = wgrp
web_kit.wonclick = wonclick
web_kit.wtoggle = wtoggle
web_kit.wpill = wpill

return web_kit