# eISY Insteon SmartThings Edge Driver

This package contains a local SmartThings Edge driver for Universal Devices eISY / IoX controllers with Insteon nodes.

## What It Does

- Creates one `eISY Controller` bridge device during SmartThings discovery.
- Adds a `Scan for devices` button on the `eISY Controller` device that scans eISY and creates supported child devices.
- Uses controller preferences for eISY host, protocol, port, username, password, polling interval, and ignored node patterns.
- Reads eISY nodes from `/rest/nodes` and status from `/rest/status`.
- Auto-creates supported Insteon child devices:
  - switches
  - dimmers
  - keypads as multi-component devices
  - fan controllers
  - outlets
  - motion sensors
  - contact sensors
  - IOLinc as a relay plus sensor multi-component device
- Skips non-Insteon eISY nodes, including node-server, Matter, Z-Wave, and Zigbee nodes.
- Splits FanLinc modules into separate SmartThings devices for the light dimmer and fan motor.
- Keypad secondary buttons display their eISY names and current on/off status with a read-only custom status capability.
- Sends local commands through `/rest/nodes/<node>/cmd/...`.
- Polls as a reliable fallback and attempts a plain-HTTP `/rest/subscribe` WebSocket connection when available.

## Install And Test

1. Package the driver:

   ```powershell
   smartthings edge:drivers:package
   ```

2. Create or use a SmartThings Edge channel, assign the package, and install it to your hub with the SmartThings CLI.

3. In the SmartThings app, run nearby device discovery. The driver creates `eISY Controller`.

4. Open the controller device settings and enter:
   - eISY host or IP
   - protocol
   - port
   - username
   - password
   - polling interval

5. Tap `Scan for devices` on the controller, or refresh the controller. Supported Insteon nodes should appear as child devices.

## Notes

- eISY/IoX must be reachable from the SmartThings hub on the local network.
- HTTPS REST calls are supported when the hub runtime exposes `ssl.https`.
- The WebSocket subscriber currently supports plain HTTP. HTTPS configurations still work through polling.
- Node classification is heuristic because eISY node metadata varies by device generation and naming. Use `ignoredNodes` to skip unwanted nodes.
- Scenes and programs are intentionally out of scope for this first version.
