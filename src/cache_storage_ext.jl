#module DB

import ..Filterlist
import ..TrustRank
import SHA

using ..Tracing: @ti, @tc, @td, @tr
using ..ProcessingGraph: @procnode, @pn, @pnl, @pnd
import ..PrimalServer

include("../src/notifications.jl")

function notification_counter_update(est, notif)
    lock(est.notification_counter_update_lock) do
        nt = Int(notif.type)
        try
            for arg in collect(values(notif))
                if arg isa Nostr.PubKeyId
                    pk = arg
                    if !is_trusted_user(est, pk)
                        return
                    end
                end
            end
        catch ex
            println("notification_counter_update: ", typeof(ex))
        end
        if !(notif.pubkey in est.pubkey_notification_cnts)
            DB.exe(est.pubkey_notification_cnts, DB.@sql("insert into pubkey_notification_cnts (pubkey) values (?1)"), notif.pubkey)
        end
        DB.exe(est.pubkey_notification_cnts, "update pubkey_notification_cnts set type$nt = type$nt + 1 where pubkey = ?1", notif.pubkey)
    end
end

function ext_init(est::CacheStorage)
##
    est.notification_processors[:notification_counter_update] = notification_counter_update
##
    est.dyn[:user_search] = est.params.DBDict(Nostr.PubKeyId, Nostr.EventId, "user_search"; est.dbargs...,
                              keycolumn="pubkey", valuecolumn="name",
                              init_queries=["create table if not exists user_search (
                                            pubkey bytea not null,
                                            event_id bytea not null,
                                            name tsvector,
                                            username tsvector,
                                            display_name tsvector,
                                            displayName tsvector,
                                            nip05 tsvector,
                                            lud16 tsvector,
                                            primary key (pubkey)
                                            )",
                                            # "create index if not exists user_search_pubkey_idx on user_search (pubkey)",
                                            "create index if not exists user_search_name_idx on user_search using GIN (name)",
                                            "create index if not exists user_search_username_idx on user_search using GIN (username)",
                                            "create index if not exists user_search_display_name_idx on user_search using GIN (display_name)",
                                            "create index if not exists user_search_displayName_idx on user_search using GIN (displayName)",
                                            "create index if not exists user_search_nip05_idx on user_search using GIN (nip05)",
                                            "create index if not exists user_search_lud16_idx on user_search using GIN (lud16)",
                                            ])
##
    est.dyn[:reported] = est.params.MembershipDBDict(Nostr.PubKeyId, Bool, "reported"; connsel=est.pqconnstr,
                                                      init_queries=["create table if not exists reported (
                                                                    pubkey bytea not null,
                                                                    type int8 not null,
                                                                    id bytea not null,
                                                                    created_at int8 not null,
                                                                    primary key (pubkey, type, id)
                                                                    )",
                                                                    "create index if not exists reported_pubkey on reported (pubkey asc)",
                                                                    "create index if not exists reported_created_at on reported (created_at desc)",
                                                                   ])
##
    est.dyn[:event_zapped] = est.params.DBSet(Nostr.EventId, "event_zapped"; est.dbargs...,
                                                 init_queries=["!create table if not exists event_zapped (
                                                               event_id blob not null,
                                                               zap_sender blob not null
                                                               )",
                                                               "create index if not exists event_zapped_event_id_zap_sender on event_zapped (event_id asc, zap_sender asc)",
                                                              ])
##
    est.dyn[:stuff] = est.params.DBSet(String, "stuff"; est.dbargs...,
                                    init_queries=["!create table if not exists stuff (
                                                  data text not null,
                                                  created_at int not null
                                                  )",
                                                  "create index if not exists stuff_created_at on stuff (created_at desc)",
                                                 ])
##
    est.dyn[:video_thumbnails] = est.params.DBDict(String, Int, "video_thumbnails"; est.dbargs...,
                                  keycolumn="url", valuecolumn="imported_at",
                                  init_queries=["!create table if not exists video_thumbnails (
                                                video_url text not null,
                                                thumbnail_url text not null,
                                                primary key (video_url)
                                                )",
                                                "create index if not exists video_thumbnails_thumbnail_url on video_thumbnails (thumbnail_url asc)",
                                               ])
##
    est.dyn[:event_attributes] = est.params.DBSet(Nostr.EventId, "event_attributes"; est.dbargs...,
                                                 init_queries=["!create table if not exists event_attributes (
                                                               event_id blob not null,
                                                               key text not null,
                                                               value int not null
                                                               )",
                                                               "create index if not exists event_attributes_event_id on event_attributes (event_id asc)",
                                                               "create index if not exists event_attributes_key_value on event_attributes (key asc, value desc)",
                                                              ])
##
    est.dyn[:human_override] = est.params.MembershipDBDict(Nostr.PubKeyId, Bool, "human_override"; connsel=est.pqconnstr, keycolumn="pubkey", valuecolumn="is_human")
##
    est.dyn[:app_subsettings] = est.params.MembershipDBDict(Nostr.PubKeyId, String, "app_subsettings"; connsel=est.pqconnstr,
                                                            init_queries=["create table if not exists app_subsettings (
                                                                          pubkey bytea not null,
                                                                          subkey varchar not null,
                                                                          updated_at int8 not null,
                                                                          settings jsonb not null,
                                                                          primary key (pubkey, subkey)
                                                                          )",
                                                                         ])
##
    est.dyn[:pubkey_trustrank] = est.params.DBDict(Nostr.PubKeyId, Float64, "pubkey_trustrank"; est.dbargs...,
                                  keycolumn="pubkey", valuecolumn="rank",
                                  init_queries=["create table if not exists pubkey_trustrank (
                                                pubkey bytea not null,
                                                rank float8 not null,
                                                primary key (pubkey)
                                                )",
                                               ])
