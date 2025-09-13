#module Media

DEFAULT_AI_HOST   = Ref("192.168.52.1")
task_ai_host()    = get(task_local_storage(), :ai_host, DEFAULT_AI_HOST[])
task_ai_timeout() = get(task_local_storage(), :ai_timeout, 30)

function async_tls_pass(body::Function)
    ai_host    = task_ai_host()
    ai_timeout = task_ai_timeout()
    function f(g::Function)
        task_local_storage(:ai_host, ai_host) do
            task_local_storage(:ai_timeout, ai_timeout) do
                g()
            end
        end
    end
    body(f)
end

function image_query(
        imgdata::Vector{UInt8}, query::String; 
        num_predict=1024, 
        model="llama3.2-vision", 
        endpoint="http://$(task_ai_host()):11434/api/chat",
        timeout=task_ai_timeout())
    req = (;
           model,
           keep_alive="180m",
           options=(; num_predict),
           messages=[
                     (;
                      role="user",
                      content=query,
                      images=[Base64.base64encode(imgdata)]
                     ),
                    ])

    s = String(HTTP.request("POST", endpoint;
                            headers=["Content-Type"=>"application/json"],
                            body=JSON.json(req), retry=false,
                            readtimeout=timeout, connect_timeout=timeout).body)
    res = []
    for s1 in split(s, '\n')
        # println(s1)
        r = JSON.parse(s1)
        r["done"] && break
        m = r["message"]
        m["role"] != "assistant" && break
        push!(res, m["content"])
    end
    join(res)
end

function media_classify(type::Symbol, model::String, data::Vector{UInt8}; timeout=task_ai_timeout())
    port =
    if     type == :image && model == "Falconsai/nsfw_image_detection"; 5012
    elseif type == :video && model == "Falconsai/nsfw_image_detection"; 5012
    elseif type == :image && model == "nudenet"; 5015
    elseif type == :image && model == "marqo_nsfw"; 5017
    elseif type == :image && model == "nsfw_detector"; 5018
    elseif type == :image && model == "opennsfw2"; 5016
    elseif type == :video && model == "opennsfw2"; 5016
    else; error("unknown model $model")
    end
    endpoint = "http://$(task_ai_host()):$port/classify"
    req = (; model, [type=>Base64.base64encode(data)]...)
    s = String(HTTP.request("POST", endpoint;
                            headers=["Content-Type"=>"application/json"],
                            body=JSON.json(req), retry=false,
                            readtimeout=timeout, connect_timeout=timeout).body)
    r = JSON.parse(s)
    haskey(r, "error") && error(r["error"])
    @assert r["model"] == model
    r
end

function image_features(
        imgdata::Vector{UInt8}; 
        model="google/vit-base-patch16-384", 
        endpoint="http://$(task_ai_host()):5013/features", 
        timeout=task_ai_timeout(),
        pool=true)
    req = (; model, pool, image=Base64.base64encode(imgdata))
    s = String(HTTP.request("POST", endpoint;
                            headers=["Content-Type"=>"application/json"],
                            body=JSON.json(req), retry=false,
                            readtimeout=timeout, connect_timeout=timeout).body)
    r = JSON.parse(s)
    haskey(r, "error") && error(r["error"])
    @assert r["model"] == model
    r
end

function video_features(
        videodata::Vector{UInt8}; 
        model="google/vivit-b-16x2-kinetics400", 
        endpoint="http://$(task_ai_host()):5014/features",
        timeout=task_ai_timeout())
    req = (; model, video=Base64.base64encode(videodata))
    s = String(HTTP.request("POST", endpoint;
                            headers=["Content-Type"=>"application/json"],
                            body=JSON.json(req), retry=false,
                            readtimeout=timeout, connect_timeout=timeout).body)
    r = JSON.parse(s)
    haskey(r, "error") && error(r["error"])
    @assert r["model"] == model
    r
end

function text_features(
        text::String; 
        model="nomic-embed-text", 
        endpoint="http://$(task_ai_host()):11434/api/embeddings",
        timeout=task_ai_timeout())
    req = (;
           model,
           keep_alive="180m",
           prompt=text,
          )

    s = String(HTTP.request("POST", endpoint;
                            headers=["Content-Type"=>"application/json"],
                            body=JSON.json(req), retry=false,
                            readtimeout=timeout, connect_timeout=timeout).body)
    r = JSON.parse(s)
    Dict(["model"=>model, "output"=>r["embedding"]])
end

function text_query(
        query::String; 
        model="llama3.2:1b", 
        endpoint="http://$(task_ai_host()):11434/api/chat",
        num_predict=1024, 
        timeout=task_ai_timeout())
    req = (;
           model,
           keep_alive="180m",
           options=(; num_predict),
           stream=false,
           messages=[
                     (;
                      role="user",
                      content=query,
                     ),
                    ])
    s = String(HTTP.request("POST", endpoint;
                            headers=["Content-Type"=>"application/json"],
                            body=JSON.json(req), retry=false,
                            readtimeout=timeout, connect_timeout=timeout).body)
    r = JSON.parse(s)
    Dict(["model"=>model, "output"=>r])
end
