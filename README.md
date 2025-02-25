# Teams Status Monitor

A PowerShell project to monitor your Microsoft Teams status and local computer state. This script tracks Teams availability, call activity (including mute status), workstation lock status, and display power state. When any monitored values change—or after a specified interval—the script sends an update (in JSON format) to a configurable endpoint.

I use this to get my teams info into Home Assistant so I can do automations like turning off my smart speaker alerts when I am in a meeting. This also allows my spouse to check if I am in a meeting or not.  I set this up so it sends to Node-RED which then updates the entities in Home Assistant for you. 

**Example Payload:**
```json
{
  "teams_status": "Available",
  "call_status": "In A Call",
  "mute_status": true,
  "in_call": true,
  "pc_locked": false,
  "display_on": true,
  "timestamp": "2025-02-18T16:27:21.569411-07:00"
}
```

## Features

- **Teams Status Monitoring:**  
  Detects if Teams is Available, Busy, Away, Do Not Disturb, or Offline.

- **Call Activity Tracking:**  
  Determines whether you are in a call and, if so, whether your microphone is muted.

- **Local Computer Status:**  
  Checks if your workstation is locked and whether your display is on based on idle time.

- **Configurable Update Interval:**  
  Sends updates only when a change is detected or after a forced update interval.

## Requirements

- PowerShell 3.0 or higher
- Microsoft Teams installed and running
- Access to the Teams log folder (by default, located in the user’s AppData directory)
- A Node-RED or similar endpoint to receive the status updates (optional)

## Installation

1. **Clone or Download this Repository**

2. **Configure Settings:**
    - Copy the file `settings.ps1.example` to `settings.ps1`.
    - Open `settings.ps1` in your favorite text editor.
    - Adjust the configuration values (endpoint URL, token, log folder path, etc.) to match your environment.

3. Run powershell as administrator and run the `install.ps1` script
    - This installs the powershell script as a service so it runs in the background and auto starts with the machine.

## Manual Usage

We recommend running this as a service but you can also run it directly for debugging purposes. Ensure you modified `settings.ps1` with your configuration.

1. Open a PowerShell window.
2. Navigate to the folder containing the scripts.
3. Run the main script:

   ```powershell
   .\TeamsStatusMonitor.ps1
   ```

The script will begin monitoring your Teams and computer status and will send updates according to your configuration.

## Contributing

Contributions are welcome! Feel free to submit issues or pull requests with improvements or bug fixes.

## License

This project is provided under the [MIT License](LICENSE).

## Disclaimer

Use this script at your own risk. The script reads log files and system information; ensure you have the appropriate permissions and that your organization allows this type of monitoring.