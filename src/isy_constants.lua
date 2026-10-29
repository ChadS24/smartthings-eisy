local constants = {}

constants.FAMILY_INSTEON = "1"
constants.FAMILY_NODESERVER = "10"
constants.FAMILY_ZMATTER_ZWAVE = "12"

constants.PROP_STATUS = "ST"
constants.PROP_BATTERY = "BATLVL"
constants.PROP_RAMP_RATE = "RR"
constants.PROP_ON_LEVEL = "OL"
constants.PROP_ERROR = "ERR"
constants.PROP_BUSY = "BUSY"

constants.CONTROL_HEARTBEAT = "_0"
constants.CONTROL_SYSTEM_CONFIG = "_1"
constants.CONTROL_NODE_CHANGED = "_3"
constants.CONTROL_SYSTEM_STATUS = "_5"
constants.CONTROL_PROGRESS = "_7"

constants.EVENT_PROPS_IGNORED = {
  DON = true,
  DOF = true,
  DFON = true,
  DFOF = true,
  BMAN = true,
  SMAN = true,
  FDUP = true,
  FDDOWN = true,
  FDSTOP = true,
  BRT = true,
  DIM = true
}

constants.STATUS_CONTROLS = {
  ST = true,
  CLIMD = true,
  CLISPH = true,
  CLISPC = true,
  CLIHCS = true,
  CLIFS = true,
  CLIHUM = true
}

constants.INSTEON_RAMP_RATES = {
  [0] = 540,
  [1] = 480,
  [2] = 420,
  [3] = 360,
  [4] = 300,
  [5] = 270,
  [6] = 240,
  [7] = 210,
  [8] = 180,
  [9] = 150,
  [10] = 120,
  [11] = 90,
  [12] = 60,
  [13] = 47,
  [14] = 43,
  [15] = 38.5,
  [16] = 34,
  [17] = 32,
  [18] = 30,
  [19] = 28,
  [20] = 26,
  [21] = 23.5,
  [22] = 21.5,
  [23] = 19,
  [24] = 8.5,
  [25] = 6.5,
  [26] = 4.5,
  [27] = 2,
  [28] = 0.5,
  [29] = 0.3,
  [30] = 0.2,
  [31] = 0.1
}

constants.THERMOSTAT_MODES = {
  [0] = "off",
  [1] = "heat",
  [2] = "cool",
  [3] = "auto",
  [4] = "program auto",
  [5] = "program heat",
  [6] = "program cool"
}

constants.THERMOSTAT_FAN_MODES = {
  [7] = "on",
  [8] = "auto"
}

constants.THERMOSTAT_OPERATING_STATES = {
  [0] = "idle",
  [1] = "heating",
  [2] = "cooling",
  [3] = "fan only",
  [4] = "pending heat",
  [5] = "pending cool",
  [6] = "vent economizer"
}

return constants