##
    est.dyn[:cmr_pubkeys_scopes] = est.params.DBSet(Nostr.PubKeyId, "cmr_pubkeys_scopes"; est.dbargs...,
                              init_queries=["create table if not exists cmr_pubkeys_scopes (
                                                user_pubkey bytea,
                                                pubkey bytea not null,
                                                scope cmr_scope not null
                                            )",
                                            "create index if not exists cmr_pubkeys_scopes_user_pubkey_pubkey_scope_idx on cmr_pubkeys_scopes (user_pubkey, pubkey, scope)",
                                            ])
    est.dyn[:cmr_pubkeys_parent] = est.params.DBSet(Nostr.PubKeyId, "cmr_pubkeys_parent"; est.dbargs...,
                              init_queries=["create table if not exists cmr_pubkeys_parent (
                                                user_pubkey bytea,
                                                pubkey bytea not null,
                                                parent bytea not null
                                            )",
                                            "create index if not exists cmr_pubkeys_parent_user_pubkey_pubkey_idx on cmr_pubkeys_parent (user_pubkey, pubkey)",
                                            ])
    est.dyn[:cmr_groups] = est.params.DBSet(Nostr.PubKeyId, "cmr_groups"; est.dbargs...,
                              init_queries=["create table if not exists cmr_groups (
                                                user_pubkey bytea,
                                                grp cmr_grp not null,
                                                scope cmr_scope not null
                                            )",
                                            "create index if not exists cmr_groups_user_pubkey_grp_scope_idx on cmr_groups (user_pubkey, grp, scope)",
                                            ])
    est.dyn[:cmr_pubkeys_allowed] = est.params.DBSet(Nostr.PubKeyId, "cmr_pubkeys_allowed"; est.dbargs...,
                              init_queries=["create table if not exists cmr_pubkeys_allowed (
                                                user_pubkey bytea,
                                                pubkey bytea not null
                                            )",
                                            "create index if not exists cmr_pubkeys_allowed_user_pubkey_pubkey_idx on cmr_pubkeys_allowed (user_pubkey, pubkey)",
                                            ])
##
    est.dyn[:filterlist] = est.params.DBSet(Vector{UInt8}, "filterlist"; est.dbargs...,
                              init_queries=["create table if not exists filterlist (
                                                target bytea not null,
                                                target_type filterlist_target not null,
                                                blocked bool not null,
                                                grp filterlist_grp not null,
                                                primary key (target, target_type, blocked, grp)
                                            )",
                                            ])
##
    est.dyn[:cache] = est.params.DBDict(String, Any, "cache"; est.dbargs...,
                                        valuefuncs=DB.DBConversionFuncs(JSON.json, identity),
                                        init_queries=["create unlogged table if not exists cache (
                                                      key text not null,
                                                      value jsonb not null,
                                                      updated_at timestamp not null default now(),
                                                      primary key (key)
                                                      )",
                                                      raw"DO $$BEGIN CREATE TRIGGER update_cache_updated_at BEFORE UPDATE ON cache FOR EACH ROW EXECUTE PROCEDURE update_updated_at(); EXCEPTION WHEN duplicate_object THEN NULL; END;$$;",
                                                     ])
##
    est.dyn[:dvm_feeds] = est.params.DBDict(Nostr.PubKeyId, Any, "dvm_feeds"; est.dbargs...,
                                            keycolumn="pubkey",
                                            valuecolumn="results",
                                            valuefuncs=DB.DBConversionFuncs(JSON.json, identity),
                                            init_queries=["create table if not exists dvm_feeds (
                                                          pubkey bytea not null,
                                                          identifier varchar not null,
                                                          updated_at timestamp not null,
                                                          results jsonb,
                                                          kind varchar not null,
                                                          personalized bool not null,
                                                          ok bool not null,
                                                          primary key (pubkey, identifier)
                                                          )",
                                                         ])
##
    est.dyn[:user_last_online_time] = est.params.MembershipDBDict(Nostr.PubKeyId, Int, "user_last_online_time"; connsel=est.pqconnstr,
                                                                  keycolumn="pubkey",
                                                                  valuecolumn="online_at",
                                                                  init_queries=["create table if not exists user_last_online_time (
                                                                                pubkey bytea not null,
                                                                                online_at int8 not null,
                                                                                primary key (pubkey)
                                                                                )",
                                                                               ])
##
end

function insert_stuff(est::CacheStorage, data)
    exec(est.dyn[:stuff], @sql("insert into stuff values (?1, ?2)"), (JSON.json(data), trunc(Int, time())))
end

function ext_preimport_check(est::CacheStorage, e::Nostr.Event)
    !(e.pubkey in Filterlist.import_pubkey_blocked)
end

function ext_preimport(est::CacheStorage, e::Nostr.Event)
    # try
    #     for t in e.tags
    #         flds = t.fields
    #         if length(flds) >= 3 && (flds[1] == "e" || flds[1] == "p")
    #             relay_url = flds[3]
    #             ps = split(relay_url, "://")
    #             if length(ps) >= 2
    #                 scheme = ps[1]
    #                 if scheme == "http" || scheme == "https" || scheme == "ws" || scheme == "wss"
    #                     register_relay(est, relay_url)
    #                 end
    #             end
    #         end
    #     end
    # catch _
    #     PRINT_EXCEPTIONS[] && print_exceptions()
    # end
    
end

function ext_pubkey(est::CacheStorage, e::Nostr.Event)
    ext_pubkey(est, e.pubkey)
end

function ext_pubkey(est::CacheStorage, pubkey::Nostr.PubKeyId)
    exe(est.pubkey_zapped, @sql("insert into pubkey_zapped (pubkey, zaps, satszapped) values (?1, ?2, ?3) on conflict do nothing"), pubkey, 0, 0)
end

