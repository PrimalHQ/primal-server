module InternalServices2

import JSON

import ..Utils
import ..Nostr
import ..Postgres
import ..Media
using ..Tracing: @ti, @tc, @td, @tr
using ..ProcessingGraph: @procnode, @pn, @pnl
using ..PostgresMacros: @p0_str, @ms_str, tonamedtuples

Postgres.jl_to_pg_type_conversion[Base.UUID] = string

@procnode function restore_media(media_block_id::Base.UUID)
    func_name = "restore_media"
    @tr media_block_id
    for f in p0"select d from media_block where id = $media_block_id limit 1"[1].d["files"]
        mp, p = f["mp"], f["p"]
        if     Symbol(mp[1]) == :local
            try @show @pn cp(f["dst"], f["filepath"])
            catch _ end
        elseif Symbol(mp[1]) == :s3
            s3_provider = Symbol(mp[2])
            try @pn Media.s3_copy(s3_provider, 
                                  Main.S3_CONFIGS[s3_provider].bucket2, string(p[2:end]),
                                  Main.S3_CONFIGS[s3_provider].bucket,  string(p[2:end]))
            catch _ end
        end
    end
    for (server, table) in [(:membership, "short_urls"), (:membership, "media_uploads"), (:p0, "media_storage")]
        @pnl ("clear_media_block_id", @show (Postgres.execute(server, "select * from $table where media_block_id = \$1", [media_block_id]) |> tonamedtuples))
        Postgres.execute(server, "update $table set media_block_id = null where media_block_id = \$1", [media_block_id])
    end
    nothing
end

@procnode function restore_user_media(pubkey::Nostr.PubKeyId)
    res = []
    for r in ms"select media_block_id from media_uploads where pubkey = $pubkey and media_block_id is not null"
        @show r
        push!(res, restore_media(r.media_block_id))
    end
    res
end

# @pn println("pntest", 123)
# @pnl ("pnltest", p0"select count(1) as cnt from media_block")

end
