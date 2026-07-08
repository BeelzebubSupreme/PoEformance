; CameraZoomProbe.ahk — RE aid (READ-ONLY, writes NOTHING to the game)
; Dumps the float layout of the game CameraStructure (WorldData+0xA0) so the
; in-game camera zoom / FoV / distance field can be located. This is the first,
; SAFE step toward an in-game zoom feature: the tool is read-only today, and the
; actual zoom (a memory write) is deliberately NOT built until this probe pins
; the correct offset in-game — a wrong write can crash the game.
;
; How to use: get in-game, click "🎥 Probe Camera". Read the log. If PoE2 exposes
; any zoom, change it and re-run to see which float moved. Otherwise look for an
; FoV / camera-distance-looking value among the "<<" candidate rows.
;
; Bridge: CameraZoomProbeRun. Writes logs\InGameStateMonitor.camera_probe.log.

CameraZoomProbeRun()
{
    global g_reader
    if !(IsObject(g_reader) && g_reader.HasOwnProp("Mem") && g_reader.Mem && g_reader.Mem.Handle)
    {
        MsgBox("Reader not ready / game not connected.", "Camera Probe")
        return
    }

    inGs := 0
    try inGs := g_reader._radarInGameStateCache
    if !(inGs && inGs > 0x10000)
    {
        MsgBox("No in-game state — get in-game first.", "Camera Probe")
        return
    }

    worldData := 0
    try worldData := g_reader.Mem.ReadPtr(inGs + PoE2Offsets.InGameState["WorldData"])
    if !(worldData && worldData > 0x10000)
    {
        MsgBox("WorldData pointer invalid (InGameState+0x"
            Format("{:X}", PoE2Offsets.InGameState["WorldData"]) ").", "Camera Probe")
        return
    }

    camPtr := 0
    try camPtr := g_reader.Mem.ReadPtr(worldData + PoE2Offsets.WorldData["CameraStructure"])
    if !(camPtr && camPtr > 0x10000)
    {
        MsgBox("CameraStructure pointer invalid (WorldData+0x"
            Format("{:X}", PoE2Offsets.WorldData["CameraStructure"]) ").", "Camera Probe")
        return
    }

    ; The W2S matrix lives at CameraStructure + (0x1A0 - 0xA0) = 0x100; mark that
    ; 0x40-byte region so we don't mistake matrix cells for a zoom float.
    matOff := PoE2Offsets.WorldData["W2SMatrix"] - PoE2Offsets.WorldData["CameraStructure"]
    nl := "`n"

    out := "Camera Probe (READ-ONLY)" nl "========================" nl
        . "CameraStructure : " Format("0x{:X}", camPtr) nl
        . "W2S matrix at    : CameraStructure+0x" Format("{:X}", matOff) " (0x40 bytes — skip)" nl nl
        . "offset    float           int          notes" nl
        . "------    -----           ---          -----" nl

    off := 0
    while (off <= 0x1FC)
    {
        fv := 0.0, iv := 0
        try fv := g_reader.Mem.ReadFloat(camPtr + off)
        try iv := g_reader.Mem.ReadInt(camPtr + off)
        inMat := (off >= matOff && off < matOff + 0x40)
        tag := inMat ? "  [matrix]" : ""
        ; A plausible zoom / FoV / distance float: positive, sane magnitude, and
        ; not part of the matrix. Real candidates usually sit in ~0.1..few-thousand.
        if (!inMat && fv > 0.05 && fv < 10000.0)
            tag .= "  << candidate"
        out .= Format("0x{:03X}", off) "    " Format("{:13.4f}", fv) "    " Format("{:11}", iv) tag nl
        off += 4
    }

    logPath := A_ScriptDir "\logs\InGameStateMonitor.camera_probe.log"
    try FileAppend(FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") nl out nl, logPath)

    MsgBox("Camera structure dumped to:`nlogs\InGameStateMonitor.camera_probe.log`n`n"
        . "CameraStructure: " Format("0x{:X}", camPtr) "`n`n"
        . "Next: if PoE2 has any zoom, change it and re-run to see which float moved; "
        . "else look at the '<< candidate' rows for an FoV / camera-distance value. "
        . "[matrix] rows are the W2S matrix — skip them.", "Camera Probe")
}
