--!strict
--
-- REQUIRES
--
local serde  = require("@lune/serde")
local stdio  = require("@lune/stdio")
local fs     = require("@lune/fs")
local roblox = require("@lune/roblox")
--
-- CONSTANTS
--
local PLACE_FILE: string = stdio.prompt(
    "text",
    "Input the place file name to deserialize. It should be stored in the same directory as this script."
)

local SKIP_PROPERTY_TAGS = {
    Deprecated = true,
    Hidden     = true,
    ReadOnly   = true,
    WriteOnly  = true,
}

local output_folder       = `./scripts`
local included_classnames = {
    ["Script"]        = ".server.luau",
    ["ServerScript"]  = ".server.luau",
    ["LocalScript"]   = ".client.luau",
    ["ModuleScript"]  = ".luau",
}

-- Load the reflection database once so we can check default property values.
local db = roblox.getReflectionDatabase()

--
-- LOCAL FUNCTIONS
--

-- Replace all known XML character entities with their ASCII equivalents.
local function Replace_Xml_With_Ascii(str: string): string
    local patterns = {
        { "%<%!%[CDATA%[", " "},
        { "%]%]>"," "},
        { "&Space;", " " },
        { "&Tab;", "\t" },
        { "&NewLine;", "\n" },
        { "&excl;", "!" },
        { "&quot;", "\"" },
        { "&num;", "#" },
        { "&dollar;", "$" },
        { "&percnt;", "%" },
        { "&amp;", "&" },
        { "&apos;", "'" },
        { "&lpar;", "(" },
        { "&rpar;", ")" },
        { "&ast;", "*" },
        { "&plus;", "+" },
        { "&comma;", "," },
        { "&period;", "." },
        { "&sol;", "/" },
        { "&colon;", ":" },
        { "&semi;", ";" },
        { "&lt;", "<" },
        { "&gt;", ">" },
        { "&equals;", "=" },
        { "&quest;", "?" },
        { "&commat;", "@" },
        { "&lsqb;", "[" },
        { "&lbrack;", "[" },
        { "&rsqb;", "]" },
        { "&rbrack;", "]" },
        { "&Hat;", "^" },
        { "&lowbar;", "_" },
        { "&UnderBar;", "_" },
        { "&grave;", "`" },
        { "&lcub;", "{" },
        { "&lbrace;", "{" },
        { "&rcub;", "}" },
        { "&rbrace;", "}" },
        { "&nbsp;", " " },
        { "&NonBreakingSpace;", " " },
        { "&hyphen;", "-" },
        { "&dash;", "-" },
    }
    
    local result = str
    for _, pattern in ipairs(patterns) do
        local entity      = pattern[1]
        local replacement = pattern[2]
        result = string.gsub(result, entity, replacement)
    end
    return result
end

-- Builds a folder path from the root DataModel up to (but not including) the given instance.
local function Get_Path_From_Instance(instance: roblox.Instance, root: roblox.DataModel): string
    local path   = output_folder
    local stack  = {}
    local parent = instance.Parent
    while ((parent ~= root) and (parent ~= nil)) do
        table.insert(stack, parent.Name or parent.ClassName)
        parent = parent.Parent
    end
    for i = #stack, 1, -1 do
        path = `{path}/{stack[i]}`
    end
    return path
end

-- Extracts the Lua source code from the serialized XML of a script instance.
local function Extract_Module_From_XML(xml: string): string
    local prefix    = `<string name="Source">`
    local increment = string.len(prefix)
    local starting  = xml:find(prefix)
    if (starting == nil) then
        return ""
    end
    local substr = xml:sub(starting + increment)
    local ending = substr:find("</string>")
    if (ending == nil) then
        return ""
    end
    local output = substr:sub(1, ending - 1)
    output = Replace_Xml_With_Ascii(output)
    return output
end

--
-- Helper: extract the inner text of a simple XML tag, e.g. <X>value</X> => "value"
--
local function Get_Simple_Tag_Content(xml: string, tag: string): string?
    local pattern = "<" .. tag .. ">(.-)</" .. tag .. ">"
    local result = string.match(xml, pattern)
    return result
end

