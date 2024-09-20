module DVMFeedChecker

import JSON
import Dates

import ..Utils
import ..Nostr
import ..DB

PRINT_EXCEPTIONS = Ref(false)
LOG = Ref(false)

exceptions_lock = ReentrantLock()

RELAYS = [
          "wss://nostr.bitcoiner.social/",
          "wss://relay.nostr.bg/",
          "wss://nostr.oxtr.dev/",
          "wss://nostr.fmt.wiz.biz/",
          "wss://relay.damus.io/",
          "wss://nostr.mom/",
          "wss://nos.lol/",
          "ws://192.168.14.7:7777", 
         ]

const RUN_PERIOD = Ref(600)
const TIMEOUT = Ref(30)

const task = Ref{Any}(nothing)
const running = Ref(true)

function start()
    @assert isnothing(task[]) || istaskdone(task[])

    running[] = true

    task[] = 
    errormonitor(@async while running[]
                     try
                         Base.invokelatest(run_dvm_checks)
                     catch _
                         PRINT_EXCEPTIONS[] && Utils.print_exceptions()
                     end
                     Utils.active_sleep(RUN_PERIOD[], running)
                 end)

    nothing
end

function stop()
    @assert !isnothing(task[])
    running[] = false
    Utils.wait_for(()->istaskdone(task[]))
end

function run_dvm_checks()
    est = Main.cache_storage
    goodcnt = Ref(0)
    badcnt = Ref(0)
    asyncmap(Main.App.get_dvm_feeds_all(est); ntasks=8) do eid
        running[] || return
        eid in est.events || return
        e = est.events[eid]
        if e.kind == 31990
            # lock(exceptions_lock) do
            #     @show e.id
            #     display(JSON.parse(e.content)["nip90Params"])
            # end
            # return
            tdur = @elapsed r = try
                Main.App.dvm_feed(est; dvm_id="?", dvm_pubkey=e.pubkey, 
                                  user_pubkey=Main.App.DVM_REQUESTER_KEYPAIR[].pubkey,
                                  timeout=TIMEOUT[], usecache=false) |> JSON.json |> JSON.parse
            catch ex
                lock(exceptions_lock) do
                    # println("run_dvm_checks: ", typeof(ex))
                    PRINT_EXCEPTIONS[] && Utils.print_exceptions()
                end
                nothing
            end
            LOG[] && println("run_dvm_checks: $(Nostr.hex(e.pubkey)) $(isnothing(r) ? "X" : "+") $tdur s")
            if isnothing(r)
                badcnt[] += 1
                DB.exec(est.dyn[:dvm_feeds], 
                        "insert into dvm_feeds values (?1, ?2, ?3, ?4, ?5) on conflict (pubkey) do update set 
                        updated_at = ?2, results = ?3, kind = ?4, ok = ?5",
                        (e.pubkey, Dates.now(), JSON.json(nothing), "", false))
            else
                goodcnt[] += 1
                notes_cnt = length([1 for e in r if e["kind"] == Int(Nostr.LONG_FORM_CONTENT)])
                reads_cnt = length([1 for e in r if e["kind"] == Int(Nostr.TEXT_NOTE)])
                DB.exec(est.dyn[:dvm_feeds], 
                        "insert into dvm_feeds values (?1, ?2, ?3, ?4, ?5) on conflict (pubkey) do update set 
                        updated_at = ?2, results = ?3, kind = ?4, ok = ?5",
                        (e.pubkey, Dates.now(), JSON.json(r),
                         (notes_cnt > reads_cnt ? :reads : :notes), notes_cnt + reads_cnt > 0))
            end
        end
    end
    (; good=goodcnt[], bad=badcnt[])
end

end
