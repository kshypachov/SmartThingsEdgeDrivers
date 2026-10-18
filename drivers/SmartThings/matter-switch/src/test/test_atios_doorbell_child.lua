-- Atios fork of matter-switch: the doorbell button of a Matter Video Doorbell
-- (endpoint with device type 0x0143 carrying the Switch cluster) exposed as
--   (D3) an EDGE_CHILD device "Doorbell" with the stock `button` profile, and
--   (D4) events delivered to that child AND to the parent's `doorbell` component.
-- Contract: atios_video_doorlock/docs/smartthings-custom-driver-plan.md §2, suite U.
-- These are unit tests of the two new functions on fake devices; the integration
-- path (doConfigure creating the child) is covered by test_matter_camera.lua (D5).

local test = require "integration_test"
local capabilities = require "st.capabilities"
local fields = require "switch_utils.fields"
local camera_cfg = require "sub_drivers.camera.camera_utils.device_configuration"
local camera_utils = require "sub_drivers.camera.camera_utils.utils"

local CAMERA_EP, DOORBELL_EP, DOORBELL_EP2, FLOOD_EP, OTHER_EP = 1, 4, 5, 2, 9

local function ep(id, dt) return { endpoint_id = id, device_types = { { device_type_id = dt, device_type_revision = 1 } } } end

local log -- shared delivery log: { who, component_or_nil, event }

local function fake_child(name)
  local c = { name = name, store = {}, metadata = {} }
  function c:emit_event(ev) table.insert(log, { who = self.name, ev = ev }) end
  function c:get_field(k) return self.store[k] end
  function c:set_field(k, v) self.store[k] = v end
  function c:try_update_metadata(md) table.insert(self.metadata, md) end
  return c
end

local function fake_parent(opts)
  opts = opts or {}
  local d = {
    id = "parent-uuid",
    store = {},
    children = opts.children or {},
    find_child_set = false,
    endpoints = opts.endpoints or { ep(0, 0x0016), ep(CAMERA_EP, 0x0142), ep(DOORBELL_EP, 0x0143) },
    profile = { components = { main = { id = "main" }, doorbell = { id = "doorbell" } } },
    supported = opts.supported or { doorbell = { [capabilities.button.ID] = true } },
    emit_calls = 0,
  }
  function d:get_field(k) return self.store[k] end
  function d:set_field(k, v) self.store[k] = v end
  function d:get_child_by_parent_assigned_key(key) return self.children[key] end
  function d:set_find_child(fn) self.find_child_set = (fn ~= nil) end
  function d:supports_capability_by_id(cap_id, comp_id)
    local c = self.supported[comp_id or "main"]
    return c ~= nil and c[cap_id] == true
  end
  function d:emit_component_event(comp, ev)
    self.emit_calls = self.emit_calls + 1
    table.insert(log, { who = "parent", comp = comp.id, ev = ev })
    return true
  end
  if opts.map ~= false then
    d.store[fields.COMPONENT_TO_ENDPOINT_MAP] = { doorbell = DOORBELL_EP }
  end
  return d
end

local function fake_driver()
  local drv = { created = {} }
  function drv:try_create_device(md) table.insert(self.created, md) end
  return drv
end

local function with_child(parent, ep_id, child)
  parent.children[string.format("%d", ep_id)] = child
  parent.store[fields.IS_PARENT_CHILD_DEVICE] = true
end