--
-- Helper: extract a numeric value from a simple tag.
--
local function Get_Number_From_Tag(xml: string, tag: string): number?
    local text = Get_Simple_Tag_Content(xml, tag)
    if (text ~= nil) then
        return tonumber(text)
    end
    return nil
end

--
-- Helper: convert a bitmask integer to a list of face names ("Right", "Top", etc.)
--
local function Faces_Integer_To_List(value: number): {string}
    local faces = {}
    local names = { "Right", "Top", "Back", "Left", "Bottom", "Front" }
    for i = 0, 5 do
        if ((math.floor(value / (2 ^ i)) % 2) == 1) then
            table.insert(faces, names[i + 1])
        end
    end
    return faces
end

--
-- Helper: convert a bitmask integer to a list of axis names ("X", "Y", "Z")
--
local function Axes_Integer_To_List(value: number): {string}
    local axes = {}
    -- Bit 0 (value & 1) -> "X"
    if ((value % 2) == 1) then
        table.insert(axes, "X")
    end
    -- Bit 1 (value & 2) -> "Y"
    if ((math.floor(value / 2) % 2) == 1) then
        table.insert(axes, "Y")
    end
    -- Bit 2 (value & 4) -> "Z"
    if ((math.floor(value / 4) % 2) == 1) then
        table.insert(axes, "Z")
    end
    return axes
end

