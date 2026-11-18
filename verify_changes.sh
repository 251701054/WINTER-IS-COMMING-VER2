#!/usr/bin/env bash
# verify_changes.sh — checks that all 11 changes from the coordinator are present in WinterIsComing.swift

FILE="WinterIsComing.swift"
PASS=0
FAIL=0

check() {
    local desc="$1"
    local pattern="$2"
    if grep -qF "$pattern" "$FILE"; then
        echo "✅ PASS: $desc"
        PASS=$((PASS+1))
    else
        echo "❌ FAIL: $desc"
        echo "   Expected to find: $pattern"
        FAIL=$((FAIL+1))
    fi
}

echo "=== WinterIsComing.swift change verification ==="
echo ""

# CHANGE 1: New types
check "CHANGE 1a: SnowmanKind enum" "enum SnowmanKind: String, CaseIterable"
check "CHANGE 1b: SnowmanExpression enum" "enum SnowmanExpression: String, CaseIterable"
check "CHANGE 1c: SnowmanAccessory enum" "enum SnowmanAccessory: String, CaseIterable"
check "CHANGE 1d: SnowmanAppearance struct" "struct SnowmanAppearance: Equatable"
check "CHANGE 1e: SnowmanAppearance.random()" "static func random() -> SnowmanAppearance"
check "CHANGE 1f: WindRegime enum" "enum WindRegime: String, CaseIterable"
check "CHANGE 1g: WindRegime amplitudeScale" "var amplitudeScale: CGFloat"
check "CHANGE 1h: WindRegime verticalLiftFactor" "var verticalLiftFactor: CGFloat"

# CHANGE 2: snowmanAppearance property on Snowball
check "CHANGE 2: snowmanAppearance on Snowball" "var snowmanAppearance: SnowmanAppearance?"

# CHANGE 3: wind state properties on SnowScene
check "CHANGE 3a: windRegime property" "var windRegime: WindRegime = .moderateWind"
check "CHANGE 3b: windTimer property" "var windTimer: CGFloat = 10"
check "CHANGE 3c: currentWindScale property" "var currentWindScale: CGFloat = 1.0"
check "CHANGE 3d: targetWindLift property" "var targetWindLift: CGFloat = 0.0"

# CHANGE 4: removeDecor clears snowmanAppearance
check "CHANGE 4: removeDecor clears snowmanAppearance" "x.snowmanAppearance = nil"

# CHANGE 5: trimBalls checks snowmanAppearance
check "CHANGE 5: trimBalls checks snowmanAppearance" "snowmanAppearance == nil && \$0 !== activeBall"

# CHANGE 6: stepBalls clears snowmanAppearance when falling
check "CHANGE 6: stepBalls clears snowmanAppearance" "b.snowmanAppearance = nil"

# CHANGE 7: new makeSnowman and helpers
check "CHANGE 7a: new makeSnowman signature" "func makeSnowman(_ st: [Snowball])"
check "CHANGE 7b: buildSnowmanHeadDecor" "func buildSnowmanHeadDecor(radius R: CGFloat, appearance: SnowmanAppearance) -> SKNode"
check "CHANGE 7c: buildSnowmanBodyDecor" "func buildSnowmanBodyDecor(radius B: CGFloat, appearance: SnowmanAppearance) -> SKNode"
check "CHANGE 7d: SnowmanAppearance.random() called" "let appearance = SnowmanAppearance.random()"
check "CHANGE 7e: baseBall marker added" "let baseMarker = SKNode()"

# CHANGE 8: stepWind function
check "CHANGE 8: stepWind function defined" "func stepWind(_ dt: CGFloat) -> (wind: CGFloat, lift: CGFloat)"
check "CHANGE 8b: windTimer -= dt" "windTimer -= dt"
check "CHANGE 8c: gustRipple calculation" "let gustRipple ="

# CHANGE 9: stepFlakes uses stepWind
check "CHANGE 9a: stepFlakes calls stepWind" "let (wind, windLift) = stepWind(dt)"
check "CHANGE 9b: gustSlowdown used" "let gustSlowdown = 1.0 -"

# CHANGE 10: reconcileDisplays sets isPaused
check "CHANGE 10: reconcileDisplays sets isPaused = true" "display.view.isPaused = true"

# CHANGE 11: togglePause sets isPaused = true
check "CHANGE 11: togglePause sets isPaused on pause" "display.view.isPaused = true"

echo ""
echo "=== Framework check (no audio frameworks) ==="
if otool -L WinterIsComing 2>/dev/null | grep -qiE "AVFoundation|AudioToolbox|CoreAudio"; then
    echo "❌ FAIL: Audio framework found in binary"
    FAIL=$((FAIL+1))
else
    echo "✅ PASS: No audio frameworks linked"
    PASS=$((PASS+1))
fi

echo ""
echo "=== Binary exists ==="
if [ -f "WinterIsComing" ] && [ -x "WinterIsComing" ]; then
    echo "✅ PASS: WinterIsComing binary exists and is executable"
    PASS=$((PASS+1))
else
    echo "❌ FAIL: WinterIsComing binary missing or not executable"
    FAIL=$((FAIL+1))
fi

if [ -f "WinterIsComing.app/Contents/MacOS/WinterIsComing" ]; then
    echo "✅ PASS: App bundle binary updated"
    PASS=$((PASS+1))
else
    echo "❌ FAIL: App bundle binary not updated"
    FAIL=$((FAIL+1))
fi

echo ""
echo "=== Summary ==="
echo "Passed: $PASS / $((PASS+FAIL))"
if [ $FAIL -eq 0 ]; then
    echo "🎉 All checks passed!"
    exit 0
else
    echo "⚠️  $FAIL check(s) failed."
    exit 1
fi
