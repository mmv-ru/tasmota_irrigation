import webserver
import string
import json

var watering_ui = module('watering_ui')

class watering_ui_driver
    var _button

    def init()
        tasmota.add_driver(self)
        webserver.on('/ws', / -> self.http_get(), webserver.HTTP_GET)
        webserver.on('/ws', / -> self.http_post(), webserver.HTTP_POST)

    end

    def deinit()
        tasmota.remove_driver(self)
    end

    def load_file(fn)
        var obj, f
        f = open(watering_ui.wd .. fn, 'r')
        obj = json.load(f.read())
        f.close()
        return obj
    end

    # Displays a "Configure Heating" button on the configuration page
    def web_add_config_button()
        if !self._button
            self._button = self.load_file('html.json')['button']
        end
        webserver.content_send(self._button)
    end

    # Add HTTP POST and GET handlers
    def http_get()
        var html = self.load_file('html.json')
        self.on_http_get(html)
    end

    def http_post()
        #self.on_http_post()
        self.http_get()
    end

    def on_http_get(html)
        if !webserver.check_privileged_access() return nil end
        #var options = tasmota.cmd("HeatingOptions")['HeatingOptions']
        var options = {'A': true, 'B': false}
        webserver.content_start('Configure Heating')
        webserver.content_send_style()
        if webserver.has_arg('set')
        else
            self.show_options(html['options'], options)
        end
        webserver.content_button(webserver.BUTTON_CONFIGURATION)
        webserver.content_stop()
    end

    def show_options(html, options)
        webserver.content_send(html[0])
        for k: options.keys()
            var checked = options[k] ? 'checked' : ''
            webserver.content_send(string.format(html[1], k, checked, k, k))
        end
        webserver.content_send(html[2])
    end

end

watering_ui.wd = ''

import introspect
if introspect.get(global, "watering_ui_driver") != nil
    print("Remove old Watering_ui driver")
    introspect.get(global, "watering_ui_driver").deinit()
end

print("Add Watering_ui driver")
var wud = watering_ui_driver()
print("Watering_ui driver initialized")

return watering_ui