-- U1: one child for the doorbell endpoint, parent marked as parent/child.
test.register_coroutine_test("U1 doorbell endpoint gets one EDGE_CHILD with the button profile", function()
  local drv, dev = fake_driver(), fake_parent()
  camera_cfg.create_doorbell_child(drv, dev)
  assert(#drv.created == 1, "expected one child, got " .. #drv.created)
  local md = drv.created[1]
  assert(md.type == "EDGE_CHILD", "type")
  assert(md.label == "Doorbell", "label")
  assert(md.profile == "doorbell-button", "profile (DoorBell category)")
  assert(md.parent_device_id == dev.id, "parent id")
  assert(md.parent_assigned_child_key == string.format("%d", DOORBELL_EP), "child key")
  assert(dev.store[fields.IS_PARENT_CHILD_DEVICE] == true, "parent/child field")
  assert(dev.find_child_set, "find_child installed")
end)

-- U4: no doorbell endpoint -> nothing.
test.register_coroutine_test("U4 no 0x0143 endpoint creates no child", function()
  local drv = fake_driver()
  local dev = fake_parent({ endpoints = { ep(0, 0x0016), ep(CAMERA_EP, 0x0142) } })
  camera_cfg.create_doorbell_child(drv, dev)
  assert(#drv.created == 0, "no child expected")
  assert(dev.store[fields.IS_PARENT_CHILD_DEVICE] == nil, "field must stay unset")
end)

-- U5: two doorbell endpoints -> only the first (as the component map).
test.register_coroutine_test("U5 only the first 0x0143 endpoint gets a child", function()
  local drv = fake_driver()
  local dev = fake_parent({ endpoints = { ep(0, 0x0016), ep(CAMERA_EP, 0x0142), ep(DOORBELL_EP, 0x0143), ep(DOORBELL_EP2, 0x0143) } })
  camera_cfg.create_doorbell_child(drv, dev)
  assert(#drv.created == 1, "one child expected")
  assert(drv.created[1].parent_assigned_child_key == string.format("%d", DOORBELL_EP), "first endpoint")
end)

-- U6: child already there -> no second create, field still set.
test.register_coroutine_test("U6 existing child is not created again", function()
  local drv, dev = fake_driver(), fake_parent()
  dev.children[string.format("%d", DOORBELL_EP)] = fake_child("child")
  camera_cfg.create_doorbell_child(drv, dev)
  assert(#drv.created == 0, "must not create a duplicate")
  assert(dev.store[fields.IS_PARENT_CHILD_DEVICE] == true, "parent/child field")
end)

-- U13: a child created by an earlier version with the plain `button` profile is moved
-- once to `doorbell-button` (DoorBell category); a second call does not repeat it.
test.register_coroutine_test("U13 existing child migrates to the doorbell-button profile once", function()
  local drv, dev = fake_driver(), fake_parent()
  local child = fake_child("child")
  dev.children[string.format("%d", DOORBELL_EP)] = child
  camera_cfg.create_doorbell_child(drv, dev)
  camera_cfg.create_doorbell_child(drv, dev)
  assert(#drv.created == 0, "no new child")
  assert(#child.metadata == 1 and child.metadata[1].profile == "doorbell-button", "one profile update")
end)

-- U14: init path (migrate_only) never creates a child and leaves the parent untouched.
test.register_coroutine_test("U14 migrate-only call does not create a child", function()
  local drv, dev = fake_driver(), fake_parent()
  local r = camera_cfg.create_doorbell_child(drv, dev, true)
  assert(r == false and #drv.created == 0, "no creation at init")
  assert(dev.store[fields.IS_PARENT_CHILD_DEVICE] == nil, "parent untouched")
end)

-- U8: two calls before the child appears (doConfigure + driverSwitched) -> one request.
test.register_coroutine_test("U8 repeated calls before the child exists request it once", function()
  local drv, dev = fake_driver(), fake_parent()
  camera_cfg.create_doorbell_child(drv, dev)
  camera_cfg.create_doorbell_child(drv, dev)
  assert(#drv.created == 1, "one request expected, got " .. #drv.created)
end)

-- U2: press -> child first, then the parent's doorbell component.
test.register_coroutine_test("U2 doorbell press goes to the child and to the doorbell component", function()
  log = {}
  local dev = fake_parent()
  with_child(dev, DOORBELL_EP, fake_child("child"))
  local ev = capabilities.button.button.double({ state_change = true })
  camera_utils.emit_event_for_endpoint(dev, DOORBELL_EP, ev)
  assert(#log == 2, "two deliveries expected, got " .. #log)
  assert(log[1].who == "child" and log[1].ev == ev, "child first")
  assert(log[2].who == "parent" and log[2].comp == "doorbell" and log[2].ev == ev, "then parent doorbell")
end)

-- U15: with `button` on main (video-doorbell profile) the press is mirrored to main as well.
test.register_coroutine_test("U15 doorbell press is mirrored to main when main has a button", function()
  log = {}
  local dev = fake_parent({ supported = { doorbell = { [capabilities.button.ID] = true }, main = { [capabilities.button.ID] = true } } })
  with_child(dev, DOORBELL_EP, fake_child("child"))
  local ev = capabilities.button.button.pushed({ state_change = true })
  camera_utils.emit_event_for_endpoint(dev, DOORBELL_EP, ev)
  assert(#log == 3, "three deliveries, got " .. #log)
  assert(log[1].who == "child" and log[2].comp == "doorbell" and log[3].comp == "main", "child, doorbell, main")
end)

-- U16: a non-doorbell endpoint mapped to nothing is not mirrored to main.
test.register_coroutine_test("U16 other endpoints are not mirrored to main", function()
  log = {}
  local dev = fake_parent({ supported = { doorbell = { [capabilities.button.ID] = true }, main = { [capabilities.button.ID] = true } } })
  camera_utils.emit_event_for_endpoint(dev, OTHER_EP, capabilities.button.button.pushed({ state_change = true }))
  assert(#log == 1 and log[1].comp == "main", "unmapped endpoint lands on main once (stock mapping), no mirror")
end)

-- U3: supportedButtonValues follows the same route.
test.register_coroutine_test("U3 supportedButtonValues reaches the child and the component", function()
  log = {}
  local dev = fake_parent()
  with_child(dev, DOORBELL_EP, fake_child("child"))
  local ev = capabilities.button.supportedButtonValues({ "pushed", "double" }, { visibility = { displayed = false } })
  camera_utils.emit_event_for_endpoint(dev, { endpoint_id = DOORBELL_EP }, ev)
  assert(#log == 2 and log[1].who == "child" and log[2].comp == "doorbell", "both deliveries")
end)

-- U7: endpoint with neither child nor a supporting component -> silent, no emit call.
test.register_coroutine_test("U7 unmapped endpoint without support is skipped silently", function()
  log = {}
  local dev = fake_parent()
  camera_utils.emit_event_for_endpoint(dev, OTHER_EP, capabilities.button.button.pushed({ state_change = true }))
  assert(#log == 0, "no delivery expected")
  assert(dev.emit_calls == 0, "emit_component_event must not be called")
end)

-- U7b: a non-doorbell child (floodlight) keeps the stock child-only behaviour.
test.register_coroutine_test("U7b non-doorbell child gets the event alone", function()
  log = {}
  local dev = fake_parent({ supported = { doorbell = { [capabilities.button.ID] = true }, main = { [capabilities.switch.ID] = true } } })
  with_child(dev, FLOOD_EP, fake_child("flood"))
  camera_utils.emit_event_for_endpoint(dev, FLOOD_EP, capabilities.switch.switch.on())
  assert(#log == 1 and log[1].who == "flood", "child only")
end)

-- U-stock: no child at all -> parent component only (stock behaviour before the child exists).
test.register_coroutine_test("U9 without a child the doorbell component still gets the press", function()
  log = {}
  local dev = fake_parent()
  camera_utils.emit_event_for_endpoint(dev, DOORBELL_EP, capabilities.button.button.pushed({ state_change = true }))
  assert(#log == 1 and log[1].who == "parent" and log[1].comp == "doorbell", "parent doorbell only")
end)

-- U12: the child's own doConfigure re-runs configure_buttons on the parent for the doorbell
-- endpoint (MultiPressMax is not subscribed, so after a driver switch the child would never
-- get supportedButtonValues otherwise); any other child is left alone.
test.register_coroutine_test("U12 doorbell child configure re-configures the parent buttons", function()
  local calls = {}
  local function record(dev, eps) table.insert(calls, { dev = dev, eps = eps }) end
  local parent = fake_parent()
  function parent:get_endpoints() return { DOORBELL_EP } end
  local child = { parent_assigned_child_key = string.format("%d", DOORBELL_EP) }
  function child:get_parent_device() return parent end
  local other = { parent_assigned_child_key = string.format("%d", FLOOD_EP) }
  function other:get_parent_device() return parent end
  local r1 = camera_cfg.configure_doorbell_child(child, record)
  local r2 = camera_cfg.configure_doorbell_child(other, record)
  assert(r1 == true and r2 == false, "doorbell child handled, other skipped")
  assert(#calls == 1 and calls[1].dev == parent, "configure_buttons once on the parent")
  assert(calls[1].eps[1] == DOORBELL_EP, "momentary-switch endpoints of the parent")
end)

test.run_registered_tests()