function ext_metadata_changed(est::CacheStorage, e::Nostr.Event)
    catch_exception(est, (:update_user_search, e.pubkey)) do
        update_user_search(est, e.pubkey)
    end
    catch_exception(est, (:import_media_from_metadata, e.pubkey)) do
        d = JSON.parse(e.content)
        d isa Dict && for a in ["banner", "picture"]
            if haskey(d, a)
                url = d[a]
                if !isnothing(url) && !isempty(url)
                    _, ext = splitext(lowercase(url))
                    if any((startswith(ext, ext2) for ext2 in image_exts))
                        # DOWNLOAD_MEDIA[] && Main.Media.media_queue(@task import_media(est, e.id, url, Main.Media.all_variants))
                        DOWNLOAD_MEDIA[] && @pnd import_media_pn(est, e.id, url, Main.Media.all_variants)
                    end
                end
            end
        end
    end
end

function import_follow_list_media(est::CacheStorage, e::Nostr.Event)
    catch_exception(est, (:import_follow_list_media, e.id)) do
        for t in e.tags
            if length(t.fields) >= 2 && t.fields[1] == "image"
                url = t.fields[2]
                # DOWNLOAD_MEDIA[] && Main.Media.media_queue(@task import_media(est, e.id, url, Main.Media.all_variants))
                DOWNLOAD_MEDIA[] && @pnd import_media_pn(est, e.id, url, Main.Media.all_variants)
            end
        end
    end
end

function ext_reaction(est::CacheStorage, e::Nostr.Event, eid)
    event_hook(est, eid, (:score_event_cb, e.pubkey, e.created_at, :like, 1))
    # event_hook(est, eid, (:notifications_cb, YOUR_POST_WAS_LIKED, e.id, e.content))
    event_hook(est, eid, (:notifications_cb, POST_YOU_WERE_MENTIONED_IN_WAS_LIKED, e.id))
    event_hook(est, eid, (:notifications_cb, POST_YOUR_POST_WAS_MENTIONED_IN_WAS_LIKED, "make_event_hooks", e.id))
end

DOWNLOAD_MEDIA    = Ref(false)
DOWNLOAD_PREVIEWS = Ref(false)
image_exts = [".png", ".gif", ".jpg", ".jpeg", ".webp"]
video_exts = [".mp4", ".mov", ".3gp"]
audio_exts = [".wav", ".mp3", ".aac", ".flac", ".ogg"]

MEDIA_BLOCKED_PUBKEYS = Set{Nostr.PubKeyId}()

function import_note_urls(est::CacheStorage, e::Nostr.Event)
    funcname = "import_note_urls"
    # @show e.id
    DB.ext_is_human(est, e.pubkey; threshold=0.0) || return
    e.pubkey in MEDIA_BLOCKED_PUBKEYS && return
    for_urls(est, e) do url
        _, ext = splitext(lowercase(url))
        if any((startswith(ext, ext2) for ext2 in image_exts))
            # DOWNLOAD_MEDIA[] && Main.Media.media_queue(@task @ti @tr e.id url import_media(est, e.id, url, Main.Media.all_variants))
            DOWNLOAD_MEDIA[] && @pnd import_media_pn(est, e.id, url, Main.Media.all_variants)
            DOWNLOAD_MEDIA[] && @pnd import_media_fast_pn(est, e.id, url)
        elseif any((startswith(ext, ext2) for ext2 in video_exts))
            # DOWNLOAD_MEDIA[] && Main.Media.media_queue(@task @ti @tr e.id url import_media(est, e.id, url, [(:original, true)]))
            DOWNLOAD_MEDIA[] && @pnd import_media_pn(est, e.id, url, [(:original, true)])
            DOWNLOAD_MEDIA[] && @pnd import_media_fast_pn(est, e.id, url)
        else
            # DOWNLOAD_PREVIEWS[] && Main.Media.media_queue(@task @ti @tr e.id url import_preview(est, e.id, url))
            DOWNLOAD_PREVIEWS[] && @pnd import_preview_pn(est, e.id, url)
        end
    end
end

function ext_text_note(est::CacheStorage, e::Nostr.Event)
    # if !isnothing(est.event_contents)
    #     exe(est.event_contents, @sql("insert into kv_fts (event_id, content) values (?1, ?2)"), 
    #         e.id, e.content)
    # end

    for_mentiones(est, e; pubkeys_in_content=true) do tag
        if tag.fields[1] == "p" 
            if !isnothing(local pk = try Nostr.PubKeyId(tag.fields[2]) catch _ end)
                # event_hook(est, e.id, (:notifications_cb, YOU_WERE_MENTIONED_IN_POST, pk))
            end
        elseif tag.fields[1] == "e" 
            if !isnothing(local eid = try Nostr.EventId(tag.fields[2]) catch _ end)
                event_hook(est, eid, (:notifications_cb, YOUR_POST_WAS_MENTIONED_IN_POST, e.id))
                try
                    if !ext_is_hidden(est, e.id)
                        event_hook(est, eid, (:event_stats_cb, :reposts, +1))
                        event_hook(est, eid, (:score_event_cb, e.pubkey, e.created_at, :repost, 7))
                        # event_pubkey_action(est, eid, e, :reposted)
                        # exe(est.event_pubkey_action_refs, @sql("insert into event_pubkey_action_refs values (?1, ?2, ?3, ?4, ?5)"), 
                        #     eid, e.id, e.pubkey, e.created_at, 50_000_001)
                    end
                catch ex
                    PRINT_EXCEPTIONS[] && Utils.print_exceptions()
                end
            end
        end
    end

    # if ext_is_human(est, e.pubkey; threshold=TrustRank.external_resources_threshold[])
        import_note_urls(est, e)
    # end

    if ext_is_human(est, e.pubkey)
        for_hashtags(est, e) do hashtag
            hashtag = lowercase(hashtag)
            exe(est.event_hashtags, @sql("insert into event_hashtags values (?1, ?2, ?3)"),
                e.id, hashtag, e.created_at)
            if isempty(exec(est.hashtags, @sql("select 1 from hashtags where hashtag = ?1 limit 1"), (hashtag,)))
                exec(est.hashtags, @sql("insert into hashtags values (?1, ?2)"), (hashtag, 0))
            end
            d_score = +1
            exec(est.hashtags, @sql("update hashtags set score = score + ?2 where hashtag = ?1"), (hashtag, d_score))
            schedule_hook(est, trunc(Int, time()+4*3600), (:expire_hashtag_score_cb, hashtag, d_score))
        end
    end
