import HTTP
import URIs
import JSON
import Gumbo
import Cascadia

function fetch_meta_data(url, proxy)
    resp = HTTP.get(url; 
                    readtimeout=15, connect_timeout=15, 
                    headers=["User-Agent"=>"WhatsApp/2"], proxy)

    doc = try 
        d = copy(collect(resp.body))
        Gumbo.parsehtml(String(d))
    catch ex
        # @show string(ex)[1:200]
        # Utils.print_exceptions()
        error("error parsing html")
    end

    mimetype = string(get(Dict(resp.headers), "Content-Type", ""))
    title = image = description = ""
    for ee in eachmatch(Cascadia.Selector("html > head > meta"), doc.root)
        e = ee.attributes
        if haskey(e, "property") && haskey(e, "content")
            prop = e["property"]
            if     prop == "og:title"; title = e["content"]
            elseif prop == "og:image"; image = e["content"]
            elseif prop == "og:description"; description = e["content"]
            elseif prop == "twitter:title"; title = e["content"]
            elseif prop == "twitter:description"; description = e["content"]
            elseif prop == "twitter:image:src"; image = e["content"]
            end
        elseif haskey(e, "name") && haskey(e, "content")
            if e["name"] == "description"; description = e["content"]; end
        end
    end
    icon_url = ""
    for ee in eachmatch(Cascadia.Selector("html > head > link"), doc.root)
        e = ee.attributes
        # @show string(e)
        if haskey(e, "rel") && haskey(e, "href")
            (e["rel"] == "icon" || e["rel"] == "shortcut icon") || continue
            u = URIs.parse_uri(url)
            icon_url = try
                string(URIs.parse_uri(e["href"]))
            catch _
                try
                    string(URIs.URI(; scheme=u.scheme, host=u.host, port=u.port, path=URIs.normpath(u.path*e["href"])))
                catch _
                    ""
                end
            end
            break
        end
    end
    res = (; mimetype, title, image, description, icon_url)

    res
end
