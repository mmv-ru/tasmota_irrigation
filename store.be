import strict
import persist
import math
import introspect

var store = module('store')

class PersistStore
    # Centralised persist layer. Every key is registered once (default value,
    # write policy, optional relative threshold). Cache holds the live value,
    # Shadow the last value actually written to Flash. Writes are deferred via
    # a dirty flag + 15s debounce timer unless the key's policy is immediate.
    # Multi-channel: per-channel keys are registered under a P{idx} prefix via
    # register_channel(), so one shared store serves all channels (memory-quark
    # budget verified for 4 channels, see BERRY_TASMOTA_CONTEXT.md gotcha #10).
    var Meta
    var Cache
    var Shadow
    var Touched
    var Dirty
    var DebounceMs
    var TimerId

    def init()
        self.Meta = {}
        self.Cache = {}
        self.Shadow = {}
        self.Touched = {}
        self.Dirty = false
        self.DebounceMs = 15000
        self.TimerId = "ID_PERSIST_SAVE"
    end

    def register(name, meta)
        self.Meta[name] = meta
        self.Cache[name] = meta.find('default', nil)
        self.Shadow[name] = meta.find('default', nil)
    end

    def register_channel(prefix)
        # Register the per-channel persistent keys (calibration, dry-soak params,
        # session/prev-stats) under a shared prefix like 'P1'. Defaults mirror the
        # iteration-1 flat registry; nothing is global anymore.
        var keys = {
            'TargetDry': '800', 'TargetWet': '760', 'DryThreshold': '820',
            'SoakStartDose': '15', 'SoakInterval': '7200',
            'SoakTrendWindow': '86400', 'SoakDoseGrow': '1.2',
            'SoakDailyCap': '220', 'SoakMaxDose': '300',
            'LastFloodVol': '0',
            # session dose params in ml: cap + default dose + backflow
            # compensation (Store-only, no UI field), see Plant.init().
            'MaxFlood': '300', 'Counter1FloodDefault': '30', 'Counter1Backflow': '0',
            'SoilHPreFlood': nil,
            'SoilMaxHymidity': nil, 'SoilMaxHymidityTime': nil,
            'PrevSoilMaxHymidity': nil, 'PrevSoilHPreFlood': nil,
            'PrevFloodedVol': nil,
            # date (unix) and avg flow (ml/min) of the last fill; nil until the
            # first flood after the upgrade. Written in _record_flood().
            'LastFloodTime': nil, 'LastFlowRate': nil,
        }
        for p: keys.keys()
            self.register(prefix .. p, {'default': keys[p], 'policy': 'debounced'})
        end
    end

    def get(name)
        return self.Cache.find(name, nil)
    end

    def set(name, value)
        # Update the live cache and the in-memory persist map immediately;
        # the physical save() to Flash is deferred per the key's policy.
        import introspect
        self.Cache[name] = value
        self.Touched[name] = true
        introspect.set(persist, name, value)
        var meta = self.Meta.find(name, {'policy': 'debounced', 'thr': nil})
        var policy = meta.find('policy', 'debounced')
        if policy == 'immediate'
            self.flush(true)
        elif policy == 'threshold'
            var thr = meta.find('thr', nil)
            if thr != nil && self._big_change(name, value, thr)
                self.flush(true)
            else
                self._mark_dirty()
            end
        else
            # debounced (default): mark dirty, the 15s timer does the save
            self._mark_dirty()
        end
    end

    def _mark_dirty()
        self.Dirty = true
        tasmota.remove_timer(self.TimerId)
        tasmota.set_timer(self.DebounceMs, /-> self.flush(), self.TimerId)
    end

    def _big_change(name, value, thr)
        # Relative change vs. the last flushed value, guarding div-by-zero.
        import math
        var old = real(self.Shadow.find(name, self.get(name)))
        var newv = real(value)
        var delta = math.abs(newv - old)
        var base = old
        if base == 0
            base = newv
        end
        if base == 0
            return false
        end
        return delta / base >= thr
    end

    def flush(force)
        # Write all registered keys in one save; Shadow tracks what is on Flash.
        # Keys whose live value is nil are left untouched in persist (they were
        # never written, and writing nil would clear a stored value on boot).
        if !self.Dirty && force != true
            return
        end
        import introspect
        for p: self.Touched.keys()
            var v = self.Cache.find(p, nil)
            if v != nil
                introspect.set(persist, p, v)
            end
            self.Shadow[p] = v
        end
        self.Touched = {}
        persist.save()
        self.Dirty = false
        tasmota.remove_timer(self.TimerId)
    end

    def save_batch_entries(entries)
        # Persist a list of [persist_key, value] pairs in one pass and save once.
        # Used for per-channel prefixed keys, where the persist key name differs
        # from the source member name (Plant stats/session snapshots).
        import introspect
        for e: entries
            var k = e[0]
            var v = e[1]
            self.Cache[k] = v
            self.Touched[k] = true
            introspect.set(persist, k, v)
        end
        self.flush(true)
    end

    def load()
        # Restore Cache/Shadow from persist, falling back to registered defaults.
        for p: self.Meta.keys()
            var d = self.Meta[p].find('default', nil)
            self.Cache[p] = persist.find(p, d)
            self.Shadow[p] = self.Cache[p]
        end
    end

    def has(name)
        # True only if the key was actually written to the device, i.e. it is
        # not merely a registered default. _migrate_units needs exactly this
        # distinction, and reaching raw `persist` from the driver would give
        # the script a second persist instance.
        return persist.find(name, nil) != nil
    end

    def dump()
        # name -> live value snapshot (for the Store command and the web table).
        var r = {}
        for p: self.Meta.keys()
            r[p] = self.Cache.find(p, nil)
        end
        return r
    end
end

# Berry's module() does not auto-collect file-level names (gotcha #13).
store.PersistStore = PersistStore

return store
