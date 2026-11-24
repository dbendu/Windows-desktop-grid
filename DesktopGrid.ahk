#Requires AutoHotkey v2.0
#SingleInstance Force
#UseHook
Persistent

; Сетка виртуальных рабочих столов Windows.
; Столы нумеруются по строкам: строка 1 = столы 1..COLS, строка 2 = следующие COLS и т.д.
;
;   Ctrl+Win+стрелки        — перейти на соседний стол в сетке
;   Ctrl+Win+Shift+стрелки  — перенести активное окно на соседний стол и перейти туда
;   Win+Tab                 — окно-сетка:
;       клик по столу            — перейти на него
;       клик по окну             — перейти к этому окну
;       перетаскивание окна      — перенести окно на другой стол
;       Shift+клик / Shift+Enter — перейти вместе с окном, которое было активным
;       стрелки + Enter          — выбор с клавиатуры
;       Tab                      — открыть стандартный Task View
;       Esc                      — закрыть (во время перетаскивания — отменить его)
;
; После изменения настроек: правый клик по значку в трее -> Reload Script.

; ================== Настройки ==================
ROWS        := 3        ; строк в сетке
COLS        := 8        ; столбцов в сетке
SHOW_OSD    := true     ; показывать мини-карту сетки при переключении клавишами
OSD_MS      := 1000     ; сколько миллисекунд показывать мини-карту
OSD_CELL    := 14       ; размер клетки мини-карты в пикселях (при масштабе 100%)
GRID_HOTKEY := "#Tab"   ; клавиша окна-сетки ("" — не перехватывать)
; ===============================================

TOTAL := ROWS * COLS
A_IconTip := "DesktopGrid " ROWS "×" COLS

dllPath := A_ScriptDir "\VirtualDesktopAccessor.dll"
hVDA := DllCall("LoadLibrary", "Str", dllPath, "Ptr")
if !hVDA {
    MsgBox("Не удалось загрузить:`n" dllPath, "DesktopGrid", "Iconx")
    ExitApp
}

pGetCount   := Proc("GetDesktopCount")
pGetCurrent := Proc("GetCurrentDesktopNumber")
pGoTo       := Proc("GoToDesktopNumber")
pMoveWin    := Proc("MoveWindowToDesktopNumber")
pCreate     := Proc("CreateDesktop")
pWinDesk    := Proc("GetWindowDesktopNumber")
pIsPinned   := Proc("IsPinnedWindow")
pGetName    := Proc("GetDesktopName")

; Состояние окна-сетки
osd := {gui: 0, pic: 0, hbm: 0, w: 0, h: 0, cs: 0, gap: 0, pad: 0}
grid := {open: false, backdrop: 0, panel: 0, pic: 0, dib: 0, fonts: 0, accent: 0, L: 0, data: [], rows: [], cur: 0, sel: 0, hoverHwnd: 0, prevHwnd: 0, drag: 0, skip: 0}

; Отладка: отрисовать сетку в BMP и выйти (--snapshot файл.bmp [--drag])
if (A_Args.Length >= 2 && A_Args[1] = "--snapshot") {
    Snapshot(A_Args[2], A_Args.Length >= 3 && A_Args[3] = "--drag")
    ExitApp
}

EnsureDesktops()

if (GRID_HOTKEY != "")
    Hotkey("$" GRID_HOTKEY, (*) => ToggleGrid())

OnMessage(0x0006, OnGridActivate)     ; WM_ACTIVATE
OnMessage(0x0200, OnGridMouseMove)    ; WM_MOUSEMOVE
OnMessage(0x0201, OnGridLButtonDown)  ; WM_LBUTTONDOWN
OnMessage(0x0202, OnGridLButtonUp)    ; WM_LBUTTONUP
OnMessage(0x0215, OnGridCaptureLost)  ; WM_CAPTURECHANGED

^#Left::   Go(0, -1)
^#Right::  Go(0, 1)
^#Up::     Go(-1, 0)
^#Down::   Go(1, 0)

^#+Left::  Go(0, -1, true)
^#+Right:: Go(0, 1, true)
^#+Up::    Go(-1, 0, true)
^#+Down::  Go(1, 0, true)

#HotIf GridActive()
Left::         MoveSel(0, -1)
Right::        MoveSel(0, 1)
Up::           MoveSel(-1, 0)
Down::         MoveSel(1, 0)
Enter::        Pick(grid.sel)
NumpadEnter::  Pick(grid.sel)
+Enter::       Pick(grid.sel, true)
+NumpadEnter:: Pick(grid.sel, true)
Tab::          OpenNativeTaskView()
Esc::          EscPressed()
#HotIf

; ============================================================
; Работа со столами
; ============================================================

Proc(name) {
    p := DllCall("GetProcAddress", "Ptr", hVDA, "AStr", name, "Ptr")
    if !p {
        MsgBox("В VirtualDesktopAccessor.dll нет функции " name, "DesktopGrid", "Iconx")
        ExitApp
    }
    return p
}

; Досоздаёт недостающие столы, чтобы заполнить сетку. Лишние не трогает.
EnsureDesktops() {
    loop TOTAL {
        if DllCall(pGetCount, "Int") >= TOTAL
            break
        if DllCall(pCreate, "Int") < 0
            break
    }
}