--
-- Converts a single property element from serialized XML to a JSON‑compatible Lua value.
--
local function Convert_Xml_Value_To_Json(element_type: string, inner_xml: string): any
    --
    -- Basic types.
    --
    if     (element_type == "string") or (element_type == "Content") or (element_type == "ProtectedString") then
        return inner_xml
    elseif (element_type == "bool") then
        return (inner_xml == "true")
    elseif (element_type == "int") or (element_type == "Int32") or (element_type == "Int64") then
        return tonumber(inner_xml)
    elseif (element_type == "float") or (element_type == "double") or (element_type == "Float32") or (element_type == "Float64") then
        return tonumber(inner_xml)
    elseif (element_type == "token") then
        return inner_xml  -- enum items are already token strings
    elseif (element_type == "BinaryString") then
        return inner_xml  -- base64 string
    end

    --
    -- Vector types
    --
    if (element_type == "Vector3") then
        local x = Get_Number_From_Tag(inner_xml, "X")
        local y = Get_Number_From_Tag(inner_xml, "Y")
        local z = Get_Number_From_Tag(inner_xml, "Z")
        return { x, y, z }
    elseif (element_type == "Vector2") then
        local x = Get_Number_From_Tag(inner_xml, "X")
        local y = Get_Number_From_Tag(inner_xml, "Y")
        return { x, y }
    elseif (element_type == "Vector3int16") then
        local x = Get_Number_From_Tag(inner_xml, "X")
        local y = Get_Number_From_Tag(inner_xml, "Y")
        local z = Get_Number_From_Tag(inner_xml, "Z")
        return { x, y, z }
    elseif (element_type == "Vector2int16") then
        local x = Get_Number_From_Tag(inner_xml, "X")
        local y = Get_Number_From_Tag(inner_xml, "Y")
        return { x, y }
    end

    --
    -- Colour types
    --
    if (element_type == "Color3") then
        local r = Get_Number_From_Tag(inner_xml, "R")
        local g = Get_Number_From_Tag(inner_xml, "G")
        local b = Get_Number_From_Tag(inner_xml, "B")
        return { r, g, b }
    elseif (element_type == "Color3uint8") then
        local r = Get_Number_From_Tag(inner_xml, "R")
        local g = Get_Number_From_Tag(inner_xml, "G")
        local b = Get_Number_From_Tag(inner_xml, "B")
        return { r, g, b }
    elseif (element_type == "BrickColor") then
        return tonumber(inner_xml)
    end

    --
    -- Coordinate frame
    --
    if (element_type == "CFrame") or (element_type == "CoordinateFrame") then
        local x   = Get_Number_From_Tag(inner_xml, "X")
        local y   = Get_Number_From_Tag(inner_xml, "Y")
        local z   = Get_Number_From_Tag(inner_xml, "Z")
        local r00 = Get_Number_From_Tag(inner_xml, "R00")
        local r01 = Get_Number_From_Tag(inner_xml, "R01")
        local r02 = Get_Number_From_Tag(inner_xml, "R02")
        local r10 = Get_Number_From_Tag(inner_xml, "R10")
        local r11 = Get_Number_From_Tag(inner_xml, "R11")
        local r12 = Get_Number_From_Tag(inner_xml, "R12")
        local r20 = Get_Number_From_Tag(inner_xml, "R20")
        local r21 = Get_Number_From_Tag(inner_xml, "R21")
        local r22 = Get_Number_From_Tag(inner_xml, "R22")
        return { x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 }
    end

    --
    -- UDim / UDim2
    --
    if (element_type == "UDim2") then
        local xs = Get_Number_From_Tag(inner_xml, "XS")
        local xo = Get_Number_From_Tag(inner_xml, "XO")
        local ys = Get_Number_From_Tag(inner_xml, "YS")
        local yo = Get_Number_From_Tag(inner_xml, "YO")
        return { { xs, xo }, { ys, yo } }
    elseif (element_type == "UDim") then
        local s = Get_Number_From_Tag(inner_xml, "S")
        local o = Get_Number_From_Tag(inner_xml, "O")
        return { s, o }
    end

    --
    -- Font
    --
    if (element_type == "Font") then
        local family_xml = Get_Simple_Tag_Content(inner_xml, "Family") or ""
        local family     = Get_Simple_Tag_Content(family_xml, "url") or family_xml
        local weight     = Get_Simple_Tag_Content(inner_xml, "Weight") or ""
        local style      = Get_Simple_Tag_Content(inner_xml, "Style") or ""
        return {
            ["family"] = family,
            ["weight"] = weight,
            ["style"]  = style,
        }
    end

    --
    -- Ray
    --
    if (element_type == "Ray") then
        -- format: <Ray><origin><Vector3>...</Vector3></origin><direction><Vector3>...</Vector3></direction></Ray>
        local origin_xml    = Get_Simple_Tag_Content(inner_xml, "origin") or ""
        local direction_xml = Get_Simple_Tag_Content(inner_xml, "direction") or ""
        local origin        = Convert_Xml_Value_To_Json("Vector3", origin_xml)
        local direction     = Convert_Xml_Value_To_Json("Vector3", direction_xml)
        return {
            ["origin"]    = origin,
            ["direction"] = direction,
        }
    end

    --
    -- Rect
    --
    if (element_type == "Rect") then
        local min_xml = Get_Simple_Tag_Content(inner_xml, "min") or ""
        local max_xml = Get_Simple_Tag_Content(inner_xml, "max") or ""
        local min_vec = Convert_Xml_Value_To_Json("Vector2", min_xml)
        local max_vec = Convert_Xml_Value_To_Json("Vector2", max_xml)
        return { min_vec, max_vec }
    end

    --
    -- NumberRange
    --
    if (element_type == "NumberRange") then
        local min_val = Get_Number_From_Tag(inner_xml, "Min")
        local max_val = Get_Number_From_Tag(inner_xml, "Max")
        return { min_val, max_val }
    end

    --
    -- NumberSequence
    --
    if (element_type == "NumberSequence") then
        local keypoints = {}
        for keypoint_xml in string.gmatch(inner_xml, "<Keypoint>(.-)</Keypoint>") do
            local time     = Get_Number_From_Tag(keypoint_xml, "Time")
            local value    = Get_Number_From_Tag(keypoint_xml, "Value")
            local envelope = Get_Number_From_Tag(keypoint_xml, "Envelope")
            table.insert(keypoints, {
                ["time"]     = time,
                ["value"]    = value,
                ["envelope"] = envelope,
            })
        end
        return { ["keypoints"] = keypoints }
    end

    --
    -- ColorSequence
    --
    if (element_type == "ColorSequence") then
        local keypoints = {}
        for keypoint_xml in string.gmatch(inner_xml, "<Keypoint>(.-)</Keypoint>") do
            local time      = Get_Number_From_Tag(keypoint_xml, "Time")
            local color_xml = Get_Simple_Tag_Content(keypoint_xml, "Color") or ""
            local color     = Convert_Xml_Value_To_Json("Color3", color_xml)
            table.insert(keypoints, {
                ["time"]  = time,
                ["color"] = color,
            })
        end
        return { ["keypoints"] = keypoints }
    end

    --
    -- PhysicalProperties
    --
    if (element_type == "PhysicalProperties") then
        -- May be "Default" or a structure
        local custom_xml = Get_Simple_Tag_Content(inner_xml, "Custom")
        if (custom_xml == nil) then
            return "Default"
        end
        local density          = Get_Number_From_Tag(custom_xml, "Density")
        local friction         = Get_Number_From_Tag(custom_xml, "Friction")
        local elasticity       = Get_Number_From_Tag(custom_xml, "Elasticity")
        local friction_weight  = Get_Number_From_Tag(custom_xml, "FrictionWeight")
        local elasticity_weight = Get_Number_From_Tag(custom_xml, "ElasticityWeight")
        return {
            ["density"]          = density,
            ["friction"]         = friction,
            ["elasticity"]       = elasticity,
            ["frictionWeight"]   = friction_weight,
            ["elasticityWeight"] = elasticity_weight,
        }
    end

    --
    -- MaterialColors
    --
    if (element_type == "MaterialColors") then
        local result = {}
        for pair_xml in string.gmatch(inner_xml, "<Item>(.-)</Item>") do
            local material_xml = Get_Simple_Tag_Content(pair_xml, "Material") or ""
            local material     = Get_Simple_Tag_Content(material_xml, "token") or material_xml
            local color_xml    = Get_Simple_Tag_Content(pair_xml, "Color") or ""
            local color        = Convert_Xml_Value_To_Json("Color3", color_xml)
            result[material]   = color
        end
        return result
    end

    --
    -- Tags
    --
    if (element_type == "Tags") then
        local tags = {}
        for tag in string.gmatch(inner_xml, "<string>(.-)</string>") do
            table.insert(tags, tag)
        end
        return tags
    end

    --
    -- Faces (bitmask => list of strings)
    --
    if (element_type == "Faces") then
        local int_val = tonumber(inner_xml)
        if (int_val ~= nil) then
            return Faces_Integer_To_List(int_val)
        end
        return {}
    end

    --
    -- Axes (bitmask => list of strings)
    --
    if (element_type == "Axes") then
        local int_val = tonumber(inner_xml)
        if (int_val ~= nil) then
            return Axes_Integer_To_List(int_val)
        end
        return {}
    end

    --
    -- Fallback for any unknown types: return the raw inner XML.
    --
    return inner_xml
