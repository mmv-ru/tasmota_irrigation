# persist stub: class instance (like real Tasmota persist), returned as a module
# so `import persist` in watering.be picks it up. Stock Berry v1.1.0 has no
# introspect.setmodule; a module file returning a class instance works, and
# `introspect.set(persist, k, v)` dispatches to the virtual setmember.
class Persist
    var _p
    var saves
    def init()
        self._p = {}
        # Characterisation fixture: the suite exercises the 4-channel page layout
        # (web-sensor channel 4 detail, NumChannels/Channels assertions). The
        # watering runner registers its own default ('2'); seeding this stub keeps
        # the existing 4-channel coverage running unchanged.
        self._p['Channels'] = '4'
        self.saves = 0
    end
    def find(k, d)
        # A nil-stored value is treated as absent (introspect.set(k, nil) removes
        # the key on the real device), so callers fall back to their default.
        var v = self._p.find(k, nil)
        if v == nil return d end
        return v
    end
    def has(k) return self._p.find(k) != nil end
    def member(k) return self._p.find(k) end
    def setmember(k, v) self._p[k] = v end
    def save()
        self.saves = self.saves + 1
        return true
    end
end
return Persist()