end

function ext_long_form_note(est::CacheStorage, e::Nostr.Event)
    funcname = "ext_long_form_note"

    # DB.ext_is_human(est, e.pubkey; threshold=0.0) || return

    import_note_urls(est, e)

    for t in e.tags
        if length(t.fields) >= 2 && t.fields[1] == "image"
            url = t.fields[2]
            # DOWNLOAD_MEDIA[] && Main.Media.media_queue(@task @ti @tr e.id url import_media(est, e.id, url, Main.Media.all_variants))
            DOWNLOAD_MEDIA[] && @pnd import_media_pn(est, e.id, url, Main.Media.all_variants)
        end
    end
end

function ext_reply(est::CacheStorage, e::Nostr.Event, parent_eid)
    event_hook(est, parent_eid, (:score_event_cb, e.pubkey, e.created_at, :reply, 10))

    # event_hook(est, parent_eid, (:notifications_cb, YOUR_POST_WAS_REPLIED_TO, e.id))
    event_hook(est, parent_eid, (:notifications_cb, POST_YOU_WERE_MENTIONED_IN_WAS_REPLIED_TO, e.id, e.id))
    event_hook(est, parent_eid, (:notifications_cb, POST_YOUR_POST_WAS_MENTIONED_IN_WAS_REPLIED_TO, "make_event_hooks", e.id, e.id))
end

function ext_repost(est::CacheStorage, e::Nostr.Event, eid)
    event_hook(est, eid, (:score_event_cb, e.pubkey, e.created_at, :repost, 7))
    event_hook(est, eid, (:notifications_cb, YOUR_POST_WAS_REPOSTED, e.id))
    event_hook(est, eid, (:notifications_cb, POST_YOU_WERE_MENTIONED_IN_WAS_REPOSTED, e.id))
    event_hook(est, eid, (:notifications_cb, POST_YOUR_POST_WAS_MENTIONED_IN_WAS_REPOSTED, "make_event_hooks", e.id))
end

ext_zap_lock = ReentrantLock()
function ext_zap(est::CacheStorage, e::Nostr.Event, parent_eid, amount_sats)
    sender = zap_sender(e)
    event_hook(est, parent_eid, (:score_event_cb, sender, e.created_at, :zap, 5))
    if ext_is_human(est, sender)
        msg = ""
        for t in e.tags
            if length(t.fields) >= 2 && t.fields[1] == "description"
                try msg = JSON.parse(t.fields[2])["content"] catch _ end
            end
        end
        event_hook(est, parent_eid, (:event_stats_cb, :satszapped, amount_sats))
        event_hook(est, parent_eid, (:notifications_cb, YOUR_POST_WAS_ZAPPED, e.id, amount_sats, msg))
        event_hook(est, parent_eid, (:notifications_cb, POST_YOU_WERE_MENTIONED_IN_WAS_ZAPPED, e.id, amount_sats))
        event_hook(est, parent_eid, (:notifications_cb, POST_YOUR_POST_WAS_MENTIONED_IN_WAS_ZAPPED, "make_event_hooks", e.id, amount_sats))
        import_zap_receipt(est, e, parent_eid, amount_sats)
    end
end

function import_zap_receipt(est::CacheStorage, e::Nostr.Event, parent_eid, amount_sats)
    sender = zap_sender(e)
    receiver = zap_receiver(e)
    exe(est.zap_receipts, @sql("insert into og_zap_receipts (zap_receipt_id, created_at, sender, receiver, amount_sats, event_id) values (?1, ?2, ?3, ?4, ?5, ?6)"),
        e.id, e.created_at, sender, receiver, amount_sats, parent_eid)
end

function ext_pubkey_zap(est::CacheStorage, e::Nostr.Event, zapped_pk, amount_sats)
    if ext_is_human(est, zap_sender(e))
        exe(est.pubkey_zapped, @sql("update pubkey_zapped set zaps = zaps + 1, satszapped = satszapped + ?2 where pubkey = ?1"), zapped_pk, amount_sats)
    end
    # if get(TrustRank.pubkey_rank, e.pubkey, 0.0) > 0.0
    #     add_human_override(zapped_pk, true, "received_zap_from_human")
    # end
end

function ext_is_hidden(est::CacheStorage, eid::Nostr.EventId)
    eid in Filterlist.access_event_blocked_spam
end
function ext_is_hidden(est::CacheStorage, pubkey::Nostr.PubKeyId)
    pubkey in Filterlist.access_pubkey_blocked_spam
end

function ext_is_human(est::CacheStorage, pubkey::Nostr.PubKeyId; threshold=TrustRank.humaness_threshold[])
    if pubkey in est.dyn[:human_override]
        return est.dyn[:human_override][pubkey]
    end
    !isempty(Postgres.execute(:p0, "select 1 from pubkey_trustrank where pubkey = \$1 and rank > \$2 limit 1", [pubkey, threshold])[2])
end

function is_trusted_user(est::DB.CacheStorage, pubkey::Nostr.PubKeyId)
    ext_is_human(est, pubkey; threshold=0.0)
end

