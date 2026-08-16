#!/bin/bash
# park.sh — 把模拟器手机竖屏窗口移离开 CarPlay 宽屏窗口，并把 CarPlay 窗口置顶(AX)
# 用法: park.sh <carplay_x> <carplay_y> <carplay_w> <carplay_h>
# 目标: 手机窗口(约302x668)移到屏幕左下(20,120)，CarPlay 窗口 AXRaise 置顶。
CXX=$1; CYY=$2; CWW=$3; CHH=$4

osascript -e '
  tell application "Simulator" to activate
  delay 1
  tell application "System Events" to tell process "Simulator"
    set out to ""
    set moved to false
    repeat with w in windows
      try
        if (name of w) contains "CarPlay" then
          perform action "AXRaise" of w
          set out to out & "raised-CarPlay;" & linefeed
        else if (size of w) is not missing value then
          set s to size of w
          if (item 1 of s) < (item 2 of s) then
            set position of w to {20, 120}
            set moved to true
            set out to out & "moved-phone;" & linefeed
          end if
        end if
      end try
    end repeat
    return out & "moved:" & moved
  end tell' 2>&1 | tail -3

exit 0