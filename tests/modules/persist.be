# persist stub: class instance (like real Tasmota persist), returned as a module
# so `import persist` in watering.be picks it up. Stock Berry v1.1.0 has no
# introspect.setmodule; a module file returning a class instance works, and
# `introspect.set(persist, k, v)` dispatches to the virtual setmember.
class Persist
    var _p
    var saves
    def init()
        self._p = {}
        self.saves = 0
    end
    def find(k, d) return self._p.find(k, d) end
    def has(k) return self._p.find(k) != nil end
    def member(k) return self._p.find(k) end
    def setmember(k, v) self._p[k] = v end
    def save()
        self.saves = self.saves + 1
        return true
    end
end
return Persist()