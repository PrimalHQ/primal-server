#module CacheServerHandlers

import ..PushGatewayExporter
import ..CacheServerSync

periodic_pushgw = Throttle(; period=15.0)
periodic_notification_counts = Throttle(; period=1.0)

Media() = Main.eval(:(Media))
SpamDetection() = Main.eval(:(SpamDetection))

function ext_periodic()
    periodic_notification_counts() do
        MetricsLogger.log(r->(; funcall=:broadcast_notification_counts)) do
            broadcast_notification_counts()
        end
    end

    periodic_pushgw() do
        d = Base.invokelatest(App().network_stats, est())
        for (k, v) in collect(JSON.parse(d.content))
            PushGatewayExporter.set!("cache_$(k)", v)
        end

        PushGatewayExporter.set!("cache_cputime_avg", MetricsLogger.cputime_avg[])

        for (ref, name, ty) in [(max_request_duration, :max_request_duration, :nonrate),
                                (requests_per_period, :requests_per_second, :rate),
                                (Media().max_task_duration, :media_max_task_duration, :nonrate),
                                (Media().tasks_per_period, :media_tasks_per_second, :rate),
                                (Media().max_download_duration, :media_max_download_duration, :nonrate),
                                (Media().downloads_per_period, :media_downloads_per_second, :rate),
                                (SpamDetection().max_msg_duration, :spam_max_msg_duration, :nonrate),
                               ]
            lock(ref) do ref
                PushGatewayExporter.set!("cache_$(name)", 
                                         ty == :nonrate ? ref[] : ref[] / periodic_pushgw.period)
                ref[] = 0
            end
        end

        PushGatewayExporter.set!("media_queue_size", Media().media_processing_channel.n_avail_items)

        for name in [:media_downloaded_bytes]
            lock(est().commons.stats) do stats
                if haskey(stats, name)
                    PushGatewayExporter.set!("cache_$(name)", stats[name])
                end
            end
        end

        PushGatewayExporter.set!("cache_cputime_avg", MetricsLogger.cputime_avg[])

        CacheServerSync.last_t[] > 0 && PushGatewayExporter.set!("cache_sync_last_t", CacheServerSync.last_t[])
        PushGatewayExporter.set!("cache_sync_last_duration", CacheServerSync.last_duration[])
    end
end

function broadcast_notification(notif)
    content = JSON.json(notif)
    for conn in collect(values(conns))
        for (subid, filters) in lock(conn) do conn; conn.subs; end
            for filt in filters
                try
                    if haskey(filt, "cache")
                        filt = filt["cache"]
                        if length(filt) >= 2 && filt[1] == "notifications"
                            pk = Nostr.PubKeyId(filt[2]["pubkey"])
                            if pk == notif.pubkey
                                d = (; kind=Int(App().NOTIFICATION), content)
                                @async send(conn, JSON.json(["EVENT", subid, d]))
                                @goto next
                            end
                        end
                    end
                catch ex
                    push!(exceptions, (:notifications, filt, ex))
                end
            end
            @label next
        end
    end
end

function broadcast_notification_counts()
    for conn in collect(values(conns))
        for (subid, filters) in lock(conn) do conn; conn.subs; end
            for filt in filters
                try
                    if haskey(filt, "cache")
                        filt = filt["cache"]
                        if length(filt) >= 2 && filt[1] == "notification_counts"
                            pubkey = Nostr.PubKeyId(filt[2]["pubkey"])
                            for d in Base.invokelatest(App().get_notification_counts, est(); pubkey)
                                @async send(conn, JSON.json(["EVENT", subid, d]))
                            end
                            @goto next
                        end
                    end
                catch ex
                    push!(exceptions, (:notification_counts, filt, ex))
                end
            end
            @label next
        end
    end
end

