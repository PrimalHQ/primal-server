module PushGatewayExporter

import HTTP

ENABLED = Ref(false)
JOB = Ref("default")

function set!(k, v; job=JOB[], type=:counter) # type is usually :counter or :gauge
    ENABLED[] || return
    s = "# TYPE $k $type\n$k $v\n"
    HTTP.post("http://127.0.0.1:9091/metrics/job/$job", [], s)
    nothing
end

end