# TODO refactor event scoring to use scheduled_hooks to expire scores
function score_event_cb(est::CacheStorage, e::Nostr.Event, initiator, scored_at, action, increment)
    initiator = Nostr.PubKeyId(initiator)
    action = Symbol(action)

    # if 1==1 && ext_is_human(est, initiator)
    #     increment2 = increment
    #     if action == :reply
    #         increment2 = 
    #         if     length(e.content) <= 20;  1
    #         elseif length(e.content) <= 100; 5
    #         else;  10
    #         end
    #     end
    #     Postgres.execute(:p0, "
    #                      insert into event_stats_2 values (\$1, \$2)
    #                      on conflict (event_id) do update set score2 = event_stats_2.score2 + \$2
    #                      ", [e.id, increment2])
    # end

    if action == :reply
        increment = 
        if     length(e.content) <= 20;  1
        elseif length(e.content) <= 100; 5
        else;  10
        end
    end

    increment_ = increment
    increment = ext_is_human(est, initiator) ? trunc(Int, 1e10*increment/91) : 0

    ref_kind = 
    if     action == :like; Int(Nostr.REACTION)
    elseif action == :reply; Int(Nostr.TEXT_NOTE)
    elseif action == :repost; Int(Nostr.REPOST)
    elseif action == :zap; Int(Nostr.ZAP_RECEIPT)
    else; error("unsupported action $(action)")
    end
    if exe(est.event_pubkey_action_refs, @sql("select count(1) from event_pubkey_action_refs where event_id = ?1 and ref_pubkey = ?2 and ref_kind = ?3"),
           e.id, initiator, ref_kind)[1][1] > 1
        # @show (:uniquepkcheck_failed, e.id, initiator, ref_kind, action)
        increment = 0
    else
        # @show (:uniquepkcheck_ok, e.id, initiator, ref_kind, action)
    end

    # push!(Main.stuff, (:score_event_cb, (; eid=e.id, initiator, scored_at, action, increment_, increment)))
    # insert_stuff(est, (:score_event_cb, (; eid=e.id, initiator, scored_at, action, increment_, increment)))

    increment > 0 || return

    exe(est.event_stats          , @sql("update event_stats           set score = score + ?2 where event_id = ?1"), e.id, increment)
    # exe(est.event_stats_by_pubkey, @sql("update event_stats_by_pubkey set score = score + ?2 where event_id = ?1"), e.id, increment)

    expire_at = scored_at+24*3600
    if expire_at > time()
        exe(est.event_stats          , @sql("update event_stats           set score24h = score24h + ?2 where event_id = ?1"), e.id, increment)
        # exe(est.event_stats_by_pubkey, @sql("update event_stats_by_pubkey set score24h = score24h + ?2 where event_id = ?1"), e.id, increment)
        exe(est.score_expiry         , @sql("insert into score_expiry (event_id, author_pubkey, change, expire_at) values (?1, ?2, ?3, ?4)"),
            e.id, e.pubkey, increment, expire_at)
    end
end

function notif2namedtuple(notif::Tuple)
    notif_type = notif[3]
    nt = (; pubkey=notif[1], created_at=notif[2], type=notif[3],
     [name => v isa ty ? v : ty(v)
      for (v, (name, ty)) in zip(notif[4:end], notification_args[notif_type])
      if !(v isa Missing || v isa Nothing)]...)
    nt = (; sort(collect(pairs(nt)); by=first)...)
    nt = (; id = bytes2hex(SHA.sha256(JSON.json(nt))), nt...)
    nt
end

PUSH_NOTIFICATIONS_ENABLED = Ref(false)

notification_periodic = Utils.Throttle(; period=5.0)