Go(dr, dc, carryWindow := false) {
    Critical   ; быстрые повторные нажатия — строго по очереди
    if grid.open
        CloseGrid()
    cur := DllCall(pGetCurrent, "Int")
    if cur < 0
        return

    if cur >= TOTAL {
        ; Стол за пределами сетки (если столов больше, чем ROWS*COLS) — возвращаемся в последнюю клетку.
        target := TOTAL - 1
    } else {
        r := cur // COLS + dr
        c := Mod(cur, COLS) + dc
        if (r < 0 || r >= ROWS || c < 0 || c >= COLS) {
            ShowOSD(cur)   ; край сетки: никуда не переходим
            return
        }
        target := r * COLS + c
    }

    EnsureDesktops()

    hwnd := 0
    if carryWindow {
        hwnd := WinExist("A")
        if (hwnd && !IsShellWindow(hwnd)) {
            FocusDesktopWindow()   ; иначе после переноса активного окна Windows станет искать ему замену
            DllCall(pMoveWin, "Ptr", hwnd, "Int", target, "Int")
        } else {
            hwnd := 0
        }
    }

    SwitchTo(target, hwnd)
    ShowOSD(target)
}

; Переход на стол n и активация окна на нём (focusHwnd, иначе верхнего окна стола).
;
; Почему так сложно. Если переключить стол из скрипта, пока активно обычное окно, Windows сама
; пытается активировать окно на новом столе, ей не хватает прав, и она подсвечивает кнопки окон
; на панели задач (а скрытая панель при этом выезжает). Активировать окно другого стола заранее
; тоже нельзя — Windows и тогда подсвечивает его кнопку. Поэтому:
;   1) перед переходом фокус отдаётся рабочему столу (Progman) — он есть на всех столах,
;      и Windows после переключения ничего сама не активирует;
;   2) после перехода ждём, пока нужное окно станет видимым, и активируем его сами,
;      если за это время не перешли на другой стол.
; Поток помечен Critical, чтобы быстрые повторные нажатия выполнялись строго по очереди.
SwitchTo(n, focusHwnd := 0) {
    wasCritical := A_IsCritical
    Critical
    FocusDesktopWindow()
    if (DllCall(pGetCurrent, "Int") != n)
        DllCall(pGoTo, "Int", n, "Int")
    if !focusHwnd
        focusHwnd := ForemostWindow(n)
    if focusHwnd {
        loop 60 {   ; до ~600 мс, пока идёт анимация переключения
            if !IsCloaked(focusHwnd)
                break
            Sleep(10)
        }
        if (DllCall(pGetCurrent, "Int") = n && !IsCloaked(focusHwnd))
            ActivateWindow(focusHwnd)
    }
    Critical(wasCritical)
}

; Фокус — рабочему столу. Он есть на всех столах и, в отличие от панели задач, не выезжает.
FocusDesktopWindow() {
    ActivateWindow(WinExist("ahk_class Progman"))
}

IsCloaked(hwnd) {
    c := 0
    DllCall("dwmapi\DwmGetWindowAttribute", "Ptr", hwnd, "UInt", 14, "UInt*", &c, "UInt", 4)   ; DWMWA_CLOAKED
    return c != 0
}

; Активирует окно без подсветки кнопки на панели задач. Если просто вызвать активацию из
; фоновой программы, Windows отклоняет первую попытку и подсвечивает кнопку окна. Поэтому
; сначала подключаемся к потоку текущего активного окна — тогда активация проходит сразу.
ActivateWindow(hwnd) {
    if !hwnd
        return
    try {
        if (WinGetMinMax("ahk_id " hwnd) = -1)
            DllCall("ShowWindow", "Ptr", hwnd, "Int", 9)   ; SW_RESTORE
    }
    me := DllCall("GetCurrentThreadId", "UInt")
    fg := DllCall("GetForegroundWindow", "Ptr")
    fgT := fg ? DllCall("GetWindowThreadProcessId", "Ptr", fg, "Ptr", 0, "UInt") : 0
    att := (fgT && fgT != me) ? DllCall("AttachThreadInput", "UInt", me, "UInt", fgT, "Int", 1) : 0
    DllCall("SetForegroundWindow", "Ptr", hwnd)
    DllCall("BringWindowToTop", "Ptr", hwnd)
    if att
        DllCall("AttachThreadInput", "UInt", me, "UInt", fgT, "Int", 0)
    if (DllCall("GetForegroundWindow", "Ptr") != hwnd)
        try WinActivate("ahk_id " hwnd)   ; запасной путь
}

ForemostWindow(n) {
    DetectHiddenWindows(true)
    for hwnd in WinGetList() {   ; WinGetList возвращает окна сверху вниз по Z-порядку
        try {
            if (IsTaskWindow(hwnd) && WinGetMinMax(hwnd) != -1 && DllCall(pWinDesk, "Ptr", hwnd, "Int") = n)
                return hwnd
        }
    }
    return 0
}

IsShellWindow(hwnd) {
    try cls := WinGetClass(hwnd)
    catch
        return true
    return cls = "Progman" || cls = "WorkerW" || cls = "Shell_TrayWnd" || cls = "Shell_SecondaryTrayWnd"
}

; Мини-карта: небольшое окно по центру экрана, не забирает фокус и пропускает клики.
; Окно создаётся один раз. Окна-подсказки (ToolWindow) Windows не привязывает к рабочему столу,
; поэтому при переходе оно остаётся на экране, и его достаточно перерисовать на месте —
; без закрытия и повторного показа, иначе при быстром листании столов оно мигает.
ShowOSD(idx) {
    if !SHOW_OSD
        return
    if !osd.gui
        CreateOSD()
    visible := DllCall("IsWindowVisible", "Ptr", osd.gui.Hwnd)
    DrawOSD(idx, visible)
    if !visible
        osd.gui.Show("NoActivate")
    SetTimer(HideOSD, -OSD_MS)
}

