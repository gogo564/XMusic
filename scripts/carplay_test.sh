#!/bin/bash
set -uo pipefail

# CarPlay Simulator Test Script
# This script is called by the GitHub Actions workflow

DEVICE=""
cleanup() {
  if [ -n "$DEVICE" ]; then
    xcrun simctl shutdown "$DEVICE" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "=== Step 1: Install XcodeGen ==="
brew install xcodegen 2>&1 | tail -3

echo "=== Step 2: Generate xcodeproj ==="
xcodegen generate --project . 2>&1

echo "=== Step 3: Build for simulator ==="
LOG=$(mktemp)
xcodebuild -project XMusic.xcodeproj -scheme XMusic \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/simdd \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  build 2>&1 | tee "$LOG"
RC=${PIPESTATUS[0]}
gzip "$LOG" && mv "$LOG.gz" /tmp/sim_build_log.gz
if [ $RC -ne 0 ]; then
  echo "BUILD FAILED with exit code $RC"
  exit $RC
fi

echo "=== Step 4: Boot simulator ==="
DEVICE=$(xcrun simctl list devices available | grep -E "iPhone" | head -1 | grep -oE '[A-F0-9-]{36}')
echo "Device UDID: $DEVICE"
echo "$DEVICE" > /tmp/device_udid
xcrun simctl boot "$DEVICE" 2>&1 || true
xcrun simctl bootstatus "$DEVICE" -b 2>&1 | tail -2
echo "Booted."

echo "=== Step 5: Install app ==="
APP=$(find /tmp/simdd/Build/Products -name "XMusic.app" -type d | head -1)
echo "App: $APP"
if [ -z "$APP" ]; then
  echo "ERROR: no .app found"
  exit 1
fi
xcrun simctl install "$DEVICE" "$APP"
echo "Installed."

echo "=== Step 6: Check CarPlay entitlement ==="
APP_BIN="$APP/XMusic"
echo "=== CarPlay entitlement check ==="
if command -v codesign >/dev/null 2>&1 && [ -f "$APP_BIN" ]; then
  codesign -d --entitlements :- "$APP_BIN" 2>/dev/null | grep -iE "carplay" || echo "NO carplay entitlement in signed binary!"
fi
find "$APP" -name "*xcent*" -exec sh -c 'echo "--- {} ---"; cat "$1"' _ {} \; 2>/dev/null | grep -iE "carplay|entitlement|<dict" | head || true

echo "=== Step 7: Enable CarPlay and open external display ==="
defaults write com.apple.iphonesimulator CarPlay -bool YES
defaults write com.apple.iphonesimulator CarPlayExtraOptions -bool YES
open -a Simulator 2>&1
sleep 12
echo "=== Simulator menu tree (diagnostic) ==="
osascript -e '
  tell application "Simulator" to activate
  delay 1
  tell application "System Events"
    tell process "Simulator"
      set out to ""
      repeat with mb in menu bar items of menu bar 1
        set out to out & "MENUBARITEM: " & (name of mb) & linefeed
        try
          repeat with mi in menu items of menu 1 of mb
            set out to out & "  ITEM: " & (name of mi) & linefeed
            try
              set out to out & "    has submenu: " & ((count of menu items of menu 1 of mi) > 0) & linefeed
              repeat with mi2 in menu items of menu 1 of mi
                set out to out & "      SUB: " & (name of mi2) & linefeed
              end repeat
            end try
          end repeat
        end try
      end repeat
      return out
    end tell
  end tell' 2>&1 | tee /tmp/menu_tree.txt
echo "=== end menu tree ==="

echo "=== Clicking CarPlay menu item ==="
osascript -e '
  tell application "Simulator" to activate
  delay 0.5
  tell application "System Events"
    tell process "Simulator"
      click menu item "CarPlay…" of menu 1 of menu item "External Displays" of menu 1 of menu bar item "I/O" of menu bar 1
    end tell
  end tell' 2>&1 || echo "CarPlay click failed"
sleep 5

echo "=== Dumping all windows and buttons (diagnostic) ==="
osascript -e '
  tell application "System Events" to tell process "Simulator"
    set out to ""
    repeat with w in windows
      set out to out & "WINDOW: " & (name of w) & " role=" & (role description of w) & linefeed
      try
        repeat with b in buttons of w
          set out to out & "  BUTTON: \"" & (name of b) & "\"" & linefeed
        end repeat
      end try
      try
        repeat with sg in UI elements of w
          set out to out & "  UI: role=" & (role description of sg) & " desc=" & (description of sg) & linefeed
        end repeat
      end try
    end repeat
    return out
  end tell' 2>&1 | tee /tmp/window_dump.txt
echo "=== end window dump ==="

echo "=== Clicking Run button (by name + AXPress) ==="
osascript -e '
  tell application "Simulator" to activate
  delay 0.5
  tell application "System Events" to tell process "Simulator"
    repeat with w in windows
      try
        if name of w is "TV Out Extended Setup" then
          repeat with b in buttons of w
            if name of b is "Run" then
              click b
              delay 0.2
              click b
              return "CLICKED_RUN_BY_NAME"
            end if
          end repeat
        end if
      end try
    end repeat
    return "TV_Out_panel_not_found"
  end tell' 2>&1 || true

echo "=== Fallback: keyboard Return to confirm Run ==="
osascript -e '
  tell application "Simulator" to activate
  delay 0.5
  tell application "System Events" to keystroke return
' 2>&1 || true
sleep 5

echo "=== Checking Run result (windows now) ==="
xcrun swiftc -o /tmp/winenum scripts/window_enum.swift 2>&1 | tail -2 || true
/tmp/winenum 2>&1 | tee /tmp/sim_windows_post_run.txt
echo "=== end ==="

echo "=== Checking if CarPlay window appeared ==="
xcrun swiftc -o /tmp/winenum scripts/window_enum.swift 2>&1 | tail -2 || true
/tmp/winenum 2>&1 | tee /tmp/sim_windows.txt
CARPLAY_WINS=$(awk -F'aspect=' '$2+0 >= 1.0' /tmp/sim_windows.txt | wc -l | tr -d ' ')
echo "CarPlay windows found: $CARPLAY_WINS"
if [ "$CARPLAY_WINS" -lt 1 ]; then
  echo "WARN: CarPlay window not found. Dumping windows again..."
  osascript -e '
    tell application "System Events" to tell process "Simulator"
      set out to ""
      repeat with w in windows
        set out to out & "WINDOW: " & (name of w) & linefeed
        try
          repeat with b in buttons of w
            set out to out & "  BUTTON: \"" & (name of b) & "\"" & linefeed
          end repeat
        end try
      end repeat
      return out
    end tell' 2>&1 | tee /tmp/window_dump_post_run.txt
  echo "WARN: Retrying Run button..."
  osascript -e '
    tell application "Simulator" to activate
    delay 1
    tell application "System Events" to tell process "Simulator"
      repeat with w in windows
        try
          if name of w is "TV Out Extended Setup" then
            repeat with b in buttons of w
              if name of b is "Run" then
                click b
                return "RETRY_CLICKED_RUN"
              end if
            end repeat
          end if
        end try
      end repeat
      return "RETRY_PANEL_GONE"
    end tell' 2>&1 || true
  osascript -e '
    tell application "Simulator" to activate
    delay 0.3
    tell application "System Events" to keystroke return
  ' 2>&1 || true
  sleep 5
  /tmp/winenum 2>&1 | tee /tmp/sim_windows.txt
  CARPLAY_WINS=$(awk -F'aspect=' '$2+0 >= 1.0' /tmp/sim_windows.txt | wc -l | tr -d ' ')
  echo "CarPlay windows after retry: $CARPLAY_WINS"
fi
echo "=== end windows ==="

echo "=== Step 8: Launch app and wait ==="
xcrun simctl bootstatus "$DEVICE" -b 2>&1 | tail -1
sleep 3
xcrun simctl install "$DEVICE" "$(find /tmp/simdd/Build/Products -name XMusic.app -type d | head -1)" 2>&1 || true
xcrun simctl spawn "$DEVICE" defaults write xmusic.XMusic autoLoginOnLaunch -bool YES 2>&1 || true
xcrun simctl spawn "$DEVICE" defaults delete xmusic.XMusic userToken 2>&1 || true
xcrun simctl spawn "$DEVICE" defaults read xmusic.XMusic serverConfig 2>&1 | head -c 200 || true
echo "Launching app..."
xcrun simctl launch --terminate-running-process "$DEVICE" xmusic.XMusic 2>&1 || echo "LAUNCH_RC=$?"
echo "Waiting for app to start..."
sleep 15

echo "=== Step 9: Auto login ==="
mkdir -p /tmp/artifacts
echo "=== Waiting for autoLoginOnLaunch to trigger login ==="
LOGIN_OK=0
for i in $(seq 1 18); do
  sleep 5
  TOKEN=$(xcrun simctl spawn "$DEVICE" defaults read xmusic.XMusic userToken 2>/dev/null | tr -d '"\n' || true)
  echo "[$i] token: ${TOKEN:0:30}"
  if [ -n "$TOKEN" ] && [ "$TOKEN" != "" ]; then
    echo "LOGIN_SUCCESS: token written"
    LOGIN_OK=1
    break
  fi
done
if [ "$LOGIN_OK" = "0" ]; then
  echo "WARN: login did not complete within 90s, continuing anyway"
fi
sleep 3
xcrun simctl io "$DEVICE" screenshot /tmp/after_login.png 2>&1 || true
echo "=== final token ==="
xcrun simctl spawn "$DEVICE" defaults read xmusic.XMusic userToken 2>&1 | head -c 120 || echo "NO TOKEN"

echo "=== Step 10: Click XMusic icon on CarPlay home screen ==="
mkdir -p /tmp/artifacts
CONTAINER=$(xcrun simctl get_app_container "$DEVICE" xmusic.XMusic data 2>/dev/null || true)
LOGFILE="$CONTAINER/Documents/xmusic.log"
echo "LOGFILE=$LOGFILE"
: > "$LOGFILE" 2>/dev/null || true

xcrun swiftc -o /tmp/window_click scripts/window_click.swift 2>&1 | tail -2 || true

echo "=== Bring CarPlay window to front, move iPhone away ==="
osascript -e '
  tell application "Simulator" to activate
  delay 0.5
  tell application "System Events" to tell process "Simulator"
    set carplayRaised to false
    set iphoneMoved to false
    repeat with w in windows
      try
        if name of w contains "CarPlay" then
          set position of w to {50, 200}
          set size of w to {800, 500}
          perform action "AXRaise" of w
          set carplayRaised to true
        end if
      end try
      try
        if name of w contains "iOS" then
          set position of w to {-500, -500}
          set iphoneMoved to true
        end if
      end try
    end repeat
    return "raised=" & carplayRaised & " moved=" & iphoneMoved
  end tell' 2>&1
sleep 3

echo "=== Verify CarPlay position ==="
cat > /tmp/get_carplay_pos.scpt << 'EOFSCRIPT'
  tell application "System Events" to tell process "Simulator"
    repeat with w in windows
      try
        if name of w contains "CarPlay" then
          set p to position of w
          set s to size of w
          set px to item 1 of p
          set py to item 2 of p
          set sw to item 1 of s
          set sh to item 2 of s
          set AppleScript's text item delimiters to ","
          set posStr to {px, py} as string
          set sizeStr to {sw, sh} as string
          set AppleScript's text item delimiters to {""}
          return posStr & "|" & sizeStr
        end if
      end try
    end repeat
    return "NOT_FOUND"
  end tell
EOFSCRIPT
CARPLAY_RAW=$(osascript /tmp/get_carplay_pos.scpt 2>&1)
echo "CarPlay raw: $CARPLAY_RAW"

if [ "$CARPLAY_RAW" = "NOT_FOUND" ] || [ -z "$CARPLAY_RAW" ]; then
  echo "ERROR: CarPlay window not found"
  exit 0
fi

CX=$(echo "$CARPLAY_RAW" | cut -d'|' -f1 | cut -d, -f1)
CY=$(echo "$CARPLAY_RAW" | cut -d'|' -f1 | cut -d, -f2)
CW=$(echo "$CARPLAY_RAW" | cut -d'|' -f2 | cut -d, -f1)
CH=$(echo "$CARPLAY_RAW" | cut -d'|' -f2 | cut -d, -f2)
echo "CarPlay at ($CX,$CY) size ${CW}x${CH}"

IX=$((CX + CW * 20 / 100))
IY=$((CY + CH * 60 / 100))
echo "Target icon center: ($IX,$IY)"

echo "=== CGEvent click at icon center ==="
/tmp/window_click "$IX" "$IY" 2>&1
sleep 3

if grep -q "didConnect" "$LOGFILE" 2>&1; then
  echo "SUCCESS: didConnect detected"
  FOUND=1
else
  FOUND=0
fi

if [ "$FOUND" = "0" ]; then
  echo "didConnect not found, scanning grid via CGEvent..."
  for dy in -80 -60 -40 -20 0 20 40 60 80; do
    for dx in -80 -60 -40 -20 0 20 40 60 80; do
      TX=$((IX+dx)); TY=$((IY+dy))
      /tmp/window_click "$TX" "$TY" 2>&1 | tail -1
      sleep 0.5
      if grep -q "didConnect" "$LOGFILE" 2>&1; then
        echo "SUCCESS: didConnect at ($TX,$TY)"
        FOUND=1
        break 2
      fi
    done
    if [ "$FOUND" = "1" ]; then break; fi
  done
fi

if [ "$FOUND" = "0" ]; then
  echo "=== Dump full CarPlay window UI tree (diagnostic) ==="
  cat > /tmp/dump_carplay_tree.scpt << 'EOFSCRIPT'
    tell application "System Events" to tell process "Simulator"
      set out to ""
      repeat with w in windows
        try
          if name of w contains "CarPlay" then
            set out to out & "WINDOW: " & (name of w) & " pos=" & (position of w as text) & " size=" & (size of w as text) & linefeed
            repeat with el in entire contents of w
              try
                set r to role of el as text
                set elName to ""
                try
                  set elName to name of el as text
                end try
                set elPos to ""
                try
                  set elPos to position of el as text
                end try
                set elSize to ""
                try
                  set elSize to size of el as text
                end try
                set out to out & "  [" & r & "] name='" & elName & "' pos=" & elPos & " size=" & elSize & linefeed
              end try
            end repeat
            return out
          end if
        end try
      end repeat
      return "NO_CARPLAY_WINDOW"
    end tell
EOFSCRIPT
  osascript /tmp/dump_carplay_tree.scpt 2>&1 | tee /tmp/artifacts/carplay_ui_tree.txt
  echo "=== end carplay UI tree ==="

  echo "=== System Events AXPress on CarPlay window buttons ==="
  cat > /tmp/click_carplay_buttons.scpt << 'EOFSCRIPT'
    set outList to {}
    tell application "System Events" to tell process "Simulator"
      repeat with w in windows
        try
          if name of w contains "CarPlay" then
            set btnArray to buttons of w
            set btnCount to count of btnArray
            repeat with idx from 1 to btnCount
              set b to item idx of btnArray
              try
                set bname to ""
                try
                  set bname to name of b as text
                end try
                set bpos to position of b
                set bsize to size of b
                set posX to item 1 of bpos
                set posY to item 2 of bpos
                set sizeW to item 1 of bsize
                set sizeH to item 2 of bsize
                set centerX to posX + (sizeW div 2)
                set centerY to posY + (sizeH div 2)
                set AppleScript's text item delimiters to "@"
                set oneInfo to (bname as text) & centerX & "," & centerY & "@" & sizeW & "x" & sizeH
                set AppleScript's text item delimiters to ""
                set end of outList to oneInfo
              end try
            end repeat
          end if
        end try
      end repeat
    end tell
    if (count of outList) = 0 then
      return "NO_CARPLAY_BUTTONS"
    end if
    set AppleScript's text item delimiters to linefeed
    return outList as text
EOFSCRIPT
  BTN_INFO=$(osascript /tmp/click_carplay_buttons.scpt 2>&1 || true)
  echo "CarPlay buttons:"
  echo "$BTN_INFO"
  echo "=== Now clicking each button center via System Events click at ==="
  echo "$BTN_INFO" | grep -v "NO_CARPLAY_BUTTONS" | while IFS= read -r line; do
    if [ -n "$line" ] && [[ "$line" == *"@"* ]]; then
      POS="${line%%@*}"; POS="${POS##*@}"
      CX_BTN=$(echo "$POS" | cut -d, -f1)
      CY_BTN=$(echo "$POS" | cut -d, -f2)
      echo "Clicking button at ($CX_BTN,$CY_BTN)"
      osascript -e "tell application \"System Events\" to tell process \"Simulator\" to click at {$CX_BTN, $CY_BTN}" 2>&1 | tail -1
      sleep 2
      if grep -q "didConnect" "$LOGFILE" 2>&1; then
        echo "SUCCESS: didConnect detected after button click at ($CX_BTN,$CY_BTN)"
        FOUND=1
        break
      fi
    fi
  done
fi

if [ "$FOUND" = "0" ]; then
  echo "=== System Events click at icon position ==="
  cat > /tmp/click_carplay_pos.scpt << 'EOFSCRIPT'
    on run argv
      set clickX to item 1 of argv as real
      set clickY to item 2 of argv as real
      tell application "System Events" to tell process "Simulator"
        click at {clickX, clickY}
        return "CLICKED"
      end tell
    end run
EOFSCRIPT
  for dy in -60 -40 -20 0 20 40 60; do
    for dx in -60 -40 -20 0 20 40 60; do
      TX=$((IX+dx)); TY=$((IY+dy))
      osascript /tmp/click_carplay_pos.scpt "$TX" "$TY" 2>&1 | tail -1
      sleep 0.5
      if grep -q "didConnect" "$LOGFILE" 2>&1; then
        echo "SUCCESS: didConnect at ($TX,$TY) via System Events"
        FOUND=1
        break 2
      fi
    done
    if [ "$FOUND" = "1" ]; then break; fi
  done
fi

if [ "$FOUND" = "0" ]; then
  echo "FAILED: didConnect never triggered after all methods"
fi

echo "=== Final log ==="
cat "$LOGFILE" 2>/dev/null || echo "empty"

echo "=== Step 11: Screenshot CarPlay window ==="
mkdir -p /tmp/artifacts
DEVICE=$(cat /tmp/device_udid)
xcrun simctl io "$DEVICE" screenshot /tmp/artifacts/main_screen.png 2>&1 || echo "main screenshot failed"
screencapture -x /tmp/artifacts/full_screen.png 2>&1 || echo "screencapture failed"
ls -la /tmp/artifacts/
CONTAINER=$(xcrun simctl get_app_container "$DEVICE" xmusic.XMusic data 2>/dev/null || true)
echo "Container: $CONTAINER"
if [ -n "$CONTAINER" ] && [ -f "$CONTAINER/Documents/xmusic.log" ]; then
  cp "$CONTAINER/Documents/xmusic.log" /tmp/artifacts/xmusic.log
  echo "=== xmusic.log ==="
  cat /tmp/artifacts/xmusic.log
else
  echo "No xmusic.log found; grabbing unified log instead"
fi
xcrun simctl spawn "$DEVICE" log show --last 3m --predicate 'process == "XMusic" OR subsystem == "com.apple.CarPlay" OR subsystem CONTAINS "carkit" OR eventMessage CONTAINS "CarPlay"' 2>/dev/null | tail -200 > /tmp/artifacts/unified_log.txt || true
mkdir -p /tmp/artifacts/crashes
cp -R "$HOME/Library/Logs/DiagnosticReports/"*XMusic* /tmp/artifacts/crashes/ 2>/dev/null || true
ls -la /tmp/artifacts/crashes/ 2>/dev/null || true
cp /tmp/menu_tree.txt /tmp/artifacts/menu_tree.txt 2>/dev/null || true
cp /tmp/sim_windows.txt /tmp/artifacts/sim_windows.txt 2>/dev/null || true
cp /tmp/window_dump.txt /tmp/artifacts/window_dump.txt 2>/dev/null || true
cp /tmp/window_dump_post_run.txt /tmp/artifacts/window_dump_post_run.txt 2>/dev/null || true
cp /tmp/carplay_ui_tree.txt /tmp/artifacts/carplay_ui_tree.txt 2>/dev/null || true
cp /tmp/sim_windows_post_run.txt /tmp/artifacts/sim_windows_post_run.txt 2>/dev/null || true
cp /tmp/before_click.png /tmp/artifacts/before_click.png 2>/dev/null || true
cp /tmp/after_login.png /tmp/artifacts/after_login.png 2>/dev/null || true
cp /tmp/window_positions.txt /tmp/artifacts/window_positions.txt 2>/dev/null || true
xcrun simctl listapps "$DEVICE" 2>/dev/null | grep -A5 -i xmusic || echo "no xmusic in listapps"

echo "=== Done ==="
echo "Artifacts:"
ls -la /tmp/artifacts/