function notification(
        est::CacheStorage,
        pubkey::Nostr.PubKeyId, notif_created_at::Int, notif_type::NotificationType,
        args...
    )
    pubkey in est.app_settings || return

    callargs = (; pubkey, notif_created_at, notif_type, args)
    # @show callargs

    for a in args
        a isa Nostr.PubKeyId && a == pubkey && return
        if a isa Nostr.EventId && (ext_is_hidden(est, a) ||
                                   try Base.invokelatest(Main.App.is_hidden, est, pubkey, :content, est.events[a].pubkey) catch _ false end)
           # push!(Main.stuff, (:hidden, a, callargs))
           return
       end
    end

    notif_type == USER_UNFOLLOWED_YOU && return
    # if notif_type == USER_UNFOLLOWED_YOU
    #     local follower = args[1]
    #     if !isempty(exe(est.pubkey_followers, @sql("select 1 from pubkey_followers where pubkey = ? and follower_pubkey = ? limit 1"),
    #                     pubkey, follower))
    #         return
    #     end
    # end

    block = Ref(false)

    catch_exception(est, :block_notifications_for_hellthreads, callargs) do
        if notif_type in [YOU_WERE_MENTIONED_IN_POST, 
                          POST_YOU_WERE_MENTIONED_IN_WAS_ZAPPED, 
                          POST_YOU_WERE_MENTIONED_IN_WAS_LIKED, 
                          POST_YOU_WERE_MENTIONED_IN_WAS_REPOSTED, 
                          POST_YOU_WERE_MENTIONED_IN_WAS_REPLIED_TO,
                         ]
            eid = args[1]
            if eid in est.events
                mentions = 0
                for_mentiones(est, est.events[eid]; pubkeys_in_content=true) do tag
                    if tag.fields[1] == "p" 
                        mentions += 1
                    end
                end
                if mentions > 10
                    for (blockit,) in Postgres.execute(:membership, "
                                          select coalesce(((value::jsonb->>'content')::jsonb->'notificationsAdditional'->'ignore_events_with_too_many_mentions')::bool, true)
                                          from app_settings where key = \$1 limit 1", [pubkey])[2]
                        block[] = blockit
                    end
                end
            end
        end
    end
    block[] && return

    block[] |= catch_exception(est, :notification_blocked_by_mutelist, callargs) do
        notification_blocked_by_mutelist(est, pubkey, args)
    end
    block[] && return

    catch_exception(est, :notification_additional_settings, callargs) do
        if notif_type == NEW_DIRECT_MESSAGE
            pk = args[2] # sender
            if !isempty(Postgres.execute(:membership, "select 1 from app_settings where key = \$1 and coalesce(((value::jsonb->>'content')::jsonb->'notificationsAdditional'->'only_show_dm_notifications_from_users_i_follow')::bool, true) limit 1", [pubkey])[2])
                if isempty(Postgres.execute(:p0, "select 1 from pubkey_followers pf where pf.follower_pubkey = \$1 and pf.pubkey = \$2 limit 1", [pubkey, pk])[2])
                    block[] = true
                end
            end
        elseif notif_type == REPLY_TO_REPLY
            pk = args[2] # who_replied_to_it
            enabled = !isempty(Postgres.execute(:membership, "select 1 from app_settings where key = \$1 and coalesce(((value::jsonb->>'content')::jsonb->'notificationsAdditional'->'include_deep_replies')::bool, true) limit 1", [pubkey])[2])
            if !enabled
                block[] = true
            end
        else
            pk =
            if     notif_type in [NEW_USER_FOLLOWED_YOU, USER_UNFOLLOWED_YOU]
                args[1] # follower
            elseif notif_type in [YOUR_POST_WAS_ZAPPED,
                                  YOUR_POST_WAS_LIKED,
                                  YOUR_POST_WAS_REPOSTED]
                args[2] # who_liked_it
            elseif notif_type == YOUR_POST_WAS_REPLIED_TO
                args[2] # who_replied_to_it
            elseif notif_type == YOU_WERE_MENTIONED_IN_POST
                args[2] # who_mentioned_it
            elseif notif_type == YOUR_POST_WAS_MENTIONED_IN_POST
                args[3] # who_mentioned_it
            elseif notif_type == YOUR_POST_WAS_HIGHLIGHTED
                args[2] # who_highlighted_it
            elseif notif_type == YOUR_POST_WAS_BOOKMARKED
                args[2] # who_bookmarked_it
            else
                nothing
            end
            # @show (notif_type, pk)
            if !isnothing(pk)
                if notification_blocked_sender_not_follower(pubkey, pk)
                    block[] = true
                end
            end
        end
    end
    block[] && return

    @assert length(args) <= 4
    @assert length(notification_args[notif_type]) == length(args)

    args = (args..., [nothing for _ in 1:4-length(args)]...)

    notif = (pubkey, notif_created_at, notif_type, args...)
    notif_d = notif2namedtuple(notif)

    if PUSH_NOTIFICATIONS_ENABLED[]
        try
            Base.invokelatest(Main.eval(:(PushNotifications.notification)), est, notif_d)
        catch ex
            @show callargs
            PRINT_EXCEPTIONS[] && Utils.print_exceptions()
        end
    end

    catch_exception(est, :notification_settings, callargs) do
        if !isempty(local r = exe(est.notification_settings, 
                                  @sql("select enabled from notification_settings where pubkey = ?1 and type = ?2 limit 1"),
                                  pubkey, string(notif_type)))
            if !r[1][1]; block[] = true; end
        end
    end
    block[] && return

    exe(est.pubkey_notifications, @sql("insert into pubkey_notifications values (?1, ?2, ?3, ?4, ?5, ?6, ?7)"),
        pubkey, notif[2:5]..., [JSON.json(x) for x in notif[6:7]]...)

    lock(est.notification_processors) do notification_processors
        for func in values(notification_processors)
            catch_exception(est, func, notif_d) do
                Base.invokelatest(func, est, notif_d)
            end
        end
    end

    notification_periodic() do
        Main.PushGatewayExporter.set!("notification_latest", Utils.current_time())
    end
end

function notification_blocked_sender_not_follower(pubkey::Nostr.PubKeyId, initiator::Union{Nostr.PubKeyId, Nothing})
    if !isempty(Postgres.execute(:membership, "select 1 from app_settings where key = \$1 and coalesce(((value::jsonb->>'content')::jsonb->'notificationsAdditional'->'only_show_reactions_from_users_i_follow')::bool, false) limit 1", [pubkey])[2])
        if isnothing(initiator) || isempty(Postgres.execute(:p0, "select 1 from pubkey_followers pf where pf.follower_pubkey = \$1 and pf.pubkey = \$2 limit 1", [pubkey, initiator])[2])
            return true
        end
    end
    false
end

function notification_blocked_by_mutelist(est::CacheStorage, pubkey::Nostr.PubKeyId, notif_args)
    if pubkey in est.mute_list
        for t in est.events[est.mute_list[pubkey]].tags
            if length(t.fields) >= 2
                if     t.fields[1] == "e" && !isnothing(local eid = try Nostr.EventId(t.fields[2]) catch _ end)
                    for eid0 in notif_args
                        if eid0 isa Nostr.EventId && eid0 in est.events 
                            for t0 in est.events[eid0].tags
                                if length(t0.fields) >= 2 && t0.fields[1] == "e" && !isnothing(local eid1 = try Nostr.EventId(t0.fields[2]) catch _ end)
                                    eid1 == eid && @goto blocked
                                end
                            end
                        end
                    end
                elseif t.fields[1] == "p" && !isnothing(local pk = try Nostr.PubKeyId(t.fields[2]) catch _ end)
                    for a in notif_args
                        a isa Nostr.PubKeyId && a == pk && @goto blocked
                    end
                elseif t.fields[1] == "t"
                    ht = t.fields[2]
                    eid = notif_args[1]
                    b = Ref(false)
                    eid isa Nostr.EventId && eid in est.events && for_hashtags(est, est.events[eid]) do hashtag
                        hashtag == ht && (b[] = true)
                    end
                    b[] && @goto blocked
                elseif t.fields[1] == "word"
                    w = t.fields[2]
                    eid = notif_args[1]
                    eid isa Nostr.EventId && eid in est.events && occursin(w, est.events[eid].content) && @goto blocked
                end
            end
        end
    end
    return false
    @label blocked
    true
end

function notifications_cb(est::CacheStorage, e::Nostr.Event, notif_type, args...)
    notif_type isa Int && (notif_type = NotificationType(notif_type))

    conv(f, v) = v isa String ? f(v) : v

    if     notif_type in [YOUR_POST_WAS_ZAPPED,
                          YOUR_POST_WAS_LIKED,
                          YOUR_POST_WAS_REPOSTED]
        e0 = est.events[conv(Nostr.EventId, args[1])]
        e0_pubkey = notif_type == YOUR_POST_WAS_ZAPPED ? zap_sender(e0) : e0.pubkey
        notification(est, e.pubkey, e0.created_at, notif_type,
                     #= your_post =# e.id, #= who =# e0_pubkey, args[2:end]...)

    elseif notif_type == YOUR_POST_WAS_REPLIED_TO
        e0 = est.events[conv(Nostr.EventId, args[1])]
        notification(est, e.pubkey, e0.created_at, notif_type,
                     #= your_post =# e.id, #= who =# e0.pubkey, #= reply =# e0.id, args[2:end]...)

    elseif notif_type == YOU_WERE_MENTIONED_IN_POST
        you = conv(Nostr.PubKeyId, args[1])
        notification(est, you, e.created_at, notif_type,
                     #= their_post =# e.id, #= mentioned_by =# e.pubkey)

    elseif notif_type == YOUR_POST_WAS_MENTIONED_IN_POST
        e0 = est.events[conv(Nostr.EventId, args[1])]
        notification(est, e.pubkey, e0.created_at, notif_type,
                     #= your_post =# e.id, #= their_post =# e0.id, #= mentioned_by =# e0.pubkey)

    # elseif notif_type in [POST_YOU_WERE_MENTIONED_IN_WAS_ZAPPED,
    #                       POST_YOU_WERE_MENTIONED_IN_WAS_LIKED,
    #                       POST_YOU_WERE_MENTIONED_IN_WAS_REPOSTED,
    #                       POST_YOU_WERE_MENTIONED_IN_WAS_REPLIED_TO,
    #                      ]
    #     e0 = est.events[conv(Nostr.EventId, args[1])]
    #     e0_pubkey = notif_type == POST_YOU_WERE_MENTIONED_IN_WAS_ZAPPED ? zap_sender(e0) : e0.pubkey
    #     for_mentiones(est, e; pubkeys_in_content=false) do tag
    #         if tag.fields[1] == "p" 
    #             if !isnothing(local pk = try Nostr.PubKeyId(tag.fields[2]) catch _ end)
    #                 notification(est, pk, e0.created_at, notif_type,
    #                              e.id, e0_pubkey, args[2:end]...)
    #             end
    #         end
    #     end

    # elseif notif_type in [POST_YOUR_POST_WAS_MENTIONED_IN_WAS_ZAPPED,
    #                       POST_YOUR_POST_WAS_MENTIONED_IN_WAS_LIKED,
    #                       POST_YOUR_POST_WAS_MENTIONED_IN_WAS_REPOSTED,
    #                       POST_YOUR_POST_WAS_MENTIONED_IN_WAS_REPLIED_TO,
    #                      ]
    #     if args[1] == "make_event_hooks"
    #         e0 = est.events[conv(Nostr.EventId, args[2])]
    #         for_mentiones(est, e) do tag
    #             if tag.fields[1] == "e" 
    #                 if !isnothing(local eid = try Nostr.EventId(tag.fields[2]) catch _ end)
    #                     event_hook(est, eid, (:notifications_cb, notif_type, "make_notification", e0.id, e.id, args[3:end]...))
    #                 end
    #             end
    #         end
    #     elseif args[1] == "make_notification"
    #         e0 = est.events[conv(Nostr.EventId, args[2])]
    #         e1 = est.events[conv(Nostr.EventId, args[3])]
    #         e0_pubkey = notif_type == POST_YOUR_POST_WAS_MENTIONED_IN_WAS_ZAPPED ? zap_sender(e0) : e0.pubkey
    #         notification(est, e.pubkey, e0.created_at, notif_type,
    #                      e1.id, #= your_post =# e.id, #= who =# e0_pubkey, args[4:end]...)
    #     end

    elseif notif_type == YOUR_POST_WAS_HIGHLIGHTED
        e0 = est.events[conv(Nostr.EventId, args[1])]
        notification(est, e.pubkey, e0.created_at, notif_type,
                     #= your post =# e.id, #= who =# e0.pubkey, #= highlight =# e0.id, args[2:end]...)

    elseif notif_type == YOUR_POST_WAS_BOOKMARKED
        e0 = est.events[conv(Nostr.EventId, args[1])]
        notification(est, e.pubkey, e0.created_at, notif_type,
                     #= your post =# e.id, #= who =# e0.pubkey, args[2:end]...)

    # elseif notif_type == YOUR_POST_HAD_REACTION
    #     e0 = est.events[conv(Nostr.EventId, args[1])]
    #     notification(est, e.pubkey, e0.created_at, notif_type,
    #                  #= your post =# e.id, #= who =# e0.pubkey, args[2:end]...)
        
    elseif notif_type == NEW_DIRECT_MESSAGE
        receiver = nothing
        for t in e.tags
            if length(t.fields) >= 2 && t.fields[1] == "p"
                try receiver = Nostr.PubKeyId(t.fields[2]) catch _ end
                break
            end
        end
        if !isnothing(receiver)
            notification(est, receiver, e.created_at, notif_type,
                         #= direct message =# e.id, #= sender =# e.pubkey)
        end
    end
end

update_user_search_exceptions = CircularBuffer(100) |> ThreadSafe
function update_user_search(est::CacheStorage, pubkey::Nostr.PubKeyId)
    if !ext_is_human(est, pubkey) #&& get(est.pubkey_followers_cnt, pubkey, 0) < 1
        return false
    end
    exec(est.dyn[:user_search], @sql("delete from user_search where pubkey = ?1"), (pubkey,))
    try
        mdid = est.meta_data[pubkey]
        content = est.events[mdid].content
        local c = JSON.parse(content)
        !isnothing(c) || return false
        c isa Dict || return false
        exec(est.dyn[:user_search], @sql("insert into user_search values (
                                         ?1, 
                                         ?2,
                                         to_tsvector('simple', ?3), 
                                         to_tsvector('simple', ?4), 
                                         to_tsvector('simple', ?5), 
                                         to_tsvector('simple', ?6), 
                                         to_tsvector('simple', ?7),
                                         to_tsvector('simple', ?8) 
                                         )"), 
             (pubkey, mdid, [get(c, a, nothing) for a in ["name", "username", "display_name", "displayName", "nip05", "lud16"]]...))
    catch ex push!(update_user_search_exceptions, (; t=time(), ex, pubkey)) end
    true
end

function expire_scores(est::CacheStorage) # should be called periodically
    tnow = trunc(Int, time())
    cnt = 0
    #@threads
    for dbconn in est.score_expiry.dbconns
        for (eid, pkid, change) in exe(dbconn, @sql("select event_id, author_pubkey, change from score_expiry where expire_at <= ?1"), (tnow,))
            eid = Nostr.EventId(eid)
            pkid = Nostr.PubKeyId(pkid)
            exe(est.event_stats          , @sql("update event_stats           set score24h = score24h - ?2 where event_id = ?1"), eid, change)
            # exe(est.event_stats_by_pubkey, @sql("update event_stats_by_pubkey set score24h = score24h - ?3 where author_pubkey = ?1 and event_id = ?2"), pkid, eid, change)
            cnt += 1
        end
        exe(dbconn, @sql("delete from score_expiry where expire_at <= ?1"), (tnow,))
    end
    cnt
end

# function reconnect_pq_tables(est::CacheStorage)
#     for d in [est.app_settings]
#         close(d)
#         empty!(d.dbconns)
#         push!(d.dbconns, LibPQConn([LibPQ.Connection(est.pqconnstr)
#                                     for _ in 1:Threads.nthreads()]) |> ThreadSafe)
#     end
# end

# function register_relay(est::CacheStorage, relay_url::String) # TDB use est.contact_lists for mining relays
#     exe(est.relays, @sql("insert into relays (url, times_referenced) values (?1, 0) on conflict do nothing"), relay_url)
#     exe(est.relays, @sql("update relays set times_referenced = times_referenced + 1 where url = ?1"), relay_url)
# end

function expire_hashtag_score_cb(est::CacheStorage, hashtag, d_score)
    exec(est.hashtags, @sql("update hashtags set score = score - ?2 where hashtag = ?1"), (hashtag, d_score))
end

re_hashtag = r"(^|[^0-9a-zA-Z_\-])\#([0-9a-zA-Z_\-]+)"

function for_hashtags(body::Function, est::CacheStorage, e::Nostr.Event)
    e.kind == Int(Nostr.TEXT_NOTE) || return
    for m in eachmatch(re_hashtag, e.content)
        body(String(m.captures[2]))
    end
end

# re_url = r"https?:\/\/(www\.)?[-a-zA-Z0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b([-a-zA-Z0-9()@:%_\+.~#?&//=]*)"
# re_url = r"https?:\/\/(www\.)?[-\pL0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b([-\pL0-9()@:%_\+.~#?&//=]*)"
re_url = r"https?:\/\/(www\.)?[-\pL0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9]{1,6}\b([-\pL0-9@:%_\+.~#?&//=]*)"

function for_urls(body::Function, est::CacheStorage, e::Nostr.Event)
    # e.kind in [Int(Nostr.TEXT_NOTE), Int(Nostr.LONG_FORM_CONTENT)] || return
    for m in eachmatch(re_url, e.content)
        body(String(m.match))
    end
    if e.kind == Nostr.PICTURE
        for t in e.tags
            if length(t.fields) >= 1 && t.fields[1] == "imeta"
                for it in t.fields[2:end]
                    ps = map(string, split(it))
                    if length(ps) >= 2 && ps[1] == "url"
                        body(ps[2])
                    end
                end
            end
        end
    end
end

function ext_media_import(est::CacheStorage, eid::Union{Nothing,Nostr.EventId}, url::Union{Nothing,String}, path::String, data::Vector{UInt8}) end

function add_human_override(est::CacheStorage, pubkey::Nostr.PubKeyId, is_human::Bool, source::String)
    try
        DB.exec(est.dyn[:human_override], "insert into human_override values (?1, ?2, now(), ?3) on conflict (pubkey) do update set is_human = ?2, source = ?3",
                      (pubkey, is_human, source))
    catch ex println("add_human_override: ", typeof(ex)) end
end

function import_filterlists(est::CacheStorage)
    Postgres.transaction(:membership) do sess
        ns = names(Filterlist; all=true)
        for ty in [:pubkey, :event]
            for (b, grp) in [
                      (:blocked, :spam),
                      (:unblocked, :spam),
                      (:blocked, :nsfw ),
                      (:unblocked, :nsfw),
                     ]
                n = Symbol("access_$(ty)_$(b)_$(grp)")
                if n in ns
                    println(n)
                    for v in collect(getproperty(Filterlist, n))
                        Postgres.execute(sess, "insert into filterlist values (\$1, \$2::filterlist_target, \$3, \$4::filterlist_grp, \$5) on conflict do nothing", 
                                         [v, ty, b == :blocked, grp, Utils.current_time()])
                    end
                end
            end
        end
    end
end

function get_trusted_followers_count(est::CacheStorage, pubkey::Nostr.PubKeyId)
    Postgres.execute(est.dbargs.connsel, 
                     "select count(1) from pubkey_followers pf, pubkey_trustrank tr 
                     where pf.pubkey = \$1 and pf.follower_pubkey = tr.pubkey and tr.rank > 0",
                     [pubkey])[2][1][1]
end