CreateOSD() {
    s := A_ScreenDPI / 96
    osd.cs := Round(OSD_CELL * s), osd.gap := Max(2, Round(OSD_CELL * s / 4)), osd.pad := Round(OSD_CELL * s * 0.8)
    osd.w := 2 * osd.pad + COLS * osd.cs + (COLS - 1) * osd.gap
    osd.h := 2 * osd.pad + ROWS * osd.cs + (ROWS - 1) * osd.gap
    osd.hbm := CreateDib(osd.w, osd.h)

    ; WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE
    g := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x08080020")
    g.MarginX := 0, g.MarginY := 0
    osd.pic := g.Add("Text", "x0 y0 w" osd.w " h" osd.h " 0xE")
    DllCall("SendMessageW", "Ptr", osd.pic.Hwnd, "UInt", 0x172, "Ptr", 0, "Ptr", osd.hbm, "Ptr")   ; STM_SETIMAGE
    DllCall("SetLayeredWindowAttributes", "Ptr", g.Hwnd, "UInt", 0, "UChar", 255, "UInt", 2)
    DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", g.Hwnd, "UInt", 33, "Int*", 2, "UInt", 4)   ; скруглённые углы
    g.Show("x" ((A_ScreenWidth - osd.w) // 2) " y" ((A_ScreenHeight - osd.h) // 2) " w" osd.w " h" osd.h " NoActivate Hide")
    osd.gui := g
}

; Рисует карту в картинку окна; если окно видно — сразу копирует её на экран (без мигания).
DrawOSD(idx, blit) {
    static osdBg := 0x202020, osdCell := 0x3C3C3C
    accent := AccentColor()
    cs := osd.cs, gap := osd.gap, pad := osd.pad
    hdc := DllCall("CreateCompatibleDC", "Ptr", 0, "Ptr")
    ob := DllCall("SelectObject", "Ptr", hdc, "Ptr", osd.hbm, "Ptr")
    FillRectC(hdc, 0, 0, osd.w, osd.h, osdBg)
    loop TOTAL {
        i := A_Index - 1
        x := pad + Mod(i, COLS) * (cs + gap)
        y := pad + (i // COLS) * (cs + gap)
        col := (i = idx) ? accent : osdCell
        RoundRectC(hdc, x, y, x + cs, y + cs, Max(2, Round(cs / 5)), col, col, 1)
    }
    if blit {
        wdc := DllCall("GetDC", "Ptr", osd.pic.Hwnd, "Ptr")
        DllCall("BitBlt", "Ptr", wdc, "Int", 0, "Int", 0, "Int", osd.w, "Int", osd.h, "Ptr", hdc, "Int", 0, "Int", 0, "UInt", 0x00CC0020)
        DllCall("ReleaseDC", "Ptr", osd.pic.Hwnd, "Ptr", wdc)
    }
    DllCall("SelectObject", "Ptr", hdc, "Ptr", ob)
    DllCall("DeleteDC", "Ptr", hdc)
}

HideOSD() {
    if osd.gui
        osd.gui.Hide()
}

; ============================================================
; Окно-сетка (Win+Tab)
; ============================================================

GridActive() {
    return grid.open && WinActive("ahk_id " grid.panel.Hwnd)
}

ToggleGrid() {
    if grid.open
        CloseGridRestore()
    else
        OpenGrid()
    KeyWait("Tab")   ; не реагировать на автоповтор при удержании
}

; OpenGrid, CloseGrid и Render не должны прерывать друг друга (иначе, например, сетка может
; закрыться посреди перерисовки), поэтому на время работы они помечают поток как Critical.
OpenGrid() {
    wasCritical := A_IsCritical
    Critical
    HideOSD()
    CloseStartMenu()   ; до запоминания активного окна: после закрытия Пуска фокус вернётся прежнему окну
    grid.prevHwnd := WinExist("A")
    grid.cur := DllCall(pGetCurrent, "Int")
    grid.sel := (grid.cur >= 0 && grid.cur < TOTAL) ? grid.cur : 0
    grid.hoverHwnd := 0
    grid.drag := 0
    grid.accent := AccentColor()
    grid.skip := Map()
    grid.data := CollectDesktops(grid.skip)

    ; Показываем на мониторе, где сейчас курсор
    CoordMode("Mouse", "Screen")
    MouseGetPos(&mx, &my)
    mon := MonitorGetPrimary()
    loop MonitorGetCount() {
        MonitorGet(A_Index, &x1, &y1, &x2, &y2)
        if (mx >= x1 && mx < x2 && my >= y1 && my < y2) {
            mon := A_Index
            break
        }
    }
    MonitorGet(mon, &ml, &mt, &mr, &mb)
    MonitorGetWorkArea(mon, &wl, &wt, &wr, &wb)
    grid.L := ComputeLayout(wr - wl, wb - wt)
    grid.fonts := MakeFonts(grid.L.s)
    pw := grid.L.W, ph := grid.L.H

    bd := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x80000")
    bd.BackColor := "000000"
    DllCall("SetLayeredWindowAttributes", "Ptr", bd.Hwnd, "UInt", 0, "UChar", 150, "UInt", 2)

    p := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +Owner" bd.Hwnd)
    p.BackColor := "202020"
    p.MarginX := 0, p.MarginY := 0
    pic := p.Add("Text", "x0 y0 w" pw " h" ph " 0xE")   ; SS_BITMAP — сюда кладём отрисованную картинку
    DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", p.Hwnd, "UInt", 33, "Int*", 2, "UInt", 4)   ; скруглённые углы

    grid.backdrop := bd, grid.panel := p, grid.pic := pic
    grid.dib := CreateDib(pw, ph)
    RenderInto(grid.dib)
    DllCall("SendMessageW", "Ptr", pic.Hwnd, "UInt", 0x172, "Ptr", 0, "Ptr", grid.dib, "Ptr")   ; STM_SETIMAGE
    grid.open := true
    bd.Show("x" ml " y" mt " w" (mr - ml) " h" (mb - mt) " NoActivate")
    p.Show("x" (wl + (wr - wl - pw) // 2) " y" (wt + (wb - wt - ph) // 2) " w" pw " h" ph)
    try WinActivate("ahk_id " p.Hwnd)
    SetTimer(RefreshGrid, 1000)
    Critical(wasCritical)
}

; Пуск (и поиск из него) живёт в отдельном слое поверх всех окон, включая «поверх всех»,
; и остался бы над сеткой. Закрываем его клавишей Esc и ждём, пока он действительно скроется.
CloseStartMenu() {
    if !StartMenuOpen()
        return
    Send("{Esc}")   ; Send сам временно отпускает зажатый Win, так что Пуск получит именно Esc
    loop 50 {       ; до ~500 мс
        Sleep(10)
        if !StartMenuOpen()
            break
    }
}

StartMenuOpen() {
    try {
        av := ComObject("{7E5FE3D9-985F-4908-91F9-EE19F9FD1514}", "{2246EA2D-CAEA-4444-A3C4-6DE827E44313}")   ; IAppVisibility
        vis := 0
        ComCall(4, av, "Int*", &vis)   ; IsLauncherVisible
        if vis
            return true
    }
    ; Запасной путь: активно видимое окно Пуска или поиска
    try {
        fg := WinExist("A")
        return fg && !IsCloaked(fg) && WinGetProcessName(fg) ~= "i)^(StartMenuExperienceHost|SearchHost)\.exe$"
    }
    return false
}

CloseGrid(*) {
    wasCritical := A_IsCritical
    Critical
    if grid.open
        DestroyGrid()
    Critical(wasCritical)
}

DestroyGrid() {
    SetTimer(RefreshGrid, 0)
    grid.open := false
    grid.drag := 0
    if grid.pic {
        old := DllCall("SendMessageW", "Ptr", grid.pic.Hwnd, "UInt", 0x172, "Ptr", 0, "Ptr", 0, "Ptr")
        if (old && old != grid.dib)
            DllCall("DeleteObject", "Ptr", old)
    }
    try grid.panel.Destroy()
    try grid.backdrop.Destroy()
    if grid.dib
        DllCall("DeleteObject", "Ptr", grid.dib)
    if grid.fonts
        FreeFonts(grid.fonts)
    grid.panel := 0, grid.backdrop := 0, grid.pic := 0, grid.fonts := 0, grid.dib := 0
}

MoveSel(dr, dc) {
    r := grid.sel // COLS + dr
    c := Mod(grid.sel, COLS) + dc
    if (r < 0 || r >= ROWS || c < 0 || c >= COLS)
        return
    grid.sel := r * COLS + c
    Render()
}

; Перейти на стол i. carry — взять с собой окно, активное до открытия сетки.
; focusHwnd — окно, которое активировать после перехода.
Pick(i, carry := false, focusHwnd := 0) {
    prev := grid.prevHwnd
    DetectHiddenWindows(true)
    if (i < 0) {
        CloseGridRestore()
        return
    }
    ; Сначала фокус — рабочему столу, потом закрываем сетку. Иначе при закрытии Windows активирует
    ; окно текущего стола и после переключения перекинет обратно на него.
    FocusDesktopWindow()
    CloseGrid()
    EnsureDesktops()
    target := 0
    if (carry && prev && DllCall("IsWindow", "Ptr", prev) && !IsShellWindow(prev)) {
        DllCall(pMoveWin, "Ptr", prev, "Int", i, "Int")
        target := prev
    } else if focusHwnd {
        target := focusHwnd
    } else if (prev && DllCall(pWinDesk, "Ptr", prev, "Int") = i) {
        target := prev
    }
    SwitchTo(i, target)   ; без target активируется верхнее окно стола
}

; Закрыть сетку без перехода и вернуть фокус окну, активному до её открытия
CloseGridRestore() {
    prev := grid.prevHwnd
    CloseGrid()
    if (prev && DllCall("IsWindow", "Ptr", prev) && DllCall(pWinDesk, "Ptr", prev, "Int") = DllCall(pGetCurrent, "Int"))
        ActivateWindow(prev)
}

; Перенести окно на стол t прямо в открытой сетке
MoveWindowInGrid(row, t) {
    EnsureDesktops()
    DllCall(pMoveWin, "Ptr", row.hwnd, "Int", t, "Int")
    if (DllCall(pWinDesk, "Ptr", row.hwnd, "Int") != t)
        return false
    src := grid.data[row.desk + 1].wins
    for i, w in src {
        if (w.hwnd = row.hwnd) {
            src.RemoveAt(i)
            grid.data[t + 1].wins.InsertAt(1, w)
            break
        }
    }
    return true
}

OpenNativeTaskView() {
    CloseGrid()
    Sleep(80)
    Send("#{Tab}")   ; своё же нажатие наш хоткей не перехватит (#UseHook)
}

EscPressed() {
    if (IsObject(grid.drag) && grid.drag.active) {
        grid.drag := 0
        DllCall("ReleaseCapture")
        Render()
    } else {
        CloseGridRestore()
    }
}

; ---------------- Мышь ----------------

IsGridMsg(hwnd) {
    return grid.open && (hwnd = grid.panel.Hwnd || hwnd = grid.pic.Hwnd)
}

MsgPos(lParam, &x, &y) {
    x := lParam << 48 >> 48
    y := lParam << 32 >> 48
}

HitCell(x, y) {
    for i, c in grid.L.cells
        if (x >= c.l && x < c.r && y >= c.t && y < c.b)
            return i - 1
    return -1
}

HitRow(x, y) {
    for row in grid.rows
        if (x >= row.l && x < row.r && y >= row.t && y < row.b)
            return row
    return 0
}

OnGridActivate(wParam, lParam, msg, hwnd) {
    if (grid.open && hwnd = grid.panel.Hwnd && (wParam & 0xFFFF) = 0)
        SetTimer(CloseGrid, -1)   ; сетка потеряла фокус (клик мимо, Alt+Tab и т.п.)
}

OnGridLButtonDown(wParam, lParam, msg, hwnd) {
    if !IsGridMsg(hwnd)
        return
    MsgPos(lParam, &x, &y)
    grid.drag := {row: HitRow(x, y), x0: x, y0: y, mx: x, my: y, active: false, target: -1}
    DllCall("SetCapture", "Ptr", grid.panel.Hwnd)
}

OnGridMouseMove(wParam, lParam, msg, hwnd) {
    if !IsGridMsg(hwnd)
        return
    MsgPos(lParam, &x, &y)
    drag := grid.drag
    if IsObject(drag) {
        if (!drag.active && IsObject(drag.row)) {
            th := Round(5 * grid.L.s)
            if (Abs(x - drag.x0) > th || Abs(y - drag.y0) > th)
                drag.active := true
        }
        if drag.active {
            drag.mx := x, drag.my := y
            drag.target := HitCell(x, y)
            Render()
        }
        return
    }
    c := HitCell(x, y)
    row := HitRow(x, y)
    hv := IsObject(row) ? row.hwnd : 0
    if ((c >= 0 && c != grid.sel) || hv != grid.hoverHwnd) {
        if (c >= 0)
            grid.sel := c
        grid.hoverHwnd := hv
        Render()
    }
}

OnGridLButtonUp(wParam, lParam, msg, hwnd) {
    if (!IsGridMsg(hwnd) || !IsObject(grid.drag))
        return
    MsgPos(lParam, &x, &y)
    drag := grid.drag
    grid.drag := 0
    DllCall("ReleaseCapture")

    ; Если события движения мыши потерялись (очень быстрый жест), решаем по точке отпускания
    if (!drag.active && IsObject(drag.row)) {
        th := Round(5 * grid.L.s)
        if (Abs(x - drag.x0) > th || Abs(y - drag.y0) > th)
            drag.active := true
    }

    if drag.active {
        t := HitCell(x, y)
        if (t >= 0 && t != drag.row.desk)
            MoveWindowInGrid(drag.row, t)
        if (t >= 0)
            grid.sel := t
        Render()
        return
    }

    c := HitCell(x, y)
    if (c < 0)
        return
    shift := GetKeyState("Shift")
    if (IsObject(drag.row) && !shift)
        Pick(c, false, drag.row.hwnd)
    else
        Pick(c, shift)
}

OnGridCaptureLost(wParam, lParam, msg, hwnd) {
    if (grid.open && hwnd = grid.panel.Hwnd && IsObject(grid.drag)) {
        grid.drag := 0
        Render()
    }
}

; ---------------- Данные ----------------

; skip — Map, куда записать окна, которых в сетке не будет никогда (см. WindowDesk)
CollectDesktops(skip := 0) {
    count := Min(DllCall(pGetCount, "Int"), TOTAL)
    data := []
    loop TOTAL
        data.Push({name: (A_Index <= count ? DesktopName(A_Index - 1) : ""), wins: []})
    for w in TaskWindows() {
        d := WindowDesk(w.hwnd)
        if (d = -2 && skip)
            skip[w.hwnd] := true
        if (d < 0)
            continue
        w.icon := WindowIcon(w.hwnd)
        data[d + 1].wins.Push(w)
    }
    return data
}

; Пока сетка открыта, следим за окнами: новые появляются в начале списка своего стола, закрытые
; исчезают, заголовки обновляются. Уже показанные окна не переставляем, чтобы список не прыгал.
; Стол узнаём только у новых окон: этот запрос медленный (~2 мс на окно), а перебор окон быстрый.
RefreshGrid() {
    Critical
    if (!grid.open || IsObject(grid.drag))   ; пока нажата кнопка мыши, список не трогаем
        return
    shown := Map()
    for info in grid.data
        for w in info.wins
            shown[w.hwnd] := w
    alive := Map()
    added := []
    loop TOTAL
        added.Push([])
    changed := false
    for w in TaskWindows() {
        alive[w.hwnd] := true
        if shown.Has(w.hwnd) {
            old := shown[w.hwnd]
            if (old.title !== w.title)
                old.title := w.title, changed := true
            continue
        }
        if grid.skip.Has(w.hwnd)
            continue
        d := WindowDesk(w.hwnd)
        if (d = -2)
            grid.skip[w.hwnd] := true
        if (d < 0)
            continue   ; при -1 спросим ещё раз в следующий раз: только что созданное окно может быть ещё не привязано к столу
        w.icon := WindowIcon(w.hwnd)
        added[d + 1].Push(w)
        changed := true
    }
    for i, info in grid.data {
        wins := added[i]
        for w in info.wins {
            if alive.Has(w.hwnd)
                wins.Push(w)
            else
                changed := true
        }
        info.wins := wins
    }
    if changed {
        Render()
        UpdateHover()
    }
}

; После перестройки списков под курсором может оказаться другое окно — переносим на него подсветку
UpdateHover() {
    pt := Buffer(8)
    DllCall("GetCursorPos", "Ptr", pt)
    DllCall("ScreenToClient", "Ptr", grid.pic.Hwnd, "Ptr", pt)
    row := HitRow(NumGet(pt, 0, "Int"), NumGet(pt, 4, "Int"))
    hv := IsObject(row) ? row.hwnd : 0
    if (hv != grid.hoverHwnd) {
        grid.hoverHwnd := hv
        Render()
    }
}

; Окна для сетки сверху вниз по Z-порядку: [{hwnd, title}]
TaskWindows() {
    DetectHiddenWindows(true)
    list := []
    for hwnd in WinGetList() {
        try {
            if IsTaskWindow(hwnd)
                list.Push({hwnd: hwnd, title: WinGetTitle(hwnd)})
        }
    }
    return list
}

; Номер стола окна; -2 — окна в сетке не будет (закреплено на всех столах или его стол вне сетки);
; -1 — не удалось узнать
WindowDesk(hwnd) {
    if (DllCall(pIsPinned, "Ptr", hwnd, "Int") = 1)
        return -2
    d := DllCall(pWinDesk, "Ptr", hwnd, "Int")
    return d >= TOTAL ? -2 : (d < 0 ? -1 : d)
}

; Окна, которые показывались бы в Alt+Tab
IsTaskWindow(hwnd) {
    style := WinGetStyle(hwnd), ex := WinGetExStyle(hwnd)
    if !(style & 0x10000000)                 ; WS_VISIBLE
        return false
    if (ex & 0x08000000)                     ; WS_EX_NOACTIVATE
        return false
    appWin := ex & 0x40000                   ; WS_EX_APPWINDOW
    if (!appWin && (ex & 0x80))              ; WS_EX_TOOLWINDOW
        return false
    if (!appWin && DllCall("GetWindow", "Ptr", hwnd, "UInt", 4, "Ptr"))   ; есть владелец
        return false
    cloaked := 0
    DllCall("dwmapi\DwmGetWindowAttribute", "Ptr", hwnd, "UInt", 14, "UInt*", &cloaked, "UInt", 4)
    if (cloaked & 1)                         ; DWM_CLOAKED_APP — «призрачные» окна UWP
        return false
    if (WinGetTitle(hwnd) = "")
        return false
    return !IsShellWindow(hwnd)
}

WindowIcon(hwnd) {
    for t in [2, 0, 1] {   ; ICON_SMALL2, ICON_SMALL, ICON_BIG
        r := 0
        if (DllCall("SendMessageTimeoutW", "Ptr", hwnd, "UInt", 0x7F, "Ptr", t, "Ptr", 0, "UInt", 2, "UInt", 50, "Ptr*", &r) && r)
            return r
    }
    if (h := DllCall("GetClassLongPtrW", "Ptr", hwnd, "Int", -34, "Ptr"))   ; GCLP_HICONSM
        return h
    if (h := DllCall("GetClassLongPtrW", "Ptr", hwnd, "Int", -14, "Ptr"))   ; GCLP_HICON
        return h
    return ExeIcon(hwnd)
}

ExeIcon(hwnd) {
    static cache := Map()
    static defIcon := DllCall("LoadIconW", "Ptr", 0, "Ptr", 32512, "Ptr")   ; IDI_APPLICATION
    try path := WinGetProcessPath(hwnd)
    catch
        return defIcon
    if cache.Has(path)
        return cache[path]
    h := 0
    DllCall("shell32\ExtractIconExW", "Str", path, "Int", 0, "Ptr", 0, "Ptr*", &h, "UInt", 1)
    cache[path] := h ? h : defIcon
    return cache[path]
}

DesktopName(i) {
    buf := Buffer(512, 0)
    DllCall(pGetName, "Int", i, "Ptr", buf, "Ptr", buf.Size, "Int")
    return StrGet(buf, "UTF-8")
}

AccentColor() {
    ; Светлый оттенок акцентного цвета Windows (хорошо читается на тёмном фоне)
    try {
        hex := RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent", "AccentPalette")
        return (Integer("0x" SubStr(hex, 9, 2)) << 16) | (Integer("0x" SubStr(hex, 11, 2)) << 8) | Integer("0x" SubStr(hex, 13, 2))
    }
    return 0x4CC2FF
}

; ---------------- Раскладка и отрисовка ----------------

ComputeLayout(aw, ah) {
    s := A_ScreenDPI / 96
    L := {s: s}
    L.pad := Round(20 * s), L.gap := Round(10 * s), L.inner := Round(10 * s)
    L.headH := Round(32 * s), L.rowH := Round(24 * s), L.footH := Round(30 * s), L.ico := Round(16 * s)
    L.cw := Min(Round(240 * s), Floor((aw * 0.96 - 2 * L.pad - (COLS - 1) * L.gap) / COLS))
    want := L.headH + 8 * L.rowH + Round(8 * s)
    L.ch := Min(want, Floor((ah * 0.94 - 2 * L.pad - L.footH - (ROWS - 1) * L.gap) / ROWS))
    L.rows := Max(0, Floor((L.ch - L.headH - Round(6 * s)) / L.rowH))
    L.W := 2 * L.pad + COLS * L.cw + (COLS - 1) * L.gap
    L.footTop := L.pad + ROWS * L.ch + (ROWS - 1) * L.gap
    L.H := L.footTop + L.footH + L.pad
    L.cells := []
    loop TOTAL {
        i := A_Index - 1
        x := L.pad + Mod(i, COLS) * (L.cw + L.gap)
        y := L.pad + (i // COLS) * (L.ch + L.gap)
        L.cells.Push({l: x, t: y, r: x + L.cw, b: y + L.ch})
    }
    return L
}

MakeFonts(s) {
    return {head: MakeFont(Round(15 * s), 600), row: MakeFont(Round(13 * s), 400), foot: MakeFont(Round(12.5 * s), 400)}
}

MakeFont(px, weight) {
    return DllCall("CreateFontW", "Int", -px, "Int", 0, "Int", 0, "Int", 0, "Int", weight
        , "UInt", 0, "UInt", 0, "UInt", 0, "UInt", 1, "UInt", 0, "UInt", 0, "UInt", 5, "UInt", 0
        , "Str", "Segoe UI", "Ptr")
}

FreeFonts(f) {
    for name, h in f.OwnProps()
        DllCall("DeleteObject", "Ptr", h)
}

; Перерисовка: рисуем в ту же картинку, что уже стоит в контроле, и сразу копируем на экран.
; (Если каждый раз ставить контролу новую картинку, он сначала заливает себя фоном — отсюда мигание.)
Render() {
    wasCritical := A_IsCritical
    Critical
    if grid.open
        RenderInto(grid.dib, grid.pic.Hwnd)
    Critical(wasCritical)
}

; 24-битный DIB без альфа-канала: с 32-битным static-контрол смешивает картинку с фоном по альфе,
; и всё, что нарисовано GDI (альфа = 0), становится прозрачным — видны только иконки.
CreateDib(w, h) {
    bi := Buffer(40, 0)
    NumPut("UInt", 40, "Int", w, "Int", -h, "UShort", 1, "UShort", 24, bi)
    pBits := 0
    return DllCall("CreateDIBSection", "Ptr", 0, "Ptr", bi, "UInt", 0, "Ptr*", &pBits, "Ptr", 0, "UInt", 0, "Ptr")
}

; Рисует сетку в hbm. Если задан blitHwnd — сразу копирует результат в это окно: так картинка
; обновляется без перерисовки фона, а значит без мигания.
RenderInto(hbm, blitHwnd := 0) {
    L := grid.L, f := grid.fonts, s := L.s, accent := grid.accent
    hdc := DllCall("CreateCompatibleDC", "Ptr", 0, "Ptr")
    oldBm := DllCall("SelectObject", "Ptr", hdc, "Ptr", hbm, "Ptr")
    oldF := DllCall("SelectObject", "Ptr", hdc, "Ptr", f.head, "Ptr")
    DllCall("SetBkMode", "Ptr", hdc, "Int", 1)   ; TRANSPARENT

    FillRectC(hdc, 0, 0, L.W, L.H, 0x202020)

    drag := grid.drag
    dragging := IsObject(drag) && drag.active
    rows := []

    for i, c in L.cells {
        d := i - 1
        info := grid.data[i]
        isCur := (d = grid.cur)
        isSel := dragging ? (d = drag.target && d != drag.row.desk) : (d = grid.sel)
        fill := isSel ? 0x353535 : 0x2A2A2A
        border := isSel ? accent : (isCur ? 0x6A6A6A : 0x2A2A2A)
        RoundRectC(hdc, c.l, c.t, c.r, c.b, Round(8 * s), fill, border, isSel ? Max(2, Round(2 * s)) : 1)

        ; Заголовок: номер стола (+ имя, если задано). Текущий стол отмечен акцентной полоской.
        DllCall("SelectObject", "Ptr", hdc, "Ptr", f.head)
        hx := c.l + L.inner
        if isCur {
            FillRectC(hdc, hx, c.t + Round(10 * s), hx + Round(3 * s), c.t + L.headH - Round(8 * s), accent)
            hx += Round(9 * s)
        }
        label := (d + 1) (info.name != "" ? "   " info.name : "")
        TextC(hdc, label, hx, c.t + Round(2 * s), c.r - L.inner, c.t + L.headH, isCur ? 0xFFFFFF : 0xBDBDBD)

        ; Окна этого стола
        DllCall("SelectObject", "Ptr", hdc, "Ptr", f.row)
        n := info.wins.Length
        y := c.t + L.headH
        x1 := c.l + L.inner, x2 := c.r - L.inner
        if (n = 0) {
            TextC(hdc, "пусто", x1, y, x2, y + L.rowH, 0x6A6A6A)
            continue
        }
        shown := (n > L.rows) ? Max(L.rows - 1, 0) : n
        loop shown {
            w := info.wins[A_Index]
            rl := c.l + Round(4 * s), rr := c.r - Round(4 * s)
            isDragged := dragging && w.hwnd = drag.row.hwnd
            if (!dragging && w.hwnd = grid.hoverHwnd)
                RoundRectC(hdc, rl, y, rr, y + L.rowH, Round(4 * s), 0x464646, 0x464646, 1)
            if !isDragged
                DrawIcon(hdc, w.icon, x1, y + (L.rowH - L.ico) // 2, L.ico)
            TextC(hdc, w.title, x1 + L.ico + Round(7 * s), y, x2, y + L.rowH, isDragged ? 0x6A6A6A : 0xDADADA)
            rows.Push({l: rl, t: y, r: rr, b: y + L.rowH, desk: d, hwnd: w.hwnd, title: w.title, icon: w.icon})
            y += L.rowH
        }
        if (n > shown)
            TextC(hdc, "+ ещё " (n - shown), x1, y, x2, y + L.rowH, 0x8A8A8A)
    }

    ; Подсказка внизу
    DllCall("SelectObject", "Ptr", hdc, "Ptr", f.foot)
    if dragging
        hint := "Отпустите над нужным столом — окно переедет туда   ·   Esc — отмена"
    else
        hint := "Клик — перейти   ·   Перетащите окно на другой стол, чтобы перенести его   ·   Shift+клик — перейти вместе с активным окном   ·   Стрелки + Enter   ·   Tab — стандартный вид   ·   Esc — закрыть"
    TextC(hdc, hint, L.pad, L.footTop, L.W - L.pad, L.footTop + L.footH, 0x9A9A9A, 0x8825)

    ; «Призрак» перетаскиваемого окна под курсором
    if dragging {
        gw := L.cw - Round(8 * s), gh := L.rowH + Round(8 * s)
        gx := drag.mx - (drag.x0 - drag.row.l)
        gy := drag.my - (drag.y0 - drag.row.t) - Round(4 * s)
        DllCall("SelectObject", "Ptr", hdc, "Ptr", f.row)
        RoundRectC(hdc, gx, gy, gx + gw, gy + gh, Round(6 * s), 0x4A4A4A, accent, Max(2, Round(2 * s)))
        DrawIcon(hdc, drag.row.icon, gx + Round(8 * s), gy + (gh - L.ico) // 2, L.ico)
        TextC(hdc, drag.row.title, gx + Round(15 * s) + L.ico, gy, gx + gw - Round(8 * s), gy + gh, 0xFFFFFF)
    }

    if blitHwnd {
        wdc := DllCall("GetDC", "Ptr", blitHwnd, "Ptr")
        DllCall("BitBlt", "Ptr", wdc, "Int", 0, "Int", 0, "Int", L.W, "Int", L.H, "Ptr", hdc, "Int", 0, "Int", 0, "UInt", 0x00CC0020)   ; SRCCOPY
        DllCall("ReleaseDC", "Ptr", blitHwnd, "Ptr", wdc)
    }
    DllCall("SelectObject", "Ptr", hdc, "Ptr", oldF)
    DllCall("SelectObject", "Ptr", hdc, "Ptr", oldBm)
    DllCall("DeleteDC", "Ptr", hdc)
    grid.rows := rows
}

BGR(rgb) {
    return ((rgb & 0xFF) << 16) | (rgb & 0xFF00) | ((rgb >> 16) & 0xFF)
}

RectBuf(l, t, r, b) {
    rc := Buffer(16)
    NumPut("Int", l, "Int", t, "Int", r, "Int", b, rc)
    return rc
}

FillRectC(hdc, l, t, r, b, rgb) {
    br := DllCall("CreateSolidBrush", "UInt", BGR(rgb), "Ptr")
    DllCall("FillRect", "Ptr", hdc, "Ptr", RectBuf(l, t, r, b), "Ptr", br)
    DllCall("DeleteObject", "Ptr", br)
}

RoundRectC(hdc, l, t, r, b, radius, fillRgb, borderRgb, bw := 1) {
    pen := DllCall("CreatePen", "Int", 6, "Int", bw, "UInt", BGR(borderRgb), "Ptr")   ; PS_INSIDEFRAME
    br := DllCall("CreateSolidBrush", "UInt", BGR(fillRgb), "Ptr")
    op := DllCall("SelectObject", "Ptr", hdc, "Ptr", pen, "Ptr")
    ob := DllCall("SelectObject", "Ptr", hdc, "Ptr", br, "Ptr")
    DllCall("RoundRect", "Ptr", hdc, "Int", l, "Int", t, "Int", r, "Int", b, "Int", radius * 2, "Int", radius * 2)
    DllCall("SelectObject", "Ptr", hdc, "Ptr", op)
    DllCall("SelectObject", "Ptr", hdc, "Ptr", ob)
    DllCall("DeleteObject", "Ptr", pen)
    DllCall("DeleteObject", "Ptr", br)
}

TextC(hdc, str, l, t, r, b, rgb, flags := 0x8824) {   ; SINGLELINE | VCENTER | END_ELLIPSIS | NOPREFIX
    DllCall("SetTextColor", "Ptr", hdc, "UInt", BGR(rgb))
    DllCall("DrawTextW", "Ptr", hdc, "Str", str, "Int", -1, "Ptr", RectBuf(l, t, r, b), "UInt", flags)
}

DrawIcon(hdc, hIcon, x, y, size) {
    if hIcon
        DllCall("DrawIconEx", "Ptr", hdc, "Int", x, "Int", y, "Ptr", hIcon, "Int", size, "Int", size, "UInt", 0, "Ptr", 0, "UInt", 3)
}

; ---------------- Отладка ----------------

Snapshot(path, simulateDrag := false) {
    grid.cur := DllCall(pGetCurrent, "Int")
    grid.sel := Mod(grid.cur + 1, TOTAL)
    grid.accent := AccentColor()
    grid.data := CollectDesktops()
    MonitorGetWorkArea(MonitorGetPrimary(), &x1, &y1, &x2, &y2)
    grid.L := ComputeLayout(x2 - x1, y2 - y1)
    grid.fonts := MakeFonts(grid.L.s)
    hbm := CreateDib(grid.L.W, grid.L.H)
    RenderInto(hbm)
    if (simulateDrag && grid.rows.Length) {
        row := grid.rows[1]
        t := Mod(row.desk + 1, TOTAL)
        c := grid.L.cells[t + 1]
        grid.drag := {row: row, x0: row.l + 30, y0: row.t + 10, mx: c.l + 60, my: c.t + 70, active: true, target: t}
        RenderInto(hbm)
    }
    SaveBmp(hbm, path)
    DllCall("DeleteObject", "Ptr", hbm)
    FreeFonts(grid.fonts)
}

SaveBmp(hbm, path) {
    w := grid.L.W, h := grid.L.H, size := w * h * 4
    bi := Buffer(40, 0)
    NumPut("UInt", 40, "Int", w, "Int", -h, "UShort", 1, "UShort", 32, bi)   ; BITMAPINFOHEADER, сверху вниз
    bits := Buffer(size)
    hdc := DllCall("GetDC", "Ptr", 0, "Ptr")
    DllCall("GetDIBits", "Ptr", hdc, "Ptr", hbm, "UInt", 0, "UInt", h, "Ptr", bits, "Ptr", bi, "UInt", 0)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdc)
    f := FileOpen(path, "w")
    f.WriteUShort(0x4D42), f.WriteUInt(54 + size), f.WriteUInt(0), f.WriteUInt(54)
    f.RawWrite(bi, 40)
    f.RawWrite(bits, size)
    f.Close()
}
