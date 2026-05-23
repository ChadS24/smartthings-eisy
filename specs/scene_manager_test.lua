local scene_manager = require "scene_manager"

local M = {}

local function assert_equal(actual, expected)
  if actual ~= expected then
    error(string.format("expected %s, got %s", tostring(expected), tostring(actual)), 2)
  end
end

local function assert_truthy(value)
  if not value then error("expected truthy value", 2) end
end

local fixture = [[
<nodes>
  <group flag="128">
    <address>12345</address>
    <name>Evening Lights</name>
    <family>1</family>
    <members>
      <link>11 22 33 1</link>
    </members>
  </group>
  <group>
    <address>67890</address>
    <name>Downstairs Off</name>
    <family>1</family>
  </group>
  <node flag="128" nodeDefId="DimmerLampSwitch">
    <address>11 22 33 1</address>
    <name>Kitchen Dimmer</name>
    <family>1</family>
  </node>
</nodes>
]]

function M.parse_scene_ids_trims_dedupes_and_ignores_empty_values()
  local ids = scene_manager.parse_scene_ids(" 12345,67890,12345, , 24680 ")
  assert_equal(#ids, 3)
  assert_equal(ids[1], "12345")
  assert_equal(ids[2], "67890")
  assert_equal(ids[3], "24680")
end

function M.parse_scenes_reads_group_records_without_nodes()
  local scenes = scene_manager.parse_scenes(fixture)
  assert_truthy(scenes["12345"])
  assert_equal(scenes["12345"].id, "12345")
  assert_equal(scenes["12345"].name, "Evening Lights")
  assert_truthy(scenes["67890"])
  assert_equal(scenes["11 22 33 1"], nil)
end

function M.selected_scenes_returns_only_configured_existing_scenes()
  local scenes = scene_manager.parse_scenes(fixture)
  local selected, missing = scene_manager.selected_scenes("67890,missing,12345", scenes)
  assert_equal(#selected, 2)
  assert_equal(selected[1].id, "67890")
  assert_equal(selected[2].id, "12345")
  assert_equal(#missing, 1)
  assert_equal(missing[1], "missing")
end

function M.scene_child_key_is_namespaced_and_stable()
  assert_equal(scene_manager.scene_child_key("uuid 1", "12345"), "eisy-scene:uuid_1:h3132333435")
  assert_equal(scene_manager.scene_child_key(nil, "12345"), "eisy-scene:h3132333435")
end

function M.select_scene_child_key_prefers_existing_uuid_then_legacy_key()
  local seen = { ["eisy-scene:h3132333435"] = true }
  local key = scene_manager.select_scene_child_key("uuid 1", "12345", function(candidate)
    return seen[candidate]
  end)
  assert_equal(key, "eisy-scene:h3132333435")

  seen["eisy-scene:uuid_1:h3132333435"] = true
  key = scene_manager.select_scene_child_key("uuid 1", "12345", function(candidate)
    return seen[candidate]
  end)
  assert_equal(key, "eisy-scene:uuid_1:h3132333435")
end

function M.scene_id_round_trips_from_child_key_without_losing_characters()
  local scene_id = "12 34/56"
  local key = scene_manager.scene_child_key("uuid 1", scene_id)
  assert_equal(scene_manager.scene_id_from_child_key(key), scene_id)
end

return M