end

--
-- Parses the serialized XML of a single Roblox instance and returns a table
-- of its properties (excluding "Name") ready for JSON encoding.
--
local function Extract_Properties_From_Serialized_XML(xml: string): { [string]: any }
    local properties = {}
    -- Find the first <Properties> block.
    local prop_start  = xml:find("<Properties>")
    if (prop_start == nil) then
        return properties
    end
    local prop_end    = xml:find("</Properties>", prop_start)
    if (prop_end == nil) then
        return properties
    end
    local props_block = xml:sub(prop_start + 12, prop_end - 1)

    -- Match each property element.  The pattern captures the whole element,
    -- the tag name, the attribute name, and the inner content (which may span lines).
    for whole_elem, elem_type, prop_name, inner_content in string.gmatch(props_block,
        "(<(%w+) name=\"([^\"]+)\">([%s%S]-)</%2>)"
    ) do
        if (prop_name ~= "Name") then
            local value = Convert_Xml_Value_To_Json(elem_type, inner_content)
            properties[prop_name] = value
        end
    end
    return properties
end

-- Converts a Lune userdata default value into a JSON‑compatible Lua value,
-- mirroring the structure produced by Convert_Xml_Value_To_Json.
--
local function Convert_Default_Value_To_Json(value: any): any
    local t = typeof(value)
    if     (t == "Color3") then
        return { value.R, value.G, value.B }
    elseif (t == "Vector3") then
        return { value.X, value.Y, value.Z }
    elseif (t == "Vector2") then
        return { value.X, value.Y }
    elseif (t == "CFrame") then
        -- GetComponents returns the 12 numbers that match the XML representation.
        local comps = { value:GetComponents() }
        return comps
    elseif (t == "UDim2") then
        return {
            { value.X.Scale, value.X.Offset },
            { value.Y.Scale, value.Y.Offset },
        }
    elseif (t == "UDim") then
        return { value.Scale, value.Offset }
    elseif (t == "BrickColor") then
        return value.Number
    elseif (t == "EnumItem") then
        -- XML stores the token as the enum item's name.
        return value.Name
    else
        -- For numbers, strings, booleans, or unknown userdata, return as‑is.
        return value
    end
