module PushGatewayExporter

import HTTP

ENABLED = Ref(false)
JOB = Ref("default")
HOSTPORT = Ref(("127.0.0.1", 9091))
TIMEOUT = Ref(10)

function set!(k, v; job=JOB[], type=:counter) # type is usually :counter or :gauge
    ENABLED[] || return
    s = "# TYPE $k $type\n$k $v\n"
    HTTP.post("http://$(HOSTPORT[][1]):$(HOSTPORT[][2])/metrics/job/$job", [], s;
              retry=false, connect_timeout=TIMEOUT[], readtimeout=TIMEOUT[])
    nothing
end

end
