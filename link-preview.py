import sys
import os
import json
import subprocess

import requests
from bs4 import BeautifulSoup

url, proxy = sys.argv[1:3]

if proxy == 'null':
    kwa = {}
else:
    kwa = dict(proxies=dict(http=proxy, https=proxy))

headers = {"User-Agent": "WhatsApp/2"}
html_doc = requests.get(url, headers=headers, **kwa).content
if os.environ.get("DEBUG", "") == "1": print(html_doc)

# html_doc = subprocess.run(['tidy'], input=html_doc, capture_output=True, check=False).stdout
# if os.environ.get("DEBUG", "") == "1": print(html_doc)

# with open("t", "wb+") as f: f.write(html_doc)
# html_doc = open("t", "rb").read()

parser = 'html.parser'
#parser = 'html5lib'
soup = BeautifulSoup(html_doc, parser)
if os.environ.get("DEBUG", "") == "1": print(soup)

mimetype = "text/html"
title = image = description = ""
for ee in soup.html.head.find_all('meta'):
    e = ee.attrs
    if "property" in e and "content" in e:
        prop = e["property"]
        if   prop == "og:title": title = e["content"]
        elif prop == "og:image": image = e["content"]
        elif prop == "og:description": description = e["content"]
        elif prop == "twitter:title": title = e["content"]
        elif prop == "twitter:description": description = e["content"]
        elif prop == "twitter:image:src": image = e["content"]

    elif "name" in e and "content" in e:
        if e["name"] == "description": description = e["content"]

icon_url = ""
# for ee in soup.html.head.find_all('link'):
#     e = ee.attrs
#     if "rel" in e and "href" in e
#         if e["rel"] in ["icon", "shortcut icon"]:
#             u = URIs.parse_uri(url)
#             try
#                 icon_url = string(URIs.parse_uri(e["href"]))
#             except:
#                 try
#                     icon_url = string(URIs.URI(; scheme=u.scheme, host=u.host, port=u.port, path=URIs.normpath(u.path*e["href"])))
#                 except:
#                     pass
#             break

print(json.dumps({"mimetype": mimetype,
                  "title": title,
                  "image": image,
                  "description": description,
                  "icon_url": icon_url,
                  }))
