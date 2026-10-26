-- tests/osm2pgsql.sh's flex style: points, lines and areas, each with its
-- kind and name. Points get their name upper-cased by naming.lua, a module
-- `require`d from the working directory; areas are in UTM zone 32N, through
-- PROJ.
local naming = require('naming')

local points = osm2pgsql.define_node_table('zs_points', {
    { column = 'kind', type = 'text' },
    { column = 'name', type = 'text' },
    { column = 'shout', type = 'text' },
    { column = 'geom', type = 'point', not_null = true },
})

local lines = osm2pgsql.define_way_table('zs_lines', {
    { column = 'kind', type = 'text' },
    { column = 'name', type = 'text' },
    { column = 'geom', type = 'linestring', not_null = true },
})

local areas = osm2pgsql.define_area_table('zs_areas', {
    { column = 'kind', type = 'text' },
    { column = 'name', type = 'text' },
    { column = 'geom', type = 'geometry', projection = 32632, not_null = true },
})

function osm2pgsql.process_node(object)
    local kind = object.tags.amenity or object.tags.tourism
    if kind then
        points:insert({
            kind = kind,
            name = object.tags.name,
            shout = naming.shout(object.tags.name),
            geom = object:as_point(),
        })
    end
end

function osm2pgsql.process_way(object)
    if object.tags.highway then
        lines:insert({ kind = object.tags.highway, name = object.tags.name, geom = object:as_linestring() })
    elseif object.is_closed and object.tags.building then
        areas:insert({ kind = 'building', name = object.tags.name, geom = object:as_polygon() })
    end
end

function osm2pgsql.process_relation(object)
    if object.tags.type == 'multipolygon' and object.tags.leisure then
        areas:insert({ kind = object.tags.leisure, name = object.tags.name, geom = object:as_multipolygon() })
    end
end
