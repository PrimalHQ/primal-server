for fn in [
           "utils.jl",
           "nostr.jl",
           "nostr_client.jl",
           "bech32.jl",
           "fetching.jl",
           "clocks.jl",
           "perf_stats.jl",
           "pushgateway_exporter.jl",
           "filterlist.jl",
           "trust_rank.jl",
           "postgres.jl",
           "postgres_macros.jl",
           "tracing.jl",
           "workers.jl",
           "db.jl",
           "media.jl",
           "metrics_logger.jl",
           "app.jl",
           "blossom.jl",
           "perf_test_redirection.jl",
           "cache_server_handlers.jl",
           "cache_server.jl",
           "spam_detection.jl",
           "firehose_client.jl",
           "firehose_server.jl",
           "cache_server_sync.jl",
           "event_sync.jl",
           "dvm_service_provider.jl",
           "dvm_feed_checker.jl",
           "dag_base.jl",
           "dag.jl",
           "dag_runner.jl",
           "event_rebroadcasting.jl",
          ]
    fn = "src/$fn"
    println(fn, " -> ", include(fn))
end

include("firehose_server_default_message_processors.jl")

include("internal_services.jl")

DB.PRINT_EXCEPTIONS[] = true

#gctask = Utils.GCTask(; full=true, period=300)

stuff = []
stuffd = Dict() |> Utils.ThreadSafe