end

--
-- Writes an init.meta.json file for a non‑script instance, creating the
-- necessary folder (named after the instance) first.
-- Skips writing if all properties match the reflection database defaults.
--
local function Write_Instance_Meta(instance: roblox.Instance, root: roblox.DataModel): ()
    local parent_path     = Get_Path_From_Instance(instance, root)
    local instance_folder = `{parent_path}/{instance.Name}`

    -- Serialize the instance alone (descendants are irrelevant for meta).
    local serialized_xml = roblox.serializeModel({instance}, true)
    local properties     = Extract_Properties_From_Serialized_XML(serialized_xml)

    -- Remove properties that are hidden, deprecated, read-only, or write-only
    local class = db:GetClass(instance.ClassName)
    if class then
        for name, _ in pairs(properties) do
            local propDef = class.Properties[name]
            if propDef then
                for _, tag in ipairs(propDef.Tags) do
                    if SKIP_PROPERTY_TAGS[tag] then
                        properties[name] = nil
                        break
                    end
                end
            end
        end
    end

    -- Check against default properties from the reflection database.
    local has_non_default_props = false
    if class then
        for name, value in properties do
            --
            -- If a property is not in the default table at all, consider it non‑default.
            --
            local default_value = class.DefaultProperties[name]
            if (default_value == nil) then
                has_non_default_props = true
                break
            end
            local converted_default_value = Convert_Default_Value_To_Json(default_value)  -- Convert the userdata default to the same JSON‑safe form as the parsed property.
            --
            -- Compare by JSON serialisation so we correctly handle userdata vs. tables.
            --
            local ok1, value_json   = pcall(serde.encode, "json", value)
            local ok2, default_json = pcall(serde.encode, "json", converted_default_value)
            if ((not ok1) or (not ok2) or (value_json ~= default_json)) then
                has_non_default_props = true
                break
            end
        end
    else
        --
        -- Unknown class – we cannot determine defaults, so write the meta to be safe.
        --
        has_non_default_props = true
    end
    --
    -- Only write the meta file when the instance actually holds custom data.
    --
    if (has_non_default_props) then
        local meta = {
            className  = instance.ClassName,
            properties = properties,
        }

        pcall(function()
            fs.writeDir(instance_folder)
        end)
        local meta_file_path = `{instance_folder}/init.meta.json`
        local prettify = true
        fs.writeFile(meta_file_path, serde.encode("json", meta, prettify))
    end
end

--
-- MODULE OPERATION
--
local place_contents = fs.readFile(PLACE_FILE)
local place          = roblox.deserializePlace(place_contents)

for _, descendant in place:GetDescendants() do
    --
    -- Skip destroyed instances.
    --
    if (not descendant) then
        continue
    end
    --
    -- Skip services (direct children of the DataModel).
    --
    if (descendant.Parent == place) then
        continue
    end

    local extension = included_classnames[descendant.ClassName]
    if (extension) then
        -- Script instance: extract source and write as a module file.
        local path        = Get_Path_From_Instance(descendant, place)
        local serialized  = roblox.serializeModel({descendant}, true)
        local source_code = Extract_Module_From_XML(serialized)
        pcall(function()
            fs.writeDir(path)
        end)
        local file_name = `{descendant.Name}{extension}`
        fs.writeFile(`{path}/{file_name}`, source_code)
    else
        -- Non‑script instance: create a folder with an init.meta.json **only if** it has custom properties.
        Write_Instance_Meta(descendant, place)
    end
end