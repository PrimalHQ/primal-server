#module Utils

export geoiplookup
geoiplookup(ip) = join(split(split(read(`geoiplookup $ip`, String), '\n')[1])[4:end], ' ')

