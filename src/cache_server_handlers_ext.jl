#module CacheServerHandlers

import ..PushGatewayExporter

periodic_pushgw = Throttle(; period=15.0)
periodic_notification_counts = Throttle(; period=1.0)
periodic_rebroadcasting_status = Throttle(; period=2.0)

function ext_periodic()
    periodic_notification_counts() do
        MetricsLogger.log(r->(; funcall=:broadcast_notification_counts)) do
            broadcast_notification_counts()
        end
    end

    periodic_rebroadcasting_status() do
        MetricsLogger.log(r->(; funcall=:broadcast_rebroadcasting_status)) do
            broadcast_rebroadcasting_status()
        end
    end

    periodic_pushgw() do
        d = Base.invokelatest(App().network_stats, est())
        for (k, v) in collect(JSON.parse(d.content))
            PushGatewayExporter.set!("cache_$(k)", v)
        end

        PushGatewayExporter.set!("cache_cputime_avg", MetricsLogger.cputime_avg[])

        for (ref, name, ty) in [[(max_request_duration, :max_request_duration, :nonrate),
                                 (requests_per_period, :requests_per_second, :rate),
                                 (max_time_between_requests, :max_time_between_requests, :nonrate),
                                 (Main.Media.max_task_duration, :media_max_task_duration, :nonrate),
                                 (Main.Media.tasks_per_period, :media_tasks_per_second, :rate),
                                 (Main.Media.max_download_duration, :media_max_download_duration, :nonrate),
                                 (Main.Media.downloads_per_period, :media_downloads_per_second, :rate),
                                 (Main.Media.execute_distributed_active_slots, :media_execute_distributed_active_slots, :nonrate),
                                ]; (hasproperty(Main, :spamdetector) ? 
                                    [
                                     (Main.spamdetector.max_msg_duration, :spam_max_msg_duration, :nonrate),
                                     (Main.spamdetector.max_spammer_follower_cnt, :max_spammer_follower_cnt, :nonrate),
                                    ] : [])]
            lock(ref) do ref
                PushGatewayExporter.set!("cache_$(name)", 
                                         ty == :nonrate ? ref[] : ref[] / periodic_pushgw.period)
                ref[] = 0
            end
        end

        PushGatewayExporter.set!("media_queue_size", Main.Media.media_processing_channel.n_avail_items)

        for name in [:media_downloaded_bytes]
            lock(est().commons.stats) do stats
                if haskey(stats, name)
                    PushGatewayExporter.set!("cache_$(name)", stats[name])
                end
            end
        end

        PushGatewayExporter.set!("cache_cputime_avg", MetricsLogger.cputime_avg[])

        Main.CacheServerSync.last_t[] > 0 && PushGatewayExporter.set!("cache_sync_last_t", Main.CacheServerSync.last_t[])
        PushGatewayExporter.set!("cache_sync_last_duration", Main.CacheServerSync.last_duration[])
    end
end

function broadcast_notification(notif)
    content = JSON.json(notif)
    with_broadcast(:broadcast_notification) do conn, subid, filt
        if haskey(filt, "cache")
            filt = filt["cache"]
            if length(filt) >= 2 && filt[1] == "notifications"
                pk = Nostr.PubKeyId(filt[2]["pubkey"])
                if pk == notif.pubkey
                    d = (; kind=Int(App().NOTIFICATION), content)
                    @async send(conn, JSON.json(["EVENT", subid, d]))
                    return true
                end
            end
        end
    end
end

function broadcast_notification_counts()
    with_broadcast(:broadcast_notification_counts) do conn, subid, filt
        if haskey(filt, "cache")
            filt = filt["cache"]
            if length(filt) >= 2
                for (funcall, f) in [
                                     ("notification_counts", App().get_notification_counts),
                                     ("notification_counts_2", App().get_notification_counts_2),
                                    ]
                    if filt[1] == funcall
                        pubkey = Nostr.PubKeyId(filt[2]["pubkey"])
                        for d in Base.invokelatest(f, est(); pubkey)
                            @async send(conn, JSON.json(["EVENT", subid, d]))
                        end
                        return true
                    end
                end
            end
        end
    end
end

function broadcast_rebroadcasting_status()
    with_broadcast(:broadcast_rebroadcasting_status) do conn, subid, filt
        if haskey(filt, "cache")
            filt = filt["cache"]
            if length(filt) >= 2
                if filt[1] == "rebroadcasting_status"
                    event_from_user = filt[2]["event_from_user"]
                    for d in Base.invokelatest(App().membership_content_rebroadcast_status, est(); event_from_user)
                        @async send(conn, JSON.json(["EVENT", subid, d]))
                    end
                    return true
                end
            end
        end
    end
end

