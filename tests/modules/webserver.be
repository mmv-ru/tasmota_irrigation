var has_arg = def (name) return false end
var arg = def (name) return "" end
var content_send = def (html) print("web:", html) end
var content_open = def (a, b) end
return {'has_arg': has_arg, 'arg': arg, 'content_send': content_send, 'content_open': content_open}