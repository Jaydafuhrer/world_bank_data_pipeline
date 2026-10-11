# macOS scheduled runs

Runs the World Bank pipeline daily at 09:00 in the Mac's local time.

## Requirements

- macOS with PostgreSQL available.
- Project dependencies installed in the project's venv directory.
- A successful manual run of main.py.
- A login Keychain password item named world-bank-db-password,
  with the account set to your macOS username.

The runner retrieves DB_PASSWORD from Keychain. No password is stored
in the script or schedule template. Other database settings must match
the pipeline's configuration.

## Install

1. Make run_pipeline.sh executable: chmod 700 run_pipeline.sh
2. Create the project's logs directory.
3. Copy com.john.worldbank.plist.template into ~/Library/LaunchAgents/
   as com.john.worldbank.plist.
4. Replace every __PROJECT_DIR__ placeholder with the absolute project path.
5. Validate with plutil -lint, then register:

launchctl bootstrap "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/com.john.worldbank.plist"

Test immediately:

launchctl kickstart "gui/$(id -u)/com.john.worldbank"

## Monitor

Inspect the job:

launchctl print "gui/$(id -u)/com.john.worldbank"

Output is appended to logs/scheduler.out.log and logs/scheduler.err.log.
A failed password lookup or pipeline run triggers a Mac notification
and preserves a nonzero exit code. Notification delivery depends on
macOS notification permissions.

This is a local user schedule. The Mac must be powered on, the user
session available, and PostgreSQL and internet access available.
It is not an always-on cloud deployment.

## Verification

A launchd-triggered run completed with 264 processed records.
A temporary runner copy exiting before database access triggered the
failure notification and returned exit code 1.

## Disable

launchctl bootout "gui/$(id -u)/com.john.worldbank"
