(* The longest URL the importer queues for media/preview import and the media jobs import. The media
   tables key on the URL (media, preview, event_media, event_preview: btree indexes, at most 2704
   bytes per entry, after compression), so a longer URL can be stored on one cluster and refused by
   a logical-replication subscriber that compresses differently: a 2.7 KB preview URL stopped the
   media subscriptions of every cache host on 2026-11-02. Nothing useful is that long. *)
let max_bytes = 2048

let too_long (url : string) : bool = String.length url > max_bytes
