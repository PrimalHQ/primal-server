#module Media

S3_TOOL_PATH = Ref("")
S3_CALL_IMPLEMENTATION = Ref(:s3_py)

function s3_call(provider::Symbol, req, data=UInt8[]; proxy=MEDIA_PROXY[], implementation=S3_CALL_IMPLEMENTATION[])
    # push!(Main.stuff, (:s3_call, (provider, req, data), (; proxy)))
    iob = IOBuffer()
    println(iob, JSON.json(req))
    write(iob, data)
    seek(iob, 0)
    timeout = trunc(Int, length(data)/(512*1024)) + 10
    try
        if     implementation == :s3_py
            JSON.parse(read(pipeline(`nice timeout $timeout $(Conda.ROOTENV)/bin/python primal-server/s3.py`, stdin=iob), String))
        elseif implementation == :s3_tool
            JSON.parse(read(pipeline(`nice timeout $timeout $S3_TOOL_PATH`, stdin=iob), String))
        end
    catch _
        println("s3_call failed: ", JSON.json(req))
        rethrow()
    end
end

function s3_upload(provider::Symbol, object::String, data::Vector{UInt8}, content_type::String; proxy=MEDIA_PROXY[])
    req = (; operation="upload", object, content_type, Main.S3_CONFIGS[provider]...)
    r = s3_call(provider, req, data; proxy)
    @assert r["status"]
    nothing
end

function s3_check(provider::Symbol, object::String; proxy=MEDIA_PROXY[])
    req = (; operation="check", object, Main.S3_CONFIGS[provider]...)
    r = s3_call(provider, req; proxy)
    r["exists"]
end

function s3_get(provider::Symbol, object::String; proxy=MEDIA_PROXY[], implementation=S3_CALL_IMPLEMENTATION[])::Vector{UInt8}
    req = (; operation="get", object, Main.S3_CONFIGS[provider]...)
    iob = IOBuffer()
    println(iob, JSON.json(req))
    seek(iob, 0)
    timeout = 120
    try
        if     implementation == :s3_py
            read(pipeline(`nice timeout 10 $(Conda.ROOTENV)/bin/python primal-server/s3.py`, stdin=iob))
        elseif implementation == :s3_tool
            read(pipeline(`nice timeout $timeout $S3_TOOL_PATH`, stdin=iob))
        end
    catch _
        println("s3_get failed: ", JSON.json(req))
        rethrow()
    end
end

function s3_delete(provider::Symbol, object::String; proxy=MEDIA_PROXY[])
    req = (; operation="delete", object, Main.S3_CONFIGS[provider]...)
    r = s3_call(provider, req; proxy)
    @assert r["status"]
end

function s3_copy(
        provider::Symbol, 
        source_bucket::String, source_object::String, 
        destination_bucket::String, destination_object::String; 
        proxy=MEDIA_PROXY[])
    req = (; operation="copy", Main.S3_CONFIGS[provider]...,
           source_bucket, source_object, destination_bucket, destination_object)
    r = s3_call(provider, req; proxy)
    @assert r["status"]
    nothing
end

function s3_presign_url(provider::Symbol, object::String, bucket=Main.S3_CONFIGS[provider].bucket; proxy=MEDIA_PROXY[])
    req = (; operation="pre-sign-url", object, Main.S3_CONFIGS[provider]..., bucket)
    r = s3_call(provider, req; proxy)
    @assert r["status"]
    r["url"]
end